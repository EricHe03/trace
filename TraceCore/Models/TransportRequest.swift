//
//  TransportRequest.swift
//  TraceCore
//
//  Created by Codex on 2026/02/24.
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
    public let ipVersion: UInt8
    public let protocolNumber: UInt8
    public let hopLimit: UInt8
    public let ipHeaderLength: Int
    public let totalLength: Int
    public let fragmentOffset: Int
    public let moreFragments: Bool
    public let summary: String?
    public let flowKey: String

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
        ipVersion: UInt8,
        protocolNumber: UInt8,
        hopLimit: UInt8,
        ipHeaderLength: Int,
        totalLength: Int,
        fragmentOffset: Int,
        moreFragments: Bool,
        summary: String? = nil,
        flowKey: String
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
        self.ipVersion = ipVersion
        self.protocolNumber = protocolNumber
        self.hopLimit = hopLimit
        self.ipHeaderLength = ipHeaderLength
        self.totalLength = totalLength
        self.fragmentOffset = fragmentOffset
        self.moreFragments = moreFragments
        self.summary = summary
        self.flowKey = flowKey
    }

    public var capturedPayloadBytes: Int {
        payload.capturedSize
    }

    public var totalPayloadBytes: Int {
        payload.totalSize
    }

    public var isPayloadTruncated: Bool {
        payload.isTruncated
    }

    public var endpointSummary: String {
        "\(sourceIP):\(sourcePort) -> \(destinationIP):\(destinationPort)"
    }
}
