//
//  DualMITMPolicyEngine.swift
//  TraceCore
//
//  Created by Codex on 2026/02/24.
//

import Foundation

/// Single policy authority for Dual MITM decisions.
public final class DualMITMPolicyEngine: @unchecked Sendable {
    public typealias Clock = @Sendable () -> Date
    public typealias TCPBreakerLookup = @Sendable (UInt16, Date) -> Bool
    public typealias TCPBypassLookup = @Sendable (String) -> DualMITMTCPBypassLookupResult

    private let lock = NSLock()
    private var snapshot: DualMITMPolicySnapshot

    private let now: Clock
    private let shouldForceTCPDirect: TCPBreakerLookup
    private let lookupTCPBypass: TCPBypassLookup
    private let eventSink: InterceptionEventSink
    private let tcpBypassStore: HostBypassStore?
    private let quicFailOpenStore: HostBypassStore?
    private let circuitBreakerController: CircuitBreakerController?

    public init(
        snapshot: DualMITMPolicySnapshot,
        now: @escaping Clock = Date.init,
        shouldForceTCPDirect: @escaping TCPBreakerLookup = { _, _ in false },
        lookupTCPBypass: @escaping TCPBypassLookup = { _ in .none },
        eventSink: InterceptionEventSink = NullInterceptionEventSink(),
        tcpBypassStore: HostBypassStore? = nil,
        quicFailOpenStore: HostBypassStore? = nil,
        circuitBreakerController: CircuitBreakerController? = nil
    ) {
        self.snapshot = snapshot
        self.now = now
        self.shouldForceTCPDirect = shouldForceTCPDirect
        self.lookupTCPBypass = lookupTCPBypass
        self.eventSink = eventSink
        self.tcpBypassStore = tcpBypassStore
        self.quicFailOpenStore = quicFailOpenStore
        self.circuitBreakerController = circuitBreakerController
    }

    public func updateSnapshot(_ snapshot: DualMITMPolicySnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    public func currentSnapshot() -> DualMITMPolicySnapshot {
        lock.lock()
        let current = snapshot
        lock.unlock()
        return current
    }

    // MARK: - Typed API

    public func planNewFlow(
        protocolName: InterceptionProtocol,
        destination: HostPort,
        metadata: DualMITMFlowMetadata = DualMITMFlowMetadata()
    ) -> FlowStartPlan {
        planNewFlow(
            snapshot: currentSnapshot(),
            protocolName: protocolName,
            destination: destination,
            metadata: metadata
        )
    }

    public func handleFailure(
        profile: FlowPolicyProfile,
        failure: InterceptionFailure
    ) -> FailurePlan {
        let decisionTime = now()
        let reasonToken = LegacyReasonCodec.encode(failure)
        let snapshot = profile.snapshot
        let shadowEnabled = snapshot.featureFlags.shadowEnabled
        let enforced = Self.isEnforced(protocolName: profile.protocolName, snapshot: snapshot)

        if snapshot.policyMode == .strictMITM, profile.isMITMEligible {
            if snapshot.featureFlags.strictEnforcementHardFail {
                let plan = FailurePlan(
                    action: .failClosedBlock(reason: reasonToken),
                    shadowEnabled: shadowEnabled,
                    enforced: enforced
                )
                emitFailureEvent(
                    profile: profile,
                    failure: failure,
                    plan: plan,
                    reasonToken: reasonToken,
                    at: decisionTime
                )
                return plan
            }
        }

        var plan = adaptiveFailurePlan(
            profile: profile,
            failure: failure,
            reasonToken: reasonToken
        )
        plan.shadowEnabled = shadowEnabled
        plan.enforced = enforced

        applyFailureSideEffects(
            profile: profile,
            plan: plan,
            at: decisionTime
        )
        emitFailureEvent(
            profile: profile,
            failure: failure,
            plan: plan,
            reasonToken: reasonToken,
            at: decisionTime
        )

        return plan
    }

    public func recordSuccess(
        profile: FlowPolicyProfile,
        details: SuccessDetails
    ) {
        guard details.establishedMITM else { return }
        guard profile.snapshot.policyMode == .adaptiveFailOpen,
              profile.snapshot.circuitBreakerEnabled
        else {
            return
        }

        let currentNow = now()
        switch profile.protocolName {
        case .tcpTransparent, .httpConnect:
            guard profile.destination.port == 443 else { return }
            circuitBreakerController?.recordTCPClientHandshake(failed: false, now: currentNow)
        case .quic:
            circuitBreakerController?.recordQUICInterceptSample(failed: false, now: currentNow)
        }
    }

    // MARK: - Compatibility API (used by existing call sites)

    public func planNewTCPTransparentFlow(
        destinationHost: String,
        destinationPort: UInt16
    ) -> DualMITMTCPFlowStartPlan {
        let flowPlan = planNewFlow(
            protocolName: .tcpTransparent,
            destination: HostPort(host: destinationHost, port: Int(destinationPort))
        )

        let decision: DualMITMTCPRouteDecision
        switch flowPlan.action {
        case .mitm:
            decision = .mitm
        case let .direct(reason):
            decision = .direct(reason: reason)
        case let .passThrough(reason), let .block(reason):
            // Local SOCKS only supports MITM vs DIRECT routing.
            decision = .direct(reason: reason)
        }

        return DualMITMTCPFlowStartPlan(
            decision: decision,
            shadowEnabled: flowPlan.shadowEnabled,
            enforceTCPRouting: flowPlan.enforced
        )
    }

    public func planNewProxyFlow(
        destinationHost: String,
        destinationPort: UInt16,
        mitmEnabled: Bool,
        allowlist: [String]
    ) -> DualMITMProxyFlowStartPlan {
        var current = currentSnapshot()
        current.mitmEnabled = mitmEnabled
        current.allowlist = allowlist

        let flowPlan = planNewFlow(
            snapshot: current,
            protocolName: .httpConnect,
            destination: HostPort(host: destinationHost, port: Int(destinationPort)),
            metadata: DualMITMFlowMetadata()
        )

        let decision: DualMITMProxyRouteDecision
        switch flowPlan.action {
        case .mitm:
            decision = .mitm
        case let .passThrough(reason), let .direct(reason):
            decision = .passThrough(reason: reason)
        case let .block(reason):
            decision = .block(reason: reason)
        }

        return DualMITMProxyFlowStartPlan(
            decision: decision,
            shadowEnabled: flowPlan.shadowEnabled,
            enforceProxyRouting: flowPlan.enforced
        )
    }

    public func planProxyFailure(
        destinationHost: String,
        destinationPort: UInt16,
        failureReason: String,
        mitmEnabled: Bool,
        allowlist: [String]
    ) -> DualMITMProxyFailurePlan {
        var snapshot = currentSnapshot()
        snapshot.mitmEnabled = mitmEnabled
        snapshot.allowlist = allowlist

        let startPlan = planNewFlow(
            snapshot: snapshot,
            protocolName: .httpConnect,
            destination: HostPort(host: destinationHost, port: Int(destinationPort)),
            metadata: DualMITMFlowMetadata()
        )
        let decoded = LegacyReasonCodec.decode(failureReason)
        let failure = decoded.failure ??
            .internalError(code: .legacyUnknownToken, context: failureReason)
        let failurePlan = handleFailure(profile: startPlan.profile, failure: failure)

        let action: DualMITMProxyFailureAction
        switch failurePlan.action {
        case let .failOpenPassThrough(reason), let .failOpenDirect(reason):
            action = .failOpenPassThrough(reason: reason)
        case let .failClosedBlock(reason):
            action = .failClosedBlock(reason: reason)
        case let .retry(reason):
            action = .failOpenPassThrough(reason: reason)
        case .noop:
            action = .failOpenPassThrough(reason: Self.sanitizedFailureReasonToken(failureReason))
        }

        return DualMITMProxyFailurePlan(
            action: action,
            shadowEnabled: failurePlan.shadowEnabled,
            enforceProxyRouting: failurePlan.enforced
        )
    }

    public func planNewQUICFlow(
        destinationHost: String,
        destinationPort: UInt16,
        quicHandlingMode: QUICHandlingMode
    ) -> DualMITMQUICFlowStartPlan {
        var current = currentSnapshot()
        current.quicHandlingMode = quicHandlingMode

        let flowPlan = planNewFlow(
            snapshot: current,
            protocolName: .quic,
            destination: HostPort(host: destinationHost, port: Int(destinationPort)),
            metadata: DualMITMFlowMetadata()
        )

        let decision: DualMITMQUICRouteDecision
        switch flowPlan.action {
        case .mitm:
            decision = .mitm
        case let .passThrough(reason), let .direct(reason):
            decision = .passThrough(reason: reason)
        case let .block(reason):
            decision = .block(reason: reason)
        }

        return DualMITMQUICFlowStartPlan(
            decision: decision,
            shadowEnabled: flowPlan.shadowEnabled,
            enforceQUICRouting: flowPlan.enforced
        )
    }

    public func planQUICFailure(
        destinationHost: String,
        destinationPort: UInt16,
        failureReason: String,
        quicHandlingMode: QUICHandlingMode
    ) -> DualMITMQUICFailurePlan {
        var snapshot = currentSnapshot()
        snapshot.quicHandlingMode = quicHandlingMode

        let startPlan = planNewFlow(
            snapshot: snapshot,
            protocolName: .quic,
            destination: HostPort(host: destinationHost, port: Int(destinationPort)),
            metadata: DualMITMFlowMetadata()
        )
        let decoded = LegacyReasonCodec.decode(failureReason)
        let failure = decoded.failure ??
            .internalError(code: .legacyUnknownToken, context: failureReason)
        let failurePlan = handleFailure(profile: startPlan.profile, failure: failure)

        let action: DualMITMQUICFailureAction
        switch failurePlan.action {
        case let .failClosedBlock(reason):
            action = .block(reason: reason)
        case let .failOpenPassThrough(reason), let .failOpenDirect(reason), let .retry(reason):
            action = .passThrough(reason: reason)
        case .noop:
            action = .passThrough(reason: Self.sanitizedFailureReasonToken(failureReason))
        }

        return DualMITMQUICFailurePlan(
            action: action,
            shadowEnabled: failurePlan.shadowEnabled,
            enforceQUICRouting: failurePlan.enforced
        )
    }

    // MARK: - Planning internals

    private func planNewFlow(
        snapshot: DualMITMPolicySnapshot,
        protocolName: InterceptionProtocol,
        destination: HostPort,
        metadata: DualMITMFlowMetadata
    ) -> FlowStartPlan {
        let normalizedHost = Self.normalizedHost(destination.host)
        let isEligible = isMITMEligible(
            snapshot: snapshot,
            protocolName: protocolName,
            host: normalizedHost,
            port: destination.port
        )
        let action = initialAction(
            snapshot: snapshot,
            protocolName: protocolName,
            normalizedHost: normalizedHost,
            destinationPort: destination.port
        )

        let profile = FlowPolicyProfile(
            snapshot: snapshot,
            protocolName: protocolName,
            destination: HostPort(host: normalizedHost, port: destination.port),
            flowID: metadata.flowID,
            startedAt: now(),
            isMITMEligible: isEligible
        )

        return FlowStartPlan(
            profile: profile,
            action: action,
            shadowEnabled: snapshot.featureFlags.shadowEnabled,
            enforced: Self.isEnforced(protocolName: protocolName, snapshot: snapshot)
        )
    }

    private func initialAction(
        snapshot: DualMITMPolicySnapshot,
        protocolName: InterceptionProtocol,
        normalizedHost: String,
        destinationPort: Int
    ) -> DualMITMRouteAction {
        guard destinationPort > 0 else {
            return .block(reason: "invalid_destination")
        }
        guard !normalizedHost.isEmpty else {
            return .block(reason: "invalid_destination")
        }

        switch protocolName {
        case .tcpTransparent:
            return initialTCPAction(
                snapshot: snapshot,
                normalizedHost: normalizedHost,
                destinationPort: destinationPort
            )
        case .httpConnect:
            return initialProxyAction(
                snapshot: snapshot,
                normalizedHost: normalizedHost
            )
        case .quic:
            return initialQUICAction(
                snapshot: snapshot,
                normalizedHost: normalizedHost
            )
        }
    }

    private func initialTCPAction(
        snapshot: DualMITMPolicySnapshot,
        normalizedHost: String,
        destinationPort: Int
    ) -> DualMITMRouteAction {
        guard snapshot.tcpTransparentMITMEnabled, snapshot.mitmProxyPort > 0 else {
            return .direct(reason: "policy_disabled")
        }
        guard let port = UInt16(exactly: destinationPort),
              snapshot.tcpInterceptPorts.contains(port) else {
            return .direct(reason: "port_not_intercepted")
        }

        let normalizedProxyHost = Self.normalizedHost(snapshot.mitmProxyHost)
        guard !normalizedProxyHost.isEmpty else {
            return .direct(reason: "proxy_host_missing")
        }

        if normalizedHost == normalizedProxyHost, destinationPort == Int(snapshot.mitmProxyPort) {
            return .direct(reason: "proxy_endpoint")
        }

        let decisionDate = now()
        if snapshot.policyMode == .adaptiveFailOpen,
           snapshot.circuitBreakerEnabled,
           shouldForceTCPDirect(port, decisionDate) {
            return .direct(reason: "dual_mitm_circuit_breaker")
        }

        if snapshot.policyMode == .adaptiveFailOpen,
           let bypassReason = activeTCPBypassReason(host: normalizedHost, at: decisionDate) {
            return .direct(reason: bypassReason)
        }

        return .mitm()
    }

    private func initialProxyAction(
        snapshot: DualMITMPolicySnapshot,
        normalizedHost: String
    ) -> DualMITMRouteAction {
        guard snapshot.mitmEnabled else {
            return .passThrough(reason: "mitm_disabled")
        }
        guard Self.hostIsAllowlisted(normalizedHost, allowlist: snapshot.allowlist) else {
            return .passThrough(reason: "not_allowlisted")
        }

        if snapshot.policyMode == .adaptiveFailOpen,
           let bypassReason = activeTCPBypassReason(host: normalizedHost, at: now()) {
            return .passThrough(reason: bypassReason)
        }

        return .mitm()
    }

    private func initialQUICAction(
        snapshot: DualMITMPolicySnapshot,
        normalizedHost: String
    ) -> DualMITMRouteAction {
        switch snapshot.quicHandlingMode {
        case .block:
            return .block(reason: "quic_policy_block")
        case .passThrough:
            return .passThrough(reason: "quic_mode_pass_through")
        case .intercept:
            break
        }

        guard snapshot.mitmEnabled else {
            return .passThrough(reason: "mitm_disabled")
        }
        guard Self.hostIsAllowlisted(normalizedHost, allowlist: snapshot.allowlist) else {
            return .passThrough(reason: "not_allowlisted")
        }

        if snapshot.policyMode == .adaptiveFailOpen,
           let store = quicFailOpenStore,
           let record = store.lookup(host: normalizedHost, domain: .quicMITM, now: now()) {
            return .passThrough(reason: "auto_bypass_\(record.reason.stableToken)")
        }

        return .mitm()
    }

    private func adaptiveFailurePlan(
        profile: FlowPolicyProfile,
        failure: InterceptionFailure,
        reasonToken: String
    ) -> FailurePlan {
        let isQUIC = profile.protocolName == .quic
        let reasonDomain: HostBypassDomain = isQUIC ? .quicMITM : .tcpMITM
        let tcpTTL = profile.snapshot.tcpBypassTTLSeconds
        let quicTTL = profile.snapshot.quicHostFailOpenSeconds

        let action: FailureOutcomeAction
        var bypassReason: BypassReason?
        var bypassTTL: Int?
        var recordBreakerFailure = false

        switch failure {
        case .transparentMetadataInvalid:
            action = .failClosedBlock(reason: reasonToken)
            recordBreakerFailure = true
        case .localProxyUnreachable:
            action = .failOpenDirect(reason: reasonToken)
            recordBreakerFailure = true
        case .resourceExhausted:
            action = .failOpenPassThrough(reason: reasonToken)
            recordBreakerFailure = true
        case .clientRejectedMITMOrPinning:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .certificatePinning
            bypassTTL = isQUIC ? quicTTL : 86_400
        case .sniInvalidOrMissing:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .sniInvalid
            bypassTTL = isQUIC ? quicTTL : 3_600
        case .connectionClosedEarly:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .transientUpstreamFailure
            bypassTTL = isQUIC ? quicTTL : tcpTTL
            recordBreakerFailure = true
        case .upstreamTimeout:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .transientUpstreamFailure
            bypassTTL = isQUIC ? quicTTL : tcpTTL
            recordBreakerFailure = true
        case .upstreamConnectionClosed:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .transientUpstreamFailure
            bypassTTL = isQUIC ? quicTTL : tcpTTL
            recordBreakerFailure = true
        case .upstreamTLSTrustFailed, .upstreamTLSHostnameMismatch:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .upstreamTLSIssue
            bypassTTL = isQUIC ? quicTTL : 3_600
        case .mitmSetupFailed:
            action = .failOpenPassThrough(reason: reasonToken)
            recordBreakerFailure = true
        case .nonHTTPProtocol, .protocolMismatch:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .protocolMismatch
            bypassTTL = isQUIC ? quicTTL : 3_600
        case .quicHandshakeFailed, .quicAuthorityRetryFailed, .quicClosedBeforeHTTP3, .quicNoProgress:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .mitmSetupInstability
            bypassTTL = quicTTL
            recordBreakerFailure = true
        case .quicCertificatePinning:
            action = .failOpenPassThrough(reason: reasonToken)
            bypassReason = .certificatePinning
            bypassTTL = quicTTL
        case .internalError:
            action = .failOpenPassThrough(reason: reasonToken)
            recordBreakerFailure = true
        }

        return FailurePlan(
            action: action,
            bypassDomain: bypassReason == nil ? nil : reasonDomain,
            bypassReason: bypassReason,
            bypassTTLSeconds: bypassTTL,
            recordBreakerFailure: recordBreakerFailure,
            shadowEnabled: profile.snapshot.featureFlags.shadowEnabled,
            enforced: Self.isEnforced(protocolName: profile.protocolName, snapshot: profile.snapshot)
        )
    }

    private func applyFailureSideEffects(
        profile: FlowPolicyProfile,
        plan: FailurePlan,
        at now: Date
    ) {
        if let domain = plan.bypassDomain,
           let reason = plan.bypassReason,
           let ttl = plan.bypassTTLSeconds,
           profile.snapshot.policyMode == .adaptiveFailOpen {
            let store = domain == .tcpMITM ? tcpBypassStore : quicFailOpenStore
            store?.record(
                host: profile.destination.host,
                domain: domain,
                reason: reason,
                ttl: TimeInterval(ttl),
                now: now
            )
        }

        guard plan.recordBreakerFailure,
              profile.snapshot.policyMode == .adaptiveFailOpen,
              profile.snapshot.circuitBreakerEnabled
        else {
            return
        }

        switch profile.protocolName {
        case .tcpTransparent, .httpConnect:
            guard profile.destination.port == 443 else { return }
            circuitBreakerController?.recordTCPClientHandshake(failed: true, now: now)
        case .quic:
            circuitBreakerController?.recordQUICInterceptSample(failed: true, now: now)
        }
    }

    private func emitFailureEvent(
        profile: FlowPolicyProfile,
        failure: InterceptionFailure,
        plan: FailurePlan,
        reasonToken: String,
        at eventTime: Date
    ) {
        let action: InterceptionAction
        let decisionReason: String

        switch plan.action {
        case let .failOpenPassThrough(reason):
            action = .passThrough
            decisionReason = reason
        case let .failOpenDirect(reason):
            action = .direct
            decisionReason = reason
        case let .failClosedBlock(reason):
            action = .block
            decisionReason = reason
        case let .retry(reason):
            action = .retry
            decisionReason = reason
        case .noop:
            action = .noop
            decisionReason = "noop"
        }

        eventSink.emit(
            InterceptionEvent(
                type: .failoverDecision,
                timestampMs: Int64(eventTime.timeIntervalSince1970 * 1_000),
                sessionID: "unknown",
                tunnelGeneration: 0,
                flowID: profile.flowID,
                captureMode: "fullTunnelDualMITM",
                dualMITMPolicy: profile.snapshot.policyMode.rawValue,
                protocolName: profile.protocolName.rawValue,
                destinationHost: profile.destination.host,
                destinationPort: profile.destination.port,
                action: action,
                decisionReason: decisionReason,
                failure: InterceptionFailurePayload(token: reasonToken, failure: failure),
                legacyToken: reasonToken
            )
        )
    }

    private func activeTCPBypassReason(host: String, at now: Date) -> String? {
        if let record = tcpBypassStore?.lookup(host: host, domain: .tcpMITM, now: now) {
            return "auto_bypass_\(record.reason.stableToken)"
        }

        let bypass = lookupTCPBypass(host)
        guard bypass.shouldBypass else {
            return nil
        }
        let normalizedReason = bypass.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedReason,
           normalizedReason.hasPrefix("quic ") || normalizedReason.hasPrefix("quic_") {
            return nil
        }
        if let normalizedReason, !normalizedReason.isEmpty {
            let sanitized = normalizedReason.replacingOccurrences(of: " ", with: "_")
            return "auto_bypass_\(sanitized)"
        }
        return "auto_bypass"
    }

    private func isMITMEligible(
        snapshot: DualMITMPolicySnapshot,
        protocolName: InterceptionProtocol,
        host: String,
        port: Int
    ) -> Bool {
        guard !host.isEmpty, port > 0 else { return false }
        guard snapshot.mitmEnabled else { return false }
        guard Self.hostIsAllowlisted(host, allowlist: snapshot.allowlist) else { return false }

        switch protocolName {
        case .tcpTransparent:
            guard snapshot.tcpTransparentMITMEnabled else { return false }
            guard let tcpPort = UInt16(exactly: port), snapshot.tcpInterceptPorts.contains(tcpPort) else {
                return false
            }
            return true
        case .httpConnect:
            return true
        case .quic:
            return port == 443 && snapshot.quicHandlingMode == .intercept
        }
    }

    private static func isEnforced(
        protocolName: InterceptionProtocol,
        snapshot: DualMITMPolicySnapshot
    ) -> Bool {
        switch protocolName {
        case .tcpTransparent:
            return snapshot.featureFlags.enforceTCPRouting
        case .httpConnect:
            return snapshot.featureFlags.enforceProxyRouting
        case .quic:
            return snapshot.featureFlags.enforceQUICRouting
        }
    }

    private static func hostIsAllowlisted(_ host: String, allowlist: [String]) -> Bool {
        let sanitized = allowlist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !sanitized.isEmpty else { return false }
        if sanitized.contains("*") { return true }
        return sanitized.contains { pattern in
            if pattern.contains("*") {
                return StringMatcher(
                    matchType: .wildcard,
                    pattern: pattern,
                    caseSensitive: false
                ).matches(host)
            }
            return host == pattern || host.hasSuffix("." + pattern)
        }
    }

    public static func sanitizedFailureReasonToken(_ reason: String) -> String {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return "mitm_failure" }
        return normalized.replacingOccurrences(of: " ", with: "_")
    }

    public static func normalizedHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.first == "[", normalized.last == "]" {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized
    }
}
