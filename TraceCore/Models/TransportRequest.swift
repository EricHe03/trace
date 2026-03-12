//
//  TransportRequest.swift
//  TraceCore
//
//  Created by Justin on 2026/02/24.
//

import Foundation

public enum TransportApplicationProtocol: String, Codable, CaseIterable, Sendable {
    case dns
    case mdns
    case ntp
    case dhcpv4
    case dhcpv6
    case snmp
    case quic
    case http
    case tls
    case unknown

    public var displayName: String {
        switch self {
        case .dns:
            "DNS"
        case .mdns:
            "mDNS"
        case .ntp:
            "NTP"
        case .dhcpv4:
            "DHCPv4"
        case .dhcpv6:
            "DHCPv6"
        case .snmp:
            "SNMP"
        case .quic:
            "QUIC"
        case .http:
            "HTTP"
        case .tls:
            "TLS"
        case .unknown:
            "Unknown"
        }
    }
}

public enum TransportParserOutcome: String, Codable, Sendable {
    case parsed
    case fallbackSignatureOnly
    case fallbackUnknown
}

public struct TransportTCPPacketTimestamp: Codable, Sendable {
    public let value: UInt32
    public let echoReply: UInt32

    public init(value: UInt32, echoReply: UInt32) {
        self.value = value
        self.echoReply = echoReply
    }
}

public struct TransportTCPPacketOptions: Codable, Sendable {
    public let maximumSegmentSize: UInt16?
    public let windowScale: UInt8?
    public let sackPermitted: Bool?
    public let timestamps: TransportTCPPacketTimestamp?

    public init(
        maximumSegmentSize: UInt16?,
        windowScale: UInt8?,
        sackPermitted: Bool?,
        timestamps: TransportTCPPacketTimestamp?
    ) {
        self.maximumSegmentSize = maximumSegmentSize
        self.windowScale = windowScale
        self.sackPermitted = sackPermitted
        self.timestamps = timestamps
    }
}

public struct TransportRequest: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let sourceIP: String
    public let destinationIP: String
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let transport: FlowTransportProtocol
    public let applicationProtocol: TransportApplicationProtocol
    public let parserOutcome: TransportParserOutcome
    public let payload: BodyStorage
    public let payloadBytes: Int
    public let packet: BodyStorage?
    public let packetBytes: Int?
    public let ipVersion: UInt8
    public let protocolNumber: UInt8
    public let hopLimit: UInt8
    public let ipHeaderLength: Int
    public let totalLength: Int
    public let fragmentOffset: Int
    public let moreFragments: Bool
    public let tcpSequenceNumber: UInt32?
    public let tcpAcknowledgmentNumber: UInt32?
    public let tcpFlags: UInt8?
    public let tcpWindowSize: UInt16?
    public let tcpDataOffset: Int?
    public let tcpOptions: TransportTCPPacketOptions?
    public let udpDatagramLength: UInt16?
    public let summary: String?
    public let flowKey: String
    public var applicationProtocolHint: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sourceIP: String,
        destinationIP: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        transport: FlowTransportProtocol,
        applicationProtocol: TransportApplicationProtocol,
        parserOutcome: TransportParserOutcome,
        payload: BodyStorage,
        payloadBytes: Int,
        packet: BodyStorage? = nil,
        packetBytes: Int? = nil,
        ipVersion: UInt8,
        protocolNumber: UInt8,
        hopLimit: UInt8,
        ipHeaderLength: Int,
        totalLength: Int,
        fragmentOffset: Int,
        moreFragments: Bool,
        tcpSequenceNumber: UInt32? = nil,
        tcpAcknowledgmentNumber: UInt32? = nil,
        tcpFlags: UInt8? = nil,
        tcpWindowSize: UInt16? = nil,
        tcpDataOffset: Int? = nil,
        tcpOptions: TransportTCPPacketOptions? = nil,
        udpDatagramLength: UInt16? = nil,
        summary: String? = nil,
        flowKey: String,
        applicationProtocolHint: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.transport = transport
        self.applicationProtocol = applicationProtocol
        self.parserOutcome = parserOutcome
        self.payload = payload
        self.payloadBytes = payloadBytes
        self.packet = packet
        self.packetBytes = packetBytes
        self.ipVersion = ipVersion
        self.protocolNumber = protocolNumber
        self.hopLimit = hopLimit
        self.ipHeaderLength = ipHeaderLength
        self.totalLength = totalLength
        self.fragmentOffset = fragmentOffset
        self.moreFragments = moreFragments
        self.tcpSequenceNumber = tcpSequenceNumber
        self.tcpAcknowledgmentNumber = tcpAcknowledgmentNumber
        self.tcpFlags = tcpFlags
        self.tcpWindowSize = tcpWindowSize
        self.tcpDataOffset = tcpDataOffset
        self.tcpOptions = tcpOptions
        self.udpDatagramLength = udpDatagramLength
        self.summary = summary
        self.flowKey = flowKey
        self.applicationProtocolHint = applicationProtocolHint
    }

    public var capturedPayloadBytes: Int {
        payload.capturedSize
    }

    public var totalPayloadBytes: Int {
        payload.totalSize
    }

    public var capturedPacketBytes: Int? {
        packet?.capturedSize
    }

    public var totalPacketBytes: Int? {
        packet?.totalSize
    }

    public var isPacketTruncated: Bool {
        packet?.isTruncated ?? false
    }

    public var isPayloadTruncated: Bool {
        payload.isTruncated
    }

    public var endpointSummary: String {
        "\(sourceIP):\(sourcePort) -> \(destinationIP):\(destinationPort)"
    }

    public var normalizedApplicationProtocolHint: String? {
        applicationProtocolHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    public var protocolBadgeText: String? {
        guard applicationProtocol == .quic,
              let normalizedHint = normalizedApplicationProtocolHint,
              normalizedHint == "h3" || normalizedHint.hasPrefix("h3-")
        else {
            return nil
        }
        return "H3"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
