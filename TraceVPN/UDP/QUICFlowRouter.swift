//
//  QUICFlowRouter.swift
//  TraceVPN
//
//  Created by Codex on 2026/02/18.
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
/// Default behavior is connectivity-first (adaptive fail-open), with optional
/// policy-engine enforcement to fail-closed for strict-mode eligible flows.
final class QUICFlowRouter: @unchecked Sendable {
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
        var authorityRetryCount: Int
        var lastAuthorityRetry: String?
        var establishedAt: Date?
        var lastProgressAt: Date?
        var clientDatagramsSeen: Int
        var processedStreamCount: Int
        var recentClientDatagrams: [Data]
        var lastRouteDecisionLogSignature: String?
        var bootstrapToken: UUID?
        var noProgressBudgetStartAt: Date?

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
            authorityRetryCount = 0
            lastAuthorityRetry = nil
            establishedAt = nil
            lastProgressAt = nil
            clientDatagramsSeen = 0
            processedStreamCount = 0
            recentClientDatagrams = []
            lastRouteDecisionLogSignature = nil
            bootstrapToken = nil
            noProgressBudgetStartAt = nil
        }
    }

    private struct RouteEvaluation {
        let inspectionOutcome: QUICInspectionOutcome
        let handshakeOutcome: QUICHandshakeOutcome
        let failureReason: String?
        let alpn: String?
        let sniHash: String?
        let forwardingDecision: UDPForwardDecision?
        let consumeOriginalDatagram: Bool
        var flowID: UUID?
    }

    private struct NoProgressSnapshot {
        let budgetStartAt: Date?
        let establishedAt: Date?
        let lastProgressAt: Date?
        let clientDatagramsSeen: Int
        let processedStreams: Int
    }

    private struct HostFailOpenState {
        let reason: String
        let expiresAt: Date
    }

    private struct BootstrapPreparation {
        let flowKey: FlowKey
        let flowID: UUID
        let bootstrapToken: UUID
        let host: String
        let port: Int
        let tunnelPolicyRequired: Bool
    }

    private struct RetryBootstrapPreparation {
        let flowKey: FlowKey
        let flowID: UUID
        let bootstrapToken: UUID
        let authority: String
        let port: Int
        let authorityHash: String
        let attempt: Int
        let tunnelPolicyRequired: Bool
        let oldSession: QUICMitmSession
    }

    private let logSampler = LogSampler()
    private let stateQueue = DispatchQueue(label: "com.trace.vpn.quic_flow_router.state", qos: .utility)
    private let interceptor: (any InterceptionProviding)?
    private let http3ClientFactory: @Sendable () -> any HTTP3Client
    private let engineStatusProvider: @Sendable () -> QUICEngineStatus
    private let dualMITMPolicy: DualMITMPolicy
    private let dualMITMCircuitBreakerEnabled: Bool
    private let dualMITMPolicyEngine: DualMITMPolicyEngine?
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private let downstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)?
    private let upstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)?
    private let certificateMaterialProvider: QUICCertificateMaterialProvider
    private var flowStates: [FlowKey: FlowSessionState] = [:]
    private var routeDecisionLogSignaturesByFlowID: [UUID: String] = [:]
    private var hostFailOpenStates: [String: HostFailOpenState] = [:]
    private var lastCleanupAt = Date.distantPast

    private let cleanupInterval: TimeInterval = 30
    private let flowIdleTimeout: TimeInterval = 120
    private let retryBackoff: TimeInterval = 15
    private let hostFailOpenBackoff: TimeInterval
    private let maxRouteDecisionLogEntries = 4096
    private let maxHostFailOpenEntries = 2048
    private let maxQueuedIngestsPerFlow = 16
    private let maxBufferedDatagramsPerFlow = 64
    private let maxAuthorityRetryAttempts: Int
    private let sessionTickInterval: UInt64 = 25_000_000
    private let noProgressGracePeriod: TimeInterval
    private let noProgressIdleTimeout: TimeInterval
    private let noProgressAbsoluteTimeout: TimeInterval
    private let noProgressMinimumClientDatagrams: Int
    private let maxFailOpenReplayDatagrams = 32
    private let maxFailOpenReplayDatagramBytes = 4096

    init(
        interceptor: (any InterceptionProviding)? = nil,
        http3ClientFactory: @escaping @Sendable () -> any HTTP3Client = { URLSessionHTTP3Client() },
        engineStatusProvider: @escaping @Sendable () -> QUICEngineStatus = { QUICEngineRuntime.currentStatus() },
        hostFailOpenBackoff: TimeInterval = 1800,
        noProgressGracePeriod: TimeInterval = 6.0,
        noProgressIdleTimeout: TimeInterval = 6.0,
        noProgressAbsoluteTimeout: TimeInterval = 20.0,
        noProgressMinimumClientDatagrams: Int = 6,
        maxAuthorityRetryAttempts: Int = 1,
        certificateMaterialCacheTTL: TimeInterval = 1800,
        dualMITMPolicy: DualMITMPolicy = .adaptiveFailOpen,
        dualMITMCircuitBreakerEnabled: Bool = true,
        dualMITMPolicyEngine: DualMITMPolicyEngine? = nil,
        eventLogHandler: (@Sendable (String, String) -> Void)? = nil,
        downstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)? = nil,
        upstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)? = nil
    ) {
        self.interceptor = interceptor
        self.http3ClientFactory = http3ClientFactory
        self.engineStatusProvider = engineStatusProvider
        self.hostFailOpenBackoff = max(60, hostFailOpenBackoff)
        self.noProgressGracePeriod = max(0.5, noProgressGracePeriod)
        self.noProgressIdleTimeout = max(0.5, noProgressIdleTimeout)
        self.noProgressAbsoluteTimeout = max(2.0, noProgressAbsoluteTimeout)
        self.dualMITMPolicy = dualMITMPolicy
        self.dualMITMCircuitBreakerEnabled = dualMITMCircuitBreakerEnabled
        self.dualMITMPolicyEngine = dualMITMPolicyEngine
        self.eventLogHandler = eventLogHandler
        self.downstreamDatagramSink = downstreamDatagramSink
        self.upstreamDatagramSink = upstreamDatagramSink
        self.noProgressMinimumClientDatagrams = max(1, min(8, noProgressMinimumClientDatagrams))
        self.maxAuthorityRetryAttempts = max(0, min(2, maxAuthorityRetryAttempts))
        self.certificateMaterialProvider = QUICCertificateMaterialProvider(
            ttl: max(60, certificateMaterialCacheTTL),
            materialGenerator: { authority in
                QUICFlowRouter.makeCertificateMaterial(
                    for: authority,
                    eventLogHandler: eventLogHandler
                )
            }
        )
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
            udpForwarderAvailable: udpForwarderAvailable,
            tunnelPolicyRequired: tunnelPolicyRequired,
            tunnelUDPSupported: tunnelUDPSupported,
            forwardingDecision: forwardingDecision
        )
        let effectiveForwardingDecision = evaluation.forwardingDecision ?? forwardingDecision
        let metadata = makeFlowMetadata(
            udpPacket: udpPacket,
            handshakeOutcome: evaluation.handshakeOutcome,
            failureReason: evaluation.failureReason,
            alpn: evaluation.alpn,
            sniHash: evaluation.sniHash
        )
        let flowIDLabel = evaluation.flowID?.uuidString ?? "unknown"
        let routeDecision = switch evaluation.inspectionOutcome {
        case .intercepted:
            "intercept"
        case .passThroughMarked:
            "pass_through"
        case .blocked:
            "block"
        case .tunnelForwarded:
            "tunnel_forwarded"
        }
        let fallbackApplied = evaluation.inspectionOutcome == .passThroughMarked
        let bypassReason = evaluation.failureReason ?? "none"
        let upstreamHash = LogRedaction.hash(ipPacket.destination.description)
        let policy = dualMITMPolicy.rawValue
        let forwardingLabel = String(describing: effectiveForwardingDecision)
        let outcomeLabel = evaluation.inspectionOutcome.rawValue
        let routeLogSignature = "\(outcomeLabel):\(bypassReason):\(forwardingLabel):\(evaluation.sniHash ?? "unknown"):\(policy)"

        if evaluation.inspectionOutcome == .passThroughMarked,
           let reason = evaluation.failureReason,
           logSampler.shouldLog(event: "vpn.quic_intercept_fallback", key: reason, first: 5, every: 250) {
            VPNLog.tunnel.info(
                "event=vpn.quic_intercept_fallback flow_id=\(flowIDLabel, privacy: .public) outcome=pass_through reason=\(reason, privacy: .public) forward=\(forwardingLabel, privacy: .public) sni_hash=\(evaluation.sniHash ?? "unknown", privacy: .public) upstream_hash=\(upstreamHash, privacy: .public) route_decision=\(routeDecision, privacy: .public) fallback_applied=\(fallbackApplied) bypass_reason=\(bypassReason, privacy: .public) policy=\(policy, privacy: .public)"
            )
        }
        if shouldEmitRouteDecisionEvent(flowID: evaluation.flowID, signature: routeLogSignature) {
            if evaluation.inspectionOutcome == .passThroughMarked, let reason = evaluation.failureReason {
                eventLogHandler?(
                    "quic_intercept",
                    "flow_id=\(flowIDLabel) outcome=pass_through reason=\(reason) forward=\(forwardingLabel) sni_hash=\(evaluation.sniHash ?? "unknown") upstream_hash=\(upstreamHash) route_decision=\(routeDecision) fallback_applied=\(fallbackApplied) bypass_reason=\(bypassReason) policy=\(policy)"
                )
            } else if evaluation.inspectionOutcome == .intercepted {
                eventLogHandler?(
                    "quic_intercept",
                    "flow_id=\(flowIDLabel) outcome=intercepted flow_sni_hash=\(evaluation.sniHash ?? "unknown") upstream_hash=\(upstreamHash) route_decision=\(routeDecision) fallback_applied=\(fallbackApplied) bypass_reason=\(bypassReason) policy=\(policy)"
                )
            } else if evaluation.inspectionOutcome == .blocked {
                eventLogHandler?(
                    "quic_intercept",
                    "flow_id=\(flowIDLabel) outcome=blocked reason=\(bypassReason) forward=\(forwardingLabel) sni_hash=\(evaluation.sniHash ?? "unknown") upstream_hash=\(upstreamHash) route_decision=\(routeDecision) fallback_applied=false bypass_reason=none policy=\(policy)"
                )
            }
        }

        return QUICRouteResult(
            forwardingDecision: effectiveForwardingDecision,
            inspectionOutcome: evaluation.inspectionOutcome,
            metadata: metadata,
            consumeOriginalDatagram: evaluation.consumeOriginalDatagram
        )
    }

    private func shouldEmitRouteDecisionEvent(flowID: UUID?, signature: String) -> Bool {
        guard let flowID else { return true }

        return stateQueue.sync {
            if routeDecisionLogSignaturesByFlowID[flowID] == signature {
                return false
            }
            routeDecisionLogSignaturesByFlowID[flowID] = signature
            trimRouteDecisionLogsLocked()

            if let flowKey = flowStates.first(where: { $0.value.flowID == flowID })?.key,
               var state = flowStates[flowKey] {
                state.lastRouteDecisionLogSignature = signature
                flowStates[flowKey] = state
            }
            return true
        }
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

    private func plannedInitialQUICDecision(
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

    private static func quicRouteDecisionValue(_ decision: DualMITMQUICRouteDecision) -> String {
        switch decision {
        case .mitm:
            "mitm"
        case .passThrough:
            "pass_through"
        case .block:
            "block"
        }
    }

    private static func quicRouteDecisionReason(_ decision: DualMITMQUICRouteDecision) -> String {
        switch decision {
        case .mitm:
            return "none"
        case let .passThrough(reason), let .block(reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "none" : trimmed
        }
    }

    private func failOpenForwardingDecision(
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

    private func shouldFailOpenForQUICFailure(
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
            failure: failure
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

    private static func quicRouteDecision(from action: DualMITMRouteAction) -> DualMITMQUICRouteDecision {
        switch action {
        case .mitm:
            .mitm
        case let .passThrough(reason), let .direct(reason):
            .passThrough(reason: reason)
        case let .block(reason):
            .block(reason: reason)
        }
    }

    private static func quicFailure(from reason: String) -> InterceptionFailure {
        let decoded = LegacyReasonCodec.decode(reason)
        if let failure = decoded.failure {
            return failure
        }
        return .internalError(code: .legacyUnknownToken, context: reason)
    }

    private func failureDecisionForFlow(
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

    private func launchBootstrapTask(
        flowKey: FlowKey,
        flowID: UUID,
        session: QUICMitmSession
    ) {
        Task { [weak self] in
            guard let self else { return }
            let establishResult = await session.establish()

            if establishResult.outcome == .intercepted {
                if self.dualMITMCircuitBreakerEnabled, self.dualMITMPolicy == .adaptiveFailOpen {
                    DualMITMCircuitBreaker.shared.recordQUICInterceptSample(failed: false)
                }
                self.stateQueue.sync {
                    guard var state = self.flowStates[flowKey], state.flowID == flowID else { return }
                    let now = Date()
                    state.isEstablishing = false
                    state.isEstablished = true
                    state.lastFailureReason = nil
                    state.lastFailureAt = nil
                    state.negotiatedALPN = "h3"
                    state.authorityRetryCount = 0
                    state.lastAuthorityRetry = nil
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

    private func launchBootstrapPreparationTask(_ preparation: BootstrapPreparation) {
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

    private func launchRetryBootstrapPreparationTask(_ retry: RetryBootstrapPreparation) {
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

    private func scheduleAuthorityRetry(
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
            state.pendingDatagrams.removeAll(keepingCapacity: false)
            if let replayDatagram, !replayDatagram.isEmpty, state.pendingDatagrams.count < maxBufferedDatagramsPerFlow {
                recordRecentClientDatagramLocked(replayDatagram, state: &state)
                state.pendingDatagrams.append(QueuedDatagram(payload: replayDatagram, fromClient: true))
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

    private func handleSessionResult(
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

    private func updateNoProgressSnapshot(
        flowKey: FlowKey,
        flowID: UUID,
        fromClient: Bool,
        ingestResult: QUICMitmIngestResult,
        now: Date
    ) -> NoProgressSnapshot? {
        stateQueue.sync {
            guard var state = flowStates[flowKey], state.flowID == flowID else {
                return nil
            }

            if fromClient {
                state.clientDatagramsSeen += 1
            }

            if ingestResult.processedStreams > 0 {
                state.processedStreamCount += ingestResult.processedStreams
            }

            if ingestResult.processedStreams > 0 ||
                !ingestResult.datagramsToClient.isEmpty ||
                !ingestResult.datagramsToUpstream.isEmpty {
                state.lastProgressAt = now
            }

            flowStates[flowKey] = state
            return NoProgressSnapshot(
                budgetStartAt: state.noProgressBudgetStartAt,
                establishedAt: state.establishedAt,
                lastProgressAt: state.lastProgressAt,
                clientDatagramsSeen: state.clientDatagramsSeen,
                processedStreams: state.processedStreamCount
            )
        }
    }

    private func shouldFailOpenForNoProgress(
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

    private func closeFlowGracefully(
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

    private func forwardOriginalDatagramIfNeeded(
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

    private func markFlowBlocked(
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

    private func markFlowFailed(
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
            if dualMITMCircuitBreakerEnabled, dualMITMPolicy == .adaptiveFailOpen {
                DualMITMCircuitBreaker.shared.recordQUICInterceptSample(failed: true)
            }
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

    private func activeHostFailOpenReasonLocked(
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

    private func recordRecentClientDatagramLocked(_ payload: Data, state: inout FlowSessionState) {
        guard !payload.isEmpty else { return }
        guard payload.count <= maxFailOpenReplayDatagramBytes else { return }

        state.recentClientDatagrams.append(payload)
        let overflow = state.recentClientDatagrams.count - maxFailOpenReplayDatagrams
        if overflow > 0 {
            state.recentClientDatagrams.removeFirst(overflow)
        }
    }

    private func replayRecentClientDatagramsIfNeeded(
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

    private func markHostFailOpenLocked(
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

    private func pruneHostFailOpenLocked(now: Date) {
        guard !hostFailOpenStates.isEmpty else { return }
        hostFailOpenStates = hostFailOpenStates.filter { _, state in
            state.expiresAt > now
        }
    }

    private func trimHostFailOpenLocked(now: Date) {
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

    private func pruneRouteDecisionLogsLocked() {
        guard !routeDecisionLogSignaturesByFlowID.isEmpty else { return }

        let activeFlowIDs = Set(flowStates.values.map(\.flowID))
        routeDecisionLogSignaturesByFlowID = routeDecisionLogSignaturesByFlowID.filter { flowID, _ in
            activeFlowIDs.contains(flowID)
        }

        trimRouteDecisionLogsLocked()
    }

    private func trimRouteDecisionLogsLocked() {
        let overflow = routeDecisionLogSignaturesByFlowID.count - maxRouteDecisionLogEntries
        guard overflow > 0 else { return }

        // Dictionary order is undefined; trimming an arbitrary overflow set is sufficient.
        let keysToDrop = Array(routeDecisionLogSignaturesByFlowID.keys.prefix(overflow))
        for key in keysToDrop {
            routeDecisionLogSignaturesByFlowID.removeValue(forKey: key)
        }
    }

    private static func isIPAddressLiteral(_ host: String) -> Bool {
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
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized == "handshakefailed" ||
            normalized == "certificatepinning" ||
            normalized == "quic_retry_with_authority_failed" {
            return true
        }

        return normalized.hasPrefix("quic_closed_before_http3_")
    }

    static func prefersDirectFailOpenForwarding(for reason: String) -> Bool {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized == "quic_no_progress_fail_open" ||
            normalized == "quic_tunnel_required_unavailable" ||
            normalized == "quic_retry_with_authority_failed" ||
            normalized == "dual_mitm_circuit_breaker" ||
            normalized == "handshakefailed" ||
            normalized == "certificatepinning" {
            return true
        }

        return normalized.hasPrefix("quic_closed_before_http3_")
    }

    private func failureReason(from reason: QUICMitmFailureReason?) -> String {
        reason?.rawValue ?? "quic_mitm_failed_open"
    }

    private func ingestFailureReason(for error: Error) -> String {
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

    private func isGracefulSessionClosure(_ error: Error) -> Bool {
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

    private func gracefulSessionClosureReason(for error: Error) -> String {
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

    func makeCertificateMaterial(for authority: String) -> QUICMitmCertificateMaterial? {
        Self.makeCertificateMaterial(
            for: authority,
            eventLogHandler: eventLogHandler
        )
    }

    private static func makeCertificateMaterial(
        for authority: String,
        eventLogHandler: (@Sendable (String, String) -> Void)?
    ) -> QUICMitmCertificateMaterial? {
        let normalized = normalizeAuthority(authority)
        guard shouldIssueCertificate(for: normalized) else {
            eventLogHandler?(
                "quic_cert_material",
                "outcome=skipped reason=empty_or_invalid_authority"
            )
            return nil
        }

        let authorityHash = LogRedaction.hash(normalized)
        if let preflightDetail = TLSHandler.preflightServerLeafTrust(for: normalized) {
            // Best-effort note only: QUIC MITM still attempts cert material generation even
            // when preflight warns, to avoid premature fail-open for non-pinned flows.
            eventLogHandler?(
                "quic_cert_material",
                "outcome=preflight_warning authority_hash=\(authorityHash) detail=\(preflightDetail)"
            )
        }

        do {
            let (certificate, privateKey) = try CertificateManager.shared.generateCertificateForDomain(normalized)
            let certificateDER = SecCertificateCopyData(certificate) as Data
            var keyError: Unmanaged<CFError>?
            guard let privateKeyDER = SecKeyCopyExternalRepresentation(privateKey, &keyError) as Data? else {
                let detail = keyError?.takeRetainedValue().localizedDescription ?? "unknown"
                eventLogHandler?(
                    "quic_cert_material",
                    "outcome=failure authority_hash=\(authorityHash) reason=private_key_export_failed detail=\(detail)"
                )
                return nil
            }
            eventLogHandler?(
                "quic_cert_material",
                "outcome=ready authority_hash=\(authorityHash) cert_bytes=\(certificateDER.count) key_bytes=\(privateKeyDER.count)"
            )
            return QUICMitmCertificateMaterial(
                leafCertificateDER: certificateDER,
                privateKeyDER: privateKeyDER
            )
        } catch {
            eventLogHandler?(
                "quic_cert_material",
                "outcome=failure authority_hash=\(authorityHash) reason=certificate_generate_failed detail=\(error.localizedDescription)"
            )
            return nil
        }
    }

    func shouldIssueCertificate(for authority: String) -> Bool {
        Self.shouldIssueCertificate(for: authority)
    }

    private static func shouldIssueCertificate(for authority: String) -> Bool {
        guard !authority.isEmpty else { return false }
        return !authority.contains(where: \.isWhitespace)
    }

    func normalizeAuthority(_ authority: String) -> String {
        Self.normalizeAuthority(authority)
    }

    private static func normalizeAuthority(_ authority: String) -> String {
        var normalized = authority.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "" }

        if normalized.hasPrefix("["),
           normalized.hasSuffix("]"),
           normalized.count > 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }

        if normalized.hasSuffix("."),
           normalized.count > 1 {
            normalized.removeLast()
        }

        if let scopeIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<scopeIndex])
        }

        if let hostOnly = splitHostAndPortIfNeeded(normalized) {
            normalized = hostOnly
        }

        return normalized
    }

    func splitHostAndPortIfNeeded(_ authority: String) -> String? {
        Self.splitHostAndPortIfNeeded(authority)
    }

    private static func splitHostAndPortIfNeeded(_ authority: String) -> String? {
        guard let colonIndex = authority.lastIndex(of: ":") else { return nil }
        let hostCandidate = String(authority[..<colonIndex])
        let portCandidate = String(authority[authority.index(after: colonIndex)...])
        guard !hostCandidate.isEmpty, !portCandidate.isEmpty else { return nil }
        guard !hostCandidate.contains(":") else { return nil }
        guard UInt16(portCandidate) != nil else { return nil }
        return hostCandidate
    }
}
