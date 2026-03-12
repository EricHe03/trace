//
//  QUICFlowRouter+FailurePolicy.swift
//  TraceVPN
//

import Darwin
import Dispatch
import Foundation
import OSLog
import Security
import TraceCore
import TracePacket
import TraceProxy
import TraceQUIC
import TraceSecurity

extension QUICFlowRouter {
    func determineForwardingDecision(
        udpForwarderAvailable: Bool,
        tunnelUDPSupported: Bool,
        tunnelPolicyRequired: Bool
    ) -> UDPForwardDecision {
        if tunnelPolicyRequired {
            return .forwardTunnel
        }
        if tunnelUDPSupported || !udpForwarderAvailable {
            return .forwardTunnel
        }
        return .forwardDirect
    }

    func plannedInitialQUICDecision(
        host: String,
        port: Int
    ) -> DualMITMQUICRouteDecision {
        let legacyDecision: DualMITMQUICRouteDecision = .mitm
        guard let dualMITMPolicyEngine else {
            return legacyDecision
        }

        let plan = dualMITMPolicyEngine.planNewFlow(
            protocolName: .quic,
            destination: HostPort(host: host, port: max(0, port))
        )
        let policyDecision = Self.quicRouteDecision(from: plan.action)

        if plan.shadowEnabled,
           policyDecision != legacyDecision,
           logSampler.shouldLog(event: "vpn.quic_policy_shadow", key: host, first: 5, every: 250) {
            eventLogHandler?(
                "dual_mitm_policy_shadow",
                "scope=quic_start host_hash=\(LogRedaction.hash(host)) port=\(port) legacy_route=\(Self.quicRouteDecisionValue(legacyDecision)) legacy_reason=\(Self.quicRouteDecisionReason(legacyDecision)) policy_route=\(Self.quicRouteDecisionValue(policyDecision)) policy_reason=\(Self.quicRouteDecisionReason(policyDecision)) enforced=\(plan.enforced)"
            )
        }

        if plan.enforced {
            return policyDecision
        }
        return legacyDecision
    }

    static func quicRouteDecisionValue(_ decision: DualMITMQUICRouteDecision) -> String {
        switch decision {
        case .mitm:
            "mitm"
        case .passThrough:
            "pass_through"
        case .block:
            "block"
        }
    }

    static func quicRouteDecisionReason(_ decision: DualMITMQUICRouteDecision) -> String {
        switch decision {
        case .mitm:
            return "none"
        case let .passThrough(reason), let .block(reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "none" : trimmed
        }
    }

    func failOpenForwardingDecision(
        current: UDPForwardDecision,
        reason: String?,
        udpForwarderAvailable: Bool,
        tunnelUDPSupported: Bool
    ) -> UDPForwardDecision {
        guard dualMITMPolicy == .adaptiveFailOpen else {
            return current
        }
        guard udpForwarderAvailable else {
            return current
        }
        if current == .forwardTunnel, !tunnelUDPSupported {
            return .forwardDirect
        }
        guard current == .forwardTunnel, let reason else {
            return current
        }
        return Self.prefersDirectFailOpenForwarding(for: reason) ? .forwardDirect : current
    }

    func shouldFailOpenForQUICFailure(
        host: String,
        port: Int,
        reason: String
    ) -> (enabled: Bool, effectiveReason: String) {
        // Legacy behavior was connectivity-first (fail-open) even in strict policy mode.
        let legacyDecision = true
        guard let dualMITMPolicyEngine else {
            return (legacyDecision, reason)
        }

        let startPlan = dualMITMPolicyEngine.planNewFlow(
            protocolName: .quic,
            destination: HostPort(host: host, port: max(0, port))
        )
        let failure = Self.quicFailure(from: reason)
        let plan = dualMITMPolicyEngine.handleFailure(
            profile: startPlan.profile,
            failure: failure,
            applySideEffects: startPlan.enforced
        )
        let policyDecision: Bool
        let policyReason: String
        switch plan.action {
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

        if plan.shadowEnabled,
           policyDecision != legacyDecision,
           logSampler.shouldLog(event: "vpn.quic_policy_shadow", key: reason, first: 5, every: 250) {
            eventLogHandler?(
                "dual_mitm_policy_shadow",
                "scope=quic host_hash=\(LogRedaction.hash(host)) port=\(port) failure_reason=\(reason) legacy_fail_open=\(legacyDecision) policy_fail_open=\(policyDecision) enforced=\(plan.enforced)"
            )
        }

        if plan.enforced {
            return (policyDecision, policyReason)
        }
        return (legacyDecision, reason)
    }

    static func quicRouteDecision(from action: DualMITMRouteAction) -> DualMITMQUICRouteDecision {
        switch action {
        case .mitm:
            .mitm
        case let .passThrough(reason), let .direct(reason):
            .passThrough(reason: reason)
        case let .block(reason):
            .block(reason: reason)
        }
    }

    static func quicFailure(from reason: String) -> InterceptionFailure {
        let decoded = LegacyReasonCodec.decode(reason)
        if let failure = decoded.failure {
            return failure
        }
        return .internalError(code: .legacyUnknownToken, context: reason)
    }

    func failureDecisionForFlow(
        flowKey: FlowKey,
        flowID: UUID,
        reason: String
    ) -> (enabled: Bool, effectiveReason: String) {
        let endpoint = stateQueue.sync { () -> (host: String, port: Int)? in
            guard let state = flowStates[flowKey], state.flowID == flowID else {
                return nil
            }
            return (state.host, state.port)
        }
        guard let endpoint else {
            return (true, reason)
        }
        return shouldFailOpenForQUICFailure(
            host: endpoint.host,
            port: endpoint.port,
            reason: reason
        )
    }

    func shouldFailOpenForNoProgress(
        snapshot: NoProgressSnapshot?,
        now: Date
    ) -> Bool {
        guard let snapshot else { return false }
        return Self.shouldFailOpenForNoProgress(
            budgetStartAt: snapshot.budgetStartAt,
            establishedAt: snapshot.establishedAt,
            lastProgressAt: snapshot.lastProgressAt,
            clientDatagramsSeen: snapshot.clientDatagramsSeen,
            processedStreams: snapshot.processedStreams,
            now: now,
            gracePeriod: noProgressGracePeriod,
            idleTimeout: noProgressIdleTimeout,
            minimumClientDatagrams: noProgressMinimumClientDatagrams,
            absoluteTimeout: noProgressAbsoluteTimeout
        )
    }

    static func shouldFailOpenForNoProgress(
        budgetStartAt: Date? = nil,
        establishedAt: Date?,
        lastProgressAt: Date?,
        clientDatagramsSeen: Int,
        processedStreams: Int,
        now: Date,
        gracePeriod: TimeInterval,
        idleTimeout: TimeInterval,
        minimumClientDatagrams: Int,
        absoluteTimeout: TimeInterval? = nil
    ) -> Bool {
        guard processedStreams == 0 else { return false }
        guard clientDatagramsSeen >= minimumClientDatagrams else { return false }
        guard let establishedAt else { return false }
        let budgetReference = budgetStartAt ?? establishedAt
        let budgetDuration = now.timeIntervalSince(budgetReference)
        let establishedDuration = now.timeIntervalSince(establishedAt)
        guard establishedDuration >= gracePeriod else { return false }
        if let absoluteTimeout, absoluteTimeout > 0, budgetDuration >= absoluteTimeout {
            return true
        }
        let progressReference = lastProgressAt ?? establishedAt
        return now.timeIntervalSince(progressReference) >= idleTimeout
    }

    func closeFlowGracefully(
        flowKey: FlowKey,
        flowID: UUID,
        reason: String
    ) -> Bool {
        var tickTask: Task<Void, Never>?
        var hostHash: String?
        let shouldClose = stateQueue.sync { () -> Bool in
            guard var state = flowStates[flowKey], state.flowID == flowID else { return false }
            tickTask = state.tickTask
            hostHash = LogRedaction.hash(state.host)
            state.isEstablishing = false
            state.isEstablished = false
            state.queuedIngests = 0
            state.pendingDatagrams.removeAll(keepingCapacity: false)
            state.session = nil
            state.bootstrapToken = nil
            state.tickTask = nil
            // Graceful close should not force fail-open backoff for subsequent datagrams.
            state.lastFailureReason = nil
            state.lastFailureAt = nil
            state.establishedAt = nil
            state.lastProgressAt = nil
            state.noProgressBudgetStartAt = nil
            state.clientDatagramsSeen = 0
            state.processedStreamCount = 0
            state.recentClientDatagrams.removeAll(keepingCapacity: false)
            flowStates[flowKey] = state
            return true
        }
        tickTask?.cancel()
        if shouldClose {
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=closed flow_id=\(flowID.uuidString) host_hash=\(hostHash ?? "unknown") reason=\(reason)"
            )
        }
        return shouldClose
    }

    func forwardOriginalDatagramIfNeeded(
        _ payload: Data?,
        fromClient: Bool,
        flowKey: FlowKey,
        flowID: UUID
    ) {
        guard let payload, !payload.isEmpty else { return }
        guard let context = datagramContext(for: flowKey, flowID: flowID) else { return }
        if fromClient {
            upstreamDatagramSink?(payload, context)
        } else {
            downstreamDatagramSink?(payload, context)
        }
    }

    func markFlowBlocked(
        flowKey: FlowKey,
        flowID: UUID,
        reason: String,
        detail: String? = nil
    ) -> Bool {
        var tickTask: Task<Void, Never>?
        var hostHash: String?
        let failureAt = Date()
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failureDetail = (normalizedDetail?.isEmpty == false ? normalizedDetail : nil) ?? "none"
        let shouldClose = stateQueue.sync { () -> Bool in
            guard var state = flowStates[flowKey], state.flowID == flowID else { return false }
            tickTask = state.tickTask
            hostHash = LogRedaction.hash(state.host)
            state.isEstablishing = false
            state.isEstablished = false
            state.queuedIngests = 0
            state.pendingDatagrams.removeAll(keepingCapacity: false)
            state.session = nil
            state.bootstrapToken = nil
            state.tickTask = nil
            state.lastFailureReason = reason
            state.lastFailureAt = failureAt
            state.establishedAt = nil
            state.lastProgressAt = nil
            state.noProgressBudgetStartAt = nil
            state.clientDatagramsSeen = 0
            state.processedStreamCount = 0
            state.recentClientDatagrams.removeAll(keepingCapacity: false)
            flowStates[flowKey] = state
            return true
        }
        tickTask?.cancel()
        if shouldClose {
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=blocked flow_id=\(flowID.uuidString) host_hash=\(hostHash ?? "unknown") reason=\(reason) failure_detail=\(failureDetail) route_decision=block fallback_applied=false bypass_reason=none policy=\(dualMITMPolicy.rawValue)"
            )
        }
        return shouldClose
    }

    func markFlowFailed(
        flowKey: FlowKey,
        flowID: UUID,
        reason: String,
        detail: String? = nil
    ) -> Bool {
        var tickTask: Task<Void, Never>?
        var hostHash: String?
        var hostFailOpenHashes: String?
        let failureAt = Date()
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failureDetail = (normalizedDetail?.isEmpty == false ? normalizedDetail : nil) ?? "none"
        let shouldClose = stateQueue.sync { () -> Bool in
            guard var state = flowStates[flowKey], state.flowID == flowID else { return false }
            tickTask = state.tickTask
            hostHash = LogRedaction.hash(state.host)
            state.isEstablishing = false
            state.isEstablished = false
            state.queuedIngests = 0
            state.pendingDatagrams.removeAll(keepingCapacity: false)
            state.session = nil
            state.bootstrapToken = nil
            state.tickTask = nil
            state.lastFailureReason = reason
            state.lastFailureAt = failureAt
            state.establishedAt = nil
            state.lastProgressAt = nil
            state.noProgressBudgetStartAt = nil
            state.clientDatagramsSeen = 0
            state.processedStreamCount = 0
            state.recentClientDatagrams.removeAll(keepingCapacity: false)
            let failOpenKeys = dualMITMPolicy == .adaptiveFailOpen
                ? markHostFailOpenLocked(
                    state: state,
                    reason: reason,
                    now: failureAt
                )
                : []
            if !failOpenKeys.isEmpty {
                hostFailOpenHashes = failOpenKeys
                    .map { LogRedaction.hash($0) }
                    .sorted()
                    .joined(separator: "|")
            }
            flowStates[flowKey] = state
            return true
        }
        tickTask?.cancel()
        if shouldClose {
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=failed flow_id=\(flowID.uuidString) host_hash=\(hostHash ?? "unknown") reason=\(reason) failure_detail=\(failureDetail) route_decision=pass_through fallback_applied=true bypass_reason=\(reason) policy=\(dualMITMPolicy.rawValue)"
            )
            if let hostFailOpenHashes, !hostFailOpenHashes.isEmpty {
                eventLogHandler?(
                    "quic_mitm_session",
                    "outcome=host_fail_open_marked flow_id=\(flowID.uuidString) reason=\(reason) failure_detail=\(failureDetail) host_hashes=\(hostFailOpenHashes) ttl_ms=\(Int(hostFailOpenBackoff * 1000)) policy=\(dualMITMPolicy.rawValue)"
                )
            }
        }
        return shouldClose
    }

    static func mitmAutoBypassReason(forQUICFailure reason: String) -> String? {
        // QUIC fail-open is transport fallback and should not poison shared host
        // bypass used by TCP MITM routing/capture.
        nil
    }

    func failureReason(from reason: QUICMitmFailureReason?) -> String {
        reason?.rawValue ?? "quic_mitm_failed_open"
    }

    func ingestFailureReason(for error: Error) -> String {
        guard let sessionError = error as? QUICMitmSessionError else {
            return "quic_mitm_ingest_failed"
        }

        switch sessionError {
        case .sessionNotEstablished:
            return "quic_mitm_session_not_established"
        case .ingestFailed:
            return "quic_mitm_ingest_failed"
        case .eventPollFailed:
            return "quic_mitm_action_poll_failed"
        case .submitResponseFailed:
            return "quic_mitm_submit_response_failed"
        case .tickFailed:
            return "quic_mitm_tick_failed"
        }
    }

    func isGracefulSessionClosure(_ error: Error) -> Bool {
        guard let sessionError = error as? QUICMitmSessionError else {
            return false
        }

        switch sessionError {
        case .sessionNotEstablished:
            return true
        case let .ingestFailed(code), let .tickFailed(code):
            return code == -2
        case let .eventPollFailed(code), let .submitResponseFailed(code):
            return code == -2
        }
    }

    func gracefulSessionClosureReason(for error: Error) -> String {
        guard let sessionError = error as? QUICMitmSessionError else {
            return "session_closed"
        }

        switch sessionError {
        case .sessionNotEstablished:
            return "session_not_established"
        case let .ingestFailed(code):
            return "ingest_code_\(code)"
        case let .tickFailed(code):
            return "tick_code_\(code)"
        case let .eventPollFailed(code):
            return "poll_code_\(code)"
        case let .submitResponseFailed(code):
            return "submit_code_\(code)"
        }
    }
}
