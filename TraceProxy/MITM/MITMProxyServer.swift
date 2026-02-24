//
//  MITMProxyServer.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import OSLog
import TraceCore
import TraceFeatures

/// Provides a MITM HTTP/HTTPS proxy server.
/// Runs inside the Network Extension and handles HTTP/HTTPS traffic routed to the local proxy
/// (proxy-only mode via the tunnel's `proxySettings`).
public class MITMProxyServer: @unchecked Sendable {
    private struct TransientFailureTracker {
        var firstFailureAt: Date
        var lastFailureAt: Date
        var count: Int
    }

    private struct RuntimeBypassState {
        let reason: String
        let expiresAt: Date
    }

    private let port: UInt16
    private var mitmEngine: (any MITMEngine)?
    private var dualMITMPolicyEngine: DualMITMPolicyEngine?

    // Concurrency: Serialize mutable state and persistence I/O to avoid cross-connection races.
    private let queue = DispatchQueue(label: "com.trace.proxy", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()

    private var configuration: [String: Any] = [:]
    private var cleanupTimer: DispatchSourceTimer?
    private var mitmAllowlist: [String] = []
    private var mitmEnabled = false
    private var dualMITMPolicyEngineEnforcedProxy = false
    private var dualMITMMITMEngineV2Enabled = false
    private var dualMITMHttp2MITMEnabled = false
    private var dualMITMStrictEnforcementHardFail = true
    // Rule: Transparent TLS accepts raw ClientHello bytes without an HTTP CONNECT and must be
    // explicitly enabled because it is outside the explicit HTTP proxy contract.
    private var transparentTLSModeEnabled = false

    // Rationale: Inject the event log to avoid multiple writers racing on the same file.
    private weak var eventLog: NDJSONLogWriter?
    private let throttler = PacketThrottler()
    private var pcapWriter: PCAPWriting?
    private var rawCaptureEnabled = false
    private var rawCaptureLimit: UInt64 = 0
    // Rule: Track bytes written to cap captures and avoid unbounded disk usage.
    private var rawCaptureBytes: UInt64 = 0
    private var logSampler = LogSampler()
    private var samplingSequence: Int = 0
    private var transientFailureTrackers: [String: TransientFailureTracker] = [:]
    private var runtimeBypassStates: [String: RuntimeBypassState] = [:]
    private let transientFailureThreshold = 5
    private let transientFailureWindow: TimeInterval = 20
    private let transientFailureRetention: TimeInterval = 120
    private var runtimeBypassTTL: TimeInterval = 180

    /// Creates a local-only MITM proxy bound to loopback, with an optional shared event log sink.
    public init(port: UInt16, eventLog: NDJSONLogWriter? = nil) {
        self.port = port
        self.eventLog = eventLog
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Updates the throttling state.
    public func updateThrottlingState(_ state: NetworkThrottlingState) {
        throttler.updateState(state)
    }

    /// Configures raw capture settings.
    public func configureRawCapture(enabled: Bool, writer: PCAPWriting?, limit: UInt64) {
        performOnQueue {
            self.rawCaptureEnabled = enabled
            self.pcapWriter = writer
            self.rawCaptureLimit = limit
            self.rawCaptureBytes = writer?.currentFileSize() ?? 0
        }
    }

    /// Updates the capture size limit without restarting capture.
    public func updateRawCaptureLimit(_ limit: UInt64) {
        performOnQueue {
            self.rawCaptureLimit = limit
        }
    }

    private func writeToPCAP(_ data: Data, isRequest: Bool) {
        guard self.rawCaptureEnabled, let writer = self.pcapWriter else { return }

        guard let packet = PCAPHTTPPacketSynthesizer.makePacket(payload: data, proxyPort: self.port, isRequest: isRequest) else {
            return
        }

        if self.rawCaptureLimit > 0 {
            let projected = self.rawCaptureBytes + UInt64(packet.count)
            if projected > self.rawCaptureLimit {
                // Rule: Disable further capture to keep the PCAP bounded and avoid truncating packets.
                self.rawCaptureEnabled = false
                ProxyLog.metrics.warning("event=pcap.capture_limit_reached outcome=disabled limit=\(self.rawCaptureLimit) current=\(self.rawCaptureBytes)")
                return
            }
            self.rawCaptureBytes = projected
        }

        writer.writePacket(packet)
    }

    // MARK: - Server Lifecycle

    /// Starts the listener and housekeeping timers.
    public func start() throws {
        if mitmEngine != nil {
            return
        }

        let interceptor: (any InterceptionProviding)? = RequestInterceptor.shared

        let engine = makeMITMEngine(
            port: port,
            eventLog: eventLog,
            throttler: throttler,
            interceptor: interceptor,
            captureConfigProvider: { AppGroupStorage.shared.loadConfiguration() },
            onRequestCaptured: { [weak self] request in
                self?.performOnQueue {
                    self?.handleCapturedRequest(request)
                }
            },
            shouldMitmConnect: { [weak self] host, port in
                guard let self else { return false }
                return self.performOnQueueSync {
                    self.shouldAttemptMITM(host: host, port: port)
                }
            },
            isTransparentTLSEnabled: { [weak self] in
                guard let self else { return false }
                return self.performOnQueueSync {
                    self.transparentTLSModeEnabled
                }
            },
            shouldFailOpenAfterMITMFailure: { [weak self] host, port, reason, context in
                guard let self else { return true }
                return self.performOnQueueSync {
                    self.shouldFailOpenAfterMITMFailure(
                        host: host,
                        port: port,
                        reason: reason,
                        context: context
                    )
                }
            },
            onMITMFailure: { [weak self] host, reason in
                guard let self else { return }
                self.performOnQueue {
                    self.recordMITMFailure(host: host, reason: reason)
                }
            }
        )

        try engine.start()
        self.mitmEngine = engine
        startCleanupTimer()

        ProxyLog.mitm.info(
            "event=proxy.server_start outcome=success backend=\(self.dualMITMMITMEngineV2Enabled ? "nio_v2" : "nio")"
        )
    }

    private func makeMITMEngine(
        port: UInt16,
        eventLog: NDJSONLogWriter?,
        throttler: PacketThrottler,
        interceptor: (any InterceptionProviding)?,
        captureConfigProvider: @escaping () -> CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?,
        shouldMitmConnect: @escaping (String, UInt16) -> Bool,
        isTransparentTLSEnabled: @escaping () -> Bool,
        shouldFailOpenAfterMITMFailure: @escaping (String, UInt16, String, MITMFailoverContext) -> Bool,
        onMITMFailure: ((String, String) -> Void)?
    ) -> any MITMEngine {
        if dualMITMMITMEngineV2Enabled {
            return MITMEngineV2(
                port: port,
                eventLog: eventLog,
                throttler: throttler,
                interceptor: interceptor,
                captureConfigProvider: captureConfigProvider,
                onRequestCaptured: onRequestCaptured,
                shouldMitmConnect: shouldMitmConnect,
                isTransparentTLSEnabled: isTransparentTLSEnabled,
                shouldFailOpenAfterMITMFailure: shouldFailOpenAfterMITMFailure,
                onMITMFailure: onMITMFailure
            )
        }

        return NIOMITMProxyEngine(
            port: port,
            eventLog: eventLog,
            throttler: throttler,
            interceptor: interceptor,
            captureConfigProvider: captureConfigProvider,
            onRequestCaptured: onRequestCaptured,
            shouldMitmConnect: shouldMitmConnect,
            isTransparentTLSEnabled: isTransparentTLSEnabled,
            shouldFailOpenAfterMITMFailure: shouldFailOpenAfterMITMFailure,
            onMITMFailure: onMITMFailure
        )
    }

    /// Stops the listener and closes all active connections.
    public func stop() {
        cleanupTimer?.cancel()
        cleanupTimer = nil

        mitmEngine?.stop()
        mitmEngine = nil

        ProxyLog.mitm.info("event=proxy.server_stop outcome=success")
    }

    // MARK: - Connection Cleanup

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.emitConnectionLifecycleSample()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func emitConnectionLifecycleSample() {
        let active = mitmEngine?.activeConnectionCount() ?? 0
        purgeExpiredRuntimeBypasses(now: Date())
        if active > 0 {
            ProxyLog.mitm.debug("event=proxy.cleanup outcome=success active=\(active)")
        }
    }

    /// Applies runtime configuration flags (kept dynamic for long-lived NE sessions).
    public func updateConfiguration(_ config: [String: Any]) {
        performOnQueue {
            self.configuration = config

            let canonicalKey = "transparentTLSModeEnabled"
            let legacyKey = "enableTransparentTLSMode"

            if let enabled = config[canonicalKey] as? Bool {
                self.transparentTLSModeEnabled = enabled
            } else if let enabled = config[legacyKey] as? Bool {
                self.transparentTLSModeEnabled = enabled
                ProxyLog.mitm.warning("event=proxy.config_legacy_key outcome=success key=\(legacyKey, privacy: .public) mapped_to=\(canonicalKey, privacy: .public)")
            }

            if let enforcedProxy = config["dualMitmPolicyEngineEnforcedProxy"] as? Bool {
                self.dualMITMPolicyEngineEnforcedProxy = enforcedProxy
            }
            if let mitmEngineV2 = config["dualMitmMITMEngineV2"] as? Bool {
                self.dualMITMMITMEngineV2Enabled = mitmEngineV2
            }
            if let http2MITMEnabled = config["dualMitmHttp2MITMEnabled"] as? Bool {
                self.dualMITMHttp2MITMEnabled = http2MITMEnabled
            }
            if let strictHardFail = config["dualMitmStrictEnforcementHardFail"] as? Bool {
                self.dualMITMStrictEnforcementHardFail = strictHardFail
            }
            if let dualMITMPolicyEngine = self.dualMITMPolicyEngine {
                var snapshot = dualMITMPolicyEngine.currentSnapshot()
                snapshot.featureFlags.http2MITMEnabled = self.dualMITMHttp2MITMEnabled
                snapshot.featureFlags.strictEnforcementHardFail = self.dualMITMStrictEnforcementHardFail
                dualMITMPolicyEngine.updateSnapshot(snapshot)
            }

            if config["proxyTransportBackend"] != nil || config["useNIOProxyEngine"] != nil {
                ProxyLog.mitm.info("event=proxy.config_update outcome=ignored key=legacy_backend_toggle backend=nio_only")
            }

            ProxyLog.mitm.debug("event=proxy.config_update outcome=success")
        }
    }

    /// Updates the allowlist used to decide which hosts may be MITM'd.
    public func setMitmAllowlist(_ list: [String]) {
        performOnQueueSync {
            // Rule: Trim and lowercase. An empty list disables MITM for all hosts.
            let sanitized = list
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            self.mitmAllowlist = sanitized
            if let dualMITMPolicyEngine = self.dualMITMPolicyEngine {
                var snapshot = dualMITMPolicyEngine.currentSnapshot()
                snapshot.allowlist = sanitized
                dualMITMPolicyEngine.updateSnapshot(snapshot)
            }

            ProxyLog.mitm.info("event=proxy.allowlist_update outcome=success count=\(self.mitmAllowlist.count)")
            self.eventLog?.append(type: "mitm_allowlist", msg: "size=\(self.mitmAllowlist.count)")
        }
    }

    /// Enables or disables MITM globally (used by hardening and UI toggles).
    public func setMitmEnabled(_ enabled: Bool) {
        performOnQueueSync {
            self.mitmEnabled = enabled
            if let dualMITMPolicyEngine = self.dualMITMPolicyEngine {
                var snapshot = dualMITMPolicyEngine.currentSnapshot()
                snapshot.mitmEnabled = enabled
                dualMITMPolicyEngine.updateSnapshot(snapshot)
            }
            ProxyLog.mitm.info("event=proxy.mitm_toggle outcome=success enabled=\(enabled, privacy: .public)")
            self.eventLog?.append(type: "mitm_enabled", msg: "\(enabled)")
        }
    }

    /// Sets the shared dual-MITM policy engine used for proxy gating and failover decisions.
    public func setDualMITMPolicyEngine(_ engine: DualMITMPolicyEngine?) {
        performOnQueueSync {
            dualMITMPolicyEngine = engine
            if let engine {
                var snapshot = engine.currentSnapshot()
                snapshot.allowlist = mitmAllowlist
                snapshot.mitmEnabled = mitmEnabled
                snapshot.featureFlags.http2MITMEnabled = dualMITMHttp2MITMEnabled
                snapshot.featureFlags.strictEnforcementHardFail = dualMITMStrictEnforcementHardFail
                engine.updateSnapshot(snapshot)
            }
        }
    }

    public func setDualMITMProxyPolicyEnforcement(_ enabled: Bool) {
        performOnQueueSync {
            dualMITMPolicyEngineEnforcedProxy = enabled
        }
    }

    public func setMITMEngineV2Enabled(_ enabled: Bool) {
        performOnQueueSync {
            dualMITMMITMEngineV2Enabled = enabled
        }
    }

    /// Returns the number of active client proxy connections.
    public func activeConnectionCount() -> Int {
        mitmEngine?.activeConnectionCount() ?? 0
    }

    private func performOnQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }

    private func performOnQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return block()
        }
        return queue.sync(execute: block)
    }

    private func handleCapturedRequest(_ request: NetworkRequest) {
        if logSampler.shouldLog(key: "proxy.request_captured", first: 10, every: 200) {
            let protocolVersion = request.protocolVersion?.rawValue ?? "unknown"
            ProxyLog.mitm.debug(
                "event=proxy.request_captured outcome=success method=\(request.method.rawValue, privacy: .public) protocol=\(protocolVersion, privacy: .public) duration_ms=\(Int(request.duration * 1000), privacy: .public) url=\(request.url, privacy: .private(mask: .hash)) request_id=\(request.id.uuidString, privacy: .public)"
            )
        }

        appendProxyCaptureEvent(
            request,
            outcome: "seen"
        )

        let effectiveConfig = AppGroupStorage.shared.loadConfiguration()
        guard shouldPersist(request, using: effectiveConfig) else {
            appendProxyCaptureEvent(
                request,
                outcome: "skipped",
                reason: "filter"
            )
            return
        }
        saveCapturedRequest(request)
    }

    private func saveCapturedRequest(_ request: NetworkRequest) {
        let samplingConfig = AppGroupStorage.shared.loadSamplingConfig()
        guard shouldSample(using: samplingConfig) else {
            appendProxyCaptureEvent(
                request,
                outcome: "skipped",
                reason: "sampling"
            )
            return
        }
        do {
            try AppGroupStorage.shared.saveRequest(request)
            appendProxyCaptureEvent(
                request,
                outcome: "success"
            )
            let hostHash = URL(string: request.url)?.host.map { LogRedaction.hash($0) } ?? "unknown"
            let protocolVersion = request.protocolVersion?.rawValue ?? "http1.1"
            eventLog?.append(
                type: "tcp_plaintext_capture",
                msg: "outcome=decrypted request_id=\(request.id.uuidString) host_hash=\(hostHash) protocol=\(protocolVersion)"
            )
            if logSampler.shouldLog(key: "proxy.request_saved", first: 10, every: 200) {
                let protocolVersion = request.protocolVersion?.rawValue ?? "unknown"
                ProxyLog.mitm.debug(
                    "event=proxy.request_saved outcome=success method=\(request.method.rawValue, privacy: .public) protocol=\(protocolVersion, privacy: .public) duration_ms=\(Int(request.duration * 1000), privacy: .public) url=\(request.url, privacy: .private(mask: .hash)) request_id=\(request.id.uuidString, privacy: .public)"
                )
            }

            if rawCaptureEnabled, pcapWriter != nil {
                captureRequestToPCAP(request)
            }
        } catch {
            ProxyLog.mitm.error("event=proxy.request_saved outcome=failure error=\(error.localizedDescription, privacy: .public)")
            appendProxyCaptureEvent(
                request,
                outcome: "failure",
                reason: "storage_write_failed",
                error: error.localizedDescription
            )
        }
    }

    private func appendProxyCaptureEvent(
        _ request: NetworkRequest,
        outcome: String,
        reason: String? = nil,
        error: String? = nil
    ) {
        let hostHash = URL(string: request.url)?.host.map { LogRedaction.hash($0) } ?? "unknown"
        let protocolVersion = request.protocolVersion?.rawValue ?? "unknown"
        let statusCode = request.statusCode.map(String.init) ?? "nil"
        var fields = [
            "outcome=\(outcome)",
            "request_id=\(request.id.uuidString)",
            "host_hash=\(hostHash)",
            "method=\(request.method.rawValue)",
            "protocol=\(protocolVersion)",
            "status=\(statusCode)"
        ]
        if let reason, !reason.isEmpty {
            fields.append("reason=\(reason)")
        }
        if let error, !error.isEmpty {
            fields.append("error=\(error)")
        }
        eventLog?.append(
            type: "proxy_request_saved",
            msg: fields.joined(separator: " ")
        )
    }

    private func shouldPersist(_ request: NetworkRequest, using config: CaptureConfiguration) -> Bool {
        switch config.filterMode {
        case .all:
            return true
        case .whitelist:
            guard !config.domainFilters.isEmpty else { return false }
        case .blacklist:
            break
        }

        guard let host = URL(string: request.url)?.host?.lowercased(), !host.isEmpty else {
            return config.filterMode != .whitelist
        }

        let matches = config.domainFilters.contains { pattern in
            domainFilterMatches(host: host, pattern: pattern)
        }

        switch config.filterMode {
        case .all:
            return true
        case .whitelist:
            return matches
        case .blacklist:
            return !matches
        }
    }

    private func domainFilterMatches(host: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let p = trimmed.lowercased()
        if p == "*" { return true }
        if p.contains("*") {
            return StringMatcher(matchType: .wildcard, pattern: p, caseSensitive: false).matches(host)
        }
        return host == p || host.hasSuffix("." + p)
    }

    private func shouldAttemptMITM(host: String, port: UInt16) -> Bool {
        guard port > 0 else { return false }

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return false }

        let legacyBypassReason = mitmBypassReason(host: normalizedHost)
        let legacyDecision = legacyBypassReason == nil
        guard let dualMITMPolicyEngine else {
            return legacyDecision
        }

        let policyPlan = dualMITMPolicyEngine.planNewFlow(
            protocolName: .httpConnect,
            destination: HostPort(host: normalizedHost, port: Int(port))
        )
        let policyDecision: Bool
        let policyReason: String
        switch policyPlan.action {
        case .mitm:
            policyDecision = true
            policyReason = "none"
        case let .passThrough(reason), let .direct(reason), let .block(reason):
            policyDecision = false
            policyReason = reason
        }
        let proxyEnforced = policyPlan.enforced || dualMITMPolicyEngineEnforcedProxy

        if policyPlan.shadowEnabled, policyDecision != legacyDecision {
            eventLog?.append(
                type: "dual_mitm_policy_shadow",
                msg: "scope=proxy_gate host_hash=\(LogRedaction.hash(normalizedHost)) port=\(port) legacy_mitm=\(legacyDecision) legacy_reason=\(legacyBypassReason ?? "none") policy_mitm=\(policyDecision) policy_reason=\(policyReason) enforced=\(proxyEnforced)"
            )
        }

        return proxyEnforced ? policyDecision : legacyDecision
    }

    private func shouldFailOpenAfterMITMFailure(
        host: String,
        port: UInt16,
        reason: String,
        context: MITMFailoverContext
    ) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let legacyDecision = legacyShouldFailOpenAfterMITMFailure(
            reason: reason,
            context: context
        )
        guard let dualMITMPolicyEngine,
              !normalizedHost.isEmpty,
              port > 0
        else {
            return legacyDecision
        }

        let protocolName: InterceptionProtocol = switch context {
        case .transparentTLS:
            .tcpTransparent
        case .httpConnect:
            .httpConnect
        }
        let startPlan = dualMITMPolicyEngine.planNewFlow(
            protocolName: protocolName,
            destination: HostPort(host: normalizedHost, port: Int(port))
        )
        let decoded = LegacyReasonCodec.decode(reason)
        let failure = decoded.failure ?? .internalError(code: .legacyUnknownToken, context: reason)
        let policyPlan = dualMITMPolicyEngine.handleFailure(
            profile: startPlan.profile,
            failure: failure
        )
        let policyDecision: Bool
        let policyReason: String
        switch policyPlan.action {
        case let .failOpenPassThrough(reason),
             let .failOpenDirect(reason),
             let .retry(reason):
            policyDecision = true
            policyReason = reason
        case let .failClosedBlock(reason):
            policyDecision = false
            policyReason = reason
        case .noop:
            policyDecision = legacyDecision
            policyReason = reason
        }
        let proxyEnforced = policyPlan.enforced || dualMITMPolicyEngineEnforcedProxy

        if policyPlan.shadowEnabled, policyDecision != legacyDecision {
            eventLog?.append(
                type: "dual_mitm_policy_shadow",
                msg: "scope=proxy_failover context=\(context.rawValue) host_hash=\(LogRedaction.hash(normalizedHost)) port=\(port) failure_reason=\(reason) legacy_fail_open=\(legacyDecision) policy_fail_open=\(policyDecision) policy_reason=\(policyReason) enforced=\(proxyEnforced)"
            )
        }

        return proxyEnforced ? policyDecision : legacyDecision
    }

    private func legacyShouldFailOpenAfterMITMFailure(
        reason: String,
        context: MITMFailoverContext
    ) -> Bool {
        switch context {
        case .transparentTLS:
            let normalized = reason
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return !normalized.contains("sni_invalid_or_missing")
        case .httpConnect:
            return true
        }
    }

    private func mitmBypassReason(host: String) -> String? {
        guard mitmEnabled else { return "disabled" }

        let now = Date()
        if let state = runtimeBypassStates[host], state.expiresAt > now {
            return "runtime auto-bypass (\(state.reason))"
        }
        runtimeBypassStates.removeValue(forKey: host)

        if let detail = MITMAutoBypassLookup.reasonForTCPMITM(host: host) {
            return detail.isEmpty
                ? "auto-bypass (previous MITM failure)"
                : "auto-bypass (\(detail))"
        }

        guard !mitmAllowlist.isEmpty else { return "not allowlisted" }
        guard mitmAllowlist.contains(where: { pattern in
            domainFilterMatches(host: host, pattern: pattern)
        }) else {
            return "not allowlisted"
        }

        return nil
    }

    private func recordMITMFailure(host: String, reason: String) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return }
        let captureConfig = AppGroupStorage.shared.loadConfiguration()
        let policy = captureConfig.dualMITMPolicy
        runtimeBypassTTL = TimeInterval(captureConfig.tcpBypassTTLSeconds)

        if policy == .strictMITM {
            eventLog?.append(
                type: "mitm_auto_bypass",
                msg: "\(LogRedaction.hash(normalizedHost)) outcome=skipped policy=\(policy.rawValue) reason=strict_policy"
            )
            return
        }

        maybeRecordRuntimeBypassForTransientFailure(
            host: normalizedHost,
            reason: reason,
            runtimeBypassTTL: runtimeBypassTTL
        )
        maybeRecordMITMAutoBypass(host: normalizedHost, reason: reason, policy: policy)
    }

    private func maybeRecordMITMAutoBypass(host: String, reason: String, policy: DualMITMPolicy) {
        guard let normalized = Self.normalizedAutoBypassReason(forFailureReason: reason) else {
            return
        }

        MITMAutoBypassCache.shared.record(host: host, reason: normalized)
        ProxyLog.mitm.info(
            "event=proxy.mitm_auto_bypass outcome=success host=\(host, privacy: .private(mask: .hash)) reason=\(normalized, privacy: .public)"
        )
        eventLog?.append(
            type: "mitm_auto_bypass",
            msg: "\(LogRedaction.hash(host)) reason=\(normalized) policy=\(policy.rawValue)"
        )
    }

    static func normalizedAutoBypassReason(forFailureReason reason: String) -> String? {
        let normalized = LegacyReasonCodec.normalizedToken(reason)
        if normalized.contains("ca_not_trusted") {
            return nil
        }

        let decoded = LegacyReasonCodec.decode(reason)
        let failure = decoded.failure
        guard let bypassReason = decoded.bypassReason else {
            return nil
        }

        switch bypassReason {
        case .certificatePinning, .clientRejected:
            return "client_rejected_mitm_or_pinning"
        case .upstreamTLSIssue:
            if case .upstreamTLSHostnameMismatch = failure {
                return "tls_upstream_hostname_mismatch"
            }
            return "tls_upstream_trust_failed"
        case .mitmSetupInstability:
            return "mitm_setup_failed"
        case .protocolMismatch:
            if case .nonHTTPProtocol = failure {
                return "mitm_non_http_protocol"
            }
            return "protocol_mismatch"
        case .legacyToken:
            return nil
        default:
            return nil
        }
    }

    static func runtimeBypassCandidateReason(forFailureReason reason: String) -> String? {
        let decoded = LegacyReasonCodec.decode(reason)
        guard let bypassReason = decoded.bypassReason else {
            return nil
        }

        switch bypassReason {
        case .transientUpstreamFailure:
            if case .upstreamConnectionClosed = decoded.failure {
                return "upstream_connection_closed"
            }
            if case .connectionClosedEarly = decoded.failure {
                return nil
            }
            return "upstream_timeout"
        default:
            return nil
        }
    }

    static func transientFailureThreshold(
        forRuntimeBypassReason reason: String,
        defaultThreshold: Int = 5
    ) -> Int {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedDefault = max(1, defaultThreshold)
        guard !normalized.isEmpty else { return normalizedDefault }
        return normalizedDefault
    }

    private func maybeRecordRuntimeBypassForTransientFailure(host: String, reason: String, runtimeBypassTTL: TimeInterval) {
        guard !host.isEmpty else { return }
        guard let normalizedReason = Self.runtimeBypassCandidateReason(forFailureReason: reason) else { return }

        let now = Date()
        purgeExpiredRuntimeBypasses(now: now)
        pruneTransientFailureTrackers(now: now)

        let trackerKey = "\(host)|\(normalizedReason)"
        var tracker = transientFailureTrackers[trackerKey] ?? TransientFailureTracker(
            firstFailureAt: now,
            lastFailureAt: now,
            count: 0
        )

        if now.timeIntervalSince(tracker.firstFailureAt) > transientFailureWindow {
            tracker.firstFailureAt = now
            tracker.lastFailureAt = now
            tracker.count = 1
        } else {
            tracker.lastFailureAt = now
            tracker.count += 1
        }

        transientFailureTrackers[trackerKey] = tracker
        let threshold = Self.transientFailureThreshold(
            forRuntimeBypassReason: normalizedReason,
            defaultThreshold: transientFailureThreshold
        )
        guard tracker.count >= threshold else { return }

        runtimeBypassStates[host] = RuntimeBypassState(
            reason: normalizedReason,
            expiresAt: now.addingTimeInterval(runtimeBypassTTL)
        )
        // Keep Local SOCKS route decisions aligned with proxy-side runtime bypasses.
        MITMAutoBypassLookup.record(host: host, reason: normalizedReason)
        transientFailureTrackers.removeValue(forKey: trackerKey)
        eventLog?.append(
            type: "mitm_auto_bypass_runtime",
            msg: "\(LogRedaction.hash(host)) reason=\(normalizedReason) ttl_ms=\(Int(runtimeBypassTTL * 1000))"
        )
        ProxyLog.mitm.info(
            "event=proxy.mitm_auto_bypass_runtime outcome=success host=\(host, privacy: .private(mask: .hash)) reason=\(normalizedReason, privacy: .public) ttl_ms=\(Int(self.runtimeBypassTTL * 1000), privacy: .public)"
        )
    }

    private func pruneTransientFailureTrackers(now: Date) {
        guard !transientFailureTrackers.isEmpty else { return }
        transientFailureTrackers = transientFailureTrackers.filter { _, tracker in
            now.timeIntervalSince(tracker.lastFailureAt) <= transientFailureRetention
        }
    }

    private func purgeExpiredRuntimeBypasses(now: Date) {
        guard !runtimeBypassStates.isEmpty else { return }
        runtimeBypassStates = runtimeBypassStates.filter { _, state in
            state.expiresAt > now
        }
    }

    private func shouldSample(using config: SamplingConfig) -> Bool {
        guard config.enabled else { return true }
        let rate = max(0.0, min(1.0, config.sampleRate))
        if rate <= 0 { return false }
        if rate >= 1 { return true }

        switch config.strategy {
        case .random:
            return Double.random(in: 0 ..< 1) < rate
        case .periodic:
            samplingSequence &+= 1
            let interval = max(1, Int((1.0 / rate).rounded()))
            return samplingSequence % interval == 0
        case .adaptive:
            let activeConnections = max(1, mitmEngine?.activeConnectionCount() ?? 1)
            let scale = 50.0 / Double(max(50, activeConnections))
            let adjustedRate = min(rate, rate * scale)
            return Double.random(in: 0 ..< 1) < adjustedRate
        }
    }

    private func captureRequestToPCAP(_ request: NetworkRequest) {
        // Rationale: PCAP records are not a canonical "full body" capture format here.
        // Capture a bounded preview to avoid loading large bodies from disk into memory.
        let maxBodyPreviewBytes = 16 * 1024

        var requestData = Data()
        let urlComponents = URLComponents(string: request.url)
        let requestPath: String = {
            let path = urlComponents?.path
            let query = urlComponents?.percentEncodedQuery
            if let path, !path.isEmpty {
                if let query, !query.isEmpty {
                    return "\(path)?\(query)"
                }
                return path
            }
            if let query, !query.isEmpty {
                return "/?\(query)"
            }
            return "/"
        }()

        let requestLine = "\(request.method.rawValue) \(requestPath) HTTP/1.1\r\n"
        if let data = requestLine.data(using: .utf8) {
            requestData.append(data)
        }
        for header in request.requestHeaders {
            if let data = "\(header.key): \(header.value)\r\n".data(using: .utf8) {
                requestData.append(data)
            }
        }
        if let crlf = "\r\n".data(using: .utf8) {
            requestData.append(crlf)
        }
        if let body = request.requestBody.getPreview(maxBytes: maxBodyPreviewBytes) {
            requestData.append(body)
        }
        writeToPCAP(requestData, isRequest: true)

        if let statusCode = request.statusCode {
            var responseData = Data()
            let statusLine = "HTTP/1.1 \(statusCode) \(request.statusMessage ?? "OK")\r\n"
            if let data = statusLine.data(using: .utf8) {
                responseData.append(data)
            }
            for header in request.responseHeaders {
                if let data = "\(header.key): \(header.value)\r\n".data(using: .utf8) {
                    responseData.append(data)
                }
            }
            if let crlf = "\r\n".data(using: .utf8) {
                responseData.append(crlf)
            }
            if let body = request.responseBody.getPreview(maxBytes: maxBodyPreviewBytes) {
                responseData.append(body)
            }
            writeToPCAP(responseData, isRequest: false)
        }
    }
}
