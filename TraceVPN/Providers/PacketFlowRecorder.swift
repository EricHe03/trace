//
//  PacketFlowRecorder.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/20.
//

import Foundation
import OSLog
import TraceCore
import TracePacket
import TraceSecurity

private struct EndpointKey: Hashable, Sendable {
    let ip: IPAddress
    let port: UInt16

    var description: String {
        "\(ip):\(port)"
    }
}

private struct ConnectionKey: Hashable, Sendable {
    let a: EndpointKey
    let b: EndpointKey
    let transport: FlowTransportProtocol

    init(srcIP: IPAddress, srcPort: UInt16, dstIP: IPAddress, dstPort: UInt16, transport: FlowTransportProtocol) {
        let left = EndpointKey(ip: srcIP, port: srcPort)
        let right = EndpointKey(ip: dstIP, port: dstPort)
        if ConnectionKey.orderKey(left, transport: transport) <= ConnectionKey.orderKey(right, transport: transport) {
            self.a = left
            self.b = right
        } else {
            self.a = right
            self.b = left
        }
        self.transport = transport
    }

    private static func orderKey(_ endpoint: EndpointKey, transport: FlowTransportProtocol) -> String {
        "\(transport.rawValue):\(endpoint.ip.description):\(endpoint.port)"
    }
}

final class PacketFlowRecorder {
    private struct RecentSegment {
        let sequence: UInt32
        let length: Int
        let timestamp: Date
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

    private struct FlowState {
        var record: PacketFlowRecord
        var source: EndpointKey
        var lastFlush: Date
        var lastSeen: Date
        var didParseTLS: Bool
        var tlsProbeBuffer: Data
        var didParseHTTP: Bool
        var endpointTrackers: [EndpointKey: EndpointTracker]
        var windowScaleByEndpoint: [EndpointKey: UInt8]
        var finSeenByEndpoint: Set<EndpointKey>
        var rstSeenByEndpoint: Set<EndpointKey>
    }

    private let queue = DispatchQueue(label: "com.trace.vpn.packet_flow_recorder", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private var flows: [ConnectionKey: FlowState] = [:]
    private let idleTimeout: TimeInterval
    private let flushInterval: TimeInterval
    private let maxFlows: Int
    private let logSampler = LogSampler()
    private let maxRecentSegments = 128
    private let maxInflightSegments = 128
    private let maxRTTSamples = 120
    private let maxThroughputSamples = 120
    private let maxSequenceSamples = 240
    private let maxTLSProbeBytes = 32 * 1024

    init(
        idleTimeout: TimeInterval = 60,
        flushInterval: TimeInterval = 2,
        maxFlows: Int = 4096
    ) {
        self.idleTimeout = idleTimeout
        self.flushInterval = flushInterval
        self.maxFlows = max(1, maxFlows)
        queue.setSpecific(key: queueKey, value: ())
    }

    func shutdown() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            shutdownOnQueue()
            return
        }
        queue.sync { [weak self] in
            self?.shutdownOnQueue()
        }
    }

    func process(ipPacket: IPPacket) {
        queue.async { [weak self] in
            guard let self else { return }
            switch ipPacket.transport {
            case .tcp:
                guard let tcpPacket = TCPParser.parse(ipPacket.payload) else { return }
                self.processTCP(ipPacket: ipPacket, tcpPacket: tcpPacket)
            case .udp:
                guard let udpPacket = UDPParser.parse(ipPacket.payload) else { return }
                self.processUDP(ipPacket: ipPacket, udpPacket: udpPacket)
            case .none:
                break
            }
        }
    }

    func processReassembled(flow: FlowKey, data: Data, isFinal: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = ConnectionKey(
                srcIP: flow.sourceIP,
                srcPort: flow.sourcePort,
                dstIP: flow.destinationIP,
                dstPort: flow.destinationPort,
                transport: .tcp
            )
            guard var state = self.flows[key] else { return }

            if !data.isEmpty {
                if !state.didParseTLS {
                    self.appendTLSProbeData(data, to: &state)
                    if let clientHello = self.tlsClientHelloCandidate(in: state.tlsProbeBuffer) {
                        let sni = TLSHandler.extractSNI(from: clientHello)
                        let alpn = TLSHandler.extractALPN(from: clientHello)
                        if sni != nil || alpn != nil {
                            state.record.tlsSNI = sni ?? state.record.tlsSNI
                            state.record.alpn = alpn ?? state.record.alpn
                            state.record.protocolHints = self.mergeHint(.tls, into: state.record.protocolHints)
                            state.didParseTLS = true
                            state.tlsProbeBuffer.removeAll(keepingCapacity: false)
                            self.flushIfNeeded(state: &state, force: true)
                        } else if state.tlsProbeBuffer.count >= self.maxTLSProbeBytes {
                            state.didParseTLS = true
                            state.tlsProbeBuffer.removeAll(keepingCapacity: false)
                        }
                    } else if state.tlsProbeBuffer.count >= self.maxTLSProbeBytes {
                        state.didParseTLS = true
                        state.tlsProbeBuffer.removeAll(keepingCapacity: false)
                    }
                }

                if !state.didParseHTTP, self.looksLikeHTTP(data) {
                    state.record.protocolHints = self.mergeHint(.http, into: state.record.protocolHints)
                    state.didParseHTTP = true
                    self.flushIfNeeded(state: &state, force: true)
                }
            }

            if isFinal {
                self.markStateClosedForFinalization(state: &state)
                self.flush(state: &state)
                self.flows.removeValue(forKey: key)
                return
            }

            self.flows[key] = state
        }
    }

    private func processTCP(ipPacket: IPPacket, tcpPacket: TCPPacket) {
        evictExpired(now: Date())
        let now = Date()

        let key = ConnectionKey(
            srcIP: ipPacket.source,
            srcPort: tcpPacket.sourcePort,
            dstIP: ipPacket.destination,
            dstPort: tcpPacket.destinationPort,
            transport: .tcp
        )

        var state = flows[key] ?? createFlowState(
            ipPacket: ipPacket,
            sourcePort: tcpPacket.sourcePort,
            destinationPort: tcpPacket.destinationPort,
            transport: .tcp
        )

        let isFromSource = ipPacket.source == state.source.ip && tcpPacket.sourcePort == state.source.port
        let payloadBytes = UInt64(tcpPacket.payload.count)
        if isFromSource {
            state.record.bytesFromSource += payloadBytes
            state.record.packetsFromSource += 1
        } else {
            state.record.bytesToSource += payloadBytes
            state.record.packetsToSource += 1
        }

        state.record.lastSeen = now
        state.lastSeen = state.record.lastSeen
        state.record.lastSequenceNumber = tcpPacket.sequenceNumber
        state.record.lastAcknowledgmentNumber = tcpPacket.acknowledgmentNumber
        state.record.lastPacketTimestamp = now
        state.record.lastPacketLength = ipPacket.totalLength

        updateTCPHandshake(state: &state, sender: ipPacket.source, senderPort: tcpPacket.sourcePort, receiver: ipPacket.destination, receiverPort: tcpPacket.destinationPort, tcpPacket: tcpPacket, timestamp: now)
        updateTCPTermination(state: &state, sender: ipPacket.source, senderPort: tcpPacket.sourcePort, tcpPacket: tcpPacket, timestamp: now)
        updateTCPMetrics(state: &state, sender: ipPacket.source, senderPort: tcpPacket.sourcePort, receiver: ipPacket.destination, receiverPort: tcpPacket.destinationPort, tcpPacket: tcpPacket, timestamp: now)
        updateConnectionState(state: &state)

        if tcpPacket.flags.contains(.rst) || shouldCloseAfterFIN(state: state) {
            state.record.isClosed = true
            flush(state: &state)
            flows.removeValue(forKey: key)
            return
        }

        flushIfNeeded(state: &state, force: false)
        flows[key] = state
    }

    private func processUDP(ipPacket: IPPacket, udpPacket: UDPPacket) {
        evictExpired(now: Date())
        let now = Date()

        let key = ConnectionKey(
            srcIP: ipPacket.source,
            srcPort: udpPacket.sourcePort,
            dstIP: ipPacket.destination,
            dstPort: udpPacket.destinationPort,
            transport: .udp
        )

        var state = flows[key] ?? createFlowState(
            ipPacket: ipPacket,
            sourcePort: udpPacket.sourcePort,
            destinationPort: udpPacket.destinationPort,
            transport: .udp
        )

        let isFromSource = ipPacket.source == state.source.ip && udpPacket.sourcePort == state.source.port
        let payloadBytes = UInt64(udpPacket.payload.count)
        if isFromSource {
            state.record.bytesFromSource += payloadBytes
            state.record.packetsFromSource += 1
        } else {
            state.record.bytesToSource += payloadBytes
            state.record.packetsToSource += 1
        }

        if udpPacket.destinationPort == 443 || udpPacket.sourcePort == 443 {
            state.record.protocolHints = mergeHint(.quic, into: state.record.protocolHints)
        }

        state.record.lastSeen = now
        state.lastSeen = state.record.lastSeen
        state.record.lastPacketTimestamp = now
        state.record.lastPacketLength = ipPacket.totalLength
        flushIfNeeded(state: &state, force: false)
        flows[key] = state
    }

    private func createFlowState(
        ipPacket: IPPacket,
        sourcePort: UInt16,
        destinationPort: UInt16,
        transport: FlowTransportProtocol
    ) -> FlowState {
        if flows.count >= maxFlows {
            evictExpired(now: Date())
            if flows.count >= maxFlows {
                evictOldestFlow()
            }
        }

        let source = EndpointKey(ip: ipPacket.source, port: sourcePort)
        let protocolHints: [FlowProtocolHint] = transport == .tcp && (destinationPort == 443 || sourcePort == 443) ? [.tls] : []

        let record = PacketFlowRecord(
            sourceIP: ipPacket.source.description,
            destinationIP: ipPacket.destination.description,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            transport: transport,
            protocolHints: protocolHints,
            startTime: Date(),
            lastSeen: Date(),
            isClosed: false
        )

        return FlowState(
            record: record,
            source: source,
            lastFlush: Date(),
            lastSeen: Date(),
            didParseTLS: false,
            tlsProbeBuffer: Data(),
            didParseHTTP: false,
            endpointTrackers: [:],
            windowScaleByEndpoint: [:],
            finSeenByEndpoint: [],
            rstSeenByEndpoint: []
        )
    }

    private func flushIfNeeded(state: inout FlowState, force: Bool) {
        let now = Date()
        if force || now.timeIntervalSince(state.lastFlush) >= flushInterval {
            flush(state: &state)
        }
    }

    private func flush(state: inout FlowState) {
        do {
            try AppGroupStorage.shared.savePacketFlowRecord(state.record)
            state.lastFlush = Date()
        } catch {
            if logSampler.shouldLog(event: "vpn.packet_flow_store", key: "write_failure", first: 3, every: 200) {
                VPNLog.tunnel.warning("event=vpn.packet_flow_store outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func shutdownOnQueue() {
        guard !flows.isEmpty else { return }
        for key in Array(flows.keys) {
            guard var state = flows[key] else { continue }
            markStateClosedForFinalization(state: &state)
            flush(state: &state)
        }
        flows.removeAll(keepingCapacity: false)
    }

    private func evictExpired(now: Date) {
        guard !flows.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-idleTimeout)
        var expiredKeys: [ConnectionKey] = []
        for (key, state) in flows where state.lastSeen < cutoff {
            expiredKeys.append(key)
        }
        for key in expiredKeys {
            if var state = flows[key] {
                markStateClosedForTimeout(state: &state)
                flush(state: &state)
            }
            flows.removeValue(forKey: key)
        }
    }

    private func evictOldestFlow() {
        guard let oldest = flows.min(by: { $0.value.lastSeen < $1.value.lastSeen }) else { return }
        guard var state = flows[oldest.key] else { return }
        markStateClosedForTimeout(state: &state)
        flush(state: &state)
        flows.removeValue(forKey: oldest.key)
    }

    private func mergeHint(_ hint: FlowProtocolHint, into list: [FlowProtocolHint]) -> [FlowProtocolHint] {
        if list.contains(hint) {
            return list
        }
        return list + [hint]
    }

    private func markStateClosedForFinalization(state: inout FlowState) {
        state.record.isClosed = true
        guard state.record.transport == .tcp else { return }
        if state.record.connectionState == .unknown || state.record.connectionState == .connecting {
            state.record.connectionState = .halfOpen
        } else if state.record.connectionState == .established {
            state.record.connectionState = .closed
        }
    }

    private func markStateClosedForTimeout(state: inout FlowState) {
        state.record.isClosed = true
        guard state.record.transport == .tcp else { return }
        if state.record.connectionState == .unknown || state.record.connectionState == .connecting {
            state.record.connectionState = .halfOpen
        } else if state.record.connectionState == .established {
            state.record.connectionState = .timedOut
        }
    }

    private func appendTLSProbeData(_ data: Data, to state: inout FlowState) {
        guard !data.isEmpty else { return }
        let remaining = max(0, maxTLSProbeBytes - state.tlsProbeBuffer.count)
        guard remaining > 0 else { return }
        state.tlsProbeBuffer.append(data.prefix(remaining))
    }

    private func tlsClientHelloCandidate(in data: Data) -> Data? {
        guard data.count >= 6 else { return nil }
        if looksLikeTLSClientHello(data) {
            return data
        }

        let maxOffset = data.count - 6
        if maxOffset <= 0 {
            return nil
        }
        for offset in 1 ... maxOffset {
            let candidate = Data(data.dropFirst(offset))
            if looksLikeTLSClientHello(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func looksLikeTLSClientHello(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        let bytes = [UInt8](data.prefix(6))
        guard bytes[0] == 0x16 else { return false }
        guard bytes[1] == 0x03 else { return false }
        return bytes[5] == 0x01
    }

    private func looksLikeHTTP(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let prefixes = ["GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT "]
        if let prefix = String(data: data.prefix(8), encoding: .ascii) {
            return prefixes.contains { prefix.hasPrefix($0) }
        }
        return false
    }

    private func updateTCPHandshake(
        state: inout FlowState,
        sender: IPAddress,
        senderPort: UInt16,
        receiver: IPAddress,
        receiverPort: UInt16,
        tcpPacket: TCPPacket,
        timestamp: Date
    ) {
        guard tcpPacket.flags.contains(.syn) else { return }
        let senderKey = EndpointKey(ip: sender, port: senderPort)
        let receiverKey = EndpointKey(ip: receiver, port: receiverPort)
        if state.record.tcpHandshake == nil {
            state.record.tcpHandshake = TCPHandshakeSummary()
        }

        if tcpPacket.flags.contains(.ack) {
            if state.record.tcpHandshake?.synAckTime == nil {
                state.record.tcpHandshake?.synAckTime = timestamp
                if let synTime = state.record.tcpHandshake?.synTime {
                    state.record.tcpHandshake?.synRtt = timestamp.timeIntervalSince(synTime)
                }
            }
            state.record.tcpHandshake?.serverOptions = optionSummary(from: tcpPacket.options)
            if let windowScale = tcpPacket.options.windowScale {
                state.windowScaleByEndpoint[senderKey] = windowScale
            }
            if state.record.clientEndpoint == nil {
                state.record.clientEndpoint = FlowEndpoint(ip: receiver.description, port: receiverPort)
                state.record.serverEndpoint = FlowEndpoint(ip: sender.description, port: senderPort)
            }
        } else {
            if state.record.tcpHandshake?.synTime == nil {
                state.record.tcpHandshake?.synTime = timestamp
            }
            state.record.tcpHandshake?.clientOptions = optionSummary(from: tcpPacket.options)
            if let windowScale = tcpPacket.options.windowScale {
                state.windowScaleByEndpoint[senderKey] = windowScale
            }
            if state.record.clientEndpoint == nil {
                state.record.clientEndpoint = FlowEndpoint(ip: sender.description, port: senderPort)
                state.record.serverEndpoint = FlowEndpoint(ip: receiver.description, port: receiverPort)
            }
        }

        state.record.connectionState = .connecting
    }

    private func updateTCPTermination(
        state: inout FlowState,
        sender: IPAddress,
        senderPort: UInt16,
        tcpPacket: TCPPacket,
        timestamp: Date
    ) {
        let senderKey = EndpointKey(ip: sender, port: senderPort)
        if state.record.tcpTermination == nil {
            state.record.tcpTermination = TCPTerminationSummary()
        }

        if tcpPacket.flags.contains(.fin) {
            state.finSeenByEndpoint.insert(senderKey)
            if isClientEndpoint(state: state, endpoint: senderKey) {
                if state.record.tcpTermination?.finFromClientTime == nil {
                    state.record.tcpTermination?.finFromClientTime = timestamp
                }
            } else {
                if state.record.tcpTermination?.finFromServerTime == nil {
                    state.record.tcpTermination?.finFromServerTime = timestamp
                }
            }
        }

        if tcpPacket.flags.contains(.rst) {
            state.rstSeenByEndpoint.insert(senderKey)
            if isClientEndpoint(state: state, endpoint: senderKey) {
                if state.record.tcpTermination?.rstFromClientTime == nil {
                    state.record.tcpTermination?.rstFromClientTime = timestamp
                }
            } else {
                if state.record.tcpTermination?.rstFromServerTime == nil {
                    state.record.tcpTermination?.rstFromServerTime = timestamp
                }
            }
            state.record.connectionState = .reset
        }
    }

    private func updateTCPMetrics(
        state: inout FlowState,
        sender: IPAddress,
        senderPort: UInt16,
        receiver: IPAddress,
        receiverPort: UInt16,
        tcpPacket: TCPPacket,
        timestamp: Date
    ) {
        let senderKey = EndpointKey(ip: sender, port: senderPort)
        let receiverKey = EndpointKey(ip: receiver, port: receiverPort)
        var senderTracker = state.endpointTrackers[senderKey] ?? EndpointTracker()
        var receiverTracker = state.endpointTrackers[receiverKey] ?? EndpointTracker()

        let payloadBytes = UInt64(tcpPacket.payload.count)
        senderTracker.metrics.bytes += payloadBytes
        senderTracker.metrics.packets += 1

        let isAckOnly = payloadBytes == 0 && tcpPacket.flags.contains(.ack)
        if tcpPacket.flags.contains(.ack) {
            if let lastAck = senderTracker.lastAck, lastAck == tcpPacket.acknowledgmentNumber, isAckOnly {
                senderTracker.metrics.duplicateAcks += 1
            }
            senderTracker.lastAck = tcpPacket.acknowledgmentNumber
            if state.record.tcpHandshake?.synAckTime != nil,
               state.record.tcpHandshake?.ackTime == nil,
               isClientEndpoint(state: state, endpoint: senderKey) {
                state.record.tcpHandshake?.ackTime = timestamp
                state.record.connectionState = .established
            }
        }

        let scale = UInt64(state.windowScaleByEndpoint[senderKey] ?? 0)
        let scaledWindow = UInt64(tcpPacket.windowSize) << scale
        senderTracker.metrics.windowSamples += 1
        senderTracker.metrics.windowSum += scaledWindow
        senderTracker.metrics.windowMin = min(senderTracker.metrics.windowMin ?? scaledWindow, scaledWindow)
        senderTracker.metrics.windowMax = max(senderTracker.metrics.windowMax ?? scaledWindow, scaledWindow)
        if scaledWindow == 0 {
            senderTracker.metrics.zeroWindowEvents += 1
        }

        if payloadBytes > 0 {
            let seq = tcpPacket.sequenceNumber
            if senderTracker.baseSeq == nil {
                senderTracker.baseSeq = seq
            }
            var isRetrans = false
            if let expected = senderTracker.expectedSeq {
                if seq < expected {
                    isRetrans = true
                } else if seq > expected {
                    senderTracker.metrics.outOfOrder += 1
                } else {
                    senderTracker.expectedSeq = seq &+ UInt32(payloadBytes)
                }
            } else {
                senderTracker.expectedSeq = seq &+ UInt32(payloadBytes)
            }

            if !senderTracker.recentSegments.isEmpty {
                let hit = senderTracker.recentSegments.contains { $0.sequence == seq && $0.length == Int(payloadBytes) }
                if hit {
                    isRetrans = true
                }
            }

            if isRetrans {
                senderTracker.metrics.retransmissions += 1
            }

            if senderTracker.recentSegments.count < maxRecentSegments {
                senderTracker.recentSegments.append(RecentSegment(sequence: seq, length: Int(payloadBytes), timestamp: timestamp))
            } else {
                senderTracker.recentSegments[senderTracker.recentIndex] = RecentSegment(sequence: seq, length: Int(payloadBytes), timestamp: timestamp)
                senderTracker.recentIndex = (senderTracker.recentIndex + 1) % maxRecentSegments
            }

            let seqEnd = seq &+ UInt32(payloadBytes)
            senderTracker.inflight.append((seqEnd, timestamp))
            if senderTracker.inflight.count > maxInflightSegments {
                senderTracker.inflight.removeFirst()
            }

            appendSeqSample(state: &state, senderKey: senderKey, tracker: &senderTracker, timestamp: timestamp, sequence: seq)
            appendThroughputSample(state: &state, senderKey: senderKey, tracker: &senderTracker, timestamp: timestamp, bytes: payloadBytes)
        }

        if tcpPacket.flags.contains(.ack) {
            let acked = tcpPacket.acknowledgmentNumber
            if !receiverTracker.inflight.isEmpty {
                var rttSample: FlowRTTSample?
                var remaining: [(UInt32, Date)] = []
                for (seqEnd, sendTime) in receiverTracker.inflight {
                    if seqEnd <= acked {
                        if rttSample == nil {
                            let rttMs = timestamp.timeIntervalSince(sendTime) * 1000.0
                            let direction = directionForEndpoint(state: state, endpoint: receiverKey)
                            rttSample = FlowRTTSample(timestamp: timestamp.timeIntervalSince1970, rttMillis: rttMs, direction: direction)
                        }
                    } else {
                        remaining.append((seqEnd, sendTime))
                    }
                }
                receiverTracker.inflight = remaining
                if let sample = rttSample {
                    appendRTTSample(state: &state, sample: sample)
                }
            }
        }

        state.endpointTrackers[senderKey] = senderTracker
        state.endpointTrackers[receiverKey] = receiverTracker
        updateRecordDirectionalMetrics(state: &state)
    }

    private func updateRecordDirectionalMetrics(state: inout FlowState) {
        var metrics = state.record.tcpMetrics ?? TCPFlowMetrics()

        if let client = state.record.clientEndpoint, let server = state.record.serverEndpoint {
            if let clientEntry = state.endpointTrackers.first(where: { key, _ in
                key.ip.description == client.ip && key.port == client.port
            }) {
                metrics.clientToServer = clientEntry.value.metrics
            }
            if let serverEntry = state.endpointTrackers.first(where: { key, _ in
                key.ip.description == server.ip && key.port == server.port
            }) {
                metrics.serverToClient = serverEntry.value.metrics
            }
        } else {
            if let sourceEntry = state.endpointTrackers.first(where: { key, _ in
                key.ip.description == state.record.sourceIP && key.port == state.record.sourcePort
            }) {
                metrics.clientToServer = sourceEntry.value.metrics
            }
            if let destEntry = state.endpointTrackers.first(where: { key, _ in
                key.ip.description == state.record.destinationIP && key.port == state.record.destinationPort
            }) {
                metrics.serverToClient = destEntry.value.metrics
            }
        }

        state.record.tcpMetrics = metrics
    }

    private func updateConnectionState(state: inout FlowState) {
        if state.record.connectionState == .reset {
            return
        }
        if shouldCloseAfterFIN(state: state) {
            state.record.connectionState = .closed
            return
        }

        guard let handshake = state.record.tcpHandshake else {
            return
        }
        if handshake.synTime != nil && handshake.synAckTime != nil {
            if handshake.ackTime != nil {
                state.record.connectionState = .established
            } else {
                state.record.connectionState = .connecting
            }
        }
    }

    private func shouldCloseAfterFIN(state: FlowState) -> Bool {
        if !state.rstSeenByEndpoint.isEmpty {
            return true
        }
        if let client = state.record.clientEndpoint, let server = state.record.serverEndpoint {
            let clientSeen = state.finSeenByEndpoint.contains { endpoint in
                endpoint.ip.description == client.ip && endpoint.port == client.port
            }
            let serverSeen = state.finSeenByEndpoint.contains { endpoint in
                endpoint.ip.description == server.ip && endpoint.port == server.port
            }
            return clientSeen && serverSeen
        }
        return state.finSeenByEndpoint.count >= 2
    }

    private func appendRTTSample(state: inout FlowState, sample: FlowRTTSample) {
        var metrics = state.record.tcpMetrics ?? TCPFlowMetrics()
        metrics.rttSamples.append(sample)
        if metrics.rttSamples.count > maxRTTSamples {
            metrics.rttSamples.removeFirst(metrics.rttSamples.count - maxRTTSamples)
        }
        state.record.tcpMetrics = metrics
    }

    private func appendThroughputSample(
        state: inout FlowState,
        senderKey: EndpointKey,
        tracker: inout EndpointTracker,
        timestamp: Date,
        bytes: UInt64
    ) {
        let bucket = Int(timestamp.timeIntervalSince1970)
        if let current = tracker.throughputBucketStart {
            if current == bucket {
                tracker.throughputBucketBytes += bytes
            } else {
                let sample = FlowTimeSeriesSample(timestamp: TimeInterval(current), value: Double(tracker.throughputBucketBytes))
                appendThroughputSample(state: &state, senderKey: senderKey, sample: sample)
                tracker.throughputBucketStart = bucket
                tracker.throughputBucketBytes = bytes
            }
        } else {
            tracker.throughputBucketStart = bucket
            tracker.throughputBucketBytes = bytes
        }
    }

    private func appendThroughputSample(state: inout FlowState, senderKey: EndpointKey, sample: FlowTimeSeriesSample) {
        var metrics = state.record.tcpMetrics ?? TCPFlowMetrics()
        let direction = directionForEndpoint(state: state, endpoint: senderKey)
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
        state.record.tcpMetrics = metrics
    }

    private func appendSeqSample(
        state: inout FlowState,
        senderKey: EndpointKey,
        tracker: inout EndpointTracker,
        timestamp: Date,
        sequence: UInt32
    ) {
        if let last = tracker.lastSeqSampleTime, timestamp.timeIntervalSince(last) < 0.2 {
            return
        }
        tracker.lastSeqSampleTime = timestamp
        let base = tracker.baseSeq ?? sequence
        let relative = sequence &- base
        let sample = FlowSeqSample(timestamp: timestamp.timeIntervalSince1970, sequence: relative)
        var metrics = state.record.tcpMetrics ?? TCPFlowMetrics()
        let direction = directionForEndpoint(state: state, endpoint: senderKey)
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
        state.record.tcpMetrics = metrics
    }

    private func directionForEndpoint(state: FlowState, endpoint: EndpointKey) -> FlowDirection {
        if let client = state.record.clientEndpoint, let server = state.record.serverEndpoint {
            if endpoint.ip.description == client.ip && endpoint.port == client.port {
                return .clientToServer
            }
            if endpoint.ip.description == server.ip && endpoint.port == server.port {
                return .serverToClient
            }
        }
        if endpoint.ip.description == state.record.sourceIP && endpoint.port == state.record.sourcePort {
            return .sourceToDestination
        }
        return .destinationToSource
    }

    private func isClientEndpoint(state: FlowState, endpoint: EndpointKey) -> Bool {
        guard let client = state.record.clientEndpoint else { return false }
        return endpoint.ip.description == client.ip && endpoint.port == client.port
    }

    private func optionSummary(from options: TCPPacket.Options) -> TCPOptionSummary {
        TCPOptionSummary(
            mss: options.mss,
            windowScale: options.windowScale,
            sackPermitted: options.sackPermitted,
            timestampsPermitted: options.timestamps != nil
        )
    }

    func activeFlowCountForTesting() -> Int {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return flows.count
        }
        return queue.sync { flows.count }
    }
}
