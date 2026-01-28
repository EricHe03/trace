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
    /// Indicates full-tunnel mode is missing SOCKS5 forwarding configuration.
    case missingSocks5Configuration

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            "Packet tunnel provider unavailable"
        case let .networkSettingsFailed(underlying):
            "Failed to apply network settings: \(underlying.localizedDescription)"
        case .missingSocks5Configuration:
            "Full-tunnel mode requires a SOCKS5 host and port"
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
/// - Uses `actor` types (`StartCompletionGate`, `PacketTunnelRuntimeState`) for safe concurrency.
/// - Background tasks (`certificateCleanupTask`, etc.) are isolated to avoid races.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let extensionStartTime = Date()

    /// Prevents duplicate `startTunnel` completion handler calls.
    private let startGate = StartCompletionGate()

    /// Encapsulates mutable runtime state (proxy server, raw capture, throttling).
    private let runtimeState = PacketTunnelRuntimeState()
    private let completionQueue = DispatchQueue(label: "com.trace.vpn.completion")

    /// NDJSON event log writer (shared App Group file).
    ///
    /// Note: We keep a direct reference so lifecycle callbacks (like stop/cancel) can
    /// force-drain and close the file before the extension exits.
    private var eventLogWriter: NDJSONLogWriter?

    // MARK: - Background Tasks

    private var certificateCleanupTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Network Configuration

    private let proxyPort: UInt16 = 8888
    private let proxyHost = "127.0.0.1"
    private let tunnelLocalAddress = "198.18.0.2" // Device's tunnel IP
    private let tunnelRemoteAddress = "198.18.0.1" // Gateway (hev-socks5-tunnel)
    private let tunnelSubnetMask = "255.255.255.0"
    private let fullTunnelMTU: Int = 1400
    private var currentCaptureMode: CaptureMode = .proxyOnly

    // MARK: - Diagnostics

    private struct MemorySnapshot: Sendable {
        let physFootprintBytes: UInt64
        let residentBytes: UInt64
    }

    /// Returns best-effort memory footprint for the extension process.
    private static func currentMemorySnapshot() -> MemorySnapshot? {
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
        // Note: We intentionally do not "dedupe" across invocations. Each `startTunnel` call
        // must invoke its own completion handler, or iOS will watchdog-terminate the extension.
        let completionBox = CompletionHandlerBox(completionHandler)
        let completion = StartTunnelCompletion(
            invocationID: invocationID,
            startWall: startWall,
            handler: completionBox,
            queue: completionQueue
        )

        VPNLog.tunnel.info("event=vpn.tunnel_start_begin id=\(invocationID, privacy: .public)")

        Task { [weak self, startGate, runtimeState] in
            await startGate.begin(invocationID: invocationID)
            await runtimeState.setStopping(false)

            // Safety: Exit early if the provider is deallocated during startup.
            guard let self else {
                await completion.complete(PacketTunnelProviderError.providerUnavailable)
                return
            }

            VPNLog.tunnel.debug(
                "event=vpn.tunnel_task_begin id=\(invocationID, privacy: .public)"
            )

            let captureConfig = AppGroupStorage.shared.loadConfiguration()
            self.currentCaptureMode = captureConfig.captureMode

            if captureConfig.captureMode == .fullTunnel {
                let host = captureConfig.fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
                if host.isEmpty || captureConfig.fullTunnelSocks5Port == 0 {
                    VPNLog.tunnel.error("event=vpn.full_tunnel_config outcome=failure reason=missing_socks5")
                    await completion.complete(PacketTunnelProviderError.missingSocks5Configuration)
                    return
                }
            }

            await HardeningConfig.shared.logCurrentConfig()

            await configureCaptureSettings()
            await initializeEventLog(mode: captureConfig.captureMode)

            await preloadRootCertificate()

            do {
                VPNLog.proxy.info("event=vpn.proxy_start_begin port=\(self.proxyPort)")
                try await startProxyServer()
                VPNLog.proxy.info("event=vpn.proxy_start outcome=success port=\(self.proxyPort)")
            } catch {
                VPNLog.proxy.error(
                    "event=vpn.proxy_start outcome=failure port=\(self.proxyPort) error=\(String(describing: error), privacy: .public)"
                )
                await completion.complete(error)
                return
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
                await completion.complete(error)
                return
            }

            let rawCaptureEnabled = await HardeningConfig.shared.enableRawCapture
            let rawCaptureLimit = await HardeningConfig.shared.maxRawCaptureSize
            let packetCaptureWriter = createPacketCaptureWriterIfNeeded(
                enabled: rawCaptureEnabled && captureConfig.captureMode == .fullTunnel
            )
            await runtimeState.configurePacketFlow(
                packetFlow: self.packetFlow,
                mode: captureConfig.captureMode,
                mtu: self.fullTunnelMTU,
                captureEnabled: rawCaptureEnabled,
                captureLimit: rawCaptureLimit,
                writer: packetCaptureWriter,
                socks5Host: captureConfig.fullTunnelSocks5Host,
                socks5Port: captureConfig.fullTunnelSocks5Port,
                udpForwardingMode: captureConfig.fullTunnelUDPForwardingMode,
                ipv6Enabled: captureConfig.fullTunnelIPv6Enabled
            )

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
            await completion.complete(nil)
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
        eventLogWriter?.appendSync(
            type: "vpn_stop_begin",
            msg: "reason=\(reasonName) reason_code=\(reason.rawValue) phys=\(stopMem?.physFootprintBytes ?? 0) resident=\(stopMem?.residentBytes ?? 0)"
        )

        certificateCleanupTask?.cancel()
        certificateCleanupTask = nil
        metricsTask?.cancel()
        metricsTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let stopCompletionBox = CompletionHandlerBox<Void> { _ in completionHandler() }
        let stopCompletion = CompletionOnce(handler: stopCompletionBox, queue: completionQueue)
        Task {
            await runtimeState.setStopping(true)
            let connectionCount = await runtimeState.proxyConnectionCount()
            let mem = Self.currentMemorySnapshot()
            await runtimeState.appendEventLog(
                type: "vpn_stop",
                msg: "reason=\(reasonName) reason_code=\(reason.rawValue) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
            )
            await runtimeState.stopPacketFlow()
            await runtimeState.stopProxyServer()
            await runtimeState.closeEventLog()
            self.eventLogWriter = nil
            await startGate.reset()

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
            eventLogWriter?.appendSync(
                type: "vpn_cancel",
                msg: "error=\(String(describing: error)) uptime_seconds=\(Int(uptime)) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
            )
            Task {
                let connectionCount = await runtimeState.proxyConnectionCount()
                await runtimeState.appendEventLog(
                    type: "vpn_cancel",
                    msg: "error=\(String(describing: error)) uptime_seconds=\(Int(uptime)) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
                await runtimeState.stopPacketFlow()
                eventLogWriter?.close()
                await runtimeState.closeEventLog()
                self.eventLogWriter = nil
            }
        } else {
            VPNLog.tunnel.info("event=vpn.tunnel_cancel uptime_seconds=\(Int(uptime))")

            eventLogWriter?.appendSync(
                type: "vpn_cancel",
                msg: "uptime_seconds=\(Int(uptime)) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
            )

            Task {
                let connectionCount = await runtimeState.proxyConnectionCount()
                await runtimeState.appendEventLog(
                    type: "vpn_cancel",
                    msg: "uptime_seconds=\(Int(uptime)) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
                await runtimeState.stopPacketFlow()
                eventLogWriter?.close()
                await runtimeState.closeEventLog()
                self.eventLogWriter = nil
            }
        }
        super.cancelTunnelWithError(error)
    }

    // MARK: - Background Tasks

    /// Prunes expired TLS certificate cache entries.
    ///
    /// Discussion: `TLSHandler` generates dynamic server certificates for MITM.
    /// This task removes expired entries to prevent unbounded memory growth.
    ///
    /// - Note: Runs every 5 minutes.
    private func startCertificateCleanupTask() {
        certificateCleanupTask?.cancel()
        certificateCleanupTask = Task {
            let interval = Duration.seconds(300)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                TLSHandler.clearExpiredCertificates()
            }
        }
    }

    /// Logs network metrics at a fixed interval.
    ///
    /// Discussion: This provides observability for diagnosing performance issues
    /// and only runs when `HardeningConfig.enableMetrics` is true.
    ///
    /// - Note: Runs every minute.
    private func startMetricsTask() {
        let runtimeState = runtimeState
        metricsTask?.cancel()
        metricsTask = Task {
            let interval = Duration.seconds(60)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                let metrics = await ProxyNetworkMetrics.shared.getAllMetrics()
                let summary = metrics.formatSummary()
                let summaryHash = LogRedaction.hash(summary)
                let connectionCount = await runtimeState.proxyConnectionCount()
                let mem = Self.currentMemorySnapshot()
                VPNLog.tunnel.debug(
                    "event=vpn.metrics_snapshot outcome=success summary_hash=\(summaryHash) summary_len=\(summary.count) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
                await runtimeState.appendEventLog(
                    type: "metrics",
                    msg: "summary_hash=\(summaryHash) summary_len=\(summary.count) connections=\(connectionCount) phys=\(mem?.physFootprintBytes ?? 0) resident=\(mem?.residentBytes ?? 0)"
                )
            }
        }
    }

    /// Logs tunnel heartbeat state at a fixed interval.
    ///
    /// Discussion: This helps diagnose tunnel state issues and only runs when
    /// `HardeningConfig.enableDebugLogging` is true.
    ///
    /// - Note: Runs every 30 seconds.
    private func startHeartbeatTask() {
        let runtimeState = runtimeState
        let startGate = startGate
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            let interval = Duration.seconds(30)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                let invocationID = await startGate.invocationID()
                let snapshot = await runtimeState.heartbeatSnapshot(invocationID: invocationID)
                let heartbeatEvent = LogEvent.vpnTunnel("heartbeat")
                    .with("id", value: snapshot.invocationID ?? "none")
                    .with("stopping", value: snapshot.isStopping)
                    .with("proxy_running", value: snapshot.proxyRunning)
                VPNLog.tunnel.debug("\(heartbeatEvent)")
            }
        }
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

    // MARK: - Network Setup

    /// Configures virtual network settings for proxy-only mode.
    ///
    /// Discussion: Proxy-only mode injects `NEProxySettings` without routing
    /// packets, which avoids TUN/TAP forwarding and NAT complexity.
    ///
    /// - Throws: `PacketTunnelProviderError.networkSettingsFailed` if system rejects settings
    private func configureNetworkSettings(using config: CaptureConfiguration) async throws {
        let modeLabel = config.captureMode == .fullTunnel ? "full_tunnel" : "proxy_only"
        VPNLog.config.debug("event=vpn.network_settings_begin mode=\(modeLabel, privacy: .public)")
        await runtimeState.appendEventLog(
            type: "network_settings",
            msg: "begin mode=\(modeLabel) dns_servers=\(config.fullTunnelDNSServers.count) ipv6=\(config.fullTunnelIPv6Enabled)"
        )

        let networkSettings = buildNetworkSettings(using: config)
        if config.captureMode == .fullTunnel {
            await runtimeState.appendEventLog(
                type: "dns_config",
                msg: "mode=full_tunnel servers=\(config.fullTunnelDNSServers.count) search_domains=\(config.fullTunnelSearchDomains.count)"
            )
        } else {
            await runtimeState.appendEventLog(type: "dns_config", msg: "mode=system_default")
        }

        VPNLog.config.info(
            "event=vpn.network_settings_configured mode=\(modeLabel, privacy: .public) proxy_host=\(self.proxyHost, privacy: .public) proxy_port=\(self.proxyPort)"
        )
        await runtimeState.appendEventLog(
            type: "network_settings",
            msg: "configured mode=\(modeLabel) proxy_host=\(self.proxyHost) proxy_port=\(self.proxyPort)"
        )

        VPNLog.config.debug("event=vpn.network_settings_apply mode=\(modeLabel, privacy: .public)")
        await runtimeState.appendEventLog(
            type: "network_settings",
            msg: "apply mode=\(modeLabel)"
        )

        do {
            try await applyTunnelNetworkSettings(networkSettings)
            await runtimeState.appendEventLog(
                type: "network_settings",
                msg: "outcome=success mode=\(modeLabel)"
            )
        } catch {
            await runtimeState.appendEventLog(
                type: "network_settings",
                msg: "outcome=failure mode=\(modeLabel) error=\(error.localizedDescription)"
            )
            throw PacketTunnelProviderError.networkSettingsFailed(underlying: error)
        }
    }

    /// Builds VPN network settings for proxy-only mode.
    ///
    /// - Returns: Configured network settings ready to apply to the system
    private func buildNetworkSettings(using config: CaptureConfiguration) -> NEPacketTunnelNetworkSettings {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

        switch config.captureMode {
        case .proxyOnly:
            // Rationale: Use system DNS settings because proxy-only mode does not intercept DNS.
            networkSettings.dnsSettings = nil
            VPNLog.config.debug("event=vpn.dns_config mode=system_default")

            // Rule: Do not route packets through the tunnel in proxy-only mode.
            let ipv4Settings = NEIPv4Settings(
                addresses: [tunnelLocalAddress],
                subnetMasks: [tunnelSubnetMask]
            )
            ipv4Settings.includedRoutes = []
            ipv4Settings.excludedRoutes = []
            networkSettings.ipv4Settings = ipv4Settings

            // Rationale: Disable IPv6 until proxy-only capture supports it.
            networkSettings.ipv6Settings = nil

        case .fullTunnel:
            if let dnsSettings = buildDNSSettings(using: config) {
                networkSettings.dnsSettings = dnsSettings
                VPNLog.config.debug("event=vpn.dns_config mode=full_tunnel servers=\(dnsSettings.servers.count)")
            } else {
                networkSettings.dnsSettings = nil
                VPNLog.config.debug("event=vpn.dns_config mode=full_tunnel servers=none")
            }

            let ipv4Settings = NEIPv4Settings(
                addresses: [tunnelLocalAddress],
                subnetMasks: [tunnelSubnetMask]
            )
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
            let excluded = buildExcludedRoutes(using: config)
            if !excluded.ipv4.isEmpty {
                ipv4Settings.excludedRoutes = excluded.ipv4
            }
            networkSettings.ipv4Settings = ipv4Settings

            if config.fullTunnelIPv6Enabled {
                let ipv6Settings = NEIPv6Settings(
                    addresses: ["fc00::1"],
                    networkPrefixLengths: [64]
                )
                ipv6Settings.includedRoutes = [NEIPv6Route.default()]
                if !excluded.ipv6.isEmpty {
                    ipv6Settings.excludedRoutes = excluded.ipv6
                }
                networkSettings.ipv6Settings = ipv6Settings
            } else {
                VPNLog.config.warning("event=vpn.ipv6_route_config outcome=skipped reason=disabled")
                networkSettings.ipv6Settings = nil
            }
        }

        // Rationale: HTTP/HTTPS proxy settings drive capture through the local MITM proxy.
        let proxy = NEProxySettings()
        proxy.httpEnabled = true
        proxy.httpsEnabled = true
        proxy.httpServer = NEProxyServer(address: proxyHost, port: Int(proxyPort))
        proxy.httpsServer = NEProxyServer(address: proxyHost, port: Int(proxyPort))
        proxy.excludeSimpleHostnames = false

        // Rule: Match all domains to force HTTP/HTTPS traffic through the proxy.
        proxy.matchDomains = [""]

        // Rule: Exclude local addresses to prevent proxy routing loops.
        proxy.exceptionList = [
            "localhost",
            "*.local",
            "127.0.0.1",
            "10.*",
            "172.16.*", "172.17.*", "172.18.*", "172.19.*",
            "172.20.*", "172.21.*", "172.22.*", "172.23.*",
            "172.24.*", "172.25.*", "172.26.*", "172.27.*",
            "172.28.*", "172.29.*", "172.30.*", "172.31.*",
            "192.168.*"
        ]

        networkSettings.proxySettings = proxy

        if config.captureMode == .fullTunnel {
            // Rationale: Full-tunnel encapsulation adds overhead; use a safer MTU to avoid fragmentation stalls.
            networkSettings.mtu = NSNumber(value: fullTunnelMTU)
        }

        return networkSettings
    }

    private func buildDNSSettings(using config: CaptureConfiguration) -> NEDNSSettings? {
        guard !config.fullTunnelDNSServers.isEmpty else { return nil }
        let dns = NEDNSSettings(servers: config.fullTunnelDNSServers)
        if !config.fullTunnelSearchDomains.isEmpty {
            dns.searchDomains = config.fullTunnelSearchDomains
        }
        return dns
    }

    private func buildExcludedRoutes(using config: CaptureConfiguration) -> (ipv4: [NEIPv4Route], ipv6: [NEIPv6Route]) {
        var ipv4Targets = Set<String>()
        var ipv6Targets = Set<String>()

        let socksHost = config.fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !socksHost.isEmpty {
            addExcludedHost(socksHost, ipv4: &ipv4Targets, ipv6: &ipv6Targets)
        }

        for server in config.fullTunnelDNSServers {
            let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            addExcludedHost(trimmed, ipv4: &ipv4Targets, ipv6: &ipv6Targets)
        }

        let ipv4Routes = ipv4Targets.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
        let ipv6Routes = ipv6Targets.map { NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128) }
        if !ipv4Routes.isEmpty || !ipv6Routes.isEmpty {
            VPNLog.config.debug("event=vpn.route_exclusions_configured ipv4=\(ipv4Routes.count) ipv6=\(ipv6Routes.count)")
        }
        return (ipv4: ipv4Routes, ipv6: ipv6Routes)
    }

    private func addExcludedHost(
        _ host: String,
        ipv4: inout Set<String>,
        ipv6: inout Set<String>
    ) {
        if IPv4Address(host) != nil {
            guard !isLoopbackIPv4(host) else { return }
            ipv4.insert(host)
            return
        }
        if IPv6Address(host) != nil {
            ipv6.insert(host)
            return
        }

        let resolved = resolveIPAddresses(for: host)
        ipv4.formUnion(resolved.ipv4.filter { !isLoopbackIPv4($0) })
        ipv6.formUnion(resolved.ipv6)
    }

    private func isLoopbackIPv4(_ address: String) -> Bool {
        guard let ipv4 = IPv4Address(address) else { return false }
        return ipv4.rawValue.first == 127
    }

    private func resolveIPAddresses(for host: String) -> (ipv4: [String], ipv6: [String]) {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            return (ipv4: [], ipv6: [])
        }
        defer { freeaddrinfo(first) }

        var ipv4 = Set<String>()
        var ipv6 = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            if info.pointee.ai_family == AF_INET {
                var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(buffer.count)) != nil {
                    ipv4.insert(String(cString: buffer))
                }
            } else if info.pointee.ai_family == AF_INET6 {
                var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr.sin6_addr, &buffer, socklen_t(buffer.count)) != nil {
                    ipv6.insert(String(cString: buffer))
                }
            }
            current = info.pointee.ai_next
        }

        return (ipv4: Array(ipv4), ipv6: Array(ipv6))
    }

    /// Applies network settings to the system using async/await.
    ///
    /// Discussion: Wraps the callback-based `setTunnelNetworkSettings(_:completionHandler:)`
    /// in a modern async interface.
    ///
    /// - Parameter settings: Network settings to apply
    /// - Throws: Any error returned by the system
    private func applyTunnelNetworkSettings(
        _ settings: NEPacketTunnelNetworkSettings
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Proxy Server

    /// Starts the local MITM proxy server on `127.0.0.1:8888`.
    ///
    /// Discussion: HTTPS decryption only works if the root CA is trusted. When
    /// the CA is untrusted, the proxy must fall back to passthrough mode to keep
    /// browsing functional while still capturing HTTP traffic.
    ///
    /// - Throws: If proxy server fails to bind to port (e.g., port already in use)
    private func startProxyServer() async throws {
        VPNLog.proxy.info("event=vpn.proxy_server_init_begin")

        let allowlist = await HardeningConfig.shared.mitmAllowlist
        let requestedMitmEnabled = await HardeningConfig.shared.enableNetworkFrameworkMITM
        let caTrusted = CertificateManager.shared.isRootCATrusted()

        VPNLog.proxy.info("event=vpn.proxy_server_config allowlist_count=\(allowlist.count) mitm_requested=\(requestedMitmEnabled) ca_trusted=\(caTrusted)")

        // Rule: Enable MITM only when requested and the CA is trusted.
        let mitmEnabled = requestedMitmEnabled && caTrusted

        VPNLog.proxy.info("event=vpn.proxy_server_mitm_decision effective_mitm_enabled=\(mitmEnabled)")

        if requestedMitmEnabled && !caTrusted {
            VPNLog.certificate.warning("event=vpn.ca_not_trusted_mitm_disabled reason=ca_not_trusted mitm_requested=\(requestedMitmEnabled)")
            await runtimeState.appendEventLog(
                type: "mitm_disabled",
                msg: "reason=ca_not_trusted"
            )
        }

        VPNLog.proxy.info("event=vpn.proxy_server_starting port=\(self.proxyPort) mitm_enabled=\(mitmEnabled)")

        do {
            try await runtimeState.startProxyServer(
                port: self.proxyPort,
                allowlist: allowlist,
                mitmEnabled: mitmEnabled
            )
            VPNLog.proxy.info("event=vpn.proxy_server_started outcome=success port=\(self.proxyPort)")
        } catch {
            VPNLog.proxy.error("event=vpn.proxy_server_start_failed outcome=failure port=\(self.proxyPort) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Message Handling

    /// Routes app messages to the appropriate handler.
    private func handleMessage(
        _ message: AppMessage,
        completionHandler: AppMessageCompletion
    ) async {
        switch message.command {
        case .getHardeningConfig:
            await respondWithHardeningConfig(completionHandler)
            return
        case .getRootCAFingerprint:
            respondWithRootCAFingerprint(completionHandler)
            return
        case .updateConfig:
            if let config = message.payload["config"] as? [String: Any] {
                await updateConfiguration(config)
            }
        case .updateCaptureConfig:
            await refreshCaptureConfiguration()
        case .updateHardeningConfig:
            if let config = message.payload["hardeningConfig"] as? [String: Any] {
                await updateHardeningConfiguration(config)
            }
        case .updateThrottlingState:
            if let stateDict = message.payload["state"] as? [String: Any],
               let state = NetworkThrottlingState.fromJSONDictionary(stateDict) {
                applyThrottlingState(state, reason: "app update")
            } else {
                VPNLog.tunnel.warning("event=vpn.throttling_update outcome=failure reason=invalid_payload")
            }
        case .clearRequests:
            await clearCapturedRequests()
        }

        // Rule: Action commands do not return a response payload.
        completionHandler.call(nil)
    }

    private func decodeAppMessage(from data: Data) throws -> AppMessage {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let payload = object as? [String: Any] else {
            throw AppMessageError.invalidFormat
        }
        guard let commandString = payload["command"] as? String,
              let command = AppCommand(rawValue: commandString) else {
            throw AppMessageError.unknownCommand(payload["command"] as? String ?? "<nil>")
        }
        return AppMessage(command: command, payload: payload)
    }

    private func respondWithHardeningConfig(_ completionHandler: AppMessageCompletion) async {
        let snapshot = await HardeningConfig.shared.getCurrentConfig()
        let response: [String: Any] = ["hardeningConfig": snapshot.toDictionary()]
        do {
            let data = try JSONSerialization.data(withJSONObject: response)
            completionHandler.call(data)
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.hardening_config_encode outcome=failure error=\(String(describing: error), privacy: .public)"
            )
            completionHandler.call(nil)
        }
    }

    private func respondWithRootCAFingerprint(_ completionHandler: AppMessageCompletion) {
        let fingerprint = CertificateManager.shared.getRootCAFingerprint()
        let response: [String: Any] = ["rootCAFingerprint": fingerprint ?? NSNull()]
        do {
            let data = try JSONSerialization.data(withJSONObject: response)
            completionHandler.call(data)
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.ca_fingerprint_encode outcome=failure error=\(String(describing: error), privacy: .public)"
            )
            completionHandler.call(nil)
        }
    }

    /// Updates proxy server configuration without restarting the server.
    private func updateConfiguration(_ config: [String: Any]) async {
        let configCopy = config
        let boxedConfig = UnsafeSendable(configCopy)
        await runtimeState.updateProxyConfiguration(boxedConfig)
        await refreshCaptureConfiguration()
    }

    private func refreshCaptureConfiguration() async {
        let config = AppGroupStorage.shared.loadConfiguration()
        currentCaptureMode = config.captureMode
        let trimmedHost = config.fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        VPNLog.tunnel.info(
            "event=vpn.capture_config mode=\(config.captureMode.rawValue, privacy: .public) socks_host=\(trimmedHost, privacy: .public) socks_port=\(config.fullTunnelSocks5Port) ipv6=\(config.fullTunnelIPv6Enabled) udp_mode=\(config.fullTunnelUDPForwardingMode.rawValue, privacy: .public) dns_servers=\(config.fullTunnelDNSServers.count) search_domains=\(config.fullTunnelSearchDomains.count)"
        )
        await runtimeState.appendEventLog(
            type: "capture_config",
            msg: "mode=\(config.captureMode.rawValue) socks_host=\(trimmedHost) socks_port=\(config.fullTunnelSocks5Port) ipv6=\(config.fullTunnelIPv6Enabled) udp_mode=\(config.fullTunnelUDPForwardingMode.rawValue) dns_servers=\(config.fullTunnelDNSServers.count) search_domains=\(config.fullTunnelSearchDomains.count)"
        )
        if config.captureMode == .fullTunnel {
            if trimmedHost.isEmpty || config.fullTunnelSocks5Port == 0 {
                VPNLog.tunnel.error("event=vpn.capture_mode_refresh outcome=failure reason=missing_socks5")
                await runtimeState.stopPacketFlow()
                return
            }
        }

        do {
            try await configureNetworkSettings(using: config)
            VPNLog.tunnel.info("event=vpn.capture_mode_refresh outcome=success mode=\(config.captureMode.rawValue)")
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.capture_mode_refresh outcome=failure mode=\(config.captureMode.rawValue) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        let rawCaptureEnabled = await HardeningConfig.shared.enableRawCapture
        let rawCaptureLimit = await HardeningConfig.shared.maxRawCaptureSize
        let packetCaptureWriter = createPacketCaptureWriterIfNeeded(
            enabled: rawCaptureEnabled && config.captureMode == .fullTunnel
        )
        await runtimeState.configurePacketFlow(
            packetFlow: packetFlow,
            mode: config.captureMode,
            mtu: fullTunnelMTU,
            captureEnabled: rawCaptureEnabled,
            captureLimit: rawCaptureLimit,
            writer: packetCaptureWriter,
            socks5Host: config.fullTunnelSocks5Host,
            socks5Port: config.fullTunnelSocks5Port,
            udpForwardingMode: config.fullTunnelUDPForwardingMode,
            ipv6Enabled: config.fullTunnelIPv6Enabled
        )
        await runtimeState.appendEventLog(
            type: "capture_mode_update",
            msg: "mode=\(config.captureMode.rawValue)"
        )
    }

    /// Updates hardening configuration and applies changes to running components.
    ///
    /// Discussion: The main app sends config updates over IPC so users can
    /// toggle settings without restarting the VPN.
    private func updateHardeningConfiguration(_ config: [String: Any]) async {
        let hardeningConfig = HardeningConfig.shared

        if let enableRobustReassembly = config["enableRobustReassembly"] as? Bool {
            await hardeningConfig.setEnableRobustReassembly(enableRobustReassembly)
        }

        if let enableMetrics = config["enableMetrics"] as? Bool {
            await hardeningConfig.setEnableMetrics(enableMetrics)

            if enableMetrics {
                startMetricsTask()
            } else {
                metricsTask?.cancel()
                metricsTask = nil
                VPNLog.tunnel.debug("event=vpn.metrics_toggle outcome=success enabled=false")
            }
        }

        if let enableDebugLogging = config["enableDebugLogging"] as? Bool {
            await hardeningConfig.setEnableDebugLogging(enableDebugLogging)
            TLSLog.setVerboseEnabled(enableDebugLogging)
            if enableDebugLogging {
                startHeartbeatTask()
            } else {
                heartbeatTask?.cancel()
                heartbeatTask = nil
                VPNLog.tunnel.info("event=vpn.heartbeat_toggle outcome=success enabled=false")
            }
        }

        if let rolloutStageString = config["rolloutStage"] as? String,
           let rolloutStage = HardeningConfig.RolloutStage(rawValue: rolloutStageString) {
            await hardeningConfig.setRolloutStage(rolloutStage)
        }

        if let enableRawCapture = config["enableRawCapture"] as? Bool {
            await hardeningConfig.setEnableRawCapture(enableRawCapture)
            let limit = await hardeningConfig.maxRawCaptureSize
            let writer = await createPCAPWriterIfNeeded(enabled: enableRawCapture)
            await runtimeState.configureRawCapture(
                enabled: enableRawCapture,
                limit: limit,
                writer: writer
            )
            if currentCaptureMode == .fullTunnel {
                let packetWriter = createPacketCaptureWriterIfNeeded(enabled: enableRawCapture)
                await runtimeState.updatePacketCaptureSettings(
                    enabled: enableRawCapture,
                    limit: limit,
                    writer: packetWriter
                )
            }
        }

        if let maxRawCaptureSize = readUInt64(from: config["maxRawCaptureSize"]) {
            await hardeningConfig.setMaxRawCaptureSize(maxRawCaptureSize)
            await runtimeState.updateRawCaptureLimit(maxRawCaptureSize)
            if currentCaptureMode == .fullTunnel {
                await runtimeState.updatePacketCaptureLimit(maxRawCaptureSize)
            }
        }

        if let allowlist = config["mitmAllowlist"] as? [String] {
            await hardeningConfig.setMitmAllowlist(allowlist)
            await runtimeState.setMitmAllowlist(allowlist)
            await runtimeState.appendEventLog(
                type: "mitm_allowlist_update",
                msg: "size=\(allowlist.count)"
            )
        }

        if let enableNetworkFrameworkMITM = config["enableNetworkFrameworkMITM"] as? Bool {
            await hardeningConfig.setEnableNetworkFrameworkMITM(enableNetworkFrameworkMITM)
            let caTrusted = CertificateManager.shared.isRootCATrusted()
            let effectiveMitmEnabled = enableNetworkFrameworkMITM && caTrusted
            await runtimeState.setMitmEnabled(effectiveMitmEnabled)
            await runtimeState.appendEventLog(
                type: "mitm_enabled_update",
                msg: "requested=\(enableNetworkFrameworkMITM) effective=\(effectiveMitmEnabled) ca_trusted=\(caTrusted)"
            )
            if enableNetworkFrameworkMITM && !caTrusted {
                VPNLog.certificate.warning("event=vpn.ca_trust_missing outcome=warning action=disable_mitm")
                await runtimeState.appendEventLog(
                    type: "mitm_disabled",
                    msg: "reason=ca_not_trusted (runtime)"
                )
            }
        }

        if let blockQUIC = config["blockQUIC"] as? Bool {
            await hardeningConfig.setBlockQUIC(blockQUIC)
            await runtimeState.setBlockQUICEnabled(blockQUIC)
            await runtimeState.appendEventLog(type: "block_quic", msg: "\(blockQUIC)")
        }

        await hardeningConfig.logCurrentConfig()
    }

    /// Extracts a `UInt64` from a JSON payload value.
    ///
    /// Discussion: JSON numbers may deserialize as `Int`, `NSNumber`, or `UInt64`,
    /// so this helper normalizes and enforces non-negative values.
    private func readUInt64(from value: Any?) -> UInt64? {
        switch value {
        case let number as UInt64:
            number
        case let number as Int where number >= 0:
            UInt64(number)
        case let number as NSNumber:
            number.compare(0) != .orderedAscending ? number.uint64Value : nil
        default:
            nil
        }
    }

    private func configureCaptureSettings() async {
        let config = HardeningConfig.shared
        let rawCaptureEnabled = await config.enableRawCapture
        let rawCaptureLimit = await config.maxRawCaptureSize
        let blockQUICEnabled = await config.blockQUIC

        let writer = await createPCAPWriterIfNeeded(enabled: rawCaptureEnabled)
        await runtimeState.configureRawCapture(
            enabled: rawCaptureEnabled,
            limit: rawCaptureLimit,
            writer: writer
        )
        await runtimeState.setBlockQUICEnabled(blockQUICEnabled)
    }

    /// Creates a PCAP writer for raw packet capture.
    ///
    /// Discussion: PCAP capture enables offline HTTP/2 frame analysis and is
    /// disabled by default for performance and privacy reasons.
    private func createPCAPWriterIfNeeded(enabled: Bool) async -> PCAPWriter? {
        guard enabled else { return nil }
        do {
            let writer = try PCAPWriter(
                appGroupID: AppGroupConfiguration.appGroupIdentifier,
                fileName: "capture_http2_proxy.pcap"
            )
            VPNLog.tunnel.info("event=vpn.pcap_writer_enabled outcome=success")
            return writer
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.pcap_writer_start outcome=failure error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Creates a PCAP writer for packet-level capture in full-tunnel mode.
    private func createPacketCaptureWriterIfNeeded(enabled: Bool) -> PCAPWriting? {
        guard enabled else { return nil }
        do {
            let writer = try PCAPWriter(
                appGroupID: AppGroupConfiguration.appGroupIdentifier,
                fileName: "capture_raw_packets.pcap"
            )
            VPNLog.tunnel.info("event=vpn.packet_capture_writer_enabled outcome=success")
            return writer
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.packet_capture_writer_start outcome=failure error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Initializes an NDJSON event log for structured event tracking.
    ///
    /// Discussion: Structured NDJSON is easier to parse than free-form OSLog and
    /// is stored in the shared App Group for main app access.
    private func initializeEventLog(mode: CaptureMode) async {
        do {
            let logWriter = try NDJSONLogWriter(
                appGroupID: AppGroupConfiguration.appGroupIdentifier,
                fileName: "vpn_events.ndjson"
            )
            self.eventLogWriter = logWriter
            await runtimeState.setEventLog(logWriter)
            await runtimeState.appendEventLog(type: "startup", msg: "Tunnel started mode=\(mode.rawValue)")
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.ndjson_logger_start outcome=failure error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Preloads the root CA certificate and verifies system trust.
    ///
    /// Discussion: Preloading avoids the first-request delay and surfaces
    /// trust warnings early. If the CA is untrusted, HTTPS MITM remains disabled
    /// until the user installs the CA and enables Full Trust in Settings.
    private func preloadRootCertificate() async {
        do {
            VPNLog.certificate.debug("event=vpn.ca_load_begin")
            _ = try CertificateManager.shared.getRootCA()
            let fingerprint = CertificateManager.shared.getRootCAFingerprint() ?? "unknown"
            VPNLog.certificate.info(
                "event=vpn.ca_load outcome=success fingerprint=\(fingerprint.prefix(16), privacy: .private(mask: .hash))"
            )

            let trusted = CertificateManager.shared.isRootCATrusted()
            if trusted {
                VPNLog.certificate.info("event=vpn.ca_trust_check outcome=trusted")
            } else {
                VPNLog.certificate.warning(
                    "event=vpn.ca_trust_check outcome=not_trusted reason=https_mitm_will_fail"
                )
            }
        } catch {
            VPNLog.certificate.error(
                "event=vpn.ca_load outcome=failure error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func loadInitialThrottlingState() {
        let state = AppGroupStorage.shared.loadThrottlingState()
        applyThrottlingState(state, reason: "startup")
    }

    private func applyThrottlingState(_ state: NetworkThrottlingState, reason: String) {
        Task {
            await runtimeState.applyThrottlingState(state, reason: reason)
        }
    }

    private func clearCapturedRequests() async {
        do {
            try AppGroupStorage.shared.clearAllRequests()
            VPNLog.tunnel.info("event=vpn.capture_clear outcome=success")
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.capture_clear outcome=failure error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}

/// Ensures `startTunnel` completes at most once per invocation.
///
/// Discussion: iOS can invoke `startTunnel` concurrently before the first
/// invocation finishes, which can corrupt VPN state if multiple completion
/// handlers are called.
///
/// - Important: Actor isolation serializes completion decisions across calls.
actor StartCompletionGate {
    private var currentInvocationID: String?
    private var completionCalled = false

    /// Registers a new tunnel start invocation.
    func begin(invocationID: String) {
        currentInvocationID = invocationID
        completionCalled = false
    }

    /// Indicates whether the completion handler should be called.
    ///
    /// - Returns: `true` only once per invocation ID.
    func shouldComplete(invocationID: String) -> Bool {
        guard currentInvocationID == invocationID, !completionCalled else {
            return false
        }
        completionCalled = true
        return true
    }

    /// Returns the current invocation ID for heartbeat logging.
    func invocationID() -> String? {
        currentInvocationID
    }

    /// Resets gate state when the tunnel stops.
    func reset() {
        currentInvocationID = nil
        completionCalled = false
    }
}

/// Ensures completion handlers are called at most once.
final class CompletionHandlerBox<T>: @unchecked Sendable {
    private let handler: (T) -> Void

    init(_ handler: @escaping (T) -> Void) {
        self.handler = handler
    }

    func call(_ value: T) {
        handler(value)
    }
}

final class UnsafeSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

actor CompletionOnce {
    private let handler: CompletionHandlerBox<Void>
    private let queue: DispatchQueue
    private var didComplete = false

    init(handler: CompletionHandlerBox<Void>, queue: DispatchQueue) {
        self.handler = handler
        self.queue = queue
    }

    func call() {
        guard !didComplete else { return }
        didComplete = true
        queue.async {
            self.handler.call(())
        }
    }
}

/// Serializes `startTunnel` completion handling and logging.
actor StartTunnelCompletion {
    private let invocationID: String
    private let startWall: Date
    private let handler: CompletionHandlerBox<Error?>
    private let queue: DispatchQueue
    private var didComplete = false

    init(invocationID: String, startWall: Date, handler: CompletionHandlerBox<Error?>, queue: DispatchQueue) {
        self.invocationID = invocationID
        self.startWall = startWall
        self.handler = handler
        self.queue = queue
    }

    func complete(_ error: Error?) {
        guard !didComplete else { return }
        didComplete = true

        let elapsedMs = Int(Date().timeIntervalSince(startWall) * 1000)
        if let error {
            VPNLog.tunnel.error(
                "event=vpn.tunnel_start outcome=failure id=\(self.invocationID, privacy: .public) duration_ms=\(elapsedMs) error=\(String(describing: error), privacy: .public)"
            )
        } else {
            VPNLog.tunnel.info(
                "event=vpn.tunnel_start outcome=success id=\(self.invocationID, privacy: .public) duration_ms=\(elapsedMs)"
            )
        }
        queue.async {
            self.handler.call(error)
        }
    }
}

/// Wraps optional IPC completion handlers to avoid cross-task data race warnings.
struct AppMessageCompletion: @unchecked Sendable {
    private let handler: CompletionHandlerBox<Data?>?
    private let queue: DispatchQueue

    init(handler: ((Data?) -> Void)?, queue: DispatchQueue) {
        self.handler = handler.map { CompletionHandlerBox($0) }
        self.queue = queue
    }

    func call(_ data: Data?) {
        guard let handler else { return }
        queue.async {
            handler.call(data)
        }
    }

    static func call(handler: ((Data?) -> Void)?, queue: DispatchQueue, data: Data?) {
        guard let handler else { return }
        queue.async {
            handler(data)
        }
    }
}

/// Captures tunnel state for periodic heartbeat logging.
///
/// - Note: Used to log invocation ID, stopping state, and proxy status.
struct HeartbeatSnapshot: Sendable {
    let invocationID: String?
    let isStopping: Bool
    let proxyRunning: Bool
}

/// Manages tunnel runtime state that must be mutated safely across async tasks.
///
/// Discussion: This actor owns the proxy server instance and capture state to
/// avoid races between IPC handlers, lifecycle events, and background tasks.
actor PacketTunnelRuntimeState {
    private var proxyServer: MITMProxyServer?
    private var pcapWriter: PCAPWriter?
    private var packetFlowLoop: PacketFlowLoop?
    private var packetCapturePipeline: PacketCapturePipeline?
    private var packetForwarder: PacketForwardingEngine?
    private var udpForwarder: UDPForwarder?
    private var packetCaptureWriter: PCAPWriting?
    private var eventLog: NDJSONLogWriter?
    private var rawCaptureBytes: UInt64 = 0
    private var rawCaptureEnabled = false
    private var rawCaptureLimit: UInt64 = 0
    private var blockQUICEnabled = true
    private var isStopping = false
    private let throttler = PacketThrottler()

    func setStopping(_ value: Bool) {
        isStopping = value
    }

    func setEventLog(_ logWriter: NDJSONLogWriter?) {
        eventLog = logWriter
    }

    func appendEventLog(type: String, msg: String) {
        eventLog?.append(type: type, msg: msg)
    }

    func closeEventLog() {
        eventLog?.close()
        eventLog = nil
    }

    /// Configures raw packet capture (PCAP) settings.
    ///
    /// Discussion: The proxy server intercepts HTTP/2 frames and can write them
    /// to PCAP, which is separate from packet-level capture.
    func configureRawCapture(enabled: Bool, limit: UInt64, writer: PCAPWriter?) {
        rawCaptureEnabled = enabled
        rawCaptureLimit = limit
        pcapWriter = writer
        rawCaptureBytes = writer?.currentFileSize() ?? 0

        // Rationale: The proxy server writes HTTP/2 frames into the PCAP stream.
        proxyServer?.configureRawCapture(enabled: enabled, writer: writer, limit: rawCaptureLimit)
    }

    func updateRawCaptureLimit(_ limit: UInt64) {
        rawCaptureLimit = limit
        proxyServer?.updateRawCaptureLimit(limit)
    }

    func configurePacketFlow(
        packetFlow: NEPacketTunnelFlow,
        mode: CaptureMode,
        mtu: Int,
        captureEnabled: Bool,
        captureLimit: UInt64,
        writer: PCAPWriting?,
        socks5Host: String,
        socks5Port: UInt16,
        udpForwardingMode: UDPForwardingMode,
        ipv6Enabled: Bool
    ) {
        stopPacketFlow()

        guard mode == .fullTunnel else {
            writer?.close()
            return
        }

        let trimmedHost = socks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        VPNLog.tunnel.info(
            "event=vpn.packet_flow_config mode=\(mode.rawValue, privacy: .public) socks_host=\(trimmedHost, privacy: .public) socks_port=\(socks5Port) ipv6=\(ipv6Enabled) udp_mode=\(udpForwardingMode.rawValue, privacy: .public) block_quic=\(self.blockQUICEnabled)"
        )
        appendEventLog(
            type: "packet_flow_config",
            msg: "mode=\(mode.rawValue) socks_host=\(trimmedHost) socks_port=\(socks5Port) ipv6=\(ipv6Enabled) udp_mode=\(udpForwardingMode.rawValue) block_quic=\(blockQUICEnabled)"
        )

        let pipeline = PacketCapturePipeline(maxPending: 4096)
        pipeline.configure(enabled: captureEnabled, limit: captureLimit, writer: writer)
        packetCapturePipeline = pipeline
        packetCaptureWriter = writer

        if !trimmedHost.isEmpty, socks5Port > 0 {
            let eventLogger: (String, String) -> Void = { [weak self] type, msg in
                Task { [weak self] in
                    await self?.appendEventLog(type: type, msg: msg)
                }
            }
            let forwarder = HevSocks5TunnelForwarder(
                packetFlow: packetFlow,
                socks5Host: trimmedHost,
                socks5Port: socks5Port,
                mtu: mtu,
                ipv6Enabled: ipv6Enabled,
                eventLogHandler: eventLogger
            ) { [weak self] support in
                let usable = support.isUsable(forIPv6: ipv6Enabled)
                if usable {
                    VPNLog.tunnel.info(
                        "event=vpn.socks5_udp_associate outcome=success support=\(support.rawValue) ipv6_enabled=\(ipv6Enabled)"
                    )
                    Task { [weak self] in
                        await self?.appendEventLog(
                            type: "socks5_udp_associate",
                            msg: "outcome=success support=\(support.rawValue) ipv6_enabled=\(ipv6Enabled)"
                        )
                    }
                } else {
                    VPNLog.tunnel.warning(
                        "event=vpn.socks5_udp_associate outcome=failure support=\(support.rawValue) ipv6_enabled=\(ipv6Enabled) fallback=block_quic"
                    )
                    Task { [weak self] in
                        await self?.setBlockQUICEnabled(true)
                        await self?.appendEventLog(
                            type: "socks5_udp_associate",
                            msg: "outcome=failure support=\(support.rawValue) ipv6_enabled=\(ipv6Enabled) action=block_quic"
                        )
                        await self?.appendEventLog(
                            type: "block_quic",
                            msg: "true reason=socks5_udp_unsupported support=\(support.rawValue)"
                        )
                    }
                }
            }
            forwarder.start()
            packetForwarder = forwarder
        } else {
            VPNLog.tunnel.error("event=vpn.packet_forwarder_start outcome=failure reason=missing_socks5")
            appendEventLog(type: "packet_forwarder_start", msg: "outcome=failure reason=missing_socks5")
            packetForwarder = nil
        }

        let udpForwarder: UDPForwarder? = if udpForwardingMode == .hevOnly {
            nil
        } else {
            UDPForwarder(packetFlow: packetFlow)
        }
        self.udpForwarder = udpForwarder

        let loop = PacketFlowLoop(
            packetFlow: packetFlow,
            capturePipeline: pipeline,
            forwarder: packetForwarder,
            udpForwarder: udpForwarder,
            udpForwardingMode: udpForwardingMode,
            blockQUICEnabled: blockQUICEnabled
        )
        packetFlowLoop = loop
        loop.start()
    }

    func updatePacketCaptureSettings(enabled: Bool, limit: UInt64, writer: PCAPWriting?) {
        packetCapturePipeline?.configure(enabled: enabled, limit: limit, writer: writer)
        packetCaptureWriter = writer
    }

    func updatePacketCaptureLimit(_ limit: UInt64) {
        packetCapturePipeline?.updateLimit(limit)
    }

    func stopPacketFlow() {
        packetFlowLoop?.stop()
        packetFlowLoop = nil
        packetForwarder?.stop()
        packetForwarder = nil
        udpForwarder?.stop()
        udpForwarder = nil
        packetCapturePipeline?.stop()
        packetCapturePipeline = nil
        packetCaptureWriter?.close()
        packetCaptureWriter = nil
    }

    func setBlockQUICEnabled(_ enabled: Bool) {
        blockQUICEnabled = enabled
        packetFlowLoop?.updateBlockQUICEnabled(enabled)
    }

    func startProxyServer(
        port: UInt16,
        allowlist: [String],
        mitmEnabled: Bool
    ) async throws {
        VPNLog.proxy.info("event=vpn.runtime_create_server port=\(port) allowlist_count=\(allowlist.count) mitm_enabled=\(mitmEnabled)")

        let server = MITMProxyServer(port: port, eventLog: eventLog)

        VPNLog.proxy.info("event=vpn.runtime_set_allowlist count=\(allowlist.count)")
        server.setMitmAllowlist(allowlist)

        VPNLog.proxy.info("event=vpn.runtime_set_mitm enabled=\(mitmEnabled)")
        server.setMitmEnabled(mitmEnabled)

        VPNLog.proxy.info("event=vpn.runtime_server_start_call port=\(port)")
        try server.start()

        proxyServer = server
        VPNLog.proxy.info("event=vpn.runtime_server_started outcome=success port=\(port)")
    }

    func stopProxyServer() {
        VPNLog.proxy.info("event=vpn.runtime_server_stop_begin has_server=\(self.proxyServer != nil)")
        self.proxyServer?.stop()
        self.proxyServer = nil
        VPNLog.proxy.info("event=vpn.runtime_server_stopped outcome=success")
    }

    @preconcurrency func updateProxyConfiguration(_ config: UnsafeSendable<[String: Any]>) {
        proxyServer?.updateConfiguration(config.value)
    }

    func setMitmAllowlist(_ allowlist: [String]) {
        proxyServer?.setMitmAllowlist(allowlist)
    }

    func setMitmEnabled(_ enabled: Bool) {
        proxyServer?.setMitmEnabled(enabled)
    }

    func heartbeatSnapshot(invocationID: String?) -> HeartbeatSnapshot {
        HeartbeatSnapshot(
            invocationID: invocationID,
            isStopping: isStopping,
            proxyRunning: proxyServer != nil
        )
    }

    func proxyConnectionCount() -> Int {
        proxyServer?.activeConnectionCount() ?? 0
    }

    /// Applies network throttling state to all throttling components.
    ///
    /// Discussion: Throttling is applied at the packet layer, the proxy layer,
    /// and the shared controller so UI and debugging stay in sync.
    func applyThrottlingState(
        _ state: NetworkThrottlingState,
        reason: String
    ) {
        throttler.updateState(state)
        proxyServer?.updateThrottlingState(state)
        NetworkThrottlingController.shared.updateState(state)

        let conditionName = state.condition?.displayName ?? "none"
        VPNLog.proxy.info("event=vpn.throttling_update outcome=success reason=\(reason) enabled=\(state.enabled) profile=\(conditionName)")
    }
}
