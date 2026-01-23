//
//  PacketFlowRecord.swift
//  TraceCore
//
//  Created by Justin on 2026/01/20.
//

import Foundation

public enum FlowTransportProtocol: String, Codable, Sendable {
    case tcp
    case udp
    case unknown
}

public enum FlowProtocolHint: String, Codable, Sendable {
    case http
    case tls
    case quic
    case unknown
}

public enum FlowConnectionState: String, Codable, Sendable {
    case unknown
    case connecting
    case established
    case closed
    case reset
    case halfOpen
    case timedOut
}

public enum FlowDirection: String, Codable, Sendable {
    case clientToServer
    case serverToClient
    case sourceToDestination
    case destinationToSource
}

public struct FlowEndpoint: Codable, Sendable, Hashable {
    public let ip: String
    public let port: UInt16

    public init(ip: String, port: UInt16) {
        self.ip = ip
        self.port = port
    }
}

public struct TCPOptionSummary: Codable, Sendable {
    public let mss: UInt16?
    public let windowScale: UInt8?
    public let sackPermitted: Bool
    public let timestampsPermitted: Bool

    public init(
        mss: UInt16? = nil,
        windowScale: UInt8? = nil,
        sackPermitted: Bool = false,
        timestampsPermitted: Bool = false
    ) {
        self.mss = mss
        self.windowScale = windowScale
        self.sackPermitted = sackPermitted
        self.timestampsPermitted = timestampsPermitted
    }
}

public struct TCPHandshakeSummary: Codable, Sendable {
    public var synTime: Date?
    public var synAckTime: Date?
    public var ackTime: Date?
    public var synRtt: TimeInterval?
    public var clientOptions: TCPOptionSummary?
    public var serverOptions: TCPOptionSummary?

    public init(
        synTime: Date? = nil,
        synAckTime: Date? = nil,
        ackTime: Date? = nil,
        synRtt: TimeInterval? = nil,
        clientOptions: TCPOptionSummary? = nil,
        serverOptions: TCPOptionSummary? = nil
    ) {
        self.synTime = synTime
        self.synAckTime = synAckTime
        self.ackTime = ackTime
        self.synRtt = synRtt
        self.clientOptions = clientOptions
        self.serverOptions = serverOptions
    }
}

public struct TCPTerminationSummary: Codable, Sendable {
    public var finFromClientTime: Date?
    public var finFromServerTime: Date?
    public var rstFromClientTime: Date?
    public var rstFromServerTime: Date?

    public init(
        finFromClientTime: Date? = nil,
        finFromServerTime: Date? = nil,
        rstFromClientTime: Date? = nil,
        rstFromServerTime: Date? = nil
    ) {
        self.finFromClientTime = finFromClientTime
        self.finFromServerTime = finFromServerTime
        self.rstFromClientTime = rstFromClientTime
        self.rstFromServerTime = rstFromServerTime
    }
}

public struct FlowDirectionalStats: Codable, Sendable {
    public var bytes: UInt64
    public var packets: UInt64
    public var retransmissions: UInt64
    public var duplicateAcks: UInt64
    public var outOfOrder: UInt64
    public var zeroWindowEvents: UInt64
    public var windowSum: UInt64
    public var windowSamples: UInt64
    public var windowMin: UInt64?
    public var windowMax: UInt64?

    public init(
        bytes: UInt64 = 0,
        packets: UInt64 = 0,
        retransmissions: UInt64 = 0,
        duplicateAcks: UInt64 = 0,
        outOfOrder: UInt64 = 0,
        zeroWindowEvents: UInt64 = 0,
        windowSum: UInt64 = 0,
        windowSamples: UInt64 = 0,
        windowMin: UInt64? = nil,
        windowMax: UInt64? = nil
    ) {
        self.bytes = bytes
        self.packets = packets
        self.retransmissions = retransmissions
        self.duplicateAcks = duplicateAcks
        self.outOfOrder = outOfOrder
        self.zeroWindowEvents = zeroWindowEvents
        self.windowSum = windowSum
        self.windowSamples = windowSamples
        self.windowMin = windowMin
        self.windowMax = windowMax
    }

    public var windowAverage: UInt64? {
        guard windowSamples > 0 else { return nil }
        return windowSum / windowSamples
    }
}

public struct FlowTimeSeriesSample: Codable, Sendable {
    public let timestamp: TimeInterval
    public let value: Double

    public init(timestamp: TimeInterval, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

public struct FlowSeqSample: Codable, Sendable {
    public let timestamp: TimeInterval
    public let sequence: UInt32

    public init(timestamp: TimeInterval, sequence: UInt32) {
        self.timestamp = timestamp
        self.sequence = sequence
    }
}

public struct FlowRTTSample: Codable, Sendable {
    public let timestamp: TimeInterval
    public let rttMillis: Double
    public let direction: FlowDirection

    public init(timestamp: TimeInterval, rttMillis: Double, direction: FlowDirection) {
        self.timestamp = timestamp
        self.rttMillis = rttMillis
        self.direction = direction
    }
}

public struct TCPFlowMetrics: Codable, Sendable {
    public var clientToServer: FlowDirectionalStats
    public var serverToClient: FlowDirectionalStats
    public var rttSamples: [FlowRTTSample]
    public var throughputClient: [FlowTimeSeriesSample]
    public var throughputServer: [FlowTimeSeriesSample]
    public var seqClient: [FlowSeqSample]
    public var seqServer: [FlowSeqSample]

    public init(
        clientToServer: FlowDirectionalStats = FlowDirectionalStats(),
        serverToClient: FlowDirectionalStats = FlowDirectionalStats(),
        rttSamples: [FlowRTTSample] = [],
        throughputClient: [FlowTimeSeriesSample] = [],
        throughputServer: [FlowTimeSeriesSample] = [],
        seqClient: [FlowSeqSample] = [],
        seqServer: [FlowSeqSample] = []
    ) {
        self.clientToServer = clientToServer
        self.serverToClient = serverToClient
        self.rttSamples = rttSamples
        self.throughputClient = throughputClient
        self.throughputServer = throughputServer
        self.seqClient = seqClient
        self.seqServer = seqServer
    }
}

public struct PacketFlowRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let sourceIP: String
    public let destinationIP: String
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let transport: FlowTransportProtocol
    public var protocolHints: [FlowProtocolHint]
    public var bytesFromSource: UInt64
    public var bytesToSource: UInt64
    public var packetsFromSource: UInt64
    public var packetsToSource: UInt64
    public var startTime: Date
    public var lastSeen: Date
    public var isClosed: Bool
    public var tlsSNI: String?
    public var alpn: [String]?
    public var lastSequenceNumber: UInt32?
    public var lastAcknowledgmentNumber: UInt32?
    public var lastPacketTimestamp: Date?
    public var lastPacketLength: Int?
    public var clientEndpoint: FlowEndpoint?
    public var serverEndpoint: FlowEndpoint?
    public var connectionState: FlowConnectionState
    public var tcpHandshake: TCPHandshakeSummary?
    public var tcpTermination: TCPTerminationSummary?
    public var tcpMetrics: TCPFlowMetrics?

    public init(
        id: UUID = UUID(),
        sourceIP: String,
        destinationIP: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        transport: FlowTransportProtocol,
        protocolHints: [FlowProtocolHint] = [],
        bytesFromSource: UInt64 = 0,
        bytesToSource: UInt64 = 0,
        packetsFromSource: UInt64 = 0,
        packetsToSource: UInt64 = 0,
        startTime: Date = Date(),
        lastSeen: Date = Date(),
        isClosed: Bool = false,
        tlsSNI: String? = nil,
        alpn: [String]? = nil,
        lastSequenceNumber: UInt32? = nil,
        lastAcknowledgmentNumber: UInt32? = nil,
        lastPacketTimestamp: Date? = nil,
        lastPacketLength: Int? = nil,
        clientEndpoint: FlowEndpoint? = nil,
        serverEndpoint: FlowEndpoint? = nil,
        connectionState: FlowConnectionState = .unknown,
        tcpHandshake: TCPHandshakeSummary? = nil,
        tcpTermination: TCPTerminationSummary? = nil,
        tcpMetrics: TCPFlowMetrics? = nil
    ) {
        self.id = id
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.transport = transport
        self.protocolHints = protocolHints
        self.bytesFromSource = bytesFromSource
        self.bytesToSource = bytesToSource
        self.packetsFromSource = packetsFromSource
        self.packetsToSource = packetsToSource
        self.startTime = startTime
        self.lastSeen = lastSeen
        self.isClosed = isClosed
        self.tlsSNI = tlsSNI
        self.alpn = alpn
        self.lastSequenceNumber = lastSequenceNumber
        self.lastAcknowledgmentNumber = lastAcknowledgmentNumber
        self.lastPacketTimestamp = lastPacketTimestamp
        self.lastPacketLength = lastPacketLength
        self.clientEndpoint = clientEndpoint
        self.serverEndpoint = serverEndpoint
        self.connectionState = connectionState
        self.tcpHandshake = tcpHandshake
        self.tcpTermination = tcpTermination
        self.tcpMetrics = tcpMetrics
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceIP
        case destinationIP
        case sourcePort
        case destinationPort
        case transport
        case protocolHints
        case bytesFromSource
        case bytesToSource
        case packetsFromSource
        case packetsToSource
        case startTime
        case lastSeen
        case isClosed
        case tlsSNI
        case alpn
        case lastSequenceNumber
        case lastAcknowledgmentNumber
        case lastPacketTimestamp
        case lastPacketLength
        case clientEndpoint
        case serverEndpoint
        case connectionState
        case tcpHandshake
        case tcpTermination
        case tcpMetrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceIP = try container.decode(String.self, forKey: .sourceIP)
        destinationIP = try container.decode(String.self, forKey: .destinationIP)
        sourcePort = try container.decode(UInt16.self, forKey: .sourcePort)
        destinationPort = try container.decode(UInt16.self, forKey: .destinationPort)
        transport = try container.decode(FlowTransportProtocol.self, forKey: .transport)
        protocolHints = try container.decodeIfPresent([FlowProtocolHint].self, forKey: .protocolHints) ?? []
        bytesFromSource = try container.decodeIfPresent(UInt64.self, forKey: .bytesFromSource) ?? 0
        bytesToSource = try container.decodeIfPresent(UInt64.self, forKey: .bytesToSource) ?? 0
        packetsFromSource = try container.decodeIfPresent(UInt64.self, forKey: .packetsFromSource) ?? 0
        packetsToSource = try container.decodeIfPresent(UInt64.self, forKey: .packetsToSource) ?? 0
        startTime = try container.decodeIfPresent(Date.self, forKey: .startTime) ?? Date()
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen) ?? startTime
        isClosed = try container.decodeIfPresent(Bool.self, forKey: .isClosed) ?? false
        tlsSNI = try container.decodeIfPresent(String.self, forKey: .tlsSNI)
        alpn = try container.decodeIfPresent([String].self, forKey: .alpn)
        lastSequenceNumber = try container.decodeIfPresent(UInt32.self, forKey: .lastSequenceNumber)
        lastAcknowledgmentNumber = try container.decodeIfPresent(UInt32.self, forKey: .lastAcknowledgmentNumber)
        lastPacketTimestamp = try container.decodeIfPresent(Date.self, forKey: .lastPacketTimestamp)
        lastPacketLength = try container.decodeIfPresent(Int.self, forKey: .lastPacketLength)
        clientEndpoint = try container.decodeIfPresent(FlowEndpoint.self, forKey: .clientEndpoint)
        serverEndpoint = try container.decodeIfPresent(FlowEndpoint.self, forKey: .serverEndpoint)
        connectionState = try container.decodeIfPresent(FlowConnectionState.self, forKey: .connectionState) ?? .unknown
        tcpHandshake = try container.decodeIfPresent(TCPHandshakeSummary.self, forKey: .tcpHandshake)
        tcpTermination = try container.decodeIfPresent(TCPTerminationSummary.self, forKey: .tcpTermination)
        tcpMetrics = try container.decodeIfPresent(TCPFlowMetrics.self, forKey: .tcpMetrics)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceIP, forKey: .sourceIP)
        try container.encode(destinationIP, forKey: .destinationIP)
        try container.encode(sourcePort, forKey: .sourcePort)
        try container.encode(destinationPort, forKey: .destinationPort)
        try container.encode(transport, forKey: .transport)
        try container.encode(protocolHints, forKey: .protocolHints)
        try container.encode(bytesFromSource, forKey: .bytesFromSource)
        try container.encode(bytesToSource, forKey: .bytesToSource)
        try container.encode(packetsFromSource, forKey: .packetsFromSource)
        try container.encode(packetsToSource, forKey: .packetsToSource)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(isClosed, forKey: .isClosed)
        try container.encodeIfPresent(tlsSNI, forKey: .tlsSNI)
        try container.encodeIfPresent(alpn, forKey: .alpn)
        try container.encodeIfPresent(lastSequenceNumber, forKey: .lastSequenceNumber)
        try container.encodeIfPresent(lastAcknowledgmentNumber, forKey: .lastAcknowledgmentNumber)
        try container.encodeIfPresent(lastPacketTimestamp, forKey: .lastPacketTimestamp)
        try container.encodeIfPresent(lastPacketLength, forKey: .lastPacketLength)
        try container.encodeIfPresent(clientEndpoint, forKey: .clientEndpoint)
        try container.encodeIfPresent(serverEndpoint, forKey: .serverEndpoint)
        try container.encode(connectionState, forKey: .connectionState)
        try container.encodeIfPresent(tcpHandshake, forKey: .tcpHandshake)
        try container.encodeIfPresent(tcpTermination, forKey: .tcpTermination)
        try container.encodeIfPresent(tcpMetrics, forKey: .tcpMetrics)
    }
}
