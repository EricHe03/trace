//
//  TunnelProviderConfiguration.swift
//  TraceVPN
//
//  Created by Codex on 2026/03/17.
//

import Foundation
import NetworkExtension
import TraceCore
import TraceProxy

struct TunnelProviderEnvironment: Sendable {
    struct ProxyEndpoint: Sendable {
        let host: String
        let port: UInt16
    }

    struct LocalSocksEndpoint: Sendable {
        let host: String
        let preferredPort: UInt16
    }

    let proxy: ProxyEndpoint
    let localSocks: LocalSocksEndpoint
    let fullTunnelMTU: Int
    let transparentMITMPorts: Set<UInt16>
}

struct TunnelHardeningConfiguration: Sendable {
    let enableMetrics: Bool
    let enableDebugLogging: Bool
    let enableRawCapture: Bool
    let maxRawCaptureSize: UInt64
    let mitmAllowlist: [String]
    let quicHandlingMode: QUICHandlingMode
    let enableNIOMITM: Bool
    let dualMITMPolicyEngineShadow: Bool
    let dualMITMPolicyEngineEnforcedTCP: Bool
    let dualMITMPolicyEngineEnforcedProxy: Bool
    let dualMITMPolicyEngineEnforcedQUIC: Bool
    let dualMITMHttp2MITMEnabled: Bool
    let dualMITMStrictEnforcementHardFail: Bool

    init(snapshot: HardeningConfigSnapshot) {
        enableMetrics = snapshot.enableMetrics
        enableDebugLogging = snapshot.enableDebugLogging
        enableRawCapture = snapshot.enableRawCapture
        maxRawCaptureSize = snapshot.maxRawCaptureSize
        mitmAllowlist = snapshot.mitmAllowlist
        quicHandlingMode = QUICHandlingMode(rawValue: snapshot.quicHandlingMode)
            ?? (snapshot.blockQUIC ? .block : .passThrough)
        enableNIOMITM = snapshot.enableNIOMITM
        dualMITMPolicyEngineShadow = snapshot.dualMITMPolicyEngineShadow
        dualMITMPolicyEngineEnforcedTCP = snapshot.dualMITMPolicyEngineEnforcedTCP
        dualMITMPolicyEngineEnforcedProxy = snapshot.dualMITMPolicyEngineEnforcedProxy
        dualMITMPolicyEngineEnforcedQUIC = snapshot.dualMITMPolicyEngineEnforcedQUIC
        dualMITMHttp2MITMEnabled = snapshot.dualMITMHttp2MITMEnabled
        dualMITMStrictEnforcementHardFail = snapshot.dualMITMStrictEnforcementHardFail
    }
}

struct TunnelProxyIngressConfiguration: Sendable, Equatable {
    let transparentTLSModeEnabled: Bool
    let dualMITMPolicyEngineEnforcedProxy: Bool
    let dualMITMHttp2MITMEnabled: Bool
    let dualMITMStrictEnforcementHardFail: Bool

    func asDictionary() -> [String: Any] {
        [
            "transparentTLSModeEnabled": transparentTLSModeEnabled,
            "dualMitmPolicyEngineEnforcedProxy": dualMITMPolicyEngineEnforcedProxy,
            "dualMitmHttp2MITMEnabled": dualMITMHttp2MITMEnabled,
            "dualMitmStrictEnforcementHardFail": dualMITMStrictEnforcementHardFail
        ]
    }

    var eventLogMessage: String {
        "transparent_tls=\(transparentTLSModeEnabled) policy_enforced_proxy=\(dualMITMPolicyEngineEnforcedProxy) http2_mitm=\(dualMITMHttp2MITMEnabled) strict_hard_fail=\(dualMITMStrictEnforcementHardFail)"
    }
}

struct TunnelProviderConfiguration: Sendable {
    let capture: CaptureConfiguration
    let hardening: TunnelHardeningConfiguration
    let environment: TunnelProviderEnvironment

    init(
        capture: CaptureConfiguration,
        hardeningSnapshot: HardeningConfigSnapshot,
        environment: TunnelProviderEnvironment
    ) {
        self.capture = capture
        self.hardening = TunnelHardeningConfiguration(snapshot: hardeningSnapshot)
        self.environment = environment
    }

    var captureMode: CaptureMode {
        capture.captureMode
    }

    var proxyRawCaptureEnabled: Bool {
        hardening.enableRawCapture && captureMode == .proxyOnly
    }

    var packetCaptureEnabled: Bool {
        hardening.enableRawCapture && captureMode.usesPacketTunnelRouting
    }

    var transparentTCPMITMEnabled: Bool {
        captureMode.enablesTCPTransparentMITM ||
            (captureMode == .fullTunnel && capture.fullTunnelHybridTCPMITMEnabled)
    }

    var proxyIngress: TunnelProxyIngressConfiguration {
        TunnelProxyIngressConfiguration(
            transparentTLSModeEnabled: transparentTCPMITMEnabled,
            dualMITMPolicyEngineEnforcedProxy: hardening.dualMITMPolicyEngineEnforcedProxy,
            dualMITMHttp2MITMEnabled: hardening.dualMITMHttp2MITMEnabled,
            dualMITMStrictEnforcementHardFail: hardening.dualMITMStrictEnforcementHardFail
        )
    }

    var captureLogMessage: String {
        let trimmedHost = capture.fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        let socksHostHash = LogRedaction.hash(trimmedHost)
        return "mode=\(captureMode.rawValue) socks_host_hash=\(socksHostHash) socks_host_len=\(trimmedHost.count) socks_port=\(capture.fullTunnelSocks5Port) ipv6=\(capture.fullTunnelIPv6Enabled) udp_mode=\(capture.fullTunnelUDPForwardingMode.rawValue) hybrid_tcp_mitm=\(capture.fullTunnelHybridTCPMITMEnabled) tcp_transparent_mitm=\(transparentTCPMITMEnabled) dns_servers=\(capture.fullTunnelDNSServers.count) search_domains=\(capture.fullTunnelSearchDomains.count) dual_mitm_policy=\(capture.dualMITMPolicy.rawValue) tcp_bypass_ttl=\(capture.tcpBypassTTLSeconds) quic_fail_open_ttl=\(capture.quicHostFailOpenSeconds) dual_mitm_breaker=\(capture.dualMITMCircuitBreakerEnabled) quic_mode=\(hardening.quicHandlingMode.rawValue) quic_no_progress_grace_ms=\(capture.quicNoProgressGraceMs) quic_no_progress_idle_ms=\(capture.quicNoProgressIdleMs) quic_no_progress_absolute_ms=\(capture.quicNoProgressAbsoluteMs) quic_no_progress_min_client_datagrams=\(capture.quicNoProgressMinClientDatagrams) quic_authority_retry_attempts=\(capture.quicAuthorityRetryAttempts) quic_cert_material_cache_ttl=\(capture.quicCertMaterialCacheTTLSeconds)"
    }

    func makePacketFlowConfig(
        packetFlow: NEPacketTunnelFlow,
        packetCaptureWriter: PCAPWriting?
    ) -> PacketTunnelRuntimeState.PacketFlowConfig {
        PacketTunnelRuntimeState.PacketFlowConfig(
            packetFlow: packetFlow,
            captureMode: captureMode,
            mtu: environment.fullTunnelMTU,
            packetCapture: .init(
                enabled: hardening.enableRawCapture,
                limit: hardening.maxRawCaptureSize,
                writer: packetCaptureWriter
            ),
            socks: .init(
                remoteHost: capture.fullTunnelSocks5Host,
                remotePort: capture.fullTunnelSocks5Port,
                localHost: environment.localSocks.host,
                preferredLocalPort: environment.localSocks.preferredPort
            ),
            udp: .init(
                forwardingMode: capture.fullTunnelUDPForwardingMode,
                ipv6Enabled: capture.fullTunnelIPv6Enabled
            ),
            transparentProxy: .init(
                enabled: transparentTCPMITMEnabled,
                interceptPorts: environment.transparentMITMPorts,
                proxyHost: environment.proxy.host,
                proxyPort: environment.proxy.port
            ),
            dualMITM: .init(
                policy: capture.dualMITMPolicy,
                tcpBypassTTLSeconds: capture.tcpBypassTTLSeconds,
                quicHostFailOpenSeconds: capture.quicHostFailOpenSeconds,
                circuitBreakerEnabled: capture.dualMITMCircuitBreakerEnabled,
                quicNoProgressGraceMs: capture.quicNoProgressGraceMs,
                quicNoProgressIdleMs: capture.quicNoProgressIdleMs,
                quicNoProgressAbsoluteMs: capture.quicNoProgressAbsoluteMs,
                quicNoProgressMinClientDatagrams: capture.quicNoProgressMinClientDatagrams,
                quicAuthorityRetryAttempts: capture.quicAuthorityRetryAttempts,
                quicCertMaterialCacheTTLSeconds: capture.quicCertMaterialCacheTTLSeconds,
                shadowEnabled: hardening.dualMITMPolicyEngineShadow,
                enforceTCPRouting: hardening.dualMITMPolicyEngineEnforcedTCP,
                enforceProxyRouting: hardening.dualMITMPolicyEngineEnforcedProxy,
                enforceQUICRouting: hardening.dualMITMPolicyEngineEnforcedQUIC,
                http2MITMEnabled: hardening.dualMITMHttp2MITMEnabled,
                strictEnforcementHardFail: hardening.dualMITMStrictEnforcementHardFail
            )
        )
    }
}
