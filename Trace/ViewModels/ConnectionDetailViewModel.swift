//
//  ConnectionDetailViewModel.swift
//  Trace
//
//  Created by Justin on 2026/01/23.
//

import Combine
import Foundation
import TraceCore
import TracePacket

struct PCAPFileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let size: UInt64
    let modified: Date?

    var displayName: String {
        url.lastPathComponent
    }
}

struct TCPPacketSummary: Identifiable {
    let id = UUID()
    let timestamp: Date
    let direction: FlowDirection
    let sequence: UInt32
    let acknowledgment: UInt32
    let length: Int
    let flags: TCPPacket.Flags
    let window: UInt16
    let isRetransmission: Bool
    let isOutOfOrder: Bool
    let isDupAck: Bool
    let isAckOnly: Bool
    let sourceIP: String
    let destinationIP: String
    let sourcePort: UInt16
    let destinationPort: UInt16
    let ipVersion: UInt8
    let hopLimit: UInt8
    let protocolNumber: UInt8
    let ipHeaderLength: Int
    let totalLength: Int
    let fragmentOffset: Int
    let moreFragments: Bool
    let scaledWindow: UInt64

    init(
        timestamp: Date,
        direction: FlowDirection,
        sequence: UInt32,
        acknowledgment: UInt32,
        length: Int,
        flags: TCPPacket.Flags,
        window: UInt16,
        isRetransmission: Bool,
        isOutOfOrder: Bool,
        isDupAck: Bool,
        isAckOnly: Bool = false,
        sourceIP: String = "",
        destinationIP: String = "",
        sourcePort: UInt16 = 0,
        destinationPort: UInt16 = 0,
        ipVersion: UInt8 = 0,
        hopLimit: UInt8 = 0,
        protocolNumber: UInt8 = 0,
        ipHeaderLength: Int = 0,
        totalLength: Int = 0,
        fragmentOffset: Int = 0,
        moreFragments: Bool = false,
        scaledWindow: UInt64 = 0
    ) {
        self.timestamp = timestamp
        self.direction = direction
        self.sequence = sequence
        self.acknowledgment = acknowledgment
        self.length = length
        self.flags = flags
        self.window = window
        self.isRetransmission = isRetransmission
        self.isOutOfOrder = isOutOfOrder
        self.isDupAck = isDupAck
        self.isAckOnly = isAckOnly
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.ipVersion = ipVersion
        self.hopLimit = hopLimit
        self.protocolNumber = protocolNumber
        self.ipHeaderLength = ipHeaderLength
        self.totalLength = totalLength
        self.fragmentOffset = fragmentOffset
        self.moreFragments = moreFragments
        self.scaledWindow = scaledWindow
    }
}

struct UDPPacketSummary: Identifiable {
    let id = UUID()
    let timestamp: Date
    let direction: FlowDirection
    let sourceIP: String
    let destinationIP: String
    let sourcePort: UInt16
    let destinationPort: UInt16
    let udpLength: UInt16
    let payloadLength: Int
    let ipVersion: UInt8
    let hopLimit: UInt8
    let protocolNumber: UInt8
    let ipHeaderLength: Int
    let totalLength: Int
    let fragmentOffset: Int
    let moreFragments: Bool
}

struct UDPPCAPDiagnostics {
    let totalDatagrams: Int
    let sourceToDestinationDatagrams: Int
    let destinationToSourceDatagrams: Int
    let fragmentedDatagrams: Int
    let maxDatagramLength: UInt16
}

struct ConnectionPCAPAnalysis {
    let clientEndpoint: FlowEndpoint?
    let serverEndpoint: FlowEndpoint?
    let handshake: TCPHandshakeSummary?
    let termination: TCPTerminationSummary?
    let state: FlowConnectionState
    let metrics: TCPFlowMetrics
    let packets: [TCPPacketSummary]
    let streamClientToServer: Data
    let streamServerToClient: Data
    let udpPackets: [UDPPacketSummary]
    let udpDiagnostics: UDPPCAPDiagnostics?

    init(
        clientEndpoint: FlowEndpoint?,
        serverEndpoint: FlowEndpoint?,
        handshake: TCPHandshakeSummary?,
        termination: TCPTerminationSummary?,
        state: FlowConnectionState,
        metrics: TCPFlowMetrics,
        packets: [TCPPacketSummary],
        streamClientToServer: Data,
        streamServerToClient: Data,
        udpPackets: [UDPPacketSummary] = [],
        udpDiagnostics: UDPPCAPDiagnostics? = nil
    ) {
        self.clientEndpoint = clientEndpoint
        self.serverEndpoint = serverEndpoint
        self.handshake = handshake
        self.termination = termination
        self.state = state
        self.metrics = metrics
        self.packets = packets
        self.streamClientToServer = streamClientToServer
        self.streamServerToClient = streamServerToClient
        self.udpPackets = udpPackets
        self.udpDiagnostics = udpDiagnostics
    }

    var hasPackets: Bool {
        !packets.isEmpty || !udpPackets.isEmpty
    }
}

@MainActor
final class ConnectionDetailViewModel: ObservableObject {
    @Published var record: PacketFlowRecord
    @Published var pcapFiles: [PCAPFileItem] = []
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var analysis: ConnectionPCAPAnalysis?
    private var analysisTask: Task<Void, Never>?
    private var analysisWorkTask: Task<ConnectionPCAPAnalysis, Error>?
    private var didAttemptAutoLoadPCAP = false

    private let rawPacketPCAPPrefixes = ["capture_raw_packets"]
    private let autoAnalyzeMaxBytes: UInt64 = 25 * 1_048_576 // 25 MB

    init(record: PacketFlowRecord) {
        self.record = record
    }

    deinit {
        analysisTask?.cancel()
        analysisWorkTask?.cancel()
    }

    func cancelPCAPAnalysis() {
        analysisTask?.cancel()
        analysisWorkTask?.cancel()
        analysisTask = nil
        analysisWorkTask = nil
        isLoading = false
    }

    func refreshPCAPFiles() {
        pcapFiles = rawPacketPCAPFiles()
    }

    func loadFromPCAP(_ file: PCAPFileItem) {
        loadFromPCAPCandidates([file], initiator: .manual)
    }

    func autoLoadPCAPIfPossible() {
        guard !didAttemptAutoLoadPCAP else { return }
        didAttemptAutoLoadPCAP = true

        guard record.transport != .unknown else { return }
        guard analysis == nil else { return }

        let candidates = rawPacketPCAPFiles()
            .filter { $0.size > 0 && $0.size <= autoAnalyzeMaxBytes }
        guard !candidates.isEmpty else { return }

        loadFromPCAPCandidates(candidates, initiator: .auto)
    }

    private enum PCAPLoadInitiator {
        case auto
        case manual
    }

    private func loadFromPCAPCandidates(_ candidates: [PCAPFileItem], initiator: PCAPLoadInitiator) {
        analysisTask?.cancel()
        analysisWorkTask?.cancel()

        isLoading = true
        loadError = nil
        analysis = nil

        let capturedRecord = record

        analysisTask = Task { @MainActor in
            defer { isLoading = false }

            var lastError: Error?

            for candidate in candidates {
                do {
                    let analysis = try await analyze(record: capturedRecord, url: candidate.url)
                    if !analysis.hasPackets {
                        throw PCAPFlowAnalyzerError.noPacketsForFlow
                    }
                    self.analysis = analysis
                    return
                } catch is CancellationError {
                    self.analysis = nil
                    return
                } catch {
                    lastError = error
                    if shouldTryNextCandidate(error: error, initiator: initiator) {
                        continue
                    }
                    if initiator == .manual {
                        self.loadError = error.localizedDescription
                    }
                    return
                }
            }

            if initiator == .manual, let lastError {
                self.loadError = lastError.localizedDescription
            }
        }
    }

    private func analyze(record: PacketFlowRecord, url: URL) async throws -> ConnectionPCAPAnalysis {
        let work = Task.detached(priority: .utility) {
            let analyzer = try PCAPFlowAnalyzer(record: record)
            return try analyzer.analyze(url: url)
        }
        analysisWorkTask = work
        defer {
            analysisWorkTask = nil
        }

        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func shouldTryNextCandidate(error _: Error, initiator: PCAPLoadInitiator) -> Bool {
        guard initiator == .auto else { return false }
        // Best-effort auto mode: if one capture is invalid or doesn't contain the flow,
        // continue scanning older candidates before giving up.
        return true
    }

    private func rawPacketPCAPFiles() -> [PCAPFileItem] {
        let urls = AppGroupStorage.shared.packetCaptureFiles(prefixes: rawPacketPCAPPrefixes)
        return urls.map { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .uint64Value ?? 0
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return PCAPFileItem(url: url, size: size, modified: modified)
        }
    }
}

enum PCAPFlowAnalyzerError: LocalizedError, Equatable {
    case noPacketsForFlow

    var errorDescription: String? {
        switch self {
        case .noPacketsForFlow:
            "No packets found for this connection in the selected PCAP."
        }
    }
}

private final class PCAPFlowAnalyzer {
    private struct EndpointKey: Hashable {
        let ip: String
        let port: UInt16
    }

    private struct TimeWindow {
        let lowerBound: Date
        let upperBound: Date
    }

    private enum ScanControl: Error {
        case reachedEndOfWindow
    }

    private struct RecentSegment {
        let sequence: UInt32
        let length: Int
    }

    private struct EndpointTracker {
        var metrics = FlowDirectionalStats()
        var expectedSeq: UInt32?
        var baseSeq: UInt32?
        var lastAck: UInt32?
        var recentSegments: [RecentSegment] = []
        var recentIndex: Int = 0
        var inflight: [(UInt32, Date)] = []
        var throughputBucketStart: Int?
        var throughputBucketBytes: UInt64 = 0
        var lastSeqSampleTime: Date?
    }

    private struct TCPPacketIndicators {
        var isRetransmission = false
        var isOutOfOrder = false
        var isDupAck = false
        var isAckOnly = false
        var scaledWindow: UInt64 = 0
    }

    private struct UDPAnalysisState {
        var packets: [UDPPacketSummary] = []
        var sourceToDestinationDatagrams = 0
        var destinationToSourceDatagrams = 0
        var fragmentedDatagrams = 0
        var maxDatagramLength: UInt16 = 0
        var matchedDatagrams = 0
    }

    private let record: PacketFlowRecord
    private let maxRecentSegments = 128
    private let maxInflightSegments = 128
    private let maxRTTSamples = 180
    private let maxThroughputSamples = 180
    private let maxSequenceSamples = 360
    private let maxPacketSummaries = 200
    private let maxStreamBytes = 256 * 1024

    init(record: PacketFlowRecord) throws {
        self.record = record
    }

    func analyze(url: URL) throws -> ConnectionPCAPAnalysis {
        switch record.transport {
        case .udp:
            try analyzeUDP(url: url)
        case .tcp, .unknown:
            try analyzeTCP(url: url)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func analyzeTCP(url: URL) throws -> ConnectionPCAPAnalysis {
        let reader = try PCAPReader(url: url)
        let reassembler = TCPReassembler()

        var clientEndpoint: FlowEndpoint?
        var serverEndpoint: FlowEndpoint?
        var handshake = TCPHandshakeSummary()
        var termination = TCPTerminationSummary()
        var connectionState: FlowConnectionState = .unknown
        var metrics = TCPFlowMetrics()
        var packets: [TCPPacketSummary] = []
        var streamClientToServer = Data()
        var streamServerToClient = Data()
        var endpointTrackers: [EndpointKey: EndpointTracker] = [:]
        var windowScaleByEndpoint: [EndpointKey: UInt8] = [:]
        var finSeen: Set<EndpointKey> = []
        var rstSeen: Set<EndpointKey> = []

        let endpointA = EndpointKey(ip: record.sourceIP, port: record.sourcePort)
        let endpointB = EndpointKey(ip: record.destinationIP, port: record.destinationPort)
        let window = scanWindow()
        var didMatchAnyPacket = false

        do {
            try reader.forEachPacket { packet in
                if Task.isCancelled {
                    throw CancellationError()
                }

                if packet.timestamp < window.lowerBound {
                    return
                }
                if packet.timestamp > window.upperBound {
                    throw ScanControl.reachedEndOfWindow
                }

                guard let ipPacket = IPPacketParser.parse(packet.data) else { return }
                guard ipPacket.transport == .tcp else { return }
                guard let tcpPacket = TCPParser.parse(ipPacket.payload) else { return }

                let src = EndpointKey(ip: ipPacket.source.description, port: tcpPacket.sourcePort)
                let dst = EndpointKey(ip: ipPacket.destination.description, port: tcpPacket.destinationPort)
                guard (src == endpointA && dst == endpointB) || (src == endpointB && dst == endpointA) else { return }
                didMatchAnyPacket = true

                if tcpPacket.flags.contains(.syn) && !tcpPacket.flags.contains(.ack) {
                    if clientEndpoint == nil {
                        clientEndpoint = FlowEndpoint(ip: src.ip, port: src.port)
                        serverEndpoint = FlowEndpoint(ip: dst.ip, port: dst.port)
                    }
                    if handshake.synTime == nil {
                        handshake.synTime = packet.timestamp
                    }
                    handshake.clientOptions = optionSummary(from: tcpPacket.options)
                    if let ws = tcpPacket.options.windowScale {
                        windowScaleByEndpoint[src] = ws
                    }
                    connectionState = .connecting
                } else if tcpPacket.flags.contains(.syn) && tcpPacket.flags.contains(.ack) {
                    if handshake.synAckTime == nil {
                        handshake.synAckTime = packet.timestamp
                        if let synTime = handshake.synTime {
                            handshake.synRtt = packet.timestamp.timeIntervalSince(synTime)
                        }
                    }
                    handshake.serverOptions = optionSummary(from: tcpPacket.options)
                    if let ws = tcpPacket.options.windowScale {
                        windowScaleByEndpoint[src] = ws
                    }
                }

                if tcpPacket.flags.contains(.ack),
                   handshake.synAckTime != nil,
                   handshake.ackTime == nil,
                   isClientEndpoint(src, client: clientEndpoint) {
                    handshake.ackTime = packet.timestamp
                    connectionState = .established
                }

                if tcpPacket.flags.contains(.fin) {
                    finSeen.insert(src)
                    if isClientEndpoint(src, client: clientEndpoint) {
                        termination.finFromClientTime = termination.finFromClientTime ?? packet.timestamp
                    } else {
                        termination.finFromServerTime = termination.finFromServerTime ?? packet.timestamp
                    }
                }

                if tcpPacket.flags.contains(.rst) {
                    rstSeen.insert(src)
                    if isClientEndpoint(src, client: clientEndpoint) {
                        termination.rstFromClientTime = termination.rstFromClientTime ?? packet.timestamp
                    } else {
                        termination.rstFromServerTime = termination.rstFromServerTime ?? packet.timestamp
                    }
                    connectionState = .reset
                }

                let context = MetricsUpdateContext(
                    src: src,
                    dst: dst,
                    tcpPacket: tcpPacket,
                    timestamp: packet.timestamp,
                    client: clientEndpoint,
                    server: serverEndpoint
                )
                let indicators = updateMetrics(
                    metrics: &metrics,
                    endpointTrackers: &endpointTrackers,
                    windowScaleByEndpoint: &windowScaleByEndpoint,
                    context: context
                )

                if packets.count < maxPacketSummaries {
                    let summary = buildPacketSummary(
                        src: src,
                        dst: dst,
                        ipPacket: ipPacket,
                        tcpPacket: tcpPacket,
                        timestamp: packet.timestamp,
                        client: clientEndpoint,
                        server: serverEndpoint,
                        indicators: indicators
                    )
                    packets.append(summary)
                }

                let outputs = reassembler.process(ipPacket: ipPacket, tcpPacket: tcpPacket)
                for output in outputs where !output.data.isEmpty {
                    let direction = directionForEndpoint(src, client: clientEndpoint, server: serverEndpoint, record: record)
                    if direction == .clientToServer || direction == .sourceToDestination {
                        if streamClientToServer.count < maxStreamBytes {
                            let remaining = maxStreamBytes - streamClientToServer.count
                            streamClientToServer.append(output.data.prefix(remaining))
                        }
                    } else {
                        if streamServerToClient.count < maxStreamBytes {
                            let remaining = maxStreamBytes - streamServerToClient.count
                            streamServerToClient.append(output.data.prefix(remaining))
                        }
                    }
                }
            }
        } catch ScanControl.reachedEndOfWindow {
            // Best-effort: stop scanning once we pass the connection's time window.
        } catch PCAPReaderError.truncatedRecord {
            // Best-effort: capture file may be actively written; treat trailing truncation as EOF.
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }

        guard didMatchAnyPacket else {
            throw PCAPFlowAnalyzerError.noPacketsForFlow
        }

        if connectionState == .unknown {
            if !rstSeen.isEmpty {
                connectionState = .reset
            } else if finSeen.count >= 2 {
                connectionState = .closed
            } else if handshake.synTime != nil && handshake.synAckTime == nil {
                connectionState = .halfOpen
            } else {
                connectionState = .closed
            }
        }

        if clientEndpoint == nil {
            clientEndpoint = record.clientEndpoint
            serverEndpoint = record.serverEndpoint
        }

        return ConnectionPCAPAnalysis(
            clientEndpoint: clientEndpoint,
            serverEndpoint: serverEndpoint,
            handshake: handshake.synTime == nil && handshake.synAckTime == nil ? nil : handshake,
            termination: termination.finFromClientTime == nil && termination.finFromServerTime == nil &&
                termination.rstFromClientTime == nil && termination.rstFromServerTime == nil ? nil : termination,
            state: connectionState,
            metrics: metrics,
            packets: packets,
            streamClientToServer: streamClientToServer,
            streamServerToClient: streamServerToClient
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func analyzeUDP(url: URL) throws -> ConnectionPCAPAnalysis {
        let reader = try PCAPReader(url: url)
        let endpointA = EndpointKey(ip: record.sourceIP, port: record.sourcePort)
        let endpointB = EndpointKey(ip: record.destinationIP, port: record.destinationPort)
        let window = scanWindow()

        var state = UDPAnalysisState()
        var didMatchAnyPacket = false

        do {
            try reader.forEachPacket { packet in
                if Task.isCancelled {
                    throw CancellationError()
                }

                if packet.timestamp < window.lowerBound {
                    return
                }
                if packet.timestamp > window.upperBound {
                    throw ScanControl.reachedEndOfWindow
                }

                guard let ipPacket = IPPacketParser.parse(packet.data) else { return }
                guard ipPacket.transport == .udp else { return }
                guard let udpPacket = UDPParser.parse(ipPacket.payload) else { return }

                let src = EndpointKey(ip: ipPacket.source.description, port: udpPacket.sourcePort)
                let dst = EndpointKey(ip: ipPacket.destination.description, port: udpPacket.destinationPort)
                guard (src == endpointA && dst == endpointB) || (src == endpointB && dst == endpointA) else { return }
                didMatchAnyPacket = true
                state.matchedDatagrams += 1

                let direction = directionForEndpoint(src, client: record.clientEndpoint, server: record.serverEndpoint, record: record)
                switch direction {
                case .clientToServer, .sourceToDestination:
                    state.sourceToDestinationDatagrams += 1
                case .serverToClient, .destinationToSource:
                    state.destinationToSourceDatagrams += 1
                }

                if ipPacket.isFragmented {
                    state.fragmentedDatagrams += 1
                }
                if udpPacket.length > state.maxDatagramLength {
                    state.maxDatagramLength = udpPacket.length
                }

                if state.packets.count < maxPacketSummaries {
                    state.packets.append(
                        UDPPacketSummary(
                            timestamp: packet.timestamp,
                            direction: direction,
                            sourceIP: src.ip,
                            destinationIP: dst.ip,
                            sourcePort: udpPacket.sourcePort,
                            destinationPort: udpPacket.destinationPort,
                            udpLength: udpPacket.length,
                            payloadLength: udpPacket.payload.count,
                            ipVersion: ipPacket.version,
                            hopLimit: ipPacket.hopLimit,
                            protocolNumber: ipPacket.protocolNumber,
                            ipHeaderLength: ipPacket.headerLength,
                            totalLength: ipPacket.totalLength,
                            fragmentOffset: ipPacket.fragmentOffset,
                            moreFragments: ipPacket.moreFragments
                        )
                    )
                }
            }
        } catch ScanControl.reachedEndOfWindow {
            // Best-effort: stop scanning once we pass the connection's time window.
        } catch PCAPReaderError.truncatedRecord {
            // Best-effort: capture file may be actively written; treat trailing truncation as EOF.
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }

        guard didMatchAnyPacket else {
            throw PCAPFlowAnalyzerError.noPacketsForFlow
        }

        let diagnostics = UDPPCAPDiagnostics(
            totalDatagrams: state.matchedDatagrams,
            sourceToDestinationDatagrams: state.sourceToDestinationDatagrams,
            destinationToSourceDatagrams: state.destinationToSourceDatagrams,
            fragmentedDatagrams: state.fragmentedDatagrams,
            maxDatagramLength: state.maxDatagramLength
        )

        let inferredState: FlowConnectionState = {
            if record.connectionState != .unknown {
                return record.connectionState
            }
            return record.isClosed ? .closed : .established
        }()

        return ConnectionPCAPAnalysis(
            clientEndpoint: record.clientEndpoint,
            serverEndpoint: record.serverEndpoint,
            handshake: nil,
            termination: nil,
            state: inferredState,
            metrics: TCPFlowMetrics(),
            packets: [],
            streamClientToServer: Data(),
            streamServerToClient: Data(),
            udpPackets: state.packets,
            udpDiagnostics: diagnostics
        )
    }

    private func scanWindow() -> TimeWindow {
        let timeSlack: TimeInterval = 15
        let lowerBound = min(record.startTime, record.lastSeen).addingTimeInterval(-timeSlack)
        let upperBound = max(record.startTime, record.lastSeen).addingTimeInterval(timeSlack)
        return TimeWindow(lowerBound: lowerBound, upperBound: upperBound)
    }

    private struct MetricsUpdateContext {
        let src: EndpointKey
        let dst: EndpointKey
        let tcpPacket: TCPPacket
        let timestamp: Date
        let client: FlowEndpoint?
        let server: FlowEndpoint?
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func updateMetrics(
        metrics: inout TCPFlowMetrics,
        endpointTrackers: inout [EndpointKey: EndpointTracker],
        windowScaleByEndpoint: inout [EndpointKey: UInt8],
        context: MetricsUpdateContext
    ) -> TCPPacketIndicators {
        let src = context.src
        let dst = context.dst
        let tcpPacket = context.tcpPacket
        let timestamp = context.timestamp
        let client = context.client
        let server = context.server

        var indicators = TCPPacketIndicators()
        var sender = endpointTrackers[src] ?? EndpointTracker()
        var receiver = endpointTrackers[dst] ?? EndpointTracker()
        let payloadBytes = UInt64(tcpPacket.payload.count)

        sender.metrics.bytes += payloadBytes
        sender.metrics.packets += 1

        indicators.isAckOnly = payloadBytes == 0 && tcpPacket.flags.contains(.ack)
        if tcpPacket.flags.contains(.ack) {
            if let lastAck = sender.lastAck,
               lastAck == tcpPacket.acknowledgmentNumber,
               indicators.isAckOnly {
                sender.metrics.duplicateAcks += 1
                indicators.isDupAck = true
            }
            sender.lastAck = tcpPacket.acknowledgmentNumber
        }

        let scale = UInt64(windowScaleByEndpoint[src] ?? 0)
        let scaledWindow = UInt64(tcpPacket.windowSize) << scale
        indicators.scaledWindow = scaledWindow
        sender.metrics.windowSamples += 1
        sender.metrics.windowSum += scaledWindow
        sender.metrics.windowMin = min(sender.metrics.windowMin ?? scaledWindow, scaledWindow)
        sender.metrics.windowMax = max(sender.metrics.windowMax ?? scaledWindow, scaledWindow)
        if scaledWindow == 0 {
            sender.metrics.zeroWindowEvents += 1
        }

        if payloadBytes > 0 {
            let seq = tcpPacket.sequenceNumber
            if sender.baseSeq == nil {
                sender.baseSeq = seq
            }
            let relativeSeq = seq &- (sender.baseSeq ?? seq)
            var isRetrans = false
            if let expected = sender.expectedSeq {
                if seq < expected {
                    isRetrans = true
                } else if seq > expected {
                    sender.metrics.outOfOrder += 1
                    indicators.isOutOfOrder = true
                } else {
                    sender.expectedSeq = seq &+ UInt32(payloadBytes)
                }
            } else {
                sender.expectedSeq = seq &+ UInt32(payloadBytes)
            }

            if !sender.recentSegments.isEmpty {
                let hit = sender.recentSegments.contains { $0.sequence == seq && $0.length == Int(payloadBytes) }
                if hit {
                    isRetrans = true
                }
            }

            if isRetrans {
                sender.metrics.retransmissions += 1
                indicators.isRetransmission = true
            }

            if sender.recentSegments.count < maxRecentSegments {
                sender.recentSegments.append(RecentSegment(sequence: seq, length: Int(payloadBytes)))
            } else {
                sender.recentSegments[sender.recentIndex] = RecentSegment(sequence: seq, length: Int(payloadBytes))
                sender.recentIndex = (sender.recentIndex + 1) % maxRecentSegments
            }

            let seqEnd = seq &+ UInt32(payloadBytes)
            sender.inflight.append((seqEnd, timestamp))
            if sender.inflight.count > maxInflightSegments {
                sender.inflight.removeFirst()
            }

            appendSeqSample(metrics: &metrics, src: src, sequence: relativeSeq, timestamp: timestamp, client: client, server: server)
            appendThroughputSample(metrics: &metrics, src: src, timestamp: timestamp, bytes: payloadBytes, sender: &sender, client: client, server: server)
        }

        if tcpPacket.flags.contains(.ack), !receiver.inflight.isEmpty {
            let acked = tcpPacket.acknowledgmentNumber
            var rttSample: FlowRTTSample?
            var remaining: [(UInt32, Date)] = []
            for (seqEnd, sendTime) in receiver.inflight {
                if seqEnd <= acked {
                    if rttSample == nil {
                        let rttMs = timestamp.timeIntervalSince(sendTime) * 1000.0
                        let direction = directionForEndpoint(dst, client: client, server: server, record: record)
                        rttSample = FlowRTTSample(timestamp: timestamp.timeIntervalSince1970, rttMillis: rttMs, direction: direction)
                    }
                } else {
                    remaining.append((seqEnd, sendTime))
                }
            }
            receiver.inflight = remaining
            if let sample = rttSample {
                metrics.rttSamples.append(sample)
                if metrics.rttSamples.count > maxRTTSamples {
                    metrics.rttSamples.removeFirst(metrics.rttSamples.count - maxRTTSamples)
                }
            }
        }

        endpointTrackers[src] = sender
        endpointTrackers[dst] = receiver

        let direction = directionForEndpoint(src, client: client, server: server, record: record)
        switch direction {
        case .clientToServer, .sourceToDestination:
            metrics.clientToServer = sender.metrics
        case .serverToClient, .destinationToSource:
            metrics.serverToClient = sender.metrics
        }

        return indicators
    }

    // swiftlint:disable:next function_parameter_count
    private func appendThroughputSample(
        metrics: inout TCPFlowMetrics,
        src: EndpointKey,
        timestamp: Date,
        bytes: UInt64,
        sender: inout EndpointTracker,
        client: FlowEndpoint?,
        server: FlowEndpoint?
    ) {
        let bucket = Int(timestamp.timeIntervalSince1970)
        if let current = sender.throughputBucketStart {
            if current == bucket {
                sender.throughputBucketBytes += bytes
            } else {
                let sample = FlowTimeSeriesSample(timestamp: TimeInterval(current), value: Double(sender.throughputBucketBytes))
                appendThroughputSample(metrics: &metrics, src: src, sample: sample, client: client, server: server)
                sender.throughputBucketStart = bucket
                sender.throughputBucketBytes = bytes
            }
        } else {
            sender.throughputBucketStart = bucket
            sender.throughputBucketBytes = bytes
        }
    }

    private func appendThroughputSample(
        metrics: inout TCPFlowMetrics,
        src: EndpointKey,
        sample: FlowTimeSeriesSample,
        client: FlowEndpoint?,
        server: FlowEndpoint?
    ) {
        let direction = directionForEndpoint(src, client: client, server: server, record: record)
        switch direction {
        case .clientToServer, .sourceToDestination:
            metrics.throughputClient.append(sample)
            if metrics.throughputClient.count > maxThroughputSamples {
                metrics.throughputClient.removeFirst(metrics.throughputClient.count - maxThroughputSamples)
            }
        case .serverToClient, .destinationToSource:
            metrics.throughputServer.append(sample)
            if metrics.throughputServer.count > maxThroughputSamples {
                metrics.throughputServer.removeFirst(metrics.throughputServer.count - maxThroughputSamples)
            }
        }
    }

    private func appendSeqSample(
        metrics: inout TCPFlowMetrics,
        src: EndpointKey,
        sequence: UInt32,
        timestamp: Date,
        client: FlowEndpoint?,
        server: FlowEndpoint?
    ) {
        let direction = directionForEndpoint(src, client: client, server: server, record: record)
        let sample = FlowSeqSample(timestamp: timestamp.timeIntervalSince1970, sequence: sequence)
        switch direction {
        case .clientToServer, .sourceToDestination:
            metrics.seqClient.append(sample)
            if metrics.seqClient.count > maxSequenceSamples {
                metrics.seqClient.removeFirst(metrics.seqClient.count - maxSequenceSamples)
            }
        case .serverToClient, .destinationToSource:
            metrics.seqServer.append(sample)
            if metrics.seqServer.count > maxSequenceSamples {
                metrics.seqServer.removeFirst(metrics.seqServer.count - maxSequenceSamples)
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func buildPacketSummary(
        src: EndpointKey,
        dst: EndpointKey,
        ipPacket: IPPacket,
        tcpPacket: TCPPacket,
        timestamp: Date,
        client: FlowEndpoint?,
        server: FlowEndpoint?,
        indicators: TCPPacketIndicators
    ) -> TCPPacketSummary {
        let direction = directionForEndpoint(src, client: client, server: server, record: record)
        return TCPPacketSummary(
            timestamp: timestamp,
            direction: direction,
            sequence: tcpPacket.sequenceNumber,
            acknowledgment: tcpPacket.acknowledgmentNumber,
            length: tcpPacket.payload.count,
            flags: tcpPacket.flags,
            window: tcpPacket.windowSize,
            isRetransmission: indicators.isRetransmission,
            isOutOfOrder: indicators.isOutOfOrder,
            isDupAck: indicators.isDupAck,
            isAckOnly: indicators.isAckOnly,
            sourceIP: src.ip,
            destinationIP: dst.ip,
            sourcePort: tcpPacket.sourcePort,
            destinationPort: tcpPacket.destinationPort,
            ipVersion: ipPacket.version,
            hopLimit: ipPacket.hopLimit,
            protocolNumber: ipPacket.protocolNumber,
            ipHeaderLength: ipPacket.headerLength,
            totalLength: ipPacket.totalLength,
            fragmentOffset: ipPacket.fragmentOffset,
            moreFragments: ipPacket.moreFragments,
            scaledWindow: indicators.scaledWindow
        )
    }

    private func directionForEndpoint(_ endpoint: EndpointKey, client: FlowEndpoint?, server: FlowEndpoint?, record: PacketFlowRecord) -> FlowDirection {
        if let client {
            if endpoint.ip == client.ip && endpoint.port == client.port {
                return .clientToServer
            }
            if let server, endpoint.ip == server.ip && endpoint.port == server.port {
                return .serverToClient
            }
        }
        if endpoint.ip == record.sourceIP && endpoint.port == record.sourcePort {
            return .sourceToDestination
        }
        return .destinationToSource
    }

    private func isClientEndpoint(_ endpoint: EndpointKey, client: FlowEndpoint?) -> Bool {
        guard let client else { return false }
        return endpoint.ip == client.ip && endpoint.port == client.port
    }

    private func optionSummary(from options: TCPPacket.Options) -> TCPOptionSummary {
        TCPOptionSummary(
            mss: options.mss,
            windowScale: options.windowScale,
            sackPermitted: options.sackPermitted,
            timestampsPermitted: options.timestamps != nil
        )
    }
}
