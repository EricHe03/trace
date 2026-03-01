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
    struct FlowKey: Hashable {
        let sourceIP: IPAddress
        let sourcePort: UInt16
        let destinationIP: IPAddress
        let destinationPort: UInt16
    }

    struct ParsedHeaderMetadata {
        let version: String?
        let sourceConnectionIDLength: Int?
        let destinationConnectionIDLength: Int?
    }

    struct QueuedDatagram {
        let payload: Data
        let fromClient: Bool
    }

    struct FlowSessionState {
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

    struct RouteEvaluation {
        let inspectionOutcome: QUICInspectionOutcome
        let handshakeOutcome: QUICHandshakeOutcome
        let failureReason: String?
        let alpn: String?
        let sniHash: String?
        let forwardingDecision: UDPForwardDecision?
        let consumeOriginalDatagram: Bool
        var flowID: UUID?
    }

    struct NoProgressSnapshot {
        let budgetStartAt: Date?
        let establishedAt: Date?
        let lastProgressAt: Date?
        let clientDatagramsSeen: Int
        let processedStreams: Int
    }

    struct HostFailOpenState {
        let reason: String
        let expiresAt: Date
    }

    struct BootstrapPreparation {
        let flowKey: FlowKey
        let flowID: UUID
        let bootstrapToken: UUID
        let host: String
        let port: Int
        let tunnelPolicyRequired: Bool
    }

    struct RetryBootstrapPreparation {
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

    let logSampler = LogSampler()
    let stateQueue = DispatchQueue(label: "com.trace.vpn.quic_flow_router.state", qos: .utility)
    let interceptor: (any InterceptionProviding)?
    let http3ClientFactory: @Sendable () -> any HTTP3Client
    let engineStatusProvider: @Sendable () -> QUICEngineStatus
    let dualMITMPolicy: DualMITMPolicy
    let dualMITMCircuitBreakerEnabled: Bool
    let dualMITMPolicyEngine: DualMITMPolicyEngine?
    let eventLogHandler: (@Sendable (String, String) -> Void)?
    let downstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)?
    let upstreamDatagramSink: (@Sendable (Data, QUICFlowDatagramContext) -> Void)?
    let certificateMaterialProvider: QUICCertificateMaterialProvider
    var flowStates: [FlowKey: FlowSessionState] = [:]
    var routeDecisionLogSignaturesByFlowID: [UUID: String] = [:]
    var hostFailOpenStates: [String: HostFailOpenState] = [:]
    var lastCleanupAt = Date.distantPast

    let cleanupInterval: TimeInterval = 30
    let flowIdleTimeout: TimeInterval = 120
    let retryBackoff: TimeInterval = 15
    let hostFailOpenBackoff: TimeInterval
    let maxRouteDecisionLogEntries = 4096
    let maxHostFailOpenEntries = 2048
    let maxQueuedIngestsPerFlow = 16
    let maxBufferedDatagramsPerFlow = 64
    let maxAuthorityRetryAttempts: Int
    let sessionTickInterval: UInt64 = 25_000_000
    let noProgressGracePeriod: TimeInterval
    let noProgressIdleTimeout: TimeInterval
    let noProgressAbsoluteTimeout: TimeInterval
    let noProgressMinimumClientDatagrams: Int
    let maxFailOpenReplayDatagrams = 32
    let maxFailOpenReplayDatagramBytes = 4096

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

    func makeCertificateMaterial(for authority: String) -> QUICMitmCertificateMaterial? {
        Self.makeCertificateMaterial(
            for: authority,
            eventLogHandler: eventLogHandler
        )
    }

    static func makeCertificateMaterial(
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

    static func shouldIssueCertificate(for authority: String) -> Bool {
        guard !authority.isEmpty else { return false }
        return !authority.contains(where: \.isWhitespace)
    }

    func normalizeAuthority(_ authority: String) -> String {
        Self.normalizeAuthority(authority)
    }

    static func normalizeAuthority(_ authority: String) -> String {
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

    static func splitHostAndPortIfNeeded(_ authority: String) -> String? {
        guard let colonIndex = authority.lastIndex(of: ":") else { return nil }
        let hostCandidate = String(authority[..<colonIndex])
        let portCandidate = String(authority[authority.index(after: colonIndex)...])
        guard !hostCandidate.isEmpty, !portCandidate.isEmpty else { return nil }
        guard !hostCandidate.contains(":") else { return nil }
        guard UInt16(portCandidate) != nil else { return nil }
        return hostCandidate
    }
}
