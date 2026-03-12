//
//  QUICFlowRouter+Maintenance.swift
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
    func cleanupIdleFlowsIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastCleanupAt) >= cleanupInterval else {
            return
        }
        lastCleanupAt = now
        pruneHostFailOpenLocked(now: now)
        pruneRouteDecisionLogsLocked()

        var sessionsToClose: [QUICMitmSession] = []
        var tickTasksToCancel: [Task<Void, Never>] = []
        flowStates = flowStates.filter { _, state in
            let isExpired = now.timeIntervalSince(state.lastActivity) >= flowIdleTimeout
            if isExpired {
                if let session = state.session {
                    sessionsToClose.append(session)
                }
                if let tickTask = state.tickTask {
                    tickTasksToCancel.append(tickTask)
                }
            }
            return !isExpired
        }

        for tickTask in tickTasksToCancel {
            tickTask.cancel()
        }

        for session in sessionsToClose {
            Task {
                await session.close()
            }
        }

        pruneRouteDecisionLogsLocked()
    }

    func activeHostFailOpenReasonLocked(
        state: FlowSessionState,
        hostHint: String,
        now: Date
    ) -> String? {
        pruneHostFailOpenLocked(now: now)

        var candidateKeys: [String] = []
        if !hostHint.isEmpty {
            candidateKeys.append(hostHint)
        }

        let normalizedStateHost = normalizeAuthority(state.host)
        if !normalizedStateHost.isEmpty {
            candidateKeys.append(normalizedStateHost)
        }

        if let lastAuthorityRetry = state.lastAuthorityRetry {
            let normalizedRetry = normalizeAuthority(lastAuthorityRetry)
            if !normalizedRetry.isEmpty {
                candidateKeys.append(normalizedRetry)
            }
        }

        for key in candidateKeys {
            if let hostFailOpen = hostFailOpenStates[key], hostFailOpen.expiresAt > now {
                return hostFailOpen.reason
            }
        }

        return nil
    }

    func recordRecentClientDatagramLocked(_ payload: Data, state: inout FlowSessionState) {
        guard !payload.isEmpty else { return }
        guard payload.count <= maxFailOpenReplayDatagramBytes else { return }

        state.recentClientDatagrams.append(payload)
        let overflow = state.recentClientDatagrams.count - maxFailOpenReplayDatagrams
        if overflow > 0 {
            state.recentClientDatagrams.removeFirst(overflow)
        }
    }

    func replayRecentClientDatagramsIfNeeded(
        flowKey: FlowKey,
        flowID: UUID,
        reason: String
    ) {
        var replayDatagrams: [Data] = []
        stateQueue.sync {
            guard var state = flowStates[flowKey], state.flowID == flowID else { return }

            replayDatagrams = state.recentClientDatagrams
            if !state.pendingDatagrams.isEmpty {
                replayDatagrams.append(
                    contentsOf: state.pendingDatagrams
                        .filter(\.fromClient)
                        .map(\.payload)
                )
            }
            state.recentClientDatagrams.removeAll(keepingCapacity: false)
            flowStates[flowKey] = state
        }

        guard !replayDatagrams.isEmpty else { return }
        let replayBudget = maxBufferedDatagramsPerFlow + maxFailOpenReplayDatagrams
        let trimmedDatagrams = replayDatagrams
            .suffix(replayBudget)
            .filter { !$0.isEmpty }
        guard !trimmedDatagrams.isEmpty else { return }

        for payload in trimmedDatagrams {
            forwardOriginalDatagramIfNeeded(
                payload,
                fromClient: true,
                flowKey: flowKey,
                flowID: flowID
            )
        }
        let droppedCount = max(0, replayDatagrams.count - trimmedDatagrams.count)
        eventLogHandler?(
            "quic_mitm_session",
            "outcome=fail_open_replay flow_id=\(flowID.uuidString) reason=\(reason) datagrams=\(trimmedDatagrams.count) dropped=\(droppedCount)"
        )
    }

    func markHostFailOpenLocked(
        state: FlowSessionState,
        reason: String,
        now: Date
    ) -> [String] {
        guard Self.shouldEnableHostFailOpen(for: reason) else {
            return []
        }

        var keys = Set<String>()
        let normalizedStateHost = normalizeAuthority(state.host)
        if !normalizedStateHost.isEmpty {
            keys.insert(normalizedStateHost)
        }

        if let lastAuthorityRetry = state.lastAuthorityRetry {
            let normalizedRetry = normalizeAuthority(lastAuthorityRetry)
            if !normalizedRetry.isEmpty {
                keys.insert(normalizedRetry)
            }
        }

        guard !keys.isEmpty else { return [] }
        let expiresAt = now.addingTimeInterval(hostFailOpenBackoff)
        var newlyMarkedKeys: [String] = []
        for key in keys {
            if let existing = hostFailOpenStates[key],
               existing.reason == reason,
               existing.expiresAt > now {
                continue
            }
            newlyMarkedKeys.append(key)
        }
        for key in keys {
            hostFailOpenStates[key] = HostFailOpenState(reason: reason, expiresAt: expiresAt)
        }
        trimHostFailOpenLocked(now: now)
        return newlyMarkedKeys
    }

    func pruneHostFailOpenLocked(now: Date) {
        guard !hostFailOpenStates.isEmpty else { return }
        hostFailOpenStates = hostFailOpenStates.filter { _, state in
            state.expiresAt > now
        }
    }

    func trimHostFailOpenLocked(now: Date) {
        pruneHostFailOpenLocked(now: now)
        let overflow = hostFailOpenStates.count - maxHostFailOpenEntries
        guard overflow > 0 else { return }

        let oldestKeys = hostFailOpenStates
            .sorted { lhs, rhs in
                lhs.value.expiresAt < rhs.value.expiresAt
            }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys {
            hostFailOpenStates.removeValue(forKey: key)
        }
    }

    func pruneRouteDecisionLogsLocked() {
        guard !routeDecisionLogSignaturesByFlowID.isEmpty else { return }

        let activeFlowIDs = Set(flowStates.values.map(\.flowID))
        routeDecisionLogSignaturesByFlowID = routeDecisionLogSignaturesByFlowID.filter { flowID, _ in
            activeFlowIDs.contains(flowID)
        }

        trimRouteDecisionLogsLocked()
    }

    func trimRouteDecisionLogsLocked() {
        let overflow = routeDecisionLogSignaturesByFlowID.count - maxRouteDecisionLogEntries
        guard overflow > 0 else { return }

        // Dictionary order is undefined; trimming an arbitrary overflow set is sufficient.
        let keysToDrop = Array(routeDecisionLogSignaturesByFlowID.keys.prefix(overflow))
        for key in keysToDrop {
            routeDecisionLogSignaturesByFlowID.removeValue(forKey: key)
        }
    }

    static func isIPAddressLiteral(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }

        var ipv4Address = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 {
            return true
        }

        var ipv6Address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &ipv6Address) } == 1
    }

    static func authorityRetrySkipReason(
        currentAuthority: String,
        nextAuthority: String,
        attemptsUsed: Int,
        maxAttempts: Int,
        lastAuthorityRetry: String?
    ) -> String? {
        if currentAuthority.caseInsensitiveCompare(nextAuthority) == .orderedSame {
            return "same_authority"
        }

        if !currentAuthority.isEmpty, !isIPAddressLiteral(currentAuthority) {
            return "retry_policy_hostname_already_known"
        }

        if attemptsUsed >= maxAttempts ||
            lastAuthorityRetry?.caseInsensitiveCompare(nextAuthority) == .orderedSame {
            return "attempt_exhausted"
        }

        return nil
    }

    static func shouldEnableHostFailOpen(for reason: String) -> Bool {
        switch canonicalQUICFailureBehavior(for: reason) {
        case .hostFailOpen:
            true
        case .directFailOpenOnly, .noSpecialHandling:
            false
        }
    }

    static func prefersDirectFailOpenForwarding(for reason: String) -> Bool {
        switch canonicalQUICFailureBehavior(for: reason) {
        case .hostFailOpen, .directFailOpenOnly:
            true
        case .noSpecialHandling:
            false
        }
    }

    private enum QUICFailureBehavior {
        case noSpecialHandling
        case hostFailOpen
        case directFailOpenOnly
    }

    private static func canonicalQUICFailureBehavior(for reason: String) -> QUICFailureBehavior {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return .noSpecialHandling }

        if normalized == "quic_no_progress_fail_open" ||
            normalized == "quic_tunnel_required_unavailable" ||
            normalized == "dual_mitm_circuit_breaker" {
            return .directFailOpenOnly
        }

        let decoded = LegacyReasonCodec.decode(reason)
        switch decoded.failure {
        case .quicHandshakeFailed,
             .quicCertificatePinning,
             .quicAuthorityRetryFailed,
             .quicClosedBeforeHTTP3:
            return .hostFailOpen
        case .quicNoProgress:
            return .directFailOpenOnly
        default:
            break
        }

        return .noSpecialHandling
    }
}
