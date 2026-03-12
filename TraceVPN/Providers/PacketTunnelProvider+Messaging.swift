//
//  PacketTunnelProvider+Messaging.swift
//  TraceVPN
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import NetworkExtension
import OSLog
import TraceCore
import TraceProxy
import TraceSecurity

extension PacketTunnelProvider {
    func handleMessage(
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

        completionHandler.call(nil)
    }

    func decodeAppMessage(from data: Data) throws -> AppMessage {
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

    func respondWithHardeningConfig(_ completionHandler: AppMessageCompletion) async {
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

    func respondWithRootCAFingerprint(_ completionHandler: AppMessageCompletion) {
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

    func updateConfiguration(_ config: [String: Any]) async {
        let boxedConfig = UnsafeSendable(config)
        await runtimeState.updateProxyConfiguration(boxedConfig)
        await refreshCaptureConfiguration()
    }

    func refreshCaptureConfiguration() async {
        let config = AppGroupStorage.shared.loadConfiguration()
        let previousCaptureMode = currentCaptureMode
        let trimmedHost = config.fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        let socksHostHash = LogRedaction.hash(trimmedHost)
        let transparentTCPMITMEnabled = effectiveTransparentTCPMITMEnabled(for: config)
        VPNLog.tunnel.info(
            "event=vpn.capture_config mode=\(config.captureMode.rawValue, privacy: .public) socks_host_hash=\(socksHostHash) socks_host_len=\(trimmedHost.count) socks_port=\(config.fullTunnelSocks5Port) ipv6=\(config.fullTunnelIPv6Enabled) udp_mode=\(config.fullTunnelUDPForwardingMode.rawValue, privacy: .public) hybrid_tcp_mitm=\(config.fullTunnelHybridTCPMITMEnabled) tcp_transparent_mitm=\(transparentTCPMITMEnabled) dns_servers=\(config.fullTunnelDNSServers.count) search_domains=\(config.fullTunnelSearchDomains.count) dual_mitm_policy=\(config.dualMITMPolicy.rawValue, privacy: .public) tcp_bypass_ttl=\(config.tcpBypassTTLSeconds) quic_fail_open_ttl=\(config.quicHostFailOpenSeconds) dual_mitm_breaker=\(config.dualMITMCircuitBreakerEnabled) quic_no_progress_grace_ms=\(config.quicNoProgressGraceMs) quic_no_progress_idle_ms=\(config.quicNoProgressIdleMs) quic_no_progress_absolute_ms=\(config.quicNoProgressAbsoluteMs) quic_no_progress_min_client_datagrams=\(config.quicNoProgressMinClientDatagrams) quic_authority_retry_attempts=\(config.quicAuthorityRetryAttempts) quic_cert_material_cache_ttl=\(config.quicCertMaterialCacheTTLSeconds)"
        )
        await runtimeState.appendEventLog(
            type: "capture_config",
            msg: "mode=\(config.captureMode.rawValue) socks_host_hash=\(socksHostHash) socks_host_len=\(trimmedHost.count) socks_port=\(config.fullTunnelSocks5Port) ipv6=\(config.fullTunnelIPv6Enabled) udp_mode=\(config.fullTunnelUDPForwardingMode.rawValue) hybrid_tcp_mitm=\(config.fullTunnelHybridTCPMITMEnabled) tcp_transparent_mitm=\(transparentTCPMITMEnabled) dns_servers=\(config.fullTunnelDNSServers.count) search_domains=\(config.fullTunnelSearchDomains.count) dual_mitm_policy=\(config.dualMITMPolicy.rawValue) tcp_bypass_ttl=\(config.tcpBypassTTLSeconds) quic_fail_open_ttl=\(config.quicHostFailOpenSeconds) dual_mitm_breaker=\(config.dualMITMCircuitBreakerEnabled) quic_no_progress_grace_ms=\(config.quicNoProgressGraceMs) quic_no_progress_idle_ms=\(config.quicNoProgressIdleMs) quic_no_progress_absolute_ms=\(config.quicNoProgressAbsoluteMs) quic_no_progress_min_client_datagrams=\(config.quicNoProgressMinClientDatagrams) quic_authority_retry_attempts=\(config.quicAuthorityRetryAttempts) quic_cert_material_cache_ttl=\(config.quicCertMaterialCacheTTLSeconds)"
        )

        let rawCaptureEnabled = await HardeningConfig.shared.enableRawCapture
        let rawCaptureLimit = await HardeningConfig.shared.maxRawCaptureSize
        let dualMITMPolicyEngineShadow = await HardeningConfig.shared.dualMITMPolicyEngineShadow
        let dualMITMPolicyEngineEnforcedTCP = await HardeningConfig.shared.dualMITMPolicyEngineEnforcedTCP
        let dualMITMPolicyEngineEnforcedProxy = await HardeningConfig.shared.dualMITMPolicyEngineEnforcedProxy
        let dualMITMPolicyEngineEnforcedQUIC = await HardeningConfig.shared.dualMITMPolicyEngineEnforcedQUIC
        let dualMITMHttp2MITMEnabled = await HardeningConfig.shared.dualMITMHttp2MITMEnabled
        let dualMITMStrictEnforcementHardFail = await HardeningConfig.shared.dualMITMStrictEnforcementHardFail
        let enableProxyPCAP = shouldEnableProxyPCAP(rawCaptureEnabled: rawCaptureEnabled, mode: config.captureMode)
        let proxyWriter = await createPCAPWriterIfNeeded(enabled: enableProxyPCAP)
        await runtimeState.configureRawCapture(
            enabled: enableProxyPCAP,
            limit: rawCaptureLimit,
            writer: proxyWriter
        )
        let reconfigEventSink: @Sendable (String, String) -> Void = { [weak self] type, msg in
            guard let self else { return }
            Task {
                await self.runtimeState.appendEventLog(type: type, msg: msg)
            }
        }

        do {
            try await captureRuntimeController.performReconfiguration(
                currentMode: previousCaptureMode,
                newMode: config.captureMode,
                reason: "capture_config_refresh",
                eventSink: reconfigEventSink
            ) { [weak self] plan in
                guard let self else { throw PacketTunnelProviderError.providerUnavailable }
                await self.runtimeState.appendEventLog(
                    type: "reconfig_step",
                    msg: "id=\(plan.id) step=network_settings"
                )
                try await self.configureNetworkSettings(using: config)
                await self.runtimeState.appendEventLog(
                    type: "reconfig_step",
                    msg: "id=\(plan.id) step=proxy_ingress_mode"
                )
                await self.applyProxyIngressMode(for: config)
                await self.runtimeState.appendEventLog(
                    type: "reconfig_step",
                    msg: "id=\(plan.id) step=packet_flow"
                )
                let packetCaptureWriter = self.createPacketCaptureWriterIfNeeded(
                    enabled: rawCaptureEnabled && config.captureMode.usesPacketTunnelRouting
                )
                let flowConfig = PacketTunnelRuntimeState.PacketFlowConfig(
                    packetFlow: self.packetFlow,
                    mode: config.captureMode,
                    mtu: self.fullTunnelMTU,
                    captureEnabled: rawCaptureEnabled,
                    captureLimit: rawCaptureLimit,
                    writer: packetCaptureWriter,
                    socks5Host: config.fullTunnelSocks5Host,
                    socks5Port: config.fullTunnelSocks5Port,
                    localSocks5Host: self.localSocks5Host,
                    localSocks5Port: self.localSocks5Port,
                    udpForwardingMode: config.fullTunnelUDPForwardingMode,
                    ipv6Enabled: config.fullTunnelIPv6Enabled,
                    tcpTransparentMITMEnabled: self.effectiveTransparentTCPMITMEnabled(for: config),
                    tcpTransparentMITMPorts: self.transparentMITMPorts,
                    mitmProxyHost: self.proxyHost,
                    mitmProxyPort: self.proxyPort,
                    dualMITMPolicy: config.dualMITMPolicy,
                    tcpBypassTTLSeconds: config.tcpBypassTTLSeconds,
                    quicHostFailOpenSeconds: config.quicHostFailOpenSeconds,
                    dualMITMCircuitBreakerEnabled: config.dualMITMCircuitBreakerEnabled,
                    quicNoProgressGraceMs: config.quicNoProgressGraceMs,
                    quicNoProgressIdleMs: config.quicNoProgressIdleMs,
                    quicNoProgressAbsoluteMs: config.quicNoProgressAbsoluteMs,
                    quicNoProgressMinClientDatagrams: config.quicNoProgressMinClientDatagrams,
                    quicAuthorityRetryAttempts: config.quicAuthorityRetryAttempts,
                    quicCertMaterialCacheTTLSeconds: config.quicCertMaterialCacheTTLSeconds,
                    dualMITMPolicyEngineShadowEnabled: dualMITMPolicyEngineShadow,
                    dualMITMPolicyEngineEnforcedTCP: dualMITMPolicyEngineEnforcedTCP,
                    dualMITMPolicyEngineEnforcedProxy: dualMITMPolicyEngineEnforcedProxy,
                    dualMITMPolicyEngineEnforcedQUIC: dualMITMPolicyEngineEnforcedQUIC,
                    dualMITMHttp2MITMEnabled: dualMITMHttp2MITMEnabled,
                    dualMITMStrictEnforcementHardFail: dualMITMStrictEnforcementHardFail
                )
                await self.runtimeState.configurePacketFlow(flowConfig)
            }
            currentCaptureMode = config.captureMode
            await runtimeState.appendEventLog(
                type: "capture_mode_update",
                msg: "mode=\(config.captureMode.rawValue)"
            )
            VPNLog.tunnel.info("event=vpn.capture_mode_refresh outcome=success mode=\(config.captureMode.rawValue)")
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.capture_mode_refresh outcome=failure mode=\(config.captureMode.rawValue) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func updateHardeningConfiguration(_ config: [String: Any]) async {
        let hardeningConfig = HardeningConfig.shared
        var shouldRefreshCaptureFlow = false
        var shouldRefreshProxyIngress = false

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
            let enableProxyPCAP = shouldEnableProxyPCAP(rawCaptureEnabled: enableRawCapture, mode: currentCaptureMode)
            let writer = await createPCAPWriterIfNeeded(enabled: enableProxyPCAP)
            await runtimeState.configureRawCapture(
                enabled: enableProxyPCAP,
                limit: limit,
                writer: writer
            )
            if currentCaptureMode.usesPacketTunnelRouting {
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
            if currentCaptureMode.usesPacketTunnelRouting {
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

        let requestedNIOMITM = (config["enableNIOMITM"] as? Bool) ?? (config["enableNetworkFrameworkMITM"] as? Bool)
        if let requestedNIOMITM {
            await hardeningConfig.setEnableNIOMITM(requestedNIOMITM)
            let caTrusted = CertificateManager.shared.isRootCATrusted()
            let effectiveMitmEnabled = requestedNIOMITM && caTrusted
            await runtimeState.setMitmEnabled(effectiveMitmEnabled)
            await runtimeState.appendEventLog(
                type: "mitm_enabled_update",
                msg: "requested=\(requestedNIOMITM) effective=\(effectiveMitmEnabled) ca_trusted=\(caTrusted)"
            )
            if requestedNIOMITM && !caTrusted {
                VPNLog.certificate.warning("event=vpn.ca_trust_missing outcome=warning action=disable_mitm")
                await runtimeState.appendEventLog(
                    type: "mitm_disabled",
                    msg: "reason=ca_not_trusted (runtime)"
                )
            }
        }

        if let quicHandlingModeRaw = config["quicHandlingMode"] as? String,
           let quicHandlingMode = QUICHandlingMode(rawValue: quicHandlingModeRaw) {
            await hardeningConfig.setQUICHandlingMode(quicHandlingMode)
            await runtimeState.setQUICHandlingMode(quicHandlingMode)
            await runtimeState.appendEventLog(
                type: "quic_mode",
                msg: "mode=\(quicHandlingMode.rawValue) block_quic=\(quicHandlingMode.blocksQUIC)"
            )
        } else if let blockQUIC = config["blockQUIC"] as? Bool {
            await hardeningConfig.setBlockQUIC(blockQUIC)
            let mode: QUICHandlingMode = blockQUIC ? .block : .passThrough
            await runtimeState.setQUICHandlingMode(mode)
            await runtimeState.appendEventLog(type: "block_quic", msg: "\(blockQUIC)")
        }

        if let policyShadowEnabled = config["dualMitmPolicyEngineShadow"] as? Bool {
            await hardeningConfig.setDualMITMPolicyEngineShadow(policyShadowEnabled)
            shouldRefreshCaptureFlow = true
            await runtimeState.appendEventLog(
                type: "dual_mitm_policy_shadow",
                msg: "enabled=\(policyShadowEnabled)"
            )
        }

        if let policyEnforcedTCP = config["dualMitmPolicyEngineEnforcedTCP"] as? Bool {
            await hardeningConfig.setDualMITMPolicyEngineEnforcedTCP(policyEnforcedTCP)
            shouldRefreshCaptureFlow = true
            await runtimeState.appendEventLog(
                type: "dual_mitm_policy_tcp_enforced",
                msg: "enabled=\(policyEnforcedTCP)"
            )
        }

        if let policyEnforcedProxy = config["dualMitmPolicyEngineEnforcedProxy"] as? Bool {
            await hardeningConfig.setDualMITMPolicyEngineEnforcedProxy(policyEnforcedProxy)
            shouldRefreshCaptureFlow = true
            shouldRefreshProxyIngress = true
            await runtimeState.appendEventLog(
                type: "dual_mitm_policy_proxy_enforced",
                msg: "enabled=\(policyEnforcedProxy)"
            )
        }

        if let policyEnforcedQUIC = config["dualMitmPolicyEngineEnforcedQUIC"] as? Bool {
            await hardeningConfig.setDualMITMPolicyEngineEnforcedQUIC(policyEnforcedQUIC)
            shouldRefreshCaptureFlow = true
            await runtimeState.appendEventLog(
                type: "dual_mitm_policy_quic_enforced",
                msg: "enabled=\(policyEnforcedQUIC)"
            )
        }

        if let http2MITMEnabled = config["dualMitmHttp2MITMEnabled"] as? Bool {
            await hardeningConfig.setDualMITMHttp2MITMEnabled(http2MITMEnabled)
            shouldRefreshCaptureFlow = true
            shouldRefreshProxyIngress = true
            await runtimeState.appendEventLog(
                type: "dual_mitm_http2_mitm",
                msg: "enabled=\(http2MITMEnabled)"
            )
        }

        if let strictHardFail = config["dualMitmStrictEnforcementHardFail"] as? Bool {
            await hardeningConfig.setDualMITMStrictEnforcementHardFail(strictHardFail)
            shouldRefreshCaptureFlow = true
            shouldRefreshProxyIngress = true
            await runtimeState.appendEventLog(
                type: "dual_mitm_strict_hard_fail",
                msg: "enabled=\(strictHardFail)"
            )
        }

        await hardeningConfig.logCurrentConfig()

        let shouldRunCaptureRefresh = shouldRefreshCaptureFlow && currentCaptureMode.usesPacketTunnelRouting
        if shouldRefreshProxyIngress, !shouldRunCaptureRefresh {
            let captureConfig = AppGroupStorage.shared.loadConfiguration()
            await applyProxyIngressMode(for: captureConfig)
        }
        if shouldRunCaptureRefresh {
            await refreshCaptureConfiguration()
        }
    }

    func readUInt64(from value: Any?) -> UInt64? {
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

    func configureCaptureSettings(for mode: CaptureMode) async {
        let config = HardeningConfig.shared
        let rawCaptureEnabled = await config.enableRawCapture
        let rawCaptureLimit = await config.maxRawCaptureSize
        let quicHandlingMode = await config.quicHandlingMode

        let enableProxyPCAP = shouldEnableProxyPCAP(rawCaptureEnabled: rawCaptureEnabled, mode: mode)
        let writer = await createPCAPWriterIfNeeded(enabled: enableProxyPCAP)
        await runtimeState.configureRawCapture(
            enabled: enableProxyPCAP,
            limit: rawCaptureLimit,
            writer: writer
        )
        await runtimeState.setQUICHandlingMode(quicHandlingMode)
    }

    func applyProxyIngressMode(for config: CaptureConfiguration) async {
        let transparentTLSModeEnabled = effectiveTransparentTCPMITMEnabled(for: config)
        let enforcedProxy = await HardeningConfig.shared.dualMITMPolicyEngineEnforcedProxy
        let http2MITMEnabled = await HardeningConfig.shared.dualMITMHttp2MITMEnabled
        let strictHardFail = await HardeningConfig.shared.dualMITMStrictEnforcementHardFail
        let payload: UnsafeSendable<[String: Any]> = UnsafeSendable(
            [
                "transparentTLSModeEnabled": transparentTLSModeEnabled,
                "dualMitmPolicyEngineEnforcedProxy": enforcedProxy,
                "dualMitmHttp2MITMEnabled": http2MITMEnabled,
                "dualMitmStrictEnforcementHardFail": strictHardFail
            ]
        )
        await runtimeState.updateProxyConfiguration(payload)
        await runtimeState.appendEventLog(
            type: "proxy_ingress_mode",
            msg: "mode=\(config.captureMode.rawValue) transparent_tls=\(transparentTLSModeEnabled) hybrid_tcp_mitm=\(config.fullTunnelHybridTCPMITMEnabled) policy_enforced_proxy=\(enforcedProxy) http2_mitm=\(http2MITMEnabled) strict_hard_fail=\(strictHardFail)"
        )
    }

    func effectiveTransparentTCPMITMEnabled(for config: CaptureConfiguration) -> Bool {
        config.captureMode.enablesTCPTransparentMITM ||
            (config.captureMode == .fullTunnel && config.fullTunnelHybridTCPMITMEnabled)
    }

    func shouldEnableProxyPCAP(rawCaptureEnabled: Bool, mode: CaptureMode) -> Bool {
        rawCaptureEnabled && mode == .proxyOnly
    }

    func createPCAPWriterIfNeeded(enabled: Bool) async -> PCAPWriting? {
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

    func createPacketCaptureWriterIfNeeded(enabled: Bool) -> PCAPWriting? {
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

    func initializeEventLog(mode: CaptureMode) async {
        do {
            let logWriter = try NDJSONLogWriter(
                appGroupID: AppGroupConfiguration.appGroupIdentifier,
                fileName: "vpn_events.ndjson"
            )
            eventLogQueue.sync {
                self.eventLogWriter = logWriter
            }
            await runtimeState.setEventLog(logWriter)
            await runtimeState.appendEventLog(type: "startup", msg: "Tunnel started mode=\(mode.rawValue)")
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.ndjson_logger_start outcome=failure error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    func preloadRootCertificate() async {
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

    func loadInitialThrottlingState() {
        let state = AppGroupStorage.shared.loadThrottlingState()
        applyThrottlingState(state, reason: "startup")
    }

    func applyThrottlingState(_ state: NetworkThrottlingState, reason: String) {
        Task {
            await runtimeState.applyThrottlingState(state, reason: reason)
        }
    }

    func clearCapturedRequests() async {
        do {
            try AppGroupStorage.shared.clearAllRequests()
            try AppGroupStorage.shared.clearAllTransportRequests()
            VPNLog.tunnel.info("event=vpn.capture_clear outcome=success")
        } catch {
            VPNLog.tunnel.error(
                "event=vpn.capture_clear outcome=failure error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}
