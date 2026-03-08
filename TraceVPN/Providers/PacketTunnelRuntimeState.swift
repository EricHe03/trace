//
//  PacketTunnelRuntimeState.swift
//  TraceVPN
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import NetworkExtension
import OSLog
import TraceCore
import TraceProxy

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

struct HeartbeatSnapshot: Sendable {
    let invocationID: String?
    let isStopping: Bool
    let proxyRunning: Bool
}

private final class PacketFlowLoopReference: @unchecked Sendable {
    weak var loop: PacketFlowLoop?
}

actor PacketTunnelRuntimeState {
    private struct EffectiveSocksEndpoint: Sendable {
        let host: String
        let port: UInt16
        let source: String
    }

    private var proxyServer: MITMProxyServer?
    private var pcapWriter: PCAPWriting?
    private var packetFlowLoop: PacketFlowLoop?
    private var packetCapturePipeline: PacketCapturePipeline?
    private var packetForwarder: PacketForwardingEngine?
    private var localSocks5Server: LocalSocks5Server?
    private var udpForwarder: UDPForwarder?
    private var dualMITMPolicyEngine: DualMITMPolicyEngine?
    private var tcpBypassStore: InMemoryHostBypassStore?
    private var quicFailOpenStore: InMemoryHostBypassStore?
    private var packetCaptureWriter: PCAPWriting?
    private var eventLog: NDJSONLogWriter?
    private var rawCaptureBytes: UInt64 = 0
    private var rawCaptureEnabled = false
    private var rawCaptureLimit: UInt64 = 0
    private var quicHandlingMode: QUICHandlingMode = .intercept
    private var udpTunnelSupported = false
    private var isStopping = false
    private let throttler = PacketThrottler()

    struct PacketFlowConfig {
        let packetFlow: NEPacketTunnelFlow
        let mode: CaptureMode
        let mtu: Int
        let captureEnabled: Bool
        let captureLimit: UInt64
        let writer: PCAPWriting?
        let socks5Host: String
        let socks5Port: UInt16
        let localSocks5Host: String
        let localSocks5Port: UInt16
        let udpForwardingMode: UDPForwardingMode
        let ipv6Enabled: Bool
        let tcpTransparentMITMEnabled: Bool
        let tcpTransparentMITMPorts: Set<UInt16>
        let mitmProxyHost: String
        let mitmProxyPort: UInt16
        let dualMITMPolicy: DualMITMPolicy
        let tcpBypassTTLSeconds: Int
        let quicHostFailOpenSeconds: Int
        let dualMITMCircuitBreakerEnabled: Bool
        let quicNoProgressGraceMs: Int
        let quicNoProgressIdleMs: Int
        let quicNoProgressAbsoluteMs: Int
        let quicNoProgressMinClientDatagrams: Int
        let quicAuthorityRetryAttempts: Int
        let quicCertMaterialCacheTTLSeconds: Int
        let dualMITMPolicyEngineShadowEnabled: Bool
        let dualMITMPolicyEngineEnforcedTCP: Bool
        let dualMITMPolicyEngineEnforcedProxy: Bool
        let dualMITMPolicyEngineEnforcedQUIC: Bool
        let dualMITMHttp2MITMEnabled: Bool
        let dualMITMStrictEnforcementHardFail: Bool
    }

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

    func configureRawCapture(enabled: Bool, limit: UInt64, writer: PCAPWriting?) {
        rawCaptureEnabled = enabled
        rawCaptureLimit = limit
        pcapWriter = writer
        rawCaptureBytes = writer?.currentFileSize() ?? 0
        proxyServer?.configureRawCapture(enabled: enabled, writer: writer, limit: rawCaptureLimit)
    }

    func updateRawCaptureLimit(_ limit: UInt64) {
        rawCaptureLimit = limit
        proxyServer?.updateRawCaptureLimit(limit)
    }

    func configurePacketFlow(_ config: PacketFlowConfig) async {
        stopPacketFlow()

        guard config.mode.usesPacketTunnelRouting else {
            stopLocalSocks5Server()
            config.writer?.close()
            return
        }

        let pipeline = PacketCapturePipeline(maxPending: 4096)
        pipeline.configure(enabled: config.captureEnabled, limit: config.captureLimit, writer: config.writer)
        packetCapturePipeline = pipeline
        packetCaptureWriter = config.writer
        let inboundCaptureObserver: @Sendable ([Data]) -> Void = { [weak pipeline] packets in
            guard let pipeline else { return }
            _ = pipeline.enqueue(packets: packets)
        }
        let inboundPacketObserver: @Sendable (Data) -> Void = { [weak pipeline] packet in
            guard let pipeline else { return }
            _ = pipeline.enqueue(packet: packet)
        }
        let packetFlowLoopReference = PacketFlowLoopReference()
        let inboundQUICInterceptor: @Sendable (Data) -> Bool = { packet in
            packetFlowLoopReference.loop?.consumeInboundQUICPacketIfIntercepted(packet) ?? false
        }
        let eventLogger: @Sendable (String, String) -> Void = { [weak self] type, msg in
            Task { [weak self] in
                await self?.appendEventLog(type: type, msg: msg)
            }
        }
        let dualMITMBreakerEnabled = config.dualMITMCircuitBreakerEnabled &&
            config.dualMITMPolicy == .adaptiveFailOpen
        DualMITMCircuitBreaker.shared.configure(
            enabled: dualMITMBreakerEnabled,
            cooldownSeconds: 180,
            tcpWindowSize: 16,
            quicWindowSeconds: 60,
            tcpFailureThreshold: 0.40,
            quicFailureThreshold: 0.40
        )
        udpTunnelSupported = false

        let policySnapshot = DualMITMPolicySnapshot(
            tcpTransparentMITMEnabled: config.tcpTransparentMITMEnabled,
            tcpInterceptPorts: config.tcpTransparentMITMPorts,
            mitmProxyHost: config.mitmProxyHost,
            mitmProxyPort: config.mitmProxyPort,
            policyMode: config.dualMITMPolicy,
            circuitBreakerEnabled: config.dualMITMCircuitBreakerEnabled,
            tcpBypassTTLSeconds: config.tcpBypassTTLSeconds,
            quicHostFailOpenSeconds: config.quicHostFailOpenSeconds,
            quicNoProgress: QUICNoProgressConfig(
                graceMs: config.quicNoProgressGraceMs,
                idleMs: config.quicNoProgressIdleMs,
                absoluteMs: config.quicNoProgressAbsoluteMs,
                minimumClientDatagrams: config.quicNoProgressMinClientDatagrams
            ),
            quicAuthorityRetryAttempts: config.quicAuthorityRetryAttempts,
            quicCertMaterialCacheTTLSeconds: config.quicCertMaterialCacheTTLSeconds,
            quicHandlingMode: quicHandlingMode,
            featureFlags: DualMITMPolicyFeatureFlags(
                shadowEnabled: config.dualMITMPolicyEngineShadowEnabled,
                enforceTCPRouting: config.dualMITMPolicyEngineEnforcedTCP,
                enforceProxyRouting: config.dualMITMPolicyEngineEnforcedProxy,
                enforceQUICRouting: config.dualMITMPolicyEngineEnforcedQUIC,
                http2MITMEnabled: config.dualMITMHttp2MITMEnabled,
                strictEnforcementHardFail: config.dualMITMStrictEnforcementHardFail
            )
        )
        let tcpStore = tcpBypassStore ?? InMemoryHostBypassStore()
        let quicStore = quicFailOpenStore ?? InMemoryHostBypassStore()
        tcpBypassStore = tcpStore
        quicFailOpenStore = quicStore

        let breakerController = DualMITMCircuitBreakerController(breaker: .shared)
        let sink = ClosureInterceptionEventSink { [weak self] event in
            Task { [weak self] in
                await self?.emitInterceptionEvent(event)
            }
        }

        let policyEngine: DualMITMPolicyEngine
        if let existing = dualMITMPolicyEngine {
            existing.updateSnapshot(policySnapshot)
            policyEngine = existing
        } else {
            policyEngine = DualMITMPolicyEngine(
                snapshot: policySnapshot,
                shouldForceTCPDirect: { port, now in
                    DualMITMCircuitBreaker.shared.shouldForceTCPDirect(port: port, now: now)
                },
                lookupTCPBypass: { host in
                    guard MITMAutoBypassLookup.shouldBypass(host: host) else {
                        return .none
                    }
                    return DualMITMTCPBypassLookupResult(
                        shouldBypass: true,
                        reason: MITMAutoBypassLookup.reason(for: host)
                    )
                },
                eventSink: sink,
                tcpBypassStore: tcpStore,
                quicFailOpenStore: quicStore,
                circuitBreakerController: breakerController
            )
        }
        dualMITMPolicyEngine = policyEngine
        proxyServer?.setDualMITMPolicyEngine(policyEngine)
        proxyServer?.setDualMITMProxyPolicyEnforcement(config.dualMITMPolicyEngineEnforcedProxy)

        do {
            let endpoint = try resolveSocksEndpoint(using: config)
            let trimmedHost = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let socksHostHash = LogRedaction.hash(trimmedHost)
            VPNLog.tunnel.info(
                "event=vpn.packet_flow_config mode=\(config.mode.rawValue, privacy: .public) socks_source=\(endpoint.source, privacy: .public) socks_host_hash=\(socksHostHash) socks_host_len=\(trimmedHost.count) socks_port=\(endpoint.port) ipv6=\(config.ipv6Enabled) udp_mode=\(config.udpForwardingMode.rawValue, privacy: .public) quic_mode=\(self.quicHandlingMode.rawValue, privacy: .public) block_quic=\(self.quicHandlingMode.blocksQUIC) tcp_transparent_mitm=\(config.tcpTransparentMITMEnabled) dual_mitm_policy=\(config.dualMITMPolicy.rawValue, privacy: .public) breaker=\(config.dualMITMCircuitBreakerEnabled) policy_shadow=\(config.dualMITMPolicyEngineShadowEnabled) policy_enforced_tcp=\(config.dualMITMPolicyEngineEnforcedTCP) policy_enforced_proxy=\(config.dualMITMPolicyEngineEnforcedProxy) policy_enforced_quic=\(config.dualMITMPolicyEngineEnforcedQUIC) http2_mitm=\(config.dualMITMHttp2MITMEnabled) strict_hard_fail=\(config.dualMITMStrictEnforcementHardFail) quic_no_progress_grace_ms=\(config.quicNoProgressGraceMs) quic_no_progress_idle_ms=\(config.quicNoProgressIdleMs) quic_no_progress_absolute_ms=\(config.quicNoProgressAbsoluteMs) quic_no_progress_min_client_datagrams=\(config.quicNoProgressMinClientDatagrams) quic_authority_retry_attempts=\(config.quicAuthorityRetryAttempts) quic_cert_material_cache_ttl=\(config.quicCertMaterialCacheTTLSeconds)"
            )
            appendEventLog(
                type: "packet_flow_config",
                msg: "mode=\(config.mode.rawValue) socks_source=\(endpoint.source) socks_host_hash=\(socksHostHash) socks_host_len=\(trimmedHost.count) socks_port=\(endpoint.port) ipv6=\(config.ipv6Enabled) udp_mode=\(config.udpForwardingMode.rawValue) quic_mode=\(quicHandlingMode.rawValue) block_quic=\(quicHandlingMode.blocksQUIC) tcp_transparent_mitm=\(config.tcpTransparentMITMEnabled) dual_mitm_policy=\(config.dualMITMPolicy.rawValue) breaker=\(config.dualMITMCircuitBreakerEnabled) policy_shadow=\(config.dualMITMPolicyEngineShadowEnabled) policy_enforced_tcp=\(config.dualMITMPolicyEngineEnforcedTCP) policy_enforced_proxy=\(config.dualMITMPolicyEngineEnforcedProxy) policy_enforced_quic=\(config.dualMITMPolicyEngineEnforcedQUIC) http2_mitm=\(config.dualMITMHttp2MITMEnabled) strict_hard_fail=\(config.dualMITMStrictEnforcementHardFail) quic_no_progress_grace_ms=\(config.quicNoProgressGraceMs) quic_no_progress_idle_ms=\(config.quicNoProgressIdleMs) quic_no_progress_absolute_ms=\(config.quicNoProgressAbsoluteMs) quic_no_progress_min_client_datagrams=\(config.quicNoProgressMinClientDatagrams) quic_authority_retry_attempts=\(config.quicAuthorityRetryAttempts) quic_cert_material_cache_ttl=\(config.quicCertMaterialCacheTTLSeconds)"
            )

            let ipv6Enabled = config.ipv6Enabled
            let forwarder = HevSocks5TunnelForwarder(
                packetFlow: config.packetFlow,
                socks5Host: trimmedHost,
                socks5Port: endpoint.port,
                mtu: config.mtu,
                ipv6Enabled: ipv6Enabled,
                outputPacketObserver: inboundCaptureObserver,
                outputPacketInterceptor: inboundQUICInterceptor,
                eventLogHandler: eventLogger
            ) { [weak self] support in
                let usable = support.isUsable(forIPv6: ipv6Enabled)
                Task { [weak self] in
                    await self?.setUDPTunnelSupported(usable, support: support, ipv6Enabled: ipv6Enabled)
                    if usable {
                        VPNLog.tunnel.info(
                            "event=vpn.socks5_udp_associate outcome=success support=\(support.rawValue) ipv6_enabled=\(ipv6Enabled)"
                        )
                        await self?.appendEventLog(
                            type: "socks5_udp_associate",
                            msg: "outcome=success support=\(support.rawValue) ipv6_enabled=\(ipv6Enabled)"
                        )
                    } else {
                        VPNLog.tunnel.warning(
                            "event=vpn.socks5_udp_associate outcome=failure support=\(support.rawValue) ipv6_enabled=\(ipv6Enabled) fallback=block_quic"
                        )
                        await self?.setQUICHandlingMode(.block)
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
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.packet_forwarder_start outcome=failure reason=socks5_unavailable error=\(error.localizedDescription, privacy: .public)"
            )
            appendEventLog(
                type: "packet_forwarder_start",
                msg: "outcome=failure reason=socks5_unavailable error=\(error.localizedDescription)"
            )
            packetForwarder = nil
        }

        let udpForwarder: UDPForwarder? = UDPForwarder(
            packetFlow: config.packetFlow,
            inboundPacketObserver: inboundPacketObserver,
            inboundPacketInterceptor: inboundQUICInterceptor
        )
        self.udpForwarder = udpForwarder

        let loop = PacketFlowLoop(
            packetFlow: config.packetFlow,
            capturePipeline: pipeline,
            forwarder: packetForwarder,
            udpForwarder: udpForwarder,
            udpForwardingMode: config.udpForwardingMode,
            quicHandlingMode: quicHandlingMode,
            dualMITMPolicy: config.dualMITMPolicy,
            quicHostFailOpenSeconds: config.quicHostFailOpenSeconds,
            dualMITMCircuitBreakerEnabled: config.dualMITMCircuitBreakerEnabled,
            quicNoProgressGraceMs: config.quicNoProgressGraceMs,
            quicNoProgressIdleMs: config.quicNoProgressIdleMs,
            quicNoProgressAbsoluteMs: config.quicNoProgressAbsoluteMs,
            quicNoProgressMinClientDatagrams: config.quicNoProgressMinClientDatagrams,
            quicAuthorityRetryAttempts: config.quicAuthorityRetryAttempts,
            quicCertMaterialCacheTTLSeconds: config.quicCertMaterialCacheTTLSeconds,
            dualMITMPolicyEngine: policyEngine,
            quicInterceptor: RequestInterceptor.shared,
            eventLogHandler: eventLogger
        )
        packetFlowLoop = loop
        packetFlowLoopReference.loop = loop
        loop.updateUDPTunnelSupported(udpTunnelSupported)
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
        stopLocalSocks5Server()
        udpTunnelSupported = false
    }

    private func resolveSocksEndpoint(using config: PacketFlowConfig) throws -> EffectiveSocksEndpoint {
        let source = selectSocksEndpointSource(host: config.socks5Host, port: config.socks5Port)
        if config.mode.supportsCustomSocksServer, source == .configured {
            let trimmedHost = config.socks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
            stopLocalSocks5Server()
            return EffectiveSocksEndpoint(host: trimmedHost, port: config.socks5Port, source: SocksEndpointSource.configured.rawValue)
        }

        let localServer: LocalSocks5Server
        if let existing = localSocks5Server {
            localServer = existing
        } else {
            let eventLogger: @Sendable (String, String) -> Void = { [weak self] type, msg in
                Task { [weak self] in
                    await self?.appendEventLog(type: type, msg: msg)
                }
            }
            let dualMITMPolicy = config.dualMITMPolicy
            let policyEngine = dualMITMPolicyEngine
            let tcpConnectRoutingPolicy = LocalSocks5Server.TCPConnectRoutingPolicy(
                enabled: config.tcpTransparentMITMEnabled,
                interceptPorts: config.tcpTransparentMITMPorts,
                mitmProxyHost: config.mitmProxyHost,
                mitmProxyPort: config.mitmProxyPort,
                failOpen: dualMITMPolicy == .adaptiveFailOpen,
                dualMITMPolicy: dualMITMPolicy,
                policyEngine: policyEngine,
                shouldBypassHost: { host in
                    guard dualMITMPolicy == .adaptiveFailOpen else {
                        return false
                    }
                    guard MITMAutoBypassLookup.shouldBypass(host: host) else {
                        return false
                    }
                    guard let reason = MITMAutoBypassLookup.reason(for: host) else {
                        return true
                    }
                    let normalized = reason
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if normalized.hasPrefix("quic ") || normalized.hasPrefix("quic_") {
                        return false
                    }
                    return true
                },
                bypassReasonForHost: { host in
                    guard dualMITMPolicy == .adaptiveFailOpen else {
                        return nil
                    }
                    guard let reason = MITMAutoBypassLookup.reason(for: host) else {
                        return MITMAutoBypassLookup.shouldBypass(host: host) ? "" : nil
                    }
                    let normalized = reason
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    if normalized.hasPrefix("quic ") || normalized.hasPrefix("quic_") {
                        return nil
                    }
                    return reason
                }
            )
            let server = LocalSocks5Server(
                bindHost: config.localSocks5Host,
                tcpConnectRoutingPolicy: tcpConnectRoutingPolicy,
                eventLogHandler: eventLogger
            )
            localSocks5Server = server
            localServer = server
        }

        do {
            let endpoint = try localServer.start(preferredPort: config.localSocks5Port)
            return EffectiveSocksEndpoint(host: endpoint.host, port: endpoint.port, source: SocksEndpointSource.embedded.rawValue)
        } catch {
            localServer.stop()
            localSocks5Server = nil
            throw error
        }
    }

    private func stopLocalSocks5Server() {
        localSocks5Server?.stop()
        localSocks5Server = nil
    }

    func setQUICHandlingMode(_ mode: QUICHandlingMode) {
        quicHandlingMode = mode
        packetFlowLoop?.updateQUICHandlingMode(mode)
    }

    func setBlockQUICEnabled(_ enabled: Bool) {
        setQUICHandlingMode(enabled ? .block : .passThrough)
    }

    func setUDPTunnelSupported(_ supported: Bool, support: Socks5UDPSupport, ipv6Enabled: Bool) {
        udpTunnelSupported = supported
        packetFlowLoop?.updateUDPTunnelSupported(supported)

        let action = supported ? "tunnel" : "direct_fallback"
        appendEventLog(
            type: "udp_tunnel_support",
            msg: "supported=\(supported) support=\(support.rawValue) ipv6_enabled=\(ipv6Enabled) action=\(action)"
        )

        if supported {
            VPNLog.tunnel.info(
                "event=vpn.udp_tunnel_support outcome=success supported=true support=\(support.rawValue, privacy: .public) ipv6_enabled=\(ipv6Enabled) action=\(action, privacy: .public)"
            )
        } else {
            VPNLog.tunnel.warning(
                "event=vpn.udp_tunnel_support outcome=success supported=false support=\(support.rawValue, privacy: .public) ipv6_enabled=\(ipv6Enabled) action=\(action, privacy: .public)"
            )
        }
    }

    func startProxyServer(
        port: UInt16,
        allowlist: [String],
        mitmEnabled: Bool
    ) async throws {
        VPNLog.proxy.info("event=vpn.runtime_create_server port=\(port) allowlist_count=\(allowlist.count) mitm_enabled=\(mitmEnabled)")

        let server = MITMProxyServer(port: port, eventLog: eventLog)
        server.setDualMITMPolicyEngine(dualMITMPolicyEngine)
        let enforcedProxy = await HardeningConfig.shared.dualMITMPolicyEngineEnforcedProxy
        server.setDualMITMProxyPolicyEnforcement(enforcedProxy)

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

    private func emitInterceptionEvent(_ event: InterceptionEvent) {
        guard let eventLog else { return }
        var redacted = event
        if let host = redacted.destinationHost {
            if redacted.destinationHostHash == nil {
                redacted.destinationHostHash = LogRedaction.hash(host)
            }
            redacted.destinationHost = nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(redacted),
              let json = String(data: data, encoding: .utf8) else { return }
        eventLog.append(type: "interception_event", msg: json)
    }
}
