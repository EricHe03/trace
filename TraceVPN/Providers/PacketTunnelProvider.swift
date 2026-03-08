//
//  PacketTunnelProvider.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/10.
//

import Darwin
import Foundation
import Network
import NetworkExtension
import OSLog
import TraceCore
import TraceProxy
import TraceSecurity

// MARK: - Architecture Overview

// Rationale: Use VPN proxy settings to route HTTP/HTTPS traffic to the local MITM proxy;
// non-proxy and non-HTTP traffic is not captured in this mode.

/// Defines errors specific to packet tunnel provider operations.
enum PacketTunnelProviderError: LocalizedError {
    /// Indicates the provider was deallocated during startup.
    case providerUnavailable

    /// Indicates VPN network settings could not be applied.
    case networkSettingsFailed(underlying: Error)
    /// Indicates the shared App Group container/defaults are unavailable.
    case appGroupUnavailable(appGroupID: String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            "Packet tunnel provider unavailable"
        case let .networkSettingsFailed(underlying):
            "Failed to apply network settings: \(underlying.localizedDescription)"
        case let .appGroupUnavailable(appGroupID):
            "App Group is unavailable: \(appGroupID)"
        }
    }
}

/// Defines errors that occur when decoding messages from the main app.
enum AppMessageError: LocalizedError {
    /// Indicates the message data is not a JSON dictionary.
    case invalidFormat

    /// Indicates the command string is not recognized.
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "App message is not a dictionary"
        case let .unknownCommand(command):
            "Unknown app message command: \(command)"
        }
    }
}

/// Defines commands that the main app can send to the VPN extension via IPC.
///
/// The VPN extension runs in a separate process, so all communication
/// happens through `NEPacketTunnelProvider.handleAppMessage(_:completionHandler:)`.
enum AppCommand: String {
    case getHardeningConfig
    case getRootCAFingerprint
    case updateConfig
    case updateCaptureConfig
    case updateHardeningConfig
    case updateThrottlingState
    case clearRequests
}

/// Represents a decoded message from the main app with a command and payload.
///
/// - Note: Payload values are untyped `Any` because they come from JSON IPC, so
///   each handler must validate and downcast what it needs.
struct AppMessage {
    let command: AppCommand
    let payload: [String: Any]
}

/// Manages VPN-based traffic capture in the network extension.
///
/// Discussion: This class runs in a separate process (Network Extension) from the main app.
/// It creates a VPN tunnel interface and configures the system to route HTTP/HTTPS
/// traffic through a local MITM proxy server (`MITMProxyServer`).
///
/// Key responsibilities:
/// - Configure VPN network settings (proxy-only mode, no packet routing)
/// - Start/stop the local MITM proxy server
/// - Manage root CA certificate lifecycle
/// - Handle IPC messages from the main app for configuration updates
/// - Coordinate network throttling, QUIC blocking, and raw packet capture
///
/// Thread safety:
/// - This class is `@unchecked Sendable` to satisfy Swift concurrency checks.
/// - Uses `actor` types (`TunnelLifecycle`, `PacketTunnelRuntimeState`) for safe concurrency.
/// - Background tasks (`certificateCleanupTask`, etc.) are isolated to avoid races.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let extensionStartTime = Date()

    /// Serializes tunnel lifecycle across concurrent NE callbacks.
    let lifecycle = TunnelLifecycle()

    /// Encapsulates mutable runtime state (proxy server, raw capture, throttling).
    let runtimeState = PacketTunnelRuntimeState()
    let captureRuntimeController = CaptureRuntimeController()
    let completionQueue = DispatchQueue(label: "com.trace.vpn.completion")
    let eventLogQueue = DispatchQueue(label: "com.trace.vpn.eventlog")
    let addressResolutionQueue = DispatchQueue(label: "com.trace.vpn.address_resolution", qos: .utility)
    let addressResolutionLock = NSLock()
    var addressResolutionCache: [String: (ipv4: [String], ipv6: [String])] = [:]

    /// NDJSON event log writer (shared App Group file).
    ///
    /// Note: We keep a direct reference so lifecycle callbacks (like stop/cancel) can
    /// force-drain and close the file before the extension exits.
    var eventLogWriter: NDJSONLogWriter?

    // MARK: - Background Tasks

    var certificateCleanupTask: Task<Void, Never>?
    var metricsTask: Task<Void, Never>?
    var heartbeatTask: Task<Void, Never>?

    // MARK: - Network Configuration

    let proxyPort: UInt16 = 8888
    let proxyHost = "127.0.0.1"
    let tunnelLocalAddress = "198.18.0.2" // Device's tunnel IP
    let tunnelRemoteAddress = "198.18.0.1" // Gateway (hev-socks5-tunnel)
    let tunnelSubnetMask = "255.255.255.0"
    let fullTunnelMTU: Int = 1400
    let localSocks5Host = "127.0.0.1"
    // Bind embedded SOCKS5 on an ephemeral port to avoid collisions with existing local listeners.
    let localSocks5Port: UInt16 = 0
    let transparentMITMPorts: Set<UInt16> = [80, 443]
    var currentCaptureMode: CaptureMode = .proxyOnly

    // MARK: - Diagnostics

    struct MemorySnapshot: Sendable {
        let physFootprintBytes: UInt64
        let residentBytes: UInt64
    }

    /// Returns best-effort memory footprint for the extension process.
    static func currentMemorySnapshot() -> MemorySnapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)

        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPtr, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return nil }
        return MemorySnapshot(
            physFootprintBytes: UInt64(info.phys_footprint),
            residentBytes: UInt64(info.resident_size)
        )
    }

    // MARK: - Tunnel Lifecycle

    /// Starts the VPN tunnel when the system activates the VPN.
    ///
    /// Discussion: The tunnel runs in proxy-only mode, which injects `NEProxySettings`
    /// instead of routing packets. This avoids TUN/TAP packet forwarding while still
    /// capturing HTTP/HTTPS for apps that honor proxy settings.
    ///
    /// - Important: iOS may call `startTunnel` concurrently; each invocation must
    ///   call its completion handler exactly once, or iOS may watchdog-terminate
    ///   the extension.
    ///
    /// - Parameters:
    ///   - options: Optional metadata from the main app (currently unused)
    ///   - completionHandler: Must be called exactly once when startup completes or fails
    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let invocationID = UUID().uuidString
        let startWall = Date()

        // Rule: Call the completion handler exactly once per invocation.
        // Note: iOS may invoke `startTunnel` concurrently. We dedupe the underlying start work,
        // but still complete each invocation's completion handler.
        let completionBox = CompletionHandlerBox(completionHandler)
        let completion = StartTunnelCompletion(
            invocationID: invocationID,
            startWall: startWall,
            handler: completionBox,
            queue: completionQueue
        )

        VPNLog.tunnel.info("event=vpn.tunnel_start_begin id=\(invocationID, privacy: .public)")

        Task { [weak self] in
            guard let self else {
                await completion.complete(PacketTunnelProviderError.providerUnavailable)
                return
            }

            do {
                try await self.lifecycle.start(invocationID: invocationID) { [weak self] in
                    guard let self else { throw PacketTunnelProviderError.providerUnavailable }
                    await self.runtimeState.setStopping(false)
                    try await self.performStart(invocationID: invocationID)
                }
                await completion.complete(nil)
            } catch {
                await completion.complete(error)
            }
        }
    }

    private func performStart(invocationID: String) async throws {
        VPNLog.tunnel.debug(
            "event=vpn.tunnel_task_begin id=\(invocationID, privacy: .public)"
        )

        try validateSharedStorage()

        let captureConfig = AppGroupStorage.shared.loadConfiguration()
        self.currentCaptureMode = captureConfig.captureMode

        await HardeningConfig.shared.logCurrentConfig()

        await configureCaptureSettings(for: captureConfig.captureMode)
        await initializeEventLog(mode: captureConfig.captureMode)
        await logProtocolRoutingConfiguration()
        await runtimeState.appendEventLog(
            type: "capture_config",
            msg: "mode=\(captureConfig.captureMode.rawValue) enabled=\(captureConfig.isEnabled) filter_mode=\(captureConfig.filterMode.rawValue) domain_filters=\(captureConfig.domainFilters.count) capture_headers=\(captureConfig.captureHeaders) capture_body=\(captureConfig.captureBody) max_body_size=\(captureConfig.maxBodySize)"
        )
        let samplingConfig = AppGroupStorage.shared.loadSamplingConfig().normalized()
        await runtimeState.appendEventLog(
            type: "capture_sampling",
            msg: "enabled=\(samplingConfig.enabled) rate=\(samplingConfig.sampleRate) strategy=\(samplingConfig.strategy.rawValue)"
        )

        await preloadRootCertificate()

        do {
            VPNLog.proxy.info("event=vpn.proxy_start_begin port=\(self.proxyPort)")
            try await startProxyServer()
            await applyProxyIngressMode(for: captureConfig)
            VPNLog.proxy.info("event=vpn.proxy_start outcome=success port=\(self.proxyPort)")
        } catch {
            VPNLog.proxy.error(
                "event=vpn.proxy_start outcome=failure port=\(self.proxyPort) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }

        do {
            // Rule: Apply proxy settings only after the proxy is listening, to avoid
            // transient "connection refused" from clients during tunnel startup.
            try await configureNetworkSettings(using: captureConfig)
            VPNLog.tunnel.info("event=vpn.network_settings outcome=success")
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.network_settings outcome=failure error=\(String(describing: error), privacy: .public)"
            )
            await runtimeState.stopProxyServer()
            throw error
        }

        let rawCaptureEnabled = await HardeningConfig.shared.enableRawCapture
        let rawCaptureLimit = await HardeningConfig.shared.maxRawCaptureSize
        let dualMITMPolicyEngineShadow = await HardeningConfig.shared.dualMITMPolicyEngineShadow
        let dualMITMPolicyEngineEnforcedTCP = await HardeningConfig.shared.dualMITMPolicyEngineEnforcedTCP
        let dualMITMPolicyEngineEnforcedProxy = await HardeningConfig.shared.dualMITMPolicyEngineEnforcedProxy
        let dualMITMPolicyEngineEnforcedQUIC = await HardeningConfig.shared.dualMITMPolicyEngineEnforcedQUIC
        let dualMITMMITMEngineV2 = await HardeningConfig.shared.dualMITMMITMEngineV2
        let dualMITMHttp2MITMEnabled = await HardeningConfig.shared.dualMITMHttp2MITMEnabled
        let dualMITMStrictEnforcementHardFail = await HardeningConfig.shared.dualMITMStrictEnforcementHardFail
        let packetCaptureWriter = createPacketCaptureWriterIfNeeded(
            enabled: rawCaptureEnabled && captureConfig.captureMode.usesPacketTunnelRouting
        )
        let flowConfig = PacketTunnelRuntimeState.PacketFlowConfig(
            packetFlow: self.packetFlow,
            mode: captureConfig.captureMode,
            mtu: self.fullTunnelMTU,
            captureEnabled: rawCaptureEnabled,
            captureLimit: rawCaptureLimit,
            writer: packetCaptureWriter,
            socks5Host: captureConfig.fullTunnelSocks5Host,
            socks5Port: captureConfig.fullTunnelSocks5Port,
            localSocks5Host: localSocks5Host,
            localSocks5Port: localSocks5Port,
            udpForwardingMode: captureConfig.fullTunnelUDPForwardingMode,
            ipv6Enabled: captureConfig.fullTunnelIPv6Enabled,
            tcpTransparentMITMEnabled: effectiveTransparentTCPMITMEnabled(for: captureConfig),
            tcpTransparentMITMPorts: transparentMITMPorts,
            mitmProxyHost: proxyHost,
            mitmProxyPort: proxyPort,
            dualMITMPolicy: captureConfig.dualMITMPolicy,
            tcpBypassTTLSeconds: captureConfig.tcpBypassTTLSeconds,
            quicHostFailOpenSeconds: captureConfig.quicHostFailOpenSeconds,
            dualMITMCircuitBreakerEnabled: captureConfig.dualMITMCircuitBreakerEnabled,
            quicNoProgressGraceMs: captureConfig.quicNoProgressGraceMs,
            quicNoProgressIdleMs: captureConfig.quicNoProgressIdleMs,
            quicNoProgressAbsoluteMs: captureConfig.quicNoProgressAbsoluteMs,
            quicNoProgressMinClientDatagrams: captureConfig.quicNoProgressMinClientDatagrams,
            quicAuthorityRetryAttempts: captureConfig.quicAuthorityRetryAttempts,
            quicCertMaterialCacheTTLSeconds: captureConfig.quicCertMaterialCacheTTLSeconds,
            dualMITMPolicyEngineShadowEnabled: dualMITMPolicyEngineShadow,
            dualMITMPolicyEngineEnforcedTCP: dualMITMPolicyEngineEnforcedTCP,
            dualMITMPolicyEngineEnforcedProxy: dualMITMPolicyEngineEnforcedProxy,
            dualMITMPolicyEngineEnforcedQUIC: dualMITMPolicyEngineEnforcedQUIC,
            dualMITMMITMEngineV2: dualMITMMITMEngineV2,
            dualMITMHttp2MITMEnabled: dualMITMHttp2MITMEnabled,
            dualMITMStrictEnforcementHardFail: dualMITMStrictEnforcementHardFail
        )
        await runtimeState.configurePacketFlow(flowConfig)

        startCertificateCleanupTask()

        if await HardeningConfig.shared.enableMetrics {
            startMetricsTask()
        }

        let debugLoggingEnabled = await HardeningConfig.shared.enableDebugLogging
        TLSLog.setVerboseEnabled(debugLoggingEnabled)
        if debugLoggingEnabled {
            startHeartbeatTask()
        }

        loadInitialThrottlingState()
    }

    private func logProtocolRoutingConfiguration() async {
        guard let protocolConfiguration = self.protocolConfiguration as? NETunnelProviderProtocol else {
            VPNLog.config.warning("event=vpn.protocol_routing outcome=skipped reason=invalid_protocol_configuration")
            return
        }

        let excludeCellularValue: String
        let excludeAPNsValue: String
        let excludeDeviceCommunicationValue: String

        if #available(iOS 16.4, macOS 13.3, *) {
            excludeCellularValue = protocolConfiguration.excludeCellularServices.description
            excludeAPNsValue = protocolConfiguration.excludeAPNs.description
        } else {
            excludeCellularValue = "n/a"
            excludeAPNsValue = "n/a"
        }

        if #available(iOS 17.4, macOS 14.4, *) {
            excludeDeviceCommunicationValue = protocolConfiguration.excludeDeviceCommunication.description
        } else {
            excludeDeviceCommunicationValue = "n/a"
        }

        VPNLog.config.info(
            "event=vpn.protocol_routing include_all=\(protocolConfiguration.includeAllNetworks) exclude_local=\(protocolConfiguration.excludeLocalNetworks) exclude_cellular=\(excludeCellularValue, privacy: .public) exclude_apns=\(excludeAPNsValue, privacy: .public) exclude_device_comm=\(excludeDeviceCommunicationValue, privacy: .public)"
        )
        await runtimeState.appendEventLog(
            type: "protocol_routing",
            msg: "include_all=\(protocolConfiguration.includeAllNetworks) exclude_local=\(protocolConfiguration.excludeLocalNetworks) exclude_cellular=\(excludeCellularValue) exclude_apns=\(excludeAPNsValue) exclude_device_comm=\(excludeDeviceCommunicationValue)"
        )
    }

    private func validateSharedStorage() throws {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        let appGroupID = AppGroupConfiguration.appGroupIdentifier
        guard !appGroupID.isEmpty else {
            throw PacketTunnelProviderError.appGroupUnavailable(appGroupID: appGroupID)
        }

        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil else {
            throw PacketTunnelProviderError.appGroupUnavailable(appGroupID: appGroupID)
        }

        guard UserDefaults(suiteName: appGroupID) != nil else {
            throw PacketTunnelProviderError.appGroupUnavailable(appGroupID: appGroupID)
        }
    }

    /// Stops the VPN tunnel when the system deactivates the VPN.
    ///
    /// - Important: Cleanup runs in a detached task so the completion handler does
    ///   not block on long-running shutdown work.
    ///
    /// - Parameters:
    ///   - reason: Why the tunnel was stopped (user action, system policy, error, etc.)
    ///   - completionHandler: Must be called when shutdown is complete
    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let reasonName = String(describing: reason)
        let stopEvent = LogEvent.vpnTunnel("stop_begin")
            .with("reason_code", value: reason.rawValue)
            .with("reason", value: reasonName)
        VPNLog.tunnel.info("\(stopEvent)")

        // Best-effort: synchronously persist the stop reason before any async cleanup.
        let stopMem = Self.currentMemorySnapshot()
        eventLogQueue.sync {
            eventLogWriter?.appendSync(
                type: "vpn_stop_begin",
                msg: "reason=\(reasonName) reason_code=\(reason.rawValue) phys=\(stopMem?.physFootprintBytes ?? 0) resident=\(stopMem?.residentBytes ?? 0)"
            )
        }

        certificateCleanupTask?.cancel()
        certificateCleanupTask = nil
        metricsTask?.cancel()
        metricsTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let stopCompletionBox = CompletionHandlerBox<Void> { _ in completionHandler() }
        let stopCompletion = CompletionOnce(handler: stopCompletionBox, queue: completionQueue)
        Task { [weak self] in
            guard let self else { return }
            await self.lifecycle.stop { [weak self] in
                guard let self else { return }
                await self.runtimeState.setStopping(true)
                let connectionCount = await self.runtimeState.proxyConnectionCount()
                let mem = Self.currentMemorySnapshot()
                await self.runtimeState.appendEventLog(
                    type: "vpn_stop",
                    msg: "reason=\(reasonName) reason_code=\(reason.rawValue) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
                await self.runtimeState.stopPacketFlow()
                await self.runtimeState.stopProxyServer()
                await self.runtimeState.closeEventLog()
                self.eventLogQueue.sync {
                    self.eventLogWriter = nil
                }
            }

            VPNLog.tunnel.info(
                LogEvent.vpnTunnel("stop")
                    .success()
                    .with("reason_code", value: reason.rawValue)
                    .with("reason", value: reasonName)
            )
            await stopCompletion.call()
        }
    }

    deinit {
        let uptime = Date().timeIntervalSince(extensionStartTime)
        VPNLog.tunnel.info("event=vpn.tunnel_deinit uptime_seconds=\(Int(uptime)) reason=deallocated")
    }

    /// Called when the system is about to terminate the extension.
    override func cancelTunnelWithError(_ error: Error?) {
        let uptime = Date().timeIntervalSince(extensionStartTime)
        let mem = Self.currentMemorySnapshot()
        if let error {
            VPNLog.tunnel.error("event=vpn.tunnel_cancel_with_error uptime_seconds=\(Int(uptime)) error=\(String(describing: error), privacy: .public)")

            // Best-effort: synchronously persist cancellation details, since the system may
            // terminate the extension immediately after this callback returns.
            eventLogQueue.sync {
                eventLogWriter?.appendSync(
                    type: "vpn_cancel",
                    msg: "error=\(String(describing: error)) uptime_seconds=\(Int(uptime)) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
            }
            Task {
                let connectionCount = await runtimeState.proxyConnectionCount()
                await runtimeState.appendEventLog(
                    type: "vpn_cancel",
                    msg: "error=\(String(describing: error)) uptime_seconds=\(Int(uptime)) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
                await runtimeState.stopPacketFlow()
                eventLogQueue.sync {
                    eventLogWriter?.close()
                    eventLogWriter = nil
                }
                await runtimeState.closeEventLog()
            }
        } else {
            VPNLog.tunnel.info("event=vpn.tunnel_cancel uptime_seconds=\(Int(uptime))")

            eventLogQueue.sync {
                eventLogWriter?.appendSync(
                    type: "vpn_cancel",
                    msg: "uptime_seconds=\(Int(uptime)) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
            }

            Task {
                let connectionCount = await runtimeState.proxyConnectionCount()
                await runtimeState.appendEventLog(
                    type: "vpn_cancel",
                    msg: "uptime_seconds=\(Int(uptime)) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
                await runtimeState.stopPacketFlow()
                eventLogQueue.sync {
                    eventLogWriter?.close()
                    eventLogWriter = nil
                }
                await runtimeState.closeEventLog()
            }
        }
        super.cancelTunnelWithError(error)
    }

    /// Handles IPC messages from the main app (config updates and queries).
    ///
    /// Discussion: The VPN extension runs in a separate process, so iOS
    /// provides `handleAppMessage` for bidirectional communication.
    ///
    /// - Parameters:
    ///   - messageData: JSON-encoded dictionary with "command" and optional payload
    ///   - completionHandler: Optional callback for responses (queries only)
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        do {
            let message = try decodeAppMessage(from: messageData)
            let completion = AppMessageCompletion(handler: completionHandler, queue: completionQueue)
            Task {
                await handleMessage(message, completionHandler: completion)
            }
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.app_message_decode outcome=failure error=\(String(describing: error), privacy: .public)"
            )
            AppMessageCompletion.call(handler: completionHandler, queue: completionQueue, data: nil)
        }
    }
}
