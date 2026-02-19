//
//  QUICFlowRouter.swift
//  TraceVPN
//
//  Created by Codex on 2026/02/18.
//

import Dispatch
import Foundation
import OSLog
import Security
import TraceCore
import TracePacket
import TraceQUIC
import TraceSecurity

struct QUICRouteResult: Sendable {
    let forwardingDecision: UDPForwardDecision
    let inspectionOutcome: QUICInspectionOutcome
    let metadata: QUICFlowMetadata
    let consumeOriginalDatagram: Bool
}

struct QUICFlowDatagramContext: Sendable {
    let flowID: UUID
    let clientIP: IPAddress
    let clientPort: UInt16
    let serverIP: IPAddress
    let serverPort: UInt16
    let upstreamForwardingDecision: UDPForwardDecision
}

/// Routes QUIC flows between interception and pass-through paths.
///
/// Current behavior is connectivity-first: when interception is requested but
/// the QUIC MITM engine is unavailable, we mark and pass-through.
final class QUICFlowRouter {
    private struct FlowKey: Hashable {
        let sourceIP: IPAddress
        let sourcePort: UInt16
        let destinationIP: IPAddress
        let destinationPort: UInt16
    }

    private struct ParsedHeaderMetadata {
        let version: String?
        let sourceConnectionIDLength: Int?
        let destinationConnectionIDLength: Int?
    }

    private struct QueuedDatagram {
        let payload: Data
        let fromClient: Bool
    }

    private struct FlowSessionState {
        let flowID: UUID
        var host: String
        var port: Int
        var clientIP: IPAddress
        var clientPort: UInt16
        var serverIP: IPAddress
        var serverPort: UInt16
        var upstreamForwardingDecision: UDPForwardDecision
        var session: QUICMitmSession?
        var isEstablishing: Bool
        var isEstablished: Bool
        var queuedIngests: Int
        var pendingDatagrams: [QueuedDatagram]
        var tickTask: Task<Void, Never>?
        var negotiatedALPN: String?
        var sniHash: String?
        var lastFailureReason: String?
        var lastFailureAt: Date?
        var lastActivity: Date
        var tunnelPolicyRequired: Bool

        init(
            flowID: UUID = UUID(),
            host: String,
            port: Int,
            clientIP: IPAddress,
            clientPort: UInt16,
            serverIP: IPAddress,
            serverPort: UInt16,
            upstreamForwardingDecision: UDPForwardDecision,
            now: Date,
            tunnelPolicyRequired: Bool
        ) {
            self.flowID = flowID
            self.host = host
            self.port = port
            self.clientIP = clientIP
            self.clientPort = clientPort
            self.serverIP = serverIP
            self.serverPort = serverPort
            self.upstreamForwardingDecision = upstreamForwardingDecision
            session = nil
            isEstablishing = false
            isEstablished = false
            queuedIngests = 0
            pendingDatagrams = []
            tickTask = nil
            negotiatedALPN = nil
            sniHash = nil
            lastFailureReason = nil
            lastFailureAt = nil
            lastActivity = now
            self.tunnelPolicyRequired = tunnelPolicyRequired
        }
    }

    private struct RouteEvaluation {
        let inspectionOutcome: QUICInspectionOutcome
        let handshakeOutcome: QUICHandshakeOutcome
        let failureReason: String?
        let alpn: String?
        let sniHash: String?
        let consumeOriginalDatagram: Bool
    }

    private let logSampler = LogSampler()
    private let stateQueue = DispatchQueue(label: "com.trace.vpn.quic_flow_router.state", qos: .utility)
    private let interceptor: (any InterceptionProviding)?
    private let http3ClientFactory: @Sendable () -> any HTTP3Client
    private let engineStatusProvider: @Sendable () -> QUICEngineStatus
    private let downstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)?
    private let upstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)?
    private var flowStates: [FlowKey: FlowSessionState] = [:]
    private var lastCleanupAt = Date.distantPast

    private let cleanupInterval: TimeInterval = 30
    private let flowIdleTimeout: TimeInterval = 120
    private let retryBackoff: TimeInterval = 15
    private let maxQueuedIngestsPerFlow = 16
    private let maxBufferedDatagramsPerFlow = 64
    private let sessionTickInterval: UInt64 = 25_000_000

    init(
        interceptor: (any InterceptionProviding)? = nil,
        http3ClientFactory: @escaping @Sendable () -> any HTTP3Client = { URLSessionHTTP3Client() },
        engineStatusProvider: @escaping @Sendable () -> QUICEngineStatus = { QUICEngineRuntime.currentStatus() },
        downstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)? = nil,
        upstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)? = nil
    ) {
        self.interceptor = interceptor
        self.http3ClientFactory = http3ClientFactory
        self.engineStatusProvider = engineStatusProvider
        self.downstreamDatagramSink = downstreamDatagramSink
        self.upstreamDatagramSink = upstreamDatagramSink
    }

    func resolveInterceptRoute(
        ipPacket: IPPacket,
        udpPacket: UDPPacket,
        udpForwarderAvailable: Bool,
        tunnelUDPSupported: Bool,
        tunnelPolicyRequired: Bool,
        authorityHint: String? = nil
    ) -> QUICRouteResult {
        let forwardingDecision = determineForwardingDecision(
            udpForwarderAvailable: udpForwarderAvailable,
            tunnelUDPSupported: tunnelUDPSupported,
            tunnelPolicyRequired: tunnelPolicyRequired
        )

        let evaluation = evaluateAndScheduleIntercept(
            ipPacket: ipPacket,
            udpPacket: udpPacket,
            authorityHint: authorityHint,
            tunnelPolicyRequired: tunnelPolicyRequired,
            tunnelUDPSupported: tunnelUDPSupported,
            forwardingDecision: forwardingDecision
        )
        let metadata = makeFlowMetadata(
            udpPacket: udpPacket,
            handshakeOutcome: evaluation.handshakeOutcome,
            failureReason: evaluation.failureReason,
            alpn: evaluation.alpn,
            sniHash: evaluation.sniHash
        )

        if evaluation.inspectionOutcome == .passThroughMarked,
           let reason = evaluation.failureReason,
           logSampler.shouldLog(event: "vpn.quic_intercept_fallback", key: reason, first: 5, every: 250) {
            VPNLog.tunnel.info(
                "event=vpn.quic_intercept_fallback outcome=pass_through reason=\(reason, privacy: .public) forward=\(String(describing: forwardingDecision), privacy: .public)"
            )
        }

        return QUICRouteResult(
            forwardingDecision: forwardingDecision,
            inspectionOutcome: evaluation.inspectionOutcome,
            metadata: metadata,
            consumeOriginalDatagram: evaluation.consumeOriginalDatagram
        )
    }

    /// Attempts to consume an upstream QUIC datagram for an active intercepted flow.
    ///
    /// Returns `true` when the datagram was handed to the intercept engine and should
    /// not be written directly back to the app. Returns `false` when no active
    /// intercepted flow matches and normal forwarding should continue.
    @discardableResult
    func ingestUpstreamDatagram(
        ipPacket: IPPacket,
        udpPacket: UDPPacket
    ) -> Bool {
        let now = Date()
        let reverseFlowKey = FlowKey(
            sourceIP: ipPacket.destination,
            sourcePort: udpPacket.destinationPort,
            destinationIP: ipPacket.source,
            destinationPort: udpPacket.sourcePort
        )
        let payload = udpPacket.payload

        guard !payload.isEmpty else { return false }

        var ingestTask: (flowID: UUID, session: QUICMitmSession, payload: Data)?
        let consumed = stateQueue.sync { () -> Bool in
            guard var state = flowStates[reverseFlowKey], state.isEstablished, let session = state.session else {
                return false
            }

            state.lastActivity = now
            guard state.queuedIngests < maxQueuedIngestsPerFlow else {
                if state.pendingDatagrams.count < maxBufferedDatagramsPerFlow {
                    state.pendingDatagrams.append(QueuedDatagram(payload: payload, fromClient: false))
                }
                flowStates[reverseFlowKey] = state
                return true
            }

            state.queuedIngests += 1
            flowStates[reverseFlowKey] = state
            ingestTask = (state.flowID, session, payload)
            return true
        }

        if let ingestTask {
            launchIngestTask(
                flowKey: reverseFlowKey,
                flowID: ingestTask.flowID,
                session: ingestTask.session,
                payload: ingestTask.payload,
                fromClient: false
            )
        }

        return consumed
    }

    func makeFlowMetadata(
        udpPacket: UDPPacket,
        handshakeOutcome: QUICHandshakeOutcome,
        failureReason: String? = nil,
        alpn: String? = nil,
        sniHash: String? = nil
    ) -> QUICFlowMetadata {
        let parsed = parseHeaderMetadata(payload: udpPacket.payload)
        return QUICFlowMetadata(
            version: parsed.version,
            alpn: alpn,
            sniHash: sniHash,
            sourceConnectionIDLength: parsed.sourceConnectionIDLength,
            destinationConnectionIDLength: parsed.destinationConnectionIDLength,
            handshakeOutcome: handshakeOutcome,
            failureReason: failureReason
        )
    }

    private func determineForwardingDecision(
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

    private func parseHeaderMetadata(payload: Data) -> ParsedHeaderMetadata {
        guard let first = payload.first else {
            return ParsedHeaderMetadata(
                version: nil,
                sourceConnectionIDLength: nil,
                destinationConnectionIDLength: nil
            )
        }

        // QUIC long headers expose version and connection ID lengths.
        guard (first & 0x80) == 0x80, payload.count >= 6 else {
            return ParsedHeaderMetadata(
                version: nil,
                sourceConnectionIDLength: nil,
                destinationConnectionIDLength: nil
            )
        }

        let versionRaw =
            (UInt32(payload[1]) << 24) |
            (UInt32(payload[2]) << 16) |
            (UInt32(payload[3]) << 8) |
            UInt32(payload[4])
        let version = String(format: "0x%08X", versionRaw)

        var index = 5
        guard payload.count > index else {
            return ParsedHeaderMetadata(
                version: version,
                sourceConnectionIDLength: nil,
                destinationConnectionIDLength: nil
            )
        }

        let destinationConnectionIDLength = Int(payload[index])
        index += 1
        guard payload.count >= index + destinationConnectionIDLength + 1 else {
            return ParsedHeaderMetadata(
                version: version,
                sourceConnectionIDLength: nil,
                destinationConnectionIDLength: destinationConnectionIDLength
            )
        }

        index += destinationConnectionIDLength
        let sourceConnectionIDLength = Int(payload[index])
        index += 1
        guard payload.count >= index + sourceConnectionIDLength else {
            return ParsedHeaderMetadata(
                version: version,
                sourceConnectionIDLength: sourceConnectionIDLength,
                destinationConnectionIDLength: destinationConnectionIDLength
            )
        }

        return ParsedHeaderMetadata(
            version: version,
            sourceConnectionIDLength: sourceConnectionIDLength,
            destinationConnectionIDLength: destinationConnectionIDLength
        )
    }

    private func evaluateAndScheduleIntercept(
        ipPacket: IPPacket,
        udpPacket: UDPPacket,
        authorityHint: String?,
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
        let payload = udpPacket.payload

        var bootstrapTask: (flowID: UUID, session: QUICMitmSession)?
        var ingestTask: (flowID: UUID, session: QUICMitmSession, payload: Data)?
        var sessionToClose: QUICMitmSession?
        var fallbackMetricReason: String?

        let evaluation = stateQueue.sync { () -> RouteEvaluation in
            cleanupIdleFlowsIfNeeded(now: now)

            var state = flowStates[flowKey] ?? FlowSessionState(
                host: hostHint,
                port: Int(udpPacket.destinationPort),
                clientIP: ipPacket.source,
                clientPort: udpPacket.sourcePort,
                serverIP: ipPacket.destination,
                serverPort: udpPacket.destinationPort,
                upstreamForwardingDecision: forwardingDecision,
                now: now,
                tunnelPolicyRequired: tunnelPolicyRequired
            )

            state.host = hostHint
            state.port = Int(udpPacket.destinationPort)
            state.clientIP = ipPacket.source
            state.clientPort = udpPacket.sourcePort
            state.serverIP = ipPacket.destination
            state.serverPort = udpPacket.destinationPort
            state.upstreamForwardingDecision = forwardingDecision
            state.lastActivity = now
            state.tunnelPolicyRequired = tunnelPolicyRequired

            if tunnelPolicyRequired, !tunnelUDPSupported {
                let priorTickTask = state.tickTask
                priorTickTask?.cancel()
                sessionToClose = state.session
                state.lastFailureReason = "quic_tunnel_required_unavailable"
                state.lastFailureAt = now
                state.isEstablishing = false
                state.isEstablished = false
                state.queuedIngests = 0
                state.pendingDatagrams.removeAll(keepingCapacity: false)
                state.session = nil
                state.tickTask = nil
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: .passThroughMarked,
                    handshakeOutcome: .passThrough,
                    failureReason: "quic_tunnel_required_unavailable",
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    consumeOriginalDatagram: false
                )
            }

            if state.isEstablished, let session = state.session {
                if !payload.isEmpty {
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
                    consumeOriginalDatagram: true
                )
            }

            if let reason = state.lastFailureReason,
               let lastFailureAt = state.lastFailureAt,
               now.timeIntervalSince(lastFailureAt) < retryBackoff {
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: .passThroughMarked,
                    handshakeOutcome: .passThrough,
                    failureReason: reason,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    consumeOriginalDatagram: false
                )
            }

            if state.isEstablishing {
                if !payload.isEmpty, state.pendingDatagrams.count < maxBufferedDatagramsPerFlow {
                    state.pendingDatagrams.append(QueuedDatagram(payload: payload, fromClient: true))
                }
                flowStates[flowKey] = state
                return RouteEvaluation(
                    inspectionOutcome: .intercepted,
                    handshakeOutcome: .negotiated,
                    failureReason: "quic_mitm_session_establishing",
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    consumeOriginalDatagram: true
                )
            }

            let engineStatus = engineStatusProvider()
            if engineStatus.availability != .available {
                let reason = QUICMitmFailureReason.engineUnavailable.rawValue
                state.lastFailureReason = reason
                state.lastFailureAt = now
                state.isEstablishing = false
                state.isEstablished = false
                state.queuedIngests = 0
                state.pendingDatagrams.removeAll(keepingCapacity: false)
                state.session = nil
                state.tickTask = nil
                state.sniHash = LogRedaction.hash(hostHint)
                flowStates[flowKey] = state
                fallbackMetricReason = reason
                return RouteEvaluation(
                    inspectionOutcome: .passThroughMarked,
                    handshakeOutcome: .passThrough,
                    failureReason: reason,
                    alpn: state.negotiatedALPN,
                    sniHash: state.sniHash,
                    consumeOriginalDatagram: false
                )
            }

            state.isEstablishing = true
            state.lastFailureReason = nil
            state.lastFailureAt = nil
            state.negotiatedALPN = nil
            state.sniHash = LogRedaction.hash(hostHint)

            let session = QUICMitmSession(
                flowID: state.flowID,
                host: state.host,
                port: state.port,
                interceptor: interceptor,
                http3Client: http3ClientFactory(),
                certificateMaterial: makeCertificateMaterial(for: state.host),
                tunnelPolicyRequired: state.tunnelPolicyRequired
            )
            state.session = session
            if !payload.isEmpty {
                state.pendingDatagrams.append(QueuedDatagram(payload: payload, fromClient: true))
            }
            flowStates[flowKey] = state
            bootstrapTask = (state.flowID, session)

            return RouteEvaluation(
                inspectionOutcome: .intercepted,
                handshakeOutcome: .negotiated,
                failureReason: "quic_mitm_session_establishing",
                alpn: state.negotiatedALPN,
                sniHash: state.sniHash,
                consumeOriginalDatagram: true
            )
        }

        if let bootstrapTask {
            launchBootstrapTask(
                flowKey: flowKey,
                flowID: bootstrapTask.flowID,
                session: bootstrapTask.session
            )
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

        return evaluation
    }

    private func launchBootstrapTask(
        flowKey: FlowKey,
        flowID: UUID,
        session: QUICMitmSession
    ) {
        Task { [weak self] in
            guard let self else { return }
            let establishResult = await session.establish()

            if establishResult.outcome == .intercepted {
                self.stateQueue.sync {
                    guard var state = self.flowStates[flowKey], state.flowID == flowID else { return }
                    state.isEstablishing = false
                    state.isEstablished = true
                    state.lastFailureReason = nil
                    state.lastFailureAt = nil
                    state.negotiatedALPN = "h3"
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
            let shouldCloseSession = self.markFlowFailed(
                flowKey: flowKey,
                flowID: flowID,
                reason: reason
            )

            if shouldCloseSession {
                if self.logSampler.shouldLog(event: "vpn.quic_session_establish_failed", key: reason, first: 5, every: 250) {
                    VPNLog.tunnel.info(
                        "event=vpn.quic_session_establish_failed outcome=pass_through reason=\(reason, privacy: .public)"
                    )
                }
                await session.close()
            }
        }
    }

    private func launchIngestTask(
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
                    direction: fromClient ? "client" : "upstream"
                )
            } catch {
                let reason = "quic_mitm_ingest_failed"
                let shouldCloseSession = self.markFlowFailed(
                    flowKey: flowKey,
                    flowID: flowID,
                    reason: reason
                )

                if shouldCloseSession {
                    if self.logSampler.shouldLog(event: "vpn.quic_session_ingest_failed", key: reason, first: 5, every: 250) {
                        VPNLog.tunnel.info(
                            "event=vpn.quic_session_ingest_failed outcome=pass_through reason=\(reason, privacy: .public) direction=\(fromClient ? "client" : "upstream", privacy: .public)"
                        )
                    }
                    await session.close()
                }
            }
        }
    }

    private func handleSessionResult(
        _ ingestResult: QUICMitmIngestResult,
        flowKey: FlowKey,
        flowID: UUID,
        session: QUICMitmSession,
        direction: String
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

        guard let fallbackReason = ingestResult.fallbackReason else {
            return
        }

        let reason = failureReason(from: fallbackReason)
        let shouldCloseSession = markFlowFailed(
            flowKey: flowKey,
            flowID: flowID,
            reason: reason
        )

        if shouldCloseSession {
            await QUICConnectionManager.shared.recordPassThroughFallback(reason: reason)
            if logSampler.shouldLog(event: "vpn.quic_session_ingest_fallback", key: reason, first: 5, every: 250) {
                VPNLog.tunnel.info(
                    "event=vpn.quic_session_ingest_fallback outcome=pass_through reason=\(reason, privacy: .public) direction=\(direction, privacy: .public)"
                )
            }
            await session.close()
        }
    }

    private func schedulePendingDatagramsIfPossible(flowKey: FlowKey, flowID: UUID) {
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

    private func makeSessionTickTask(
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
                        direction: "timer"
                    )
                } catch {
                    let reason = "quic_mitm_tick_failed"
                    let shouldCloseSession = self.markFlowFailed(
                        flowKey: flowKey,
                        flowID: flowID,
                        reason: reason
                    )

                    if shouldCloseSession {
                        if self.logSampler.shouldLog(event: "vpn.quic_session_tick_failed", key: reason, first: 5, every: 250) {
                            VPNLog.tunnel.info(
                                "event=vpn.quic_session_tick_failed outcome=pass_through reason=\(reason, privacy: .public)"
                            )
                        }
                        await session.close()
                    }
                    return
                }
            }
        }
    }

    private func markFlowFailed(
        flowKey: FlowKey,
        flowID: UUID,
        reason: String
    ) -> Bool {
        var tickTask: Task<Void, Never>?
        let shouldClose = stateQueue.sync { () -> Bool in
            guard var state = flowStates[flowKey], state.flowID == flowID else { return false }
            tickTask = state.tickTask
            state.isEstablishing = false
            state.isEstablished = false
            state.queuedIngests = 0
            state.pendingDatagrams.removeAll(keepingCapacity: false)
            state.session = nil
            state.tickTask = nil
            state.lastFailureReason = reason
            state.lastFailureAt = Date()
            flowStates[flowKey] = state
            return true
        }
        tickTask?.cancel()
        return shouldClose
    }

    private func datagramContext(for flowKey: FlowKey, flowID: UUID) -> QUICFlowDatagramContext? {
        stateQueue.sync {
            guard let state = flowStates[flowKey], state.flowID == flowID else {
                return nil
            }
            return QUICFlowDatagramContext(
                flowID: state.flowID,
                clientIP: state.clientIP,
                clientPort: state.clientPort,
                serverIP: state.serverIP,
                serverPort: state.serverPort,
                upstreamForwardingDecision: state.upstreamForwardingDecision
            )
        }
    }

    private func cleanupIdleFlowsIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastCleanupAt) >= cleanupInterval else {
            return
        }
        lastCleanupAt = now

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
    }

    private func failureReason(from reason: QUICMitmFailureReason?) -> String {
        reason?.rawValue ?? "quic_mitm_failed_open"
    }

    func makeCertificateMaterial(for authority: String) -> QUICMitmCertificateMaterial? {
        let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldIssueCertificate(for: trimmed) else { return nil }

        if TLSHandler.preflightServerLeafTrust(for: trimmed) != nil {
            return nil
        }

        do {
            let (certificate, privateKey) = try CertificateManager.shared.generateCertificateForDomain(trimmed)
            let certificateDER = SecCertificateCopyData(certificate) as Data
            var keyError: Unmanaged<CFError>?
            guard let privateKeyDER = SecKeyCopyExternalRepresentation(privateKey, &keyError) as Data? else {
                return nil
            }
            return QUICMitmCertificateMaterial(
                leafCertificateDER: certificateDER,
                privateKeyDER: privateKeyDER
            )
        } catch {
            return nil
        }
    }

    func shouldIssueCertificate(for authority: String) -> Bool {
        guard !authority.isEmpty else { return false }
        // Best effort: skip IP literals and unknown authorities.
        return authority.contains { $0.isLetter }
    }
}
