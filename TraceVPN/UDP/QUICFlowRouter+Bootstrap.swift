//
//  QUICFlowRouter+Bootstrap.swift
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
    func evaluateAndScheduleIntercept(
        ipPacket: IPPacket,
        udpPacket: UDPPacket,
        authorityHint: String?,
        udpForwarderAvailable: Bool,
        tunnelPolicyRequired: Bool,
        tunnelUDPSupported: Bool,
        forwardingDecision: UDPForwardDecision
    ) -> RouteEvaluation {
        let now = Date()
        let flowKey = FlowKey(
            sourceIP: ipPacket.source,
            sourcePort: udpPacket.sourcePort,
            destinationIP: ipPacket.destination,
            destinationPort: udpPacket.destinationPort
        )
        let trimmedAuthorityHint = authorityHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hostHint = trimmedAuthorityHint.isEmpty ? ipPacket.destination.description : trimmedAuthorityHint
        let normalizedHostHint = normalizeAuthority(hostHint)
        let payload = udpPacket.payload

        var bootstrapPreparation: BootstrapPreparation?
        var ingestTask: (flowID: UUID, session: QUICMitmSession, payload: Data)?
        var sessionToClose: QUICMitmSession?
        var fallbackMetricReason: String?
        var evaluationFlowID: UUID?

        var evaluation = stateQueue.sync { () -> RouteEvaluation in
            cleanupIdleFlowsIfNeeded(now: now)

            var state = flowStates[flowKey] ?? FlowSessionState(
                host: normalizedHostHint.isEmpty ? hostHint : normalizedHostHint,
                port: Int(udpPacket.destinationPort),
                clientIP: ipPacket.source,
                clientPort: udpPacket.sourcePort,
                serverIP: ipPacket.destination,
                serverPort: udpPacket.destinationPort,
                upstreamForwardingDecision: forwardingDecision,
                now: now,
                tunnelPolicyRequired: tunnelPolicyRequired
            )
            evaluationFlowID = state.flowID

            let shouldPromoteAuthorityHint =
                !normalizedHostHint.isEmpty &&
                state.session == nil &&
                !state.isEstablished &&
                !state.isEstablishing &&
                (
                    state.host.isEmpty ||
                        (Self.isIPAddressLiteral(state.host) && !Self.isIPAddressLiteral(normalizedHostHint))
                )
            if shouldPromoteAuthorityHint {
                state.host = normalizedHostHint
            }
            state.port = Int(udpPacket.destinationPort)
            state.clientIP = ipPacket.source
            state.clientPort = udpPacket.sourcePort
            state.serverIP = ipPacket.destination
            state.serverPort = udpPacket.destinationPort
            state.upstreamForwardingDecision = forwardingDecision
            state.lastActivity = now
            state.tunnelPolicyRequired = tunnelPolicyRequired

            let initialRoute = plannedInitialQUICDecision(
                host: state.host,
                port: state.port
            )
            switch initialRoute {
            case .mitm:
                break
            case let .passThrough(reason):
                let priorTickTask = state.tickTask
                priorTickTask?.cancel()
                sessionToClose = state.session
                let passThroughForwardingDecision = failOpenForwardingDecision(
                    current: forwardingDecision,
                    reason: reason,
                    udpForwarderAvailable: udpForwarderAvailable,
                    tunnelUDPSupported: tunnelUDPSupported
                )
                state.upstreamForwardingDecision = passThroughForwardingDecision
                state.lastFailureReason = reason
                state.lastFailureAt = now
                state.isEstablishing = false
                state.isEstablished = false
                state.queuedIngests = 0
                state.pendingDatagrams.removeAll(keepingCapacity: false)
                state.session = nil
                state.bootstrapToken = nil
                state.tickTask = nil
                state.establishedAt = nil
                state.lastProgressAt = nil
                state.noProgressBudgetStartAt = nil
                state.clientDatagramsSeen = 0
                state.processedStreamCount = 0
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: .passThroughMarked,
                    handshakeOutcome: .passThrough,
                    failureReason: reason,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: passThroughForwardingDecision,
                    consumeOriginalDatagram: false
                )
            case let .block(reason):
                let priorTickTask = state.tickTask
                priorTickTask?.cancel()
                sessionToClose = state.session
                state.upstreamForwardingDecision = .dropQUIC
                state.lastFailureReason = reason
                state.lastFailureAt = now
                state.isEstablishing = false
                state.isEstablished = false
                state.queuedIngests = 0
                state.pendingDatagrams.removeAll(keepingCapacity: false)
                state.session = nil
                state.bootstrapToken = nil
                state.tickTask = nil
                state.establishedAt = nil
                state.lastProgressAt = nil
                state.noProgressBudgetStartAt = nil
                state.clientDatagramsSeen = 0
                state.processedStreamCount = 0
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: .blocked,
                    handshakeOutcome: .blocked,
                    failureReason: reason,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: .dropQUIC,
                    consumeOriginalDatagram: false
                )
            }

            if dualMITMCircuitBreakerEnabled,
               dualMITMPolicy == .adaptiveFailOpen,
               DualMITMCircuitBreaker.shared.shouldForceQUICPassThrough(now: now) {
                let priorTickTask = state.tickTask
                priorTickTask?.cancel()
                sessionToClose = state.session
                let fallbackForwardingDecision = failOpenForwardingDecision(
                    current: forwardingDecision,
                    reason: "dual_mitm_circuit_breaker",
                    udpForwarderAvailable: udpForwarderAvailable,
                    tunnelUDPSupported: tunnelUDPSupported
                )
                state.upstreamForwardingDecision = fallbackForwardingDecision
                state.lastFailureReason = "dual_mitm_circuit_breaker"
                state.lastFailureAt = now
                state.isEstablishing = false
                state.isEstablished = false
                state.queuedIngests = 0
                state.pendingDatagrams.removeAll(keepingCapacity: false)
                state.session = nil
                state.bootstrapToken = nil
                state.tickTask = nil
                state.establishedAt = nil
                state.lastProgressAt = nil
                state.noProgressBudgetStartAt = nil
                state.clientDatagramsSeen = 0
                state.processedStreamCount = 0
                flowStates[flowKey] = state
                fallbackMetricReason = "dual_mitm_circuit_breaker"
                return RouteEvaluation(
                    inspectionOutcome: .passThroughMarked,
                    handshakeOutcome: .passThrough,
                    failureReason: "dual_mitm_circuit_breaker",
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: fallbackForwardingDecision,
                    consumeOriginalDatagram: false
                )
            }

            if dualMITMPolicy == .adaptiveFailOpen,
               !state.isEstablished,
               let hostFailOpenReason = activeHostFailOpenReasonLocked(
                   state: state,
                   hostHint: normalizedHostHint,
                   now: now
               ) {
                let priorTickTask = state.tickTask
                priorTickTask?.cancel()
                sessionToClose = state.session
                let fallbackForwardingDecision = failOpenForwardingDecision(
                    current: forwardingDecision,
                    reason: hostFailOpenReason,
                    udpForwarderAvailable: udpForwarderAvailable,
                    tunnelUDPSupported: tunnelUDPSupported
                )
                state.upstreamForwardingDecision = fallbackForwardingDecision
                state.lastFailureReason = hostFailOpenReason
                state.lastFailureAt = now
                state.isEstablishing = false
                state.isEstablished = false
                state.queuedIngests = 0
                state.pendingDatagrams.removeAll(keepingCapacity: false)
                state.session = nil
                state.bootstrapToken = nil
                state.tickTask = nil
                state.establishedAt = nil
                state.lastProgressAt = nil
                state.noProgressBudgetStartAt = nil
                state.clientDatagramsSeen = 0
                state.processedStreamCount = 0
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: .passThroughMarked,
                    handshakeOutcome: .passThrough,
                    failureReason: hostFailOpenReason,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: fallbackForwardingDecision,
                    consumeOriginalDatagram: false
                )
            }

            if tunnelPolicyRequired, !tunnelUDPSupported {
                let priorTickTask = state.tickTask
                priorTickTask?.cancel()
                sessionToClose = state.session
                let failureDecision = shouldFailOpenForQUICFailure(
                    host: state.host,
                    port: state.port,
                    reason: "quic_tunnel_required_unavailable"
                )
                let fallbackForwardingDecision = failureDecision.enabled
                    ? failOpenForwardingDecision(
                        current: forwardingDecision,
                        reason: failureDecision.effectiveReason,
                        udpForwarderAvailable: udpForwarderAvailable,
                        tunnelUDPSupported: tunnelUDPSupported
                    )
                    : .dropQUIC
                state.upstreamForwardingDecision = fallbackForwardingDecision
                state.lastFailureReason = failureDecision.effectiveReason
                state.lastFailureAt = now
                state.isEstablishing = false
                state.isEstablished = false
                state.queuedIngests = 0
                state.pendingDatagrams.removeAll(keepingCapacity: false)
                state.session = nil
                state.bootstrapToken = nil
                state.tickTask = nil
                state.establishedAt = nil
                state.lastProgressAt = nil
                state.noProgressBudgetStartAt = nil
                state.clientDatagramsSeen = 0
                state.processedStreamCount = 0
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: failureDecision.enabled ? .passThroughMarked : .blocked,
                    handshakeOutcome: failureDecision.enabled ? .passThrough : .blocked,
                    failureReason: failureDecision.effectiveReason,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: fallbackForwardingDecision,
                    consumeOriginalDatagram: false
                )
            }

            if state.isEstablished, let session = state.session {
                if !payload.isEmpty {
                    recordRecentClientDatagramLocked(payload, state: &state)
                    if state.queuedIngests < maxQueuedIngestsPerFlow {
                        state.queuedIngests += 1
                        ingestTask = (state.flowID, session, payload)
                    } else if state.pendingDatagrams.count < maxBufferedDatagramsPerFlow {
                        state.pendingDatagrams.append(QueuedDatagram(payload: payload, fromClient: true))
                    }
                }
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: .intercepted,
                    handshakeOutcome: .negotiated,
                    failureReason: nil,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: nil,
                    consumeOriginalDatagram: true
                )
            }

            if let reason = state.lastFailureReason,
               let lastFailureAt = state.lastFailureAt,
               now.timeIntervalSince(lastFailureAt) < retryBackoff {
                let fallbackForwardingDecision = state.upstreamForwardingDecision
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: fallbackForwardingDecision == .dropQUIC ? .blocked : .passThroughMarked,
                    handshakeOutcome: fallbackForwardingDecision == .dropQUIC ? .blocked : .passThrough,
                    failureReason: reason,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: fallbackForwardingDecision,
                    consumeOriginalDatagram: false
                )
            }

            if state.isEstablishing {
                if !payload.isEmpty {
                    recordRecentClientDatagramLocked(payload, state: &state)
                    if state.pendingDatagrams.count < maxBufferedDatagramsPerFlow {
                        state.pendingDatagrams.append(QueuedDatagram(payload: payload, fromClient: true))
                    }
                }
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: .intercepted,
                    handshakeOutcome: .negotiated,
                    failureReason: "quic_mitm_session_establishing",
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: nil,
                    consumeOriginalDatagram: true
                )
            }

            let engineStatus = engineStatusProvider()
            if engineStatus.availability != .available {
                let reason = QUICMitmFailureReason.engineUnavailable.rawValue
                let failureDecision = shouldFailOpenForQUICFailure(
                    host: state.host,
                    port: state.port,
                    reason: reason
                )
                let fallbackForwardingDecision = failureDecision.enabled
                    ? failOpenForwardingDecision(
                        current: forwardingDecision,
                        reason: failureDecision.effectiveReason,
                        udpForwarderAvailable: udpForwarderAvailable,
                        tunnelUDPSupported: tunnelUDPSupported
                    )
                    : .dropQUIC
                state.upstreamForwardingDecision = fallbackForwardingDecision
                state.lastFailureReason = failureDecision.effectiveReason
                state.lastFailureAt = now
                state.isEstablishing = false
                state.isEstablished = false
                state.queuedIngests = 0
                state.pendingDatagrams.removeAll(keepingCapacity: false)
                state.session = nil
                state.bootstrapToken = nil
                state.tickTask = nil
                state.establishedAt = nil
                state.lastProgressAt = nil
                state.noProgressBudgetStartAt = nil
                state.clientDatagramsSeen = 0
                state.processedStreamCount = 0
                state.sniHash = LogRedaction.hash(state.host)
                flowStates[flowKey] = state
                fallbackMetricReason = failureDecision.enabled ? failureDecision.effectiveReason : nil
                return RouteEvaluation(
                    inspectionOutcome: failureDecision.enabled ? .passThroughMarked : .blocked,
                    handshakeOutcome: failureDecision.enabled ? .passThrough : .blocked,
                    failureReason: failureDecision.effectiveReason,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    forwardingDecision: fallbackForwardingDecision,
                    consumeOriginalDatagram: false
                )
            }

            state.isEstablishing = true
            state.lastFailureReason = nil
            state.lastFailureAt = nil
            state.negotiatedALPN = nil
            state.sniHash = LogRedaction.hash(state.host)
            state.establishedAt = nil
            state.lastProgressAt = nil
            if state.noProgressBudgetStartAt == nil {
                state.noProgressBudgetStartAt = now
            }
            state.clientDatagramsSeen = 0
            state.processedStreamCount = 0
            state.session = nil
            let bootstrapToken = UUID()
            state.bootstrapToken = bootstrapToken
            if !payload.isEmpty {
                recordRecentClientDatagramLocked(payload, state: &state)
                state.pendingDatagrams.append(QueuedDatagram(payload: payload, fromClient: true))
            }
            flowStates[flowKey] = state
            bootstrapPreparation = BootstrapPreparation(
                flowKey: flowKey,
                flowID: state.flowID,
                bootstrapToken: bootstrapToken,
                host: state.host,
                port: state.port,
                tunnelPolicyRequired: state.tunnelPolicyRequired
            )

            return RouteEvaluation(
                inspectionOutcome: .intercepted,
                handshakeOutcome: .negotiated,
                failureReason: "quic_mitm_session_establishing",
                alpn: state.negotiatedALPN,
                sniHash: state.sniHash,
                forwardingDecision: nil,
                consumeOriginalDatagram: true
            )
        }

        if let bootstrapPreparation {
            launchBootstrapPreparationTask(bootstrapPreparation)
        }
        if let sessionToClose {
            Task {
                await sessionToClose.close()
            }
        }
        if let ingestTask {
            launchIngestTask(
                flowKey: flowKey,
                flowID: ingestTask.flowID,
                session: ingestTask.session,
                payload: ingestTask.payload,
                fromClient: true
            )
        }
        if let fallbackMetricReason {
            Task {
                await QUICConnectionManager.shared.recordPassThroughFallback(reason: fallbackMetricReason)
            }
        }

        evaluation.flowID = evaluationFlowID
        return evaluation
    }

    func launchBootstrapTask(
        flowKey: FlowKey,
        flowID: UUID,
        session: QUICMitmSession
    ) {
        Task { [weak self] in
            guard let self else { return }
            let establishResult = await session.establish()

            if establishResult.outcome == .intercepted {
                if let dualMITMPolicyEngine = self.dualMITMPolicyEngine {
                    let hostPort: (String, Int)? = self.stateQueue.sync {
                        guard let state = self.flowStates[flowKey], state.flowID == flowID else { return nil }
                        return (state.host, state.port)
                    }
                    if let (host, port) = hostPort {
                        let startPlan = dualMITMPolicyEngine.planNewFlow(
                            protocolName: .quic,
                            destination: HostPort(host: host, port: port)
                        )
                        dualMITMPolicyEngine.recordSuccess(
                            profile: startPlan.profile,
                            details: SuccessDetails(establishedMITM: true)
                        )
                    }
                }
                self.stateQueue.sync {
                    guard var state = self.flowStates[flowKey], state.flowID == flowID else { return }
                    let now = Date()
                    state.isEstablishing = false
                    state.isEstablished = true
                    state.lastFailureReason = nil
                    state.lastFailureAt = nil
                    state.negotiatedALPN = "h3"
                    state.establishedAt = now
                    state.lastProgressAt = now
                    if state.noProgressBudgetStartAt == nil {
                        state.noProgressBudgetStartAt = now
                    }
                    state.clientDatagramsSeen = 0
                    state.processedStreamCount = 0
                    state.bootstrapToken = nil
                    state.tickTask?.cancel()
                    state.tickTask = self.makeSessionTickTask(
                        flowKey: flowKey,
                        flowID: flowID,
                        session: session
                    )
                    self.flowStates[flowKey] = state
                }
                self.schedulePendingDatagramsIfPossible(flowKey: flowKey, flowID: flowID)
                return
            }

            let reason = self.failureReason(from: establishResult.reason)
            let failureDecision = self.failureDecisionForFlow(
                flowKey: flowKey,
                flowID: flowID,
                reason: reason
            )
            let shouldCloseSession = failureDecision.enabled
                ? self.markFlowFailed(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: failureDecision.effectiveReason,
                    detail: establishResult.reasonDetail
                )
                : self.markFlowBlocked(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: failureDecision.effectiveReason,
                    detail: establishResult.reasonDetail
                )

            if shouldCloseSession {
                if self.logSampler.shouldLog(event: "vpn.quic_session_establish_failed", key: failureDecision.effectiveReason, first: 5, every: 250) {
                    VPNLog.tunnel.info(
                        "event=vpn.quic_session_establish_failed outcome=\(failureDecision.enabled ? "pass_through" : "blocked", privacy: .public) reason=\(failureDecision.effectiveReason, privacy: .public)"
                    )
                }
                await session.close()
            }
        }
    }

    func launchBootstrapPreparationTask(_ preparation: BootstrapPreparation) {
        Task { [weak self] in
            guard let self else { return }
            let certificateMaterial = await self.certificateMaterialProvider.material(for: preparation.host)
            if certificateMaterial == nil {
                self.eventLogHandler?(
                    "quic_mitm_session",
                    "stage=establish_prepare flow_id=\(preparation.flowID.uuidString) host_hash=\(LogRedaction.hash(preparation.host)) cert_material=missing"
                )
            }
            let session = QUICMitmSession(
                flowID: preparation.flowID,
                host: preparation.host,
                port: preparation.port,
                interceptor: self.interceptor,
                http3Client: self.http3ClientFactory(),
                certificateMaterial: certificateMaterial,
                tunnelPolicyRequired: preparation.tunnelPolicyRequired,
                eventLogHandler: self.eventLogHandler
            )

            let shouldLaunch = self.stateQueue.sync { () -> Bool in
                guard var state = self.flowStates[preparation.flowKey],
                      state.flowID == preparation.flowID,
                      state.isEstablishing,
                      state.session == nil,
                      state.bootstrapToken == preparation.bootstrapToken else {
                    return false
                }
                state.session = session
                self.flowStates[preparation.flowKey] = state
                return true
            }

            if shouldLaunch {
                self.launchBootstrapTask(
                    flowKey: preparation.flowKey,
                    flowID: preparation.flowID,
                    session: session
                )
            } else {
                await session.close()
            }
        }
    }

    func launchRetryBootstrapPreparationTask(_ retry: RetryBootstrapPreparation) {
        Task { [weak self] in
            guard let self else {
                await retry.oldSession.close()
                return
            }

            let certificateMaterial = await self.certificateMaterialProvider.material(for: retry.authority)
            if certificateMaterial == nil {
                self.eventLogHandler?(
                    "quic_mitm_session",
                    "stage=retry_prepare flow_id=\(retry.flowID.uuidString) authority_hash=\(retry.authorityHash) cert_material=missing"
                )
            }
            let session = QUICMitmSession(
                flowID: retry.flowID,
                host: retry.authority,
                port: retry.port,
                interceptor: self.interceptor,
                http3Client: self.http3ClientFactory(),
                certificateMaterial: certificateMaterial,
                tunnelPolicyRequired: retry.tunnelPolicyRequired,
                eventLogHandler: self.eventLogHandler
            )

            let shouldLaunch = self.stateQueue.sync { () -> Bool in
                guard var state = self.flowStates[retry.flowKey],
                      state.flowID == retry.flowID,
                      state.isEstablishing,
                      state.session == nil,
                      state.host.caseInsensitiveCompare(retry.authority) == .orderedSame,
                      state.bootstrapToken == retry.bootstrapToken else {
                    return false
                }
                state.session = session
                self.flowStates[retry.flowKey] = state
                return true
            }

            if shouldLaunch {
                self.launchBootstrapTask(
                    flowKey: retry.flowKey,
                    flowID: retry.flowID,
                    session: session
                )
            } else {
                await session.close()
            }
            await retry.oldSession.close()
        }
    }

    func scheduleAuthorityRetry(
        flowKey: FlowKey,
        flowID: UUID,
        authorityHint: String,
        replayDatagram: Data?,
        fromClient: Bool
    ) -> RetryBootstrapPreparation? {
        guard fromClient else {
            return nil
        }

        let normalizedAuthority = normalizeAuthority(authorityHint)
        guard shouldIssueCertificate(for: normalizedAuthority) else {
            eventLogHandler?(
                "quic_mitm_session",
                "outcome=retry_with_authority_skipped flow_id=\(flowID.uuidString) reason=invalid_authority"
            )
            return nil
        }

        var retryTask: RetryBootstrapPreparation?
        stateQueue.sync {
            guard var state = flowStates[flowKey],
                  state.flowID == flowID,
                  let activeSession = state.session else { return }

            let currentAuthority = normalizeAuthority(state.host)
            if let skipReason = Self.authorityRetrySkipReason(
                currentAuthority: currentAuthority,
                nextAuthority: normalizedAuthority,
                attemptsUsed: state.authorityRetryCount,
                maxAttempts: maxAuthorityRetryAttempts,
                lastAuthorityRetry: state.lastAuthorityRetry
            ) {
                eventLogHandler?(
                    "quic_mitm_session",
                    "outcome=retry_with_authority_skipped flow_id=\(flowID.uuidString) reason=\(skipReason) authority_hash=\(LogRedaction.hash(normalizedAuthority)) attempts=\(state.authorityRetryCount)"
                )
                return
            }

            let now = Date()
            if let hostFailOpenReason = activeHostFailOpenReasonLocked(
                state: state,
                hostHint: normalizedAuthority,
                now: now
            ) {
                eventLogHandler?(
                    "quic_mitm_session",
                    "outcome=retry_with_authority_skipped flow_id=\(flowID.uuidString) reason=host_fail_open_active authority_hash=\(LogRedaction.hash(normalizedAuthority)) fail_open_reason=\(hostFailOpenReason)"
                )
                return
            }

            state.tickTask?.cancel()
            state.tickTask = nil
            state.host = normalizedAuthority
            state.port = Int(state.serverPort)
            state.isEstablishing = true
            state.isEstablished = false
            state.queuedIngests = 0
            let bufferedClientReplay = state.recentClientDatagrams +
                state.pendingDatagrams
                .filter(\.fromClient)
                .map(\.payload)
            state.pendingDatagrams.removeAll(keepingCapacity: false)
            var replayQueue = Array(
                bufferedClientReplay
                    .suffix(maxBufferedDatagramsPerFlow)
                    .filter { !$0.isEmpty }
            )
            if let replayDatagram, !replayDatagram.isEmpty,
               replayQueue.last != replayDatagram {
                replayQueue.append(replayDatagram)
            }
            if replayQueue.count > maxBufferedDatagramsPerFlow {
                replayQueue = Array(replayQueue.suffix(maxBufferedDatagramsPerFlow))
            }
            for payload in replayQueue {
                state.pendingDatagrams.append(QueuedDatagram(payload: payload, fromClient: true))
            }
            state.negotiatedALPN = nil
            state.sniHash = LogRedaction.hash(normalizedAuthority)
            state.lastFailureReason = nil
            state.lastFailureAt = nil
            state.authorityRetryCount += 1
            state.lastAuthorityRetry = normalizedAuthority
            state.establishedAt = nil
            state.lastProgressAt = nil
            if state.noProgressBudgetStartAt == nil {
                state.noProgressBudgetStartAt = now
            }
            state.clientDatagramsSeen = 0
            state.processedStreamCount = 0
            let bootstrapToken = UUID()
            state.bootstrapToken = bootstrapToken
            state.session = nil
            flowStates[flowKey] = state
            retryTask = RetryBootstrapPreparation(
                flowKey: flowKey,
                flowID: state.flowID,
                bootstrapToken: bootstrapToken,
                authority: normalizedAuthority,
                port: state.port,
                authorityHash: state.sniHash ?? "unknown",
                attempt: state.authorityRetryCount,
                tunnelPolicyRequired: state.tunnelPolicyRequired,
                oldSession: activeSession
            )
        }
        return retryTask
    }
}
