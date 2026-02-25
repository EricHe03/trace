//
//  PacketFlowLoop.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/19.
//

import Darwin
import Foundation
import NetworkExtension
import OSLog
import TraceCore
import TraceNetworking
import TracePacket
import TraceProxy
import TraceQUIC

final class PacketCapturePipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.trace.vpn.packet_capture", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let pendingLock = NSLock()
    private let maxPending: Int
    private let logSampler = LogSampler()
    private let reassembler = TCPReassembler()
    private let flowRecorder = PacketFlowRecorder()
    private let transportRequestRecorder = TransportRequestRecorder()
    private let udpFlowManager = UDPFlowManager()
    private var pendingCount = 0
    private var isStopped = false

    private var enabled = false
    private var limit: UInt64 = 0
    private var bytes: UInt64 = 0
    private var writer: PCAPWriting?

    init(maxPending: Int) {
        self.maxPending = max(1, maxPending)
        queue.setSpecific(key: queueKey, value: ())
    }

    func configure(enabled: Bool, limit: UInt64, writer: PCAPWriting?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let stopped = self.isStopped
            self.pendingLock.unlock()
            guard !stopped else {
                writer?.close()
                return
            }

            if let current = self.writer, let next = writer {
                if current !== next {
                    current.close()
                }
            } else if writer == nil {
                self.writer?.close()
            }
            self.enabled = enabled
            self.limit = limit
            self.writer = writer
            self.bytes = writer?.currentFileSize() ?? 0
            if enabled, writer != nil {
                VPNLog.tunnel.info("event=vpn.packet_capture_config outcome=success enabled=true limit=\(limit)")
            } else {
                VPNLog.tunnel.info("event=vpn.packet_capture_config outcome=success enabled=false")
            }
        }
    }

    func updateLimit(_ limit: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let stopped = self.isStopped
            self.pendingLock.unlock()
            guard !stopped else { return }
            self.limit = limit
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
            return
        }

        pendingLock.lock()
        isStopped = true
        pendingLock.unlock()

        queue.sync { [weak self] in
            self?.stopOnQueue()
        }
    }

    func enqueue(packet: Data) -> Bool {
        enqueue(packets: [packet]) == 1
    }

    @discardableResult
    func enqueue(packets: [Data]) -> Int {
        guard !packets.isEmpty else { return 0 }

        let acceptedPackets: [Data]
        let droppedCount: Int
        pendingLock.lock()
        if isStopped {
            pendingLock.unlock()
            return 0
        }
        let available = max(0, maxPending - pendingCount)
        let acceptedCount = min(available, packets.count)
        if acceptedCount > 0 {
            pendingCount += acceptedCount
            acceptedPackets = Array(packets.prefix(acceptedCount))
        } else {
            acceptedPackets = []
        }
        droppedCount = packets.count - acceptedCount
        pendingLock.unlock()

        if droppedCount > 0 {
            if logSampler.shouldLog(event: "vpn.packet_capture_drop", key: "pending_full", first: 5, every: 200) {
                VPNLog.tunnel.warning("event=vpn.packet_capture_drop outcome=skipped reason=pending_full count=\(droppedCount)")
            }
        }

        guard !acceptedPackets.isEmpty else {
            return 0
        }

        queue.async { [weak self] in
            defer {
                self?.pendingLock.lock()
                self?.pendingCount = max(0, (self?.pendingCount ?? acceptedCount) - acceptedCount)
                self?.pendingLock.unlock()
            }

            guard let self else { return }
            if self.enabled, let writer = self.writer {
                let packetsToWrite: [Data]
                if self.limit > 0, !writer.supportsRolling {
                    var limitedPackets: [Data] = []
                    limitedPackets.reserveCapacity(acceptedPackets.count)
                    for packet in acceptedPackets {
                        let projected = self.bytes + UInt64(packet.count)
                        if projected > self.limit {
                            self.enabled = false
                            VPNLog.tunnel.warning("event=vpn.packet_capture_limit_reached outcome=disabled limit=\(self.limit) current=\(self.bytes)")
                            break
                        }
                        self.bytes = projected
                        limitedPackets.append(packet)
                    }
                    packetsToWrite = limitedPackets
                } else {
                    packetsToWrite = acceptedPackets
                }

                if !packetsToWrite.isEmpty {
                    writer.writePackets(packetsToWrite)
                }
            }

            for packet in acceptedPackets {
                self.processParsedPacket(packet: packet)
            }
        }

        return acceptedCount
    }

    func recordQUICInspection(
        ipPacket: IPPacket,
        udpPacket: UDPPacket,
        outcome: QUICInspectionOutcome,
        metadata: QUICFlowMetadata
    ) {
        udpFlowManager.recordQUICInspection(
            ipPacket: ipPacket,
            udpPacket: udpPacket,
            outcome: outcome,
            metadata: metadata
        )
    }

    private func processParsedPacket(packet: Data) {
        guard let ipPacket = IPPacketParser.parse(packet) else { return }
        transportRequestRecorder.process(ipPacket: ipPacket)
        flowRecorder.process(ipPacket: ipPacket)

        if ipPacket.transport == .udp, let udpPacket = UDPParser.parse(ipPacket.payload) {
            udpFlowManager.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        }

        guard ipPacket.transport == .tcp else { return }
        guard let tcpPacket = TCPParser.parse(ipPacket.payload) else { return }

        let outputs = reassembler.process(ipPacket: ipPacket, tcpPacket: tcpPacket)
        for output in outputs {
            flowRecorder.processReassembled(flow: output.flow, data: output.data, isFinal: output.isFinal)
            if !output.data.isEmpty,
               logSampler.shouldLog(event: "vpn.stream_reassembly", key: output.flow.description, first: 3, every: 200) {
                VPNLog.tunnel.debug(
                    "event=vpn.stream_reassembly outcome=success flow=\(output.flow.description, privacy: .private(mask: .hash)) bytes=\(output.data.count) final=\(output.isFinal)"
                )
            }
        }
    }

    private func stopOnQueue() {
        pendingLock.lock()
        isStopped = true
        pendingCount = 0
        pendingLock.unlock()

        enabled = false
        transportRequestRecorder.shutdown()
        flowRecorder.shutdown()
        udpFlowManager.shutdown()
        writer?.close()
        writer = nil
    }
}

protocol PacketForwardingEngine: AnyObject {
    func start()
    func stop()
    func enqueue(packets: [Data], protocols: [NSNumber])
}

final class PacketFlowLoop: @unchecked Sendable {
    typealias UDPForwardDecision = TraceCore.UDPForwardDecision

    private struct QUICBlockFlowKey: Hashable {
        let sourceIP: TracePacket.IPAddress
        let sourcePort: UInt16
        let destinationIP: TracePacket.IPAddress
        let destinationPort: UInt16
    }

    private struct QUICAuthorityHint {
        let authority: String
        let expiresAt: Date
    }

    private struct DualMITMHealthSnapshot {
        let enabled: Bool
        let policy: DualMITMPolicy
        let degraded: Bool
        let degradedUntil: Date?
        let degradeReason: String?
        let tcpAttempts: Int
        let tcpFailures: Int
        let tcpFailureRate: Double
        let quicAttempts: Int
        let quicFailures: Int
        let quicFailureRate: Double
    }

    private struct QUICMetricBatch {
        var flowSeen: UInt64 = 0
        var blocked: UInt64 = 0
        var tunnelForwarded: UInt64 = 0
        var policyPassThrough: UInt64 = 0

        var hasUpdates: Bool {
            flowSeen > 0 || blocked > 0 || tunnelForwarded > 0 || policyPassThrough > 0
        }
    }

    private static let quicICMPRateLimitNanos: UInt64 = 1_000_000_000
    private static let quicICMPStateCleanupIntervalNanos: UInt64 = 30_000_000_000
    private static let quicICMPStateExpireNanos: UInt64 = 120_000_000_000
    private static let quicICMPStateMaxEntries: Int = 2048
    private static let quicAuthorityHintMaxEntries: Int = 4096
    private static let quicAuthorityHintMinTTL: TimeInterval = 30
    private static let quicAuthorityHintMaxTTL: TimeInterval = 900
    private static let quicObservedFlowMaxEntries: Int = 8192
    private static let maxSynthesizedUDPPayloadIPv4 = 65507
    private static let maxSynthesizedUDPPayloadIPv6 = 65527

    static func decideUDPForwarding(
        udpForwarderAvailable: Bool,
        mode: UDPForwardingMode,
        sourcePort: UInt16,
        destinationPort: UInt16,
        quicHandlingMode: QUICHandlingMode,
        tunnelUDPSupported: Bool
    ) -> (decision: UDPForwardDecision, isQUIC: Bool) {
        TraceCore.decideUDPForwarding(
            udpForwarderAvailable: udpForwarderAvailable,
            mode: mode,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            quicHandlingMode: quicHandlingMode,
            tunnelUDPSupported: tunnelUDPSupported
        )
    }

    private let packetFlow: NEPacketTunnelFlow
    private let capturePipeline: PacketCapturePipeline
    private weak var forwarder: PacketForwardingEngine?
    private weak var udpForwarder: UDPForwarder?
    private lazy var quicFlowRouter: QUICFlowRouter = makeQUICFlowRouter()
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private let initialQUICInterceptor: (any InterceptionProviding)?
    private let udpForwardingMode: UDPForwardingMode
    private var quicHandlingMode: QUICHandlingMode
    private var tunnelUDPSupported = true
    private let queue = DispatchQueue(label: "com.trace.vpn.packet_flow_loop", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var isRunning = false
    private var isStopping = false
    private var hasPendingRead = false
    private let logSampler = LogSampler()
    private var udpForwardedPackets: UInt64 = 0
    private var udpForwardedPackets443: UInt64 = 0
    private var quicBlockedPackets: UInt64 = 0
    private var quicInterceptCandidates: UInt64 = 0
    private var quicPassThroughMarked: UInt64 = 0
    private var quicBlockedICMPSent: UInt64 = 0
    private var quicBlockedICMPRateLimited: UInt64 = 0
    private var quicBlockFlowLastICMPSent: [QUICBlockFlowKey: UInt64] = [:]
    private var quicBlockLastCleanup: UInt64 = 0
    private var udpSyntheticPacketIdentifier: UInt16 = 0
    private var icmpPacketIdentifier: UInt16 = 0
    private var quicAuthorityHintsByIP: [String: QUICAuthorityHint] = [:]
    private var observedQUICFlows: Set<String> = []
    private let dualMITMPolicy: DualMITMPolicy
    private let quicHostFailOpenSeconds: Int
    private let dualMITMCircuitBreakerEnabled: Bool
    private let quicNoProgressGraceMs: Int
    private let quicNoProgressIdleMs: Int
    private let quicNoProgressAbsoluteMs: Int
    private let quicNoProgressMinClientDatagrams: Int
    private let quicAuthorityRetryAttempts: Int
    private let quicCertMaterialCacheTTLSeconds: Int
    private let dualMITMPolicyEngine: DualMITMPolicyEngine?
    private var lastDualMITMDegradedState = false

    init(
        packetFlow: NEPacketTunnelFlow,
        capturePipeline: PacketCapturePipeline,
        forwarder: PacketForwardingEngine?,
        udpForwarder: UDPForwarder?,
        udpForwardingMode: UDPForwardingMode,
        quicHandlingMode: QUICHandlingMode,
        dualMITMPolicy: DualMITMPolicy = .adaptiveFailOpen,
        quicHostFailOpenSeconds: Int = 1800,
        dualMITMCircuitBreakerEnabled: Bool = true,
        quicNoProgressGraceMs: Int = 2500,
        quicNoProgressIdleMs: Int = 2500,
        quicNoProgressAbsoluteMs: Int = 9000,
        quicNoProgressMinClientDatagrams: Int = 2,
        quicAuthorityRetryAttempts: Int = 1,
        quicCertMaterialCacheTTLSeconds: Int = 1800,
        dualMITMPolicyEngine: DualMITMPolicyEngine? = nil,
        quicInterceptor: (any InterceptionProviding)? = nil,
        eventLogHandler: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.packetFlow = packetFlow
        self.capturePipeline = capturePipeline
        self.forwarder = forwarder
        self.udpForwarder = udpForwarder
        self.udpForwardingMode = udpForwardingMode
        self.quicHandlingMode = quicHandlingMode
        self.dualMITMPolicy = dualMITMPolicy
        self.quicHostFailOpenSeconds = quicHostFailOpenSeconds
        self.dualMITMCircuitBreakerEnabled = dualMITMCircuitBreakerEnabled
        self.quicNoProgressGraceMs = quicNoProgressGraceMs
        self.quicNoProgressIdleMs = quicNoProgressIdleMs
        self.quicNoProgressAbsoluteMs = quicNoProgressAbsoluteMs
        self.quicNoProgressMinClientDatagrams = quicNoProgressMinClientDatagrams
        self.quicAuthorityRetryAttempts = quicAuthorityRetryAttempts
        self.quicCertMaterialCacheTTLSeconds = quicCertMaterialCacheTTLSeconds
        self.dualMITMPolicyEngine = dualMITMPolicyEngine
        self.initialQUICInterceptor = quicInterceptor
        self.eventLogHandler = eventLogHandler
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else { return }
            self.isRunning = true
            self.isStopping = false
            VPNLog.tunnel.info("event=vpn.packet_loop_start outcome=success")
            self.scheduleRead()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            isStopping = true
            logUDPForwardSummary(reason: "stop")
            return
        }

        queue.sync { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.logUDPForwardSummary(reason: "stop")
        }
    }

    func updateBlockQUICEnabled(_ enabled: Bool) {
        updateQUICHandlingMode(enabled ? .block : .passThrough)
    }

    func updateQUICHandlingMode(_ mode: QUICHandlingMode) {
        queue.async { [weak self] in
            self?.quicHandlingMode = mode
        }
    }

    func updateUDPTunnelSupported(_ supported: Bool) {
        queue.async { [weak self] in
            self?.tunnelUDPSupported = supported
        }
    }

    /// Returns true when an inbound packet from upstream was consumed by the
    /// QUIC intercept engine and should not be written directly to the app.
    func consumeInboundQUICPacketIfIntercepted(_ packet: Data) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return consumeInboundQUICPacketIfInterceptedOnQueue(packet)
        }

        return queue.sync { [weak self] in
            guard let self else { return false }
            return consumeInboundQUICPacketIfInterceptedOnQueue(packet)
        }
    }

    private func makeQUICFlowRouter() -> QUICFlowRouter {
        QUICFlowRouter(
            interceptor: initialQUICInterceptor,
            hostFailOpenBackoff: TimeInterval(max(180, quicHostFailOpenSeconds)),
            noProgressGracePeriod: TimeInterval(quicNoProgressGraceMs) / 1000,
            noProgressIdleTimeout: TimeInterval(quicNoProgressIdleMs) / 1000,
            noProgressAbsoluteTimeout: TimeInterval(quicNoProgressAbsoluteMs) / 1000,
            noProgressMinimumClientDatagrams: quicNoProgressMinClientDatagrams,
            maxAuthorityRetryAttempts: quicAuthorityRetryAttempts,
            certificateMaterialCacheTTL: TimeInterval(quicCertMaterialCacheTTLSeconds),
            dualMITMPolicy: dualMITMPolicy,
            dualMITMCircuitBreakerEnabled: dualMITMCircuitBreakerEnabled,
            dualMITMPolicyEngine: dualMITMPolicyEngine,
            eventLogHandler: eventLogHandler,
            downstreamDatagramSink: { [weak self] payload, context in
                self?.queue.async {
                    self?.handleInterceptedQUICDatagramToClient(payload, context: context)
                }
            },
            upstreamDatagramSink: { [weak self] payload, context in
                self?.queue.async {
                    self?.handleInterceptedQUICDatagramToUpstream(payload, context: context)
                }
            }
        )
    }

    private func requiresTunnelForQUICInterception() -> Bool {
        switch udpForwardingMode {
        case .hevOnly, .split:
            true
        case .direct:
            false
        }
    }

    @discardableResult
    private func maybeRecordQUICFlowSeen(ipPacket: IPPacket, udpPacket: UDPPacket) -> Bool {
        let endpointA = "\(ipPacket.source.description):\(udpPacket.sourcePort)"
        let endpointB = "\(ipPacket.destination.description):\(udpPacket.destinationPort)"
        let key = endpointA <= endpointB ? "\(endpointA)|\(endpointB)" : "\(endpointB)|\(endpointA)"
        let inserted = observedQUICFlows.insert(key).inserted
        if observedQUICFlows.count > Self.quicObservedFlowMaxEntries {
            observedQUICFlows.removeAll(keepingCapacity: true)
            _ = observedQUICFlows.insert(key)
        }
        return inserted
    }

    private func submitQUICMetricBatchIfNeeded(_ batch: QUICMetricBatch) {
        guard batch.hasUpdates else { return }
        Task {
            await QUICConnectionManager.shared.recordBatch(
                flowSeen: batch.flowSeen,
                blocked: batch.blocked,
                tunnelForwarded: batch.tunnelForwarded,
                policyPassThrough: batch.policyPassThrough
            )
        }
    }

    private func scheduleRead() {
        queue.async { [weak self] in
            self?.readOnce()
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func readOnce() {
        guard !isStopping else {
            isRunning = false
            VPNLog.tunnel.info("event=vpn.packet_loop_stop outcome=success")
            return
        }

        guard !hasPendingRead else { return }
        hasPendingRead = true
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                self.hasPendingRead = false
                guard !self.isStopping else {
                    self.isRunning = false
                    return
                }

                if packets.isEmpty {
                    self.scheduleRead()
                    return
                }

                _ = self.capturePipeline.enqueue(packets: packets)
                var quicMetricBatch = QUICMetricBatch()

                if let udpForwarder = self.udpForwarder {
                    let udpForwarderAvailable = udpForwarder.isAvailable()
                    var forwardPackets: [Data] = []
                    var forwardProtocols: [NSNumber] = []

                    for (index, packet) in packets.enumerated() {
                        if let ipPacket = IPPacketParser.parse(packet), ipPacket.transport == .udp,
                           let udpPacket = UDPParser.parse(ipPacket.payload) {
                            self.recordQUICAuthorityHintIfNeeded(
                                ipPacket: ipPacket,
                                udpPacket: udpPacket
                            )
                            let decision = Self.decideUDPForwarding(
                                udpForwarderAvailable: udpForwarderAvailable,
                                mode: self.udpForwardingMode,
                                sourcePort: udpPacket.sourcePort,
                                destinationPort: udpPacket.destinationPort,
                                quicHandlingMode: self.quicHandlingMode,
                                tunnelUDPSupported: self.tunnelUDPSupported
                            )
                            if decision.isQUIC,
                               self.maybeRecordQUICFlowSeen(ipPacket: ipPacket, udpPacket: udpPacket) {
                                quicMetricBatch.flowSeen &+= 1
                            }

                            if decision.decision == .dropQUIC {
                                if self.logSampler.shouldLog(event: "vpn.packet_forward", key: "quic_blocked", first: 3, every: 200) {
                                    VPNLog.tunnel.info("event=vpn.packet_forward outcome=skipped reason=quic_blocked")
                                }
                                self.quicBlockedPackets &+= 1
                                let reason = "quic_blocked_by_policy"
                                let metadata = self.quicFlowRouter.makeFlowMetadata(
                                    udpPacket: udpPacket,
                                    handshakeOutcome: .blocked,
                                    failureReason: reason
                                )
                                self.capturePipeline.recordQUICInspection(
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    outcome: .blocked,
                                    metadata: metadata
                                )
                                quicMetricBatch.blocked &+= 1
                                let proto = protocols.indices.contains(index) ? protocols[index] : nil
                                self.maybeInjectQUICBlockedICMP(
                                    originalPacket: packet,
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    proto: proto
                                )
                                continue
                            }

                            switch decision.decision {
                            case .forwardDirect:
                                if !self.tunnelUDPSupported,
                                   self.udpForwardingMode == .hevOnly || (self.udpForwardingMode == .split && decision.isQUIC),
                                   self.logSampler.shouldLog(event: "vpn.udp_forward_fallback", key: "direct", first: 3, every: 200) {
                                    VPNLog.tunnel.warning(
                                        "event=vpn.udp_forward_fallback outcome=success mode=\(self.udpForwardingMode.rawValue, privacy: .public) action=direct reason=tunnel_udp_unsupported"
                                    )
                                }
                                if decision.isQUIC, self.quicHandlingMode == .passThrough {
                                    let reason = "quic_policy_pass_through_direct"
                                    let metadata = self.quicFlowRouter.makeFlowMetadata(
                                        udpPacket: udpPacket,
                                        handshakeOutcome: .passThrough,
                                        failureReason: reason
                                    )
                                    self.capturePipeline.recordQUICInspection(
                                        ipPacket: ipPacket,
                                        udpPacket: udpPacket,
                                        outcome: .passThroughMarked,
                                        metadata: metadata
                                    )
                                    self.quicPassThroughMarked &+= 1
                                    quicMetricBatch.policyPassThrough &+= 1
                                }
                                udpForwarder.enqueue(packet: packet, ipPacket: ipPacket)
                            case .forwardTunnel:
                                forwardPackets.append(packet)
                                if protocols.indices.contains(index) {
                                    forwardProtocols.append(protocols[index])
                                }
                                self.udpForwardedPackets &+= 1
                                if decision.isQUIC {
                                    self.udpForwardedPackets443 &+= 1
                                    if self.quicHandlingMode == .passThrough {
                                        let reason = "quic_policy_pass_through_tunnel"
                                        let metadata = self.quicFlowRouter.makeFlowMetadata(
                                            udpPacket: udpPacket,
                                            handshakeOutcome: .passThrough,
                                            failureReason: reason
                                        )
                                        self.capturePipeline.recordQUICInspection(
                                            ipPacket: ipPacket,
                                            udpPacket: udpPacket,
                                            outcome: .tunnelForwarded,
                                            metadata: metadata
                                        )
                                        quicMetricBatch.tunnelForwarded &+= 1
                                    }
                                }
                            case .interceptQUIC:
                                self.quicInterceptCandidates &+= 1
                                let authorityHint = self.resolveQUICAuthorityHint(
                                    for: ipPacket.destination
                                )
                                let quicRoute = self.quicFlowRouter.resolveInterceptRoute(
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    udpForwarderAvailable: udpForwarderAvailable,
                                    tunnelUDPSupported: self.tunnelUDPSupported,
                                    tunnelPolicyRequired: self.requiresTunnelForQUICInterception(),
                                    authorityHint: authorityHint
                                )
                                self.capturePipeline.recordQUICInspection(
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    outcome: quicRoute.inspectionOutcome,
                                    metadata: quicRoute.metadata
                                )
                                if quicRoute.inspectionOutcome == .passThroughMarked {
                                    self.quicPassThroughMarked &+= 1
                                } else if quicRoute.inspectionOutcome == .blocked {
                                    quicMetricBatch.blocked &+= 1
                                } else if quicRoute.inspectionOutcome == .tunnelForwarded {
                                    quicMetricBatch.tunnelForwarded &+= 1
                                }
                                switch quicRoute.forwardingDecision {
                                case .forwardDirect:
                                    if quicRoute.consumeOriginalDatagram {
                                        continue
                                    }
                                    udpForwarder.enqueue(packet: packet, ipPacket: ipPacket)
                                case .forwardTunnel:
                                    if quicRoute.consumeOriginalDatagram {
                                        continue
                                    }
                                    forwardPackets.append(packet)
                                    if protocols.indices.contains(index) {
                                        forwardProtocols.append(protocols[index])
                                    }
                                    self.udpForwardedPackets &+= 1
                                    self.udpForwardedPackets443 &+= 1
                                case .dropQUIC:
                                    self.quicBlockedPackets &+= 1
                                case .interceptQUIC:
                                    break
                                }
                            case .dropQUIC:
                                break
                            }
                        } else {
                            forwardPackets.append(packet)
                            if protocols.indices.contains(index) {
                                forwardProtocols.append(protocols[index])
                            }
                        }
                    }

                    if let forwarder = self.forwarder, !forwardPackets.isEmpty {
                        forwarder.enqueue(packets: forwardPackets, protocols: forwardProtocols)
                    } else if self.forwarder == nil,
                              self.logSampler.shouldLog(event: "vpn.packet_forward", key: "disabled", first: 3, every: 200) {
                        VPNLog.tunnel.debug("event=vpn.packet_forward outcome=skipped reason=forwarder_disabled")
                    }
                } else if let forwarder = self.forwarder {
                    var forwardPackets: [Data] = []
                    var forwardProtocols: [NSNumber] = []
                    for (index, packet) in packets.enumerated() {
                        if let ipPacket = IPPacketParser.parse(packet), ipPacket.transport == .udp,
                           let udpPacket = UDPParser.parse(ipPacket.payload) {
                            self.recordQUICAuthorityHintIfNeeded(
                                ipPacket: ipPacket,
                                udpPacket: udpPacket
                            )
                            let decision = Self.decideUDPForwarding(
                                udpForwarderAvailable: false,
                                mode: self.udpForwardingMode,
                                sourcePort: udpPacket.sourcePort,
                                destinationPort: udpPacket.destinationPort,
                                quicHandlingMode: self.quicHandlingMode,
                                tunnelUDPSupported: self.tunnelUDPSupported
                            )
                            if decision.isQUIC,
                               self.maybeRecordQUICFlowSeen(ipPacket: ipPacket, udpPacket: udpPacket) {
                                quicMetricBatch.flowSeen &+= 1
                            }
                            if decision.decision == .dropQUIC {
                                if self.logSampler.shouldLog(event: "vpn.packet_forward", key: "quic_blocked", first: 3, every: 200) {
                                    VPNLog.tunnel.info("event=vpn.packet_forward outcome=skipped reason=quic_blocked")
                                }
                                self.quicBlockedPackets &+= 1
                                let reason = "quic_blocked_by_policy"
                                let metadata = self.quicFlowRouter.makeFlowMetadata(
                                    udpPacket: udpPacket,
                                    handshakeOutcome: .blocked,
                                    failureReason: reason
                                )
                                self.capturePipeline.recordQUICInspection(
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    outcome: .blocked,
                                    metadata: metadata
                                )
                                quicMetricBatch.blocked &+= 1
                                let proto = protocols.indices.contains(index) ? protocols[index] : nil
                                self.maybeInjectQUICBlockedICMP(
                                    originalPacket: packet,
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    proto: proto
                                )
                                continue
                            }
                            self.udpForwardedPackets &+= 1
                            switch decision.decision {
                            case .forwardDirect, .forwardTunnel:
                                if decision.isQUIC {
                                    self.udpForwardedPackets443 &+= 1
                                    if self.quicHandlingMode == .passThrough {
                                        let outcome: QUICInspectionOutcome =
                                            decision.decision == .forwardTunnel ? .tunnelForwarded : .passThroughMarked
                                        let reason: String =
                                            decision.decision == .forwardTunnel ? "quic_policy_pass_through_tunnel" : "quic_policy_pass_through_direct"
                                        let metadata = self.quicFlowRouter.makeFlowMetadata(
                                            udpPacket: udpPacket,
                                            handshakeOutcome: .passThrough,
                                            failureReason: reason
                                        )
                                        self.capturePipeline.recordQUICInspection(
                                            ipPacket: ipPacket,
                                            udpPacket: udpPacket,
                                            outcome: outcome,
                                            metadata: metadata
                                        )
                                        if outcome == .passThroughMarked {
                                            self.quicPassThroughMarked &+= 1
                                            quicMetricBatch.policyPassThrough &+= 1
                                        } else {
                                            quicMetricBatch.tunnelForwarded &+= 1
                                        }
                                    }
                                }
                            case .interceptQUIC:
                                self.quicInterceptCandidates &+= 1
                                let authorityHint = self.resolveQUICAuthorityHint(
                                    for: ipPacket.destination
                                )
                                let quicRoute = self.quicFlowRouter.resolveInterceptRoute(
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    udpForwarderAvailable: false,
                                    tunnelUDPSupported: self.tunnelUDPSupported,
                                    tunnelPolicyRequired: self.requiresTunnelForQUICInterception(),
                                    authorityHint: authorityHint
                                )
                                self.capturePipeline.recordQUICInspection(
                                    ipPacket: ipPacket,
                                    udpPacket: udpPacket,
                                    outcome: quicRoute.inspectionOutcome,
                                    metadata: quicRoute.metadata
                                )
                                if quicRoute.inspectionOutcome == .passThroughMarked {
                                    self.quicPassThroughMarked &+= 1
                                } else if quicRoute.inspectionOutcome == .blocked {
                                    quicMetricBatch.blocked &+= 1
                                } else if quicRoute.inspectionOutcome == .tunnelForwarded {
                                    quicMetricBatch.tunnelForwarded &+= 1
                                }
                                if quicRoute.consumeOriginalDatagram {
                                    continue
                                }
                            case .dropQUIC:
                                break
                            }
                        }
                        forwardPackets.append(packet)
                        if protocols.indices.contains(index) {
                            forwardProtocols.append(protocols[index])
                        }
                    }
                    if !forwardPackets.isEmpty {
                        forwarder.enqueue(packets: forwardPackets, protocols: forwardProtocols)
                    }
                } else if self.logSampler.shouldLog(event: "vpn.packet_forward", key: "disabled", first: 3, every: 200) {
                    VPNLog.tunnel.debug("event=vpn.packet_forward outcome=skipped reason=forwarder_disabled")
                }

                self.submitQUICMetricBatchIfNeeded(quicMetricBatch)
                self.scheduleRead()
            }
        }
    }

    private func logUDPForwardSummary(reason: String) {
        let dualMITMHealth = makeDualMITMHealthSnapshot()
        guard self.udpForwardedPackets > 0 ||
            self.udpForwardedPackets443 > 0 ||
            self.quicBlockedPackets > 0 ||
            self.quicInterceptCandidates > 0 ||
            self.quicPassThroughMarked > 0 ||
            self.quicBlockedICMPSent > 0 else { return }
        VPNLog.tunnel.info(
            "event=vpn.udp_forward_summary reason=\(reason, privacy: .public) udp_out_packets=\(self.udpForwardedPackets) udp_out_443=\(self.udpForwardedPackets443) quic_mode=\(self.quicHandlingMode.rawValue, privacy: .public) quic_intercept_candidates=\(self.quicInterceptCandidates) quic_pass_through_marked=\(self.quicPassThroughMarked) quic_blocked=\(self.quicBlockedPackets) quic_icmp=\(self.quicBlockedICMPSent) quic_icmp_rl=\(self.quicBlockedICMPRateLimited) dual_mitm_policy=\(dualMITMHealth.policy.rawValue, privacy: .public) dual_mitm_breaker_enabled=\(dualMITMHealth.enabled) dual_mitm_breaker_degraded=\(dualMITMHealth.degraded) dual_mitm_breaker_reason=\(dualMITMHealth.degradeReason ?? "none", privacy: .public) dual_mitm_tcp_failure_rate=\(dualMITMHealth.tcpFailureRate) dual_mitm_quic_failure_rate=\(dualMITMHealth.quicFailureRate)"
        )
        if dualMITMHealth.degraded != lastDualMITMDegradedState {
            lastDualMITMDegradedState = dualMITMHealth.degraded
            let outcome = dualMITMHealth.degraded ? "entered" : "exited"
            eventLogHandler?(
                "dual_mitm_breaker",
                "outcome=\(outcome) degraded=\(dualMITMHealth.degraded) reason=\(dualMITMHealth.degradeReason ?? "none") policy=\(dualMITMHealth.policy.rawValue) cooldown_until=\(dualMITMHealth.degradedUntil?.timeIntervalSince1970 ?? 0)"
            )
        }
        if let eventLogHandler {
            Task {
                let snapshot = await QUICConnectionManager.shared.snapshot()
                eventLogHandler(
                    "quic_summary",
                    "reason=\(reason) flows_seen=\(snapshot.quicFlowsSeenTotal) intercepted=\(snapshot.quicFlowsInterceptedTotal) pass_through=\(snapshot.quicFlowsPassThroughTotal) blocked=\(snapshot.quicFlowsBlockedTotal) tunnel_forwarded=\(snapshot.quicFlowsTunnelForwardedTotal) http3_captured=\(snapshot.http3RequestsCapturedTotal) failures=\(snapshot.quicMitmFailuresTotal) dual_mitm_policy=\(dualMITMHealth.policy.rawValue) dual_mitm_breaker_enabled=\(dualMITMHealth.enabled) dual_mitm_breaker_degraded=\(dualMITMHealth.degraded) dual_mitm_tcp_failure_rate=\(dualMITMHealth.tcpFailureRate) dual_mitm_quic_failure_rate=\(dualMITMHealth.quicFailureRate)"
                )
            }
        }
    }

    private func makeDualMITMHealthSnapshot() -> DualMITMHealthSnapshot {
        let breakerSnapshot = DualMITMCircuitBreaker.shared.snapshot()
        return DualMITMHealthSnapshot(
            enabled: dualMITMCircuitBreakerEnabled && breakerSnapshot.enabled,
            policy: dualMITMPolicy,
            degraded: dualMITMCircuitBreakerEnabled && breakerSnapshot.isDegraded,
            degradedUntil: breakerSnapshot.degradedUntil,
            degradeReason: breakerSnapshot.degradeReason,
            tcpAttempts: breakerSnapshot.tcpAttempts,
            tcpFailures: breakerSnapshot.tcpFailures,
            tcpFailureRate: breakerSnapshot.tcpFailureRate,
            quicAttempts: breakerSnapshot.quicAttemptsInWindow,
            quicFailures: breakerSnapshot.quicFailuresInWindow,
            quicFailureRate: breakerSnapshot.quicFailureRate
        )
    }

    private func handleInterceptedQUICDatagramToClient(
        _ payload: Data,
        context: QUICFlowDatagramContext
    ) {
        guard !payload.isEmpty else { return }
        guard let packet = buildSynthesizedUDPPacket(
            sourceIP: context.serverIP,
            destinationIP: context.clientIP,
            sourcePort: context.serverPort,
            destinationPort: context.clientPort,
            payload: payload
        ) else {
            if logSampler.shouldLog(event: "vpn.quic_datagram_to_client", key: "build_failed", first: 3, every: 200) {
                VPNLog.tunnel.warning("event=vpn.quic_datagram_to_client outcome=skipped reason=build_failed")
            }
            return
        }

        _ = capturePipeline.enqueue(packet: packet.data)
        packetFlow.writePackets([packet.data], withProtocols: [packet.protocolNumber])
    }

    private func consumeInboundQUICPacketIfInterceptedOnQueue(_ packet: Data) -> Bool {
        guard quicHandlingMode == .intercept else {
            return false
        }
        guard let ipPacket = IPPacketParser.parse(packet), ipPacket.transport == .udp else {
            return false
        }
        guard let udpPacket = UDPParser.parse(ipPacket.payload) else {
            return false
        }
        let isQUIC = udpPacket.destinationPort == 443 || udpPacket.sourcePort == 443
        guard isQUIC else {
            return false
        }

        let consumed = quicFlowRouter.ingestUpstreamDatagram(
            ipPacket: ipPacket,
            udpPacket: udpPacket
        )
        if consumed, logSampler.shouldLog(event: "vpn.quic_inbound_intercept", key: "consumed", first: 5, every: 500) {
            VPNLog.tunnel.debug(
                "event=vpn.quic_inbound_intercept outcome=consumed src=\(ipPacket.source.description, privacy: .private(mask: .hash)):\(udpPacket.sourcePort) dst=\(ipPacket.destination.description, privacy: .private(mask: .hash)):\(udpPacket.destinationPort)"
            )
        }
        return consumed
    }

    private func recordQUICAuthorityHintIfNeeded(
        ipPacket: IPPacket,
        udpPacket: UDPPacket
    ) {
        guard udpPacket.sourcePort == 53 || udpPacket.destinationPort == 53 else {
            return
        }

        guard let dnsMessage = DNSParser.parseSafely(
            data: udpPacket.payload,
            sourceIP: ipPacket.source.description,
            sourcePort: udpPacket.sourcePort,
            destIP: ipPacket.destination.description,
            destPort: udpPacket.destinationPort
        ), dnsMessage.isResponse, dnsMessage.isSuccessful else {
            return
        }

        let authority = dnsMessage.queryDomain?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !authority.isEmpty else { return }

        let now = Date()
        purgeExpiredQUICAuthorityHints(now: now)

        var wroteHint = false
        for answer in dnsMessage.answers where answer.type == .a || answer.type == .aaaa {
            let resolvedIP = answer.dataString
            guard isIPAddressLiteral(resolvedIP) else { continue }
            let ttl = max(
                Self.quicAuthorityHintMinTTL,
                min(Self.quicAuthorityHintMaxTTL, TimeInterval(answer.ttl))
            )
            quicAuthorityHintsByIP[resolvedIP] = QUICAuthorityHint(
                authority: authority,
                expiresAt: now.addingTimeInterval(ttl)
            )
            wroteHint = true
        }

        if !wroteHint {
            for resolvedIP in dnsMessage.resolvedIPs where isIPAddressLiteral(resolvedIP) {
                quicAuthorityHintsByIP[resolvedIP] = QUICAuthorityHint(
                    authority: authority,
                    expiresAt: now.addingTimeInterval(Self.quicAuthorityHintMinTTL)
                )
                wroteHint = true
            }
        }

        if wroteHint, quicAuthorityHintsByIP.count > Self.quicAuthorityHintMaxEntries {
            trimQUICAuthorityHints(now: now)
        }
    }

    private func resolveQUICAuthorityHint(for destinationIP: TracePacket.IPAddress) -> String? {
        let now = Date()
        let key = destinationIP.description
        guard let hint = quicAuthorityHintsByIP[key] else { return nil }
        guard hint.expiresAt > now else {
            quicAuthorityHintsByIP.removeValue(forKey: key)
            return nil
        }
        return hint.authority
    }

    private func purgeExpiredQUICAuthorityHints(now: Date) {
        guard !quicAuthorityHintsByIP.isEmpty else { return }
        quicAuthorityHintsByIP = quicAuthorityHintsByIP.filter { _, hint in
            hint.expiresAt > now
        }
    }

    private func trimQUICAuthorityHints(now: Date) {
        purgeExpiredQUICAuthorityHints(now: now)
        guard quicAuthorityHintsByIP.count > Self.quicAuthorityHintMaxEntries else {
            return
        }

        let sorted = quicAuthorityHintsByIP.sorted { lhs, rhs in
            lhs.value.expiresAt < rhs.value.expiresAt
        }
        let removeCount = quicAuthorityHintsByIP.count - Self.quicAuthorityHintMaxEntries
        for index in 0 ..< removeCount {
            quicAuthorityHintsByIP.removeValue(forKey: sorted[index].key)
        }
    }

    private func isIPAddressLiteral(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }

        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private func handleInterceptedQUICDatagramToUpstream(
        _ payload: Data,
        context: QUICFlowDatagramContext
    ) {
        guard !payload.isEmpty else { return }
        guard let packet = buildSynthesizedUDPPacket(
            sourceIP: context.clientIP,
            destinationIP: context.serverIP,
            sourcePort: context.clientPort,
            destinationPort: context.serverPort,
            payload: payload
        ) else {
            if logSampler.shouldLog(event: "vpn.quic_datagram_to_upstream", key: "build_failed", first: 3, every: 200) {
                VPNLog.tunnel.warning("event=vpn.quic_datagram_to_upstream outcome=skipped reason=build_failed")
            }
            return
        }

        switch context.upstreamForwardingDecision {
        case .forwardDirect:
            guard let udpForwarder else {
                if logSampler.shouldLog(event: "vpn.quic_datagram_to_upstream", key: "udp_forwarder_missing", first: 3, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.quic_datagram_to_upstream outcome=skipped reason=udp_forwarder_missing")
                }
                return
            }
            guard let ipPacket = IPPacketParser.parse(packet.data) else {
                if logSampler.shouldLog(event: "vpn.quic_datagram_to_upstream", key: "ip_parse_failed", first: 3, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.quic_datagram_to_upstream outcome=skipped reason=ip_parse_failed")
                }
                return
            }
            _ = capturePipeline.enqueue(packet: packet.data)
            udpForwarder.enqueue(packet: packet.data, ipPacket: ipPacket)
        case .forwardTunnel:
            guard let forwarder else {
                if logSampler.shouldLog(event: "vpn.quic_datagram_to_upstream", key: "forwarder_missing", first: 3, every: 200) {
                    VPNLog.tunnel.warning("event=vpn.quic_datagram_to_upstream outcome=skipped reason=forwarder_missing")
                }
                return
            }
            _ = capturePipeline.enqueue(packet: packet.data)
            forwarder.enqueue(packets: [packet.data], protocols: [packet.protocolNumber])
        case .dropQUIC, .interceptQUIC:
            return
        }
    }

    private func buildSynthesizedUDPPacket(
        sourceIP: TracePacket.IPAddress,
        destinationIP: TracePacket.IPAddress,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data
    ) -> (data: Data, protocolNumber: NSNumber)? {
        switch (sourceIP, destinationIP) {
        case let (.v4(src), .v4(dst)):
            guard payload.count <= Self.maxSynthesizedUDPPayloadIPv4 else {
                if logSampler.shouldLog(event: "vpn.quic_datagram_synth", key: "payload_too_large_v4", first: 3, every: 200) {
                    VPNLog.tunnel.warning(
                        "event=vpn.quic_datagram_synth outcome=skipped reason=payload_too_large_v4 payload_bytes=\(payload.count)"
                    )
                }
                return nil
            }
            let udpDatagram = buildSynthesizedUDPDatagramV4(
                sourcePort: sourcePort,
                destinationPort: destinationPort,
                payload: payload,
                sourceIP: src,
                destinationIP: dst
            )
            return (
                data: buildSynthesizedIPv4UDPPacket(
                    sourceIP: src,
                    destinationIP: dst,
                    udpDatagram: udpDatagram
                ),
                protocolNumber: NSNumber(value: AF_INET)
            )
        case let (.v6(src), .v6(dst)):
            guard payload.count <= Self.maxSynthesizedUDPPayloadIPv6 else {
                if logSampler.shouldLog(event: "vpn.quic_datagram_synth", key: "payload_too_large_v6", first: 3, every: 200) {
                    VPNLog.tunnel.warning(
                        "event=vpn.quic_datagram_synth outcome=skipped reason=payload_too_large_v6 payload_bytes=\(payload.count)"
                    )
                }
                return nil
            }
            let udpDatagram = buildSynthesizedUDPDatagramV6(
                sourcePort: sourcePort,
                destinationPort: destinationPort,
                payload: payload,
                sourceIP: src,
                destinationIP: dst
            )
            return (
                data: buildSynthesizedIPv6UDPPacket(
                    sourceIP: src,
                    destinationIP: dst,
                    udpDatagram: udpDatagram
                ),
                protocolNumber: NSNumber(value: AF_INET6)
            )
        default:
            return nil
        }
    }

    private func buildSynthesizedUDPDatagramV4(
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data,
        sourceIP: UInt32,
        destinationIP: UInt32
    ) -> Data {
        let length = UInt16(8 + payload.count)
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = UInt8(sourcePort >> 8)
        header[1] = UInt8(sourcePort & 0xFF)
        header[2] = UInt8(destinationPort >> 8)
        header[3] = UInt8(destinationPort & 0xFF)
        header[4] = UInt8(length >> 8)
        header[5] = UInt8(length & 0xFF)

        var checksum = udpChecksumV4(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            udpHeader: header,
            payload: payload
        )
        if checksum == 0 {
            checksum = 0xFFFF
        }
        header[6] = UInt8(checksum >> 8)
        header[7] = UInt8(checksum & 0xFF)

        var data = Data(header)
        data.append(payload)
        return data
    }

    private func buildSynthesizedUDPDatagramV6(
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data,
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64)
    ) -> Data {
        let length = UInt16(8 + payload.count)
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = UInt8(sourcePort >> 8)
        header[1] = UInt8(sourcePort & 0xFF)
        header[2] = UInt8(destinationPort >> 8)
        header[3] = UInt8(destinationPort & 0xFF)
        header[4] = UInt8(length >> 8)
        header[5] = UInt8(length & 0xFF)

        var checksum = udpChecksumV6(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            udpHeader: header,
            payload: payload
        )
        if checksum == 0 {
            checksum = 0xFFFF
        }
        header[6] = UInt8(checksum >> 8)
        header[7] = UInt8(checksum & 0xFF)

        var data = Data(header)
        data.append(payload)
        return data
    }

    private func buildSynthesizedIPv4UDPPacket(
        sourceIP: UInt32,
        destinationIP: UInt32,
        udpDatagram: Data
    ) -> Data {
        let totalLength = 20 + udpDatagram.count
        udpSyntheticPacketIdentifier &+= 1

        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        header[1] = 0x00
        header[2] = UInt8((totalLength >> 8) & 0xFF)
        header[3] = UInt8(totalLength & 0xFF)
        header[4] = UInt8((udpSyntheticPacketIdentifier >> 8) & 0xFF)
        header[5] = UInt8(udpSyntheticPacketIdentifier & 0xFF)
        header[6] = 0x00
        header[7] = 0x00
        header[8] = 64
        header[9] = 17
        header[10] = 0x00
        header[11] = 0x00
        header[12] = UInt8((sourceIP >> 24) & 0xFF)
        header[13] = UInt8((sourceIP >> 16) & 0xFF)
        header[14] = UInt8((sourceIP >> 8) & 0xFF)
        header[15] = UInt8(sourceIP & 0xFF)
        header[16] = UInt8((destinationIP >> 24) & 0xFF)
        header[17] = UInt8((destinationIP >> 16) & 0xFF)
        header[18] = UInt8((destinationIP >> 8) & 0xFF)
        header[19] = UInt8(destinationIP & 0xFF)

        let checksum = internetChecksum(header)
        header[10] = UInt8((checksum >> 8) & 0xFF)
        header[11] = UInt8(checksum & 0xFF)

        var packet = Data(header)
        packet.append(udpDatagram)
        return packet
    }

    private func buildSynthesizedIPv6UDPPacket(
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64),
        udpDatagram: Data
    ) -> Data {
        var header = [UInt8](repeating: 0, count: 40)
        header[0] = 0x60
        let payloadLength = udpDatagram.count
        header[4] = UInt8((payloadLength >> 8) & 0xFF)
        header[5] = UInt8(payloadLength & 0xFF)
        header[6] = 17
        header[7] = 64

        writeIPv6Address(sourceIP, into: &header, offset: 8)
        writeIPv6Address(destinationIP, into: &header, offset: 24)

        var packet = Data(header)
        packet.append(udpDatagram)
        return packet
    }

    private func maybeInjectQUICBlockedICMP(
        originalPacket: Data,
        ipPacket: IPPacket,
        udpPacket: UDPPacket,
        proto: NSNumber?
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        cleanupQUICBlockStateIfNeeded(now: now)

        let flowKey = QUICBlockFlowKey(
            sourceIP: ipPacket.source,
            sourcePort: udpPacket.sourcePort,
            destinationIP: ipPacket.destination,
            destinationPort: udpPacket.destinationPort
        )

        if let last = quicBlockFlowLastICMPSent[flowKey], now &- last < Self.quicICMPRateLimitNanos {
            quicBlockedICMPRateLimited &+= 1
            return
        }
        quicBlockFlowLastICMPSent[flowKey] = now

        guard let icmpPacket = buildICMPPortUnreachable(ipPacket: ipPacket, originalPacket: originalPacket) else { return }
        let protocolNumber = proto ?? NSNumber(value: ipPacket.version == 4 ? AF_INET : AF_INET6)
        packetFlow.writePackets([icmpPacket], withProtocols: [protocolNumber])
        quicBlockedICMPSent &+= 1

        if logSampler.shouldLog(event: "vpn.quic_block_icmp", key: "\(flowKey.hashValue)", first: 3, every: 200) {
            let srcHash = LogRedaction.hash("\(ipPacket.source):\(udpPacket.sourcePort)")
            let dstHash = LogRedaction.hash("\(ipPacket.destination):\(udpPacket.destinationPort)")
            VPNLog.tunnel.info(
                "event=vpn.quic_block_icmp outcome=sent ip_version=\(ipPacket.version) src=\(srcHash, privacy: .public) dst=\(dstHash, privacy: .public)"
            )
        }
    }

    private func cleanupQUICBlockStateIfNeeded(now: UInt64) {
        let shouldCleanupByTime = now &- quicBlockLastCleanup >= Self.quicICMPStateCleanupIntervalNanos
        let shouldCleanupBySize = quicBlockFlowLastICMPSent.count >= Self.quicICMPStateMaxEntries
        guard shouldCleanupByTime || shouldCleanupBySize else { return }
        quicBlockLastCleanup = now

        let cutoff = now > Self.quicICMPStateExpireNanos ? (now - Self.quicICMPStateExpireNanos) : 0
        quicBlockFlowLastICMPSent = quicBlockFlowLastICMPSent.filter { $0.value >= cutoff }
        if quicBlockFlowLastICMPSent.count > Self.quicICMPStateMaxEntries {
            quicBlockFlowLastICMPSent = Dictionary(
                uniqueKeysWithValues: quicBlockFlowLastICMPSent
                    .prefix(Self.quicICMPStateMaxEntries)
                    .map { ($0.key, $0.value) }
            )
        }
    }

    private func buildICMPPortUnreachable(ipPacket: IPPacket, originalPacket: Data) -> Data? {
        let quoteLength = min(originalPacket.count, ipPacket.totalLength, ipPacket.headerLength + 8)
        guard quoteLength > 0 else { return nil }
        let quoted = originalPacket.prefix(quoteLength)

        switch (ipPacket.source, ipPacket.destination) {
        case let (.v4(sourceIP), .v4(destinationIP)):
            return buildIPv4ICMPPortUnreachable(
                sourceIP: destinationIP,
                destinationIP: sourceIP,
                quotedPacket: quoted
            )
        case let (.v6(sourceIP), .v6(destinationIP)):
            return buildIPv6ICMPPortUnreachable(
                sourceIP: destinationIP,
                destinationIP: sourceIP,
                quotedPacket: quoted
            )
        default:
            return nil
        }
    }

    private func buildIPv4ICMPPortUnreachable(sourceIP: UInt32, destinationIP: UInt32, quotedPacket: Data) -> Data {
        var icmpBytes = [UInt8](repeating: 0, count: 8 + quotedPacket.count)
        icmpBytes[0] = 3 // Destination Unreachable
        icmpBytes[1] = 3 // Port Unreachable
        if !quotedPacket.isEmpty {
            icmpBytes.replaceSubrange(8 ..< 8 + quotedPacket.count, with: quotedPacket)
        }
        let icmpChecksum = internetChecksum(icmpBytes)
        icmpBytes[2] = UInt8((icmpChecksum >> 8) & 0xFF)
        icmpBytes[3] = UInt8(icmpChecksum & 0xFF)

        let totalLength = 20 + icmpBytes.count
        icmpPacketIdentifier &+= 1

        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        header[1] = 0x00
        header[2] = UInt8((totalLength >> 8) & 0xFF)
        header[3] = UInt8(totalLength & 0xFF)
        header[4] = UInt8((icmpPacketIdentifier >> 8) & 0xFF)
        header[5] = UInt8(icmpPacketIdentifier & 0xFF)
        header[6] = 0x00
        header[7] = 0x00
        header[8] = 64
        header[9] = 1 // ICMP
        header[10] = 0x00
        header[11] = 0x00
        header[12] = UInt8((sourceIP >> 24) & 0xFF)
        header[13] = UInt8((sourceIP >> 16) & 0xFF)
        header[14] = UInt8((sourceIP >> 8) & 0xFF)
        header[15] = UInt8(sourceIP & 0xFF)
        header[16] = UInt8((destinationIP >> 24) & 0xFF)
        header[17] = UInt8((destinationIP >> 16) & 0xFF)
        header[18] = UInt8((destinationIP >> 8) & 0xFF)
        header[19] = UInt8(destinationIP & 0xFF)

        let checksum = internetChecksum(header)
        header[10] = UInt8((checksum >> 8) & 0xFF)
        header[11] = UInt8(checksum & 0xFF)

        var packet = Data(header)
        packet.append(contentsOf: icmpBytes)
        return packet
    }

    private func buildIPv6ICMPPortUnreachable(
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64),
        quotedPacket: Data
    ) -> Data {
        var icmpBytes = [UInt8](repeating: 0, count: 8 + quotedPacket.count)
        icmpBytes[0] = 1 // Destination Unreachable
        icmpBytes[1] = 4 // Port Unreachable
        if !quotedPacket.isEmpty {
            icmpBytes.replaceSubrange(8 ..< 8 + quotedPacket.count, with: quotedPacket)
        }

        let checksum = icmpv6Checksum(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            message: icmpBytes
        )
        icmpBytes[2] = UInt8((checksum >> 8) & 0xFF)
        icmpBytes[3] = UInt8(checksum & 0xFF)

        var header = [UInt8](repeating: 0, count: 40)
        header[0] = 0x60
        let payloadLength = icmpBytes.count
        header[4] = UInt8((payloadLength >> 8) & 0xFF)
        header[5] = UInt8(payloadLength & 0xFF)
        header[6] = 58 // ICMPv6
        header[7] = 64

        writeIPv6Address(sourceIP, into: &header, offset: 8)
        writeIPv6Address(destinationIP, into: &header, offset: 24)

        var packet = Data(header)
        packet.append(contentsOf: icmpBytes)
        return packet
    }

    private func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            let word = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            sum += UInt32(word)
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(UInt16(bytes[index]) << 8)
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func udpChecksumV4(
        sourceIP: UInt32,
        destinationIP: UInt32,
        udpHeader: [UInt8],
        payload: Data
    ) -> UInt16 {
        var sum: UInt32 = 0

        sum += UInt32((sourceIP >> 16) & 0xFFFF)
        sum += UInt32(sourceIP & 0xFFFF)
        sum += UInt32((destinationIP >> 16) & 0xFFFF)
        sum += UInt32(destinationIP & 0xFFFF)
        sum += UInt32(17)
        let udpLength = UInt16(udpHeader.count + payload.count)
        sum += UInt32(udpLength)

        var index = 0
        while index < udpHeader.count {
            let word = UInt16(udpHeader[index]) << 8 | UInt16(udpHeader[index + 1])
            sum += UInt32(word)
            index += 2
        }

        var payloadBytes = [UInt8](payload)
        if payloadBytes.count % 2 != 0 {
            payloadBytes.append(0)
        }
        index = 0
        while index < payloadBytes.count {
            let word = UInt16(payloadBytes[index]) << 8 | UInt16(payloadBytes[index + 1])
            sum += UInt32(word)
            index += 2
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func udpChecksumV6(
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64),
        udpHeader: [UInt8],
        payload: Data
    ) -> UInt16 {
        var sum: UInt32 = 0

        sum += checksumWord(from: sourceIP.0)
        sum += checksumWord(from: sourceIP.1)
        sum += checksumWord(from: destinationIP.0)
        sum += checksumWord(from: destinationIP.1)

        let udpLength = UInt32(udpHeader.count + payload.count)
        sum += UInt32((udpLength >> 16) & 0xFFFF)
        sum += UInt32(udpLength & 0xFFFF)
        sum += UInt32(17)

        var index = 0
        while index < udpHeader.count {
            let word = UInt16(udpHeader[index]) << 8 | UInt16(udpHeader[index + 1])
            sum += UInt32(word)
            index += 2
        }

        var payloadBytes = [UInt8](payload)
        if payloadBytes.count % 2 != 0 {
            payloadBytes.append(0)
        }
        index = 0
        while index < payloadBytes.count {
            let word = UInt16(payloadBytes[index]) << 8 | UInt16(payloadBytes[index + 1])
            sum += UInt32(word)
            index += 2
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func icmpv6Checksum(
        sourceIP: (UInt64, UInt64),
        destinationIP: (UInt64, UInt64),
        message: [UInt8]
    ) -> UInt16 {
        var sum: UInt32 = 0
        sum += checksumWord(from: sourceIP.0)
        sum += checksumWord(from: sourceIP.1)
        sum += checksumWord(from: destinationIP.0)
        sum += checksumWord(from: destinationIP.1)

        let length = UInt32(message.count)
        sum += UInt32((length >> 16) & 0xFFFF)
        sum += UInt32(length & 0xFFFF)
        sum += UInt32(58)

        var bytes = message
        if bytes.count % 2 != 0 {
            bytes.append(0)
        }
        var index = 0
        while index < bytes.count {
            let word = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            sum += UInt32(word)
            index += 2
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func checksumWord(from value: UInt64) -> UInt32 {
        var sum: UInt32 = 0
        sum += UInt32((value >> 48) & 0xFFFF)
        sum += UInt32((value >> 32) & 0xFFFF)
        sum += UInt32((value >> 16) & 0xFFFF)
        sum += UInt32(value & 0xFFFF)
        return sum
    }

    private func writeIPv6Address(_ address: (UInt64, UInt64), into buffer: inout [UInt8], offset: Int) {
        let hi = address.0
        let lo = address.1
        buffer[offset + 0] = UInt8((hi >> 56) & 0xFF)
        buffer[offset + 1] = UInt8((hi >> 48) & 0xFF)
        buffer[offset + 2] = UInt8((hi >> 40) & 0xFF)
        buffer[offset + 3] = UInt8((hi >> 32) & 0xFF)
        buffer[offset + 4] = UInt8((hi >> 24) & 0xFF)
        buffer[offset + 5] = UInt8((hi >> 16) & 0xFF)
        buffer[offset + 6] = UInt8((hi >> 8) & 0xFF)
        buffer[offset + 7] = UInt8(hi & 0xFF)
        buffer[offset + 8] = UInt8((lo >> 56) & 0xFF)
        buffer[offset + 9] = UInt8((lo >> 48) & 0xFF)
        buffer[offset + 10] = UInt8((lo >> 40) & 0xFF)
        buffer[offset + 11] = UInt8((lo >> 32) & 0xFF)
        buffer[offset + 12] = UInt8((lo >> 24) & 0xFF)
        buffer[offset + 13] = UInt8((lo >> 16) & 0xFF)
        buffer[offset + 14] = UInt8((lo >> 8) & 0xFF)
        buffer[offset + 15] = UInt8(lo & 0xFF)
    }
}
