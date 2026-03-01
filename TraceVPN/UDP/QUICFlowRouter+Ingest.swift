//
//  QUICFlowRouter+Ingest.swift
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
    func launchIngestTask(
        flowKey: FlowKey,
        flowID: UUID,
        session: QUICMitmSession,
        payload: Data,
        fromClient: Bool
    ) {
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.stateQueue.sync {
                    guard var state = self.flowStates[flowKey], state.flowID == flowID else { return }
                    state.queuedIngests = max(0, state.queuedIngests - 1)
                    self.flowStates[flowKey] = state
                }
                self.schedulePendingDatagramsIfPossible(flowKey: flowKey, flowID: flowID)
            }

            do {
                let ingestResult = try await session.ingestDatagram(payload, fromClient: fromClient)
                await self.handleSessionResult(
                    ingestResult,
                    flowKey: flowKey,
                    flowID: flowID,
                    session: session,
                    direction: fromClient ? "client" : "upstream",
                    originalPayload: payload,
                    fromClient: fromClient
                )
            } catch {
                if self.isGracefulSessionClosure(error) {
                    let reason = self.gracefulSessionClosureReason(for: error)
                    self.forwardOriginalDatagramIfNeeded(
                        payload,
                        fromClient: fromClient,
                        flowKey: flowKey,
                        flowID: flowID
                    )
                    let shouldCloseSession = self.closeFlowGracefully(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: reason
                    )
                    if shouldCloseSession {
                        if self.logSampler.shouldLog(event: "vpn.quic_session_ingest_closed", key: reason, first: 5, every: 250) {
                            VPNLog.tunnel.info(
                                "event=vpn.quic_session_ingest_closed outcome=closed reason=\(reason, privacy: .public) direction=\(fromClient ? "client" : "upstream", privacy: .public)"
                            )
                        }
                        await session.close()
                    }
                    return
                }

                let errorDescription = String(describing: error)
                let reason = self.ingestFailureReason(for: error)
                self.eventLogHandler?(
                    "quic_mitm_session",
                    "outcome=ingest_exception flow_id=\(flowID.uuidString) reason=\(reason) direction=\(fromClient ? "client" : "upstream") error=\(errorDescription)"
                )
                let failureDecision = self.failureDecisionForFlow(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: reason
                )
                if failureDecision.enabled {
                    self.forwardOriginalDatagramIfNeeded(
                        payload,
                        fromClient: fromClient,
                        flowKey: flowKey,
                        flowID: flowID
                    )
                }
                let shouldCloseSession = failureDecision.enabled
                    ? self.markFlowFailed(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: failureDecision.effectiveReason
                    )
                    : self.markFlowBlocked(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: failureDecision.effectiveReason
                    )

                if shouldCloseSession {
                    if failureDecision.enabled {
                        await QUICConnectionManager.shared.recordPassThroughFallback(reason: failureDecision.effectiveReason)
                    }
                    if self.logSampler.shouldLog(event: "vpn.quic_session_ingest_failed", key: failureDecision.effectiveReason, first: 5, every: 250) {
                        VPNLog.tunnel.info(
                            "event=vpn.quic_session_ingest_failed outcome=\(failureDecision.enabled ? "pass_through" : "blocked", privacy: .public) reason=\(failureDecision.effectiveReason, privacy: .public) direction=\(fromClient ? "client" : "upstream", privacy: .public) error=\(errorDescription, privacy: .public)"
                        )
                    }
                    await session.close()
                }
            }
        }
    }

    func handleSessionResult(
        _ ingestResult: QUICMitmIngestResult,
        flowKey: FlowKey,
        flowID: UUID,
        session: QUICMitmSession,
        direction: String,
        originalPayload: Data? = nil,
        fromClient: Bool
    ) async {
        if let context = datagramContext(for: flowKey, flowID: flowID) {
            if let sink = downstreamDatagramSink, !ingestResult.datagramsToClient.isEmpty {
                for datagram in ingestResult.datagramsToClient where !datagram.isEmpty {
                    sink(datagram, context)
                }
            }
            if let sink = upstreamDatagramSink, !ingestResult.datagramsToUpstream.isEmpty {
                for datagram in ingestResult.datagramsToUpstream where !datagram.isEmpty {
                    sink(datagram, context)
                }
            }
        }

        if ingestResult.processedStreams > 0 {
            eventLogHandler?(
                "quic_plaintext_capture",
                "outcome=decrypted flow_id=\(flowID.uuidString) streams=\(ingestResult.processedStreams)"
            )
        }
        let now = Date()
        let noProgressSnapshot = updateNoProgressSnapshot(
            flowKey: flowKey,
            flowID: flowID,
            fromClient: fromClient,
            ingestResult: ingestResult,
            now: now
        )

        if let retryAuthorityHint = ingestResult.retryAuthorityHint {
            if let retryTask = scheduleAuthorityRetry(
                flowKey: flowKey,
                flowID: flowID,
                authorityHint: retryAuthorityHint,
                replayDatagram: originalPayload,
                fromClient: fromClient
            ) {
                eventLogHandler?(
                    "quic_mitm_session",
                    "outcome=retry_with_authority_scheduled flow_id=\(flowID.uuidString) authority_hash=\(retryTask.authorityHash) attempt=\(retryTask.attempt)"
                )
                launchRetryBootstrapPreparationTask(retryTask)
                return
            }

            let reason = "quic_retry_with_authority_failed"
            let failureDecision = failureDecisionForFlow(
                flowKey: flowKey,
                flowID: flowID,
                reason: reason
            )
            if failureDecision.enabled {
                forwardOriginalDatagramIfNeeded(
                    originalPayload,
                    fromClient: fromClient,
                    flowKey: flowKey,
                    flowID: flowID
                )
            }
            let shouldCloseSession = failureDecision.enabled
                ? markFlowFailed(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: failureDecision.effectiveReason
                )
                : markFlowBlocked(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: failureDecision.effectiveReason
                )
            if shouldCloseSession {
                if failureDecision.enabled {
                    await QUICConnectionManager.shared.recordPassThroughFallback(reason: failureDecision.effectiveReason)
                }
                await session.close()
            }
            return
        }

        if ingestResult.connectionClosed, ingestResult.fallbackReason == nil {
            let reason = ingestResult.connectionCloseReason?.rawValue ?? "none"
            let candidateFailOpen = ingestResult.processedStreams == 0
            let failOpenReason = "quic_closed_before_http3_\(reason)"
            let failureDecision = candidateFailOpen
                ? failureDecisionForFlow(flowKey: flowKey, flowID: flowID, reason: failOpenReason)
                : (enabled: false, effectiveReason: reason)
            if candidateFailOpen, failureDecision.enabled {
                if originalPayload == nil {
                    replayRecentClientDatagramsIfNeeded(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: failureDecision.effectiveReason
                    )
                }
                forwardOriginalDatagramIfNeeded(
                    originalPayload,
                    fromClient: fromClient,
                    flowKey: flowKey,
                    flowID: flowID
                )
            }

            let shouldCloseSession: Bool = if candidateFailOpen {
                if failureDecision.enabled {
                    markFlowFailed(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: failureDecision.effectiveReason,
                        detail: ingestResult.connectionCloseReasonDetail
                    )
                } else {
                    markFlowBlocked(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: failureDecision.effectiveReason,
                        detail: ingestResult.connectionCloseReasonDetail
                    )
                }
            } else {
                closeFlowGracefully(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: reason
                )
            }
            if shouldCloseSession {
                if candidateFailOpen, failureDecision.enabled {
                    await QUICConnectionManager.shared.recordPassThroughFallback(reason: failureDecision.effectiveReason)
                }
                let outcome = candidateFailOpen
                    ? (failureDecision.enabled ? "pass_through" : "blocked")
                    : "success"
                let effectiveReason = candidateFailOpen ? failureDecision.effectiveReason : reason
                if logSampler.shouldLog(event: "vpn.quic_session_closed", key: effectiveReason, first: 5, every: 250) {
                    VPNLog.tunnel.debug(
                        "event=vpn.quic_session_closed outcome=\(outcome, privacy: .public) reason=\(effectiveReason, privacy: .public) direction=\(direction, privacy: .public)"
                    )
                }
                await session.close()
            }
            return
        }

        guard let fallbackReason = ingestResult.fallbackReason else {
            let shouldFailOpenForNoProgress = shouldFailOpenForNoProgress(
                snapshot: noProgressSnapshot,
                now: now
            )
            if shouldFailOpenForNoProgress {
                let reason = "quic_no_progress_fail_open"
                let failureDecision = failureDecisionForFlow(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: reason
                )
                if failureDecision.enabled {
                    if originalPayload == nil {
                        replayRecentClientDatagramsIfNeeded(
                            flowKey: flowKey,
                            flowID: flowID,
                            reason: failureDecision.effectiveReason
                        )
                    }
                    forwardOriginalDatagramIfNeeded(
                        originalPayload,
                        fromClient: fromClient,
                        flowKey: flowKey,
                        flowID: flowID
                    )
                }
                let shouldCloseSession = failureDecision.enabled
                    ? markFlowFailed(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: failureDecision.effectiveReason
                    )
                    : markFlowBlocked(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: failureDecision.effectiveReason
                    )
                if shouldCloseSession {
                    let idleMs = noProgressSnapshot?.lastProgressAt
                        .map { max(0, Int(now.timeIntervalSince($0) * 1000)) } ?? -1
                    eventLogHandler?(
                        "quic_mitm_session",
                        "outcome=\(failureDecision.enabled ? "no_progress_fail_open" : "no_progress_blocked") flow_id=\(flowID.uuidString) direction=\(direction) client_datagrams=\(noProgressSnapshot?.clientDatagramsSeen ?? -1) idle_ms=\(idleMs)"
                    )
                    if failureDecision.enabled {
                        await QUICConnectionManager.shared.recordPassThroughFallback(reason: failureDecision.effectiveReason)
                    }
                    if logSampler.shouldLog(event: "vpn.quic_no_progress_fail_open", key: failureDecision.effectiveReason, first: 5, every: 250) {
                        VPNLog.tunnel.info(
                            "event=vpn.quic_no_progress_fail_open outcome=\(failureDecision.enabled ? "pass_through" : "blocked", privacy: .public) reason=\(failureDecision.effectiveReason, privacy: .public) direction=\(direction, privacy: .public)"
                        )
                    }
                    await session.close()
                }
            }
            return
        }

        let reason = failureReason(from: fallbackReason)
        let failureDecision = failureDecisionForFlow(
            flowKey: flowKey,
            flowID: flowID,
            reason: reason
        )
        if failureDecision.enabled {
            if originalPayload == nil {
                replayRecentClientDatagramsIfNeeded(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: failureDecision.effectiveReason
                )
            }
            forwardOriginalDatagramIfNeeded(
                originalPayload,
                fromClient: fromClient,
                flowKey: flowKey,
                flowID: flowID
            )
        }
        let shouldCloseSession = failureDecision.enabled
            ? markFlowFailed(
                flowKey: flowKey,
                flowID: flowID,
                reason: failureDecision.effectiveReason,
                detail: ingestResult.fallbackReasonDetail
            )
            : markFlowBlocked(
                flowKey: flowKey,
                flowID: flowID,
                reason: failureDecision.effectiveReason,
                detail: ingestResult.fallbackReasonDetail
            )

        if shouldCloseSession {
            if failureDecision.enabled {
                await QUICConnectionManager.shared.recordPassThroughFallback(reason: failureDecision.effectiveReason)
            }
            if logSampler.shouldLog(event: "vpn.quic_session_ingest_fallback", key: failureDecision.effectiveReason, first: 5, every: 250) {
                VPNLog.tunnel.info(
                    "event=vpn.quic_session_ingest_fallback outcome=\(failureDecision.enabled ? "pass_through" : "blocked", privacy: .public) reason=\(failureDecision.effectiveReason, privacy: .public) direction=\(direction, privacy: .public)"
                )
            }
            await session.close()
        }
    }

    func schedulePendingDatagramsIfPossible(flowKey: FlowKey, flowID: UUID) {
        var session: QUICMitmSession?
        var datagrams: [QueuedDatagram] = []

        stateQueue.sync {
            guard var state = flowStates[flowKey],
                  state.flowID == flowID,
                  state.isEstablished,
                  let activeSession = state.session else { return }

            let availableSlots = max(0, maxQueuedIngestsPerFlow - state.queuedIngests)
            guard availableSlots > 0, !state.pendingDatagrams.isEmpty else {
                return
            }

            let dequeueCount = min(availableSlots, state.pendingDatagrams.count)
            datagrams = Array(state.pendingDatagrams.prefix(dequeueCount))
            state.pendingDatagrams.removeFirst(dequeueCount)
            state.queuedIngests += dequeueCount
            flowStates[flowKey] = state
            session = activeSession
        }

        guard let session else { return }
        for datagram in datagrams {
            launchIngestTask(
                flowKey: flowKey,
                flowID: flowID,
                session: session,
                payload: datagram.payload,
                fromClient: datagram.fromClient
            )
        }
    }

    func makeSessionTickTask(
        flowKey: FlowKey,
        flowID: UUID,
        session: QUICMitmSession
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.sessionTickInterval)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }

                let shouldTick = self.stateQueue.sync {
                    guard let state = self.flowStates[flowKey], state.flowID == flowID else {
                        return false
                    }
                    return state.isEstablished && state.session != nil
                }

                guard shouldTick else { return }

                do {
                    let tickResult = try await session.tick(
                        nowNanoseconds: DispatchTime.now().uptimeNanoseconds
                    )
                    await self.handleSessionResult(
                        tickResult,
                        flowKey: flowKey,
                        flowID: flowID,
                        session: session,
                        direction: "timer",
                        fromClient: false
                    )
                } catch {
                    if self.isGracefulSessionClosure(error) {
                        let reason = self.gracefulSessionClosureReason(for: error)
                        let shouldCloseSession = self.closeFlowGracefully(
                            flowKey: flowKey,
                            flowID: flowID,
                            reason: reason
                        )
                        if shouldCloseSession {
                            if self.logSampler.shouldLog(event: "vpn.quic_session_tick_closed", key: reason, first: 5, every: 250) {
                                VPNLog.tunnel.debug(
                                    "event=vpn.quic_session_tick_closed outcome=closed reason=\(reason, privacy: .public)"
                                )
                            }
                            await session.close()
                        }
                        return
                    }

                    let errorDescription = String(describing: error)
                    let reason = self.ingestFailureReason(for: error)
                    self.eventLogHandler?(
                        "quic_mitm_session",
                        "outcome=tick_exception flow_id=\(flowID.uuidString) reason=\(reason) error=\(errorDescription)"
                    )
                    let failureDecision = self.failureDecisionForFlow(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: reason
                    )
                    let shouldCloseSession = failureDecision.enabled
                        ? self.markFlowFailed(
                            flowKey: flowKey,
                            flowID: flowID,
                            reason: failureDecision.effectiveReason
                        )
                        : self.markFlowBlocked(
                            flowKey: flowKey,
                            flowID: flowID,
                            reason: failureDecision.effectiveReason
                        )

                    if shouldCloseSession {
                        if failureDecision.enabled {
                            await QUICConnectionManager.shared.recordPassThroughFallback(reason: failureDecision.effectiveReason)
                        }
                        if self.logSampler.shouldLog(event: "vpn.quic_session_tick_failed", key: failureDecision.effectiveReason, first: 5, every: 250) {
                            VPNLog.tunnel.info(
                                "event=vpn.quic_session_tick_failed outcome=\(failureDecision.enabled ? "pass_through" : "blocked", privacy: .public) reason=\(failureDecision.effectiveReason, privacy: .public) error=\(errorDescription, privacy: .public)"
                            )
                        }
                        await session.close()
                    }
                    return
                }
            }
        }
    }
}
