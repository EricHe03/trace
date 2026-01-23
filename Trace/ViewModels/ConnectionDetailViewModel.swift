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
}

@MainActor
final class ConnectionDetailViewModel: ObservableObject {
    @Published var record: PacketFlowRecord
    @Published var pcapFiles: [PCAPFileItem] = []
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var analysis: ConnectionPCAPAnalysis?

    init(record: PacketFlowRecord) {
        self.record = record
    }

    func refreshPCAPFiles() {
        let urls = AppGroupStorage.shared.packetCaptureFiles()
        pcapFiles = urls.map { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .uint64Value ?? 0
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return PCAPFileItem(url: url, size: size, modified: modified)
        }
    }

    func loadFromPCAP(_ file: PCAPFileItem) {
        isLoading = true
        loadError = nil

        Task.detached(priority: .utility) { [record] in
            do {
                let analyzer = try PCAPFlowAnalyzer(record: record)
                let analysis = try analyzer.analyze(url: file.url)
                await MainActor.run {
                    self.analysis = analysis
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

private final class PCAPFlowAnalyzer {
    private struct EndpointKey: Hashable {
        let ip: String
        let port: UInt16
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

        try reader.forEachPacket { packet in
            guard let ipPacket = IPPacketParser.parse(packet.data) else { return }
            guard ipPacket.transport == .tcp else { return }
            guard let tcpPacket = TCPParser.parse(ipPacket.payload) else { return }

            let src = EndpointKey(ip: ipPacket.source.description, port: tcpPacket.sourcePort)
            let dst = EndpointKey(ip: ipPacket.destination.description, port: tcpPacket.destinationPort)
            guard (src == endpointA && dst == endpointB) || (src == endpointB && dst == endpointA) else { return }

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

            updateMetrics(
                metrics: &metrics,
                endpointTrackers: &endpointTrackers,
                windowScaleByEndpoint: &windowScaleByEndpoint,
                src: src,
                dst: dst,
                tcpPacket: tcpPacket,
                timestamp: packet.timestamp,
                client: clientEndpoint,
                server: serverEndpoint
            )

            if packets.count < maxPacketSummaries {
                let summary = buildPacketSummary(
                    endpointTrackers: endpointTrackers,
                    src: src,
                    tcpPacket: tcpPacket,
                    timestamp: packet.timestamp,
                    client: clientEndpoint,
                    server: serverEndpoint
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

    private func updateMetrics(
        metrics: inout TCPFlowMetrics,
        endpointTrackers: inout [EndpointKey: EndpointTracker],
        windowScaleByEndpoint: inout [EndpointKey: UInt8],
        src: EndpointKey,
        dst: EndpointKey,
        tcpPacket: TCPPacket,
        timestamp: Date,
        client: FlowEndpoint?,
        server: FlowEndpoint?
    ) {
        var sender = endpointTrackers[src] ?? EndpointTracker()
        var receiver = endpointTrackers[dst] ?? EndpointTracker()
        let payloadBytes = UInt64(tcpPacket.payload.count)

        sender.metrics.bytes += payloadBytes
        sender.metrics.packets += 1

        let isAckOnly = payloadBytes == 0 && tcpPacket.flags.contains(.ack)
        if tcpPacket.flags.contains(.ack) {
            if let lastAck = sender.lastAck, lastAck == tcpPacket.acknowledgmentNumber, isAckOnly {
                sender.metrics.duplicateAcks += 1
            }
            sender.lastAck = tcpPacket.acknowledgmentNumber
        }

        let scale = UInt64(windowScaleByEndpoint[src] ?? 0)
        let scaledWindow = UInt64(tcpPacket.windowSize) << scale
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
    }

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

    private func buildPacketSummary(
        endpointTrackers: [EndpointKey: EndpointTracker],
        src: EndpointKey,
        tcpPacket: TCPPacket,
        timestamp: Date,
        client: FlowEndpoint?,
        server: FlowEndpoint?
    ) -> TCPPacketSummary {
        let direction = directionForEndpoint(src, client: client, server: server, record: record)
        let tracker = endpointTrackers[src]
        let isDupAck = tracker?.lastAck == tcpPacket.acknowledgmentNumber &&
            tcpPacket.payload.isEmpty &&
            tcpPacket.flags.contains(.ack)
        return TCPPacketSummary(
            timestamp: timestamp,
            direction: direction,
            sequence: tcpPacket.sequenceNumber,
            acknowledgment: tcpPacket.acknowledgmentNumber,
            length: tcpPacket.payload.count,
            flags: tcpPacket.flags,
            window: tcpPacket.windowSize,
            isRetransmission: false,
            isOutOfOrder: false,
            isDupAck: isDupAck
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
