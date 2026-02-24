//
//  UDPFlowMetadata.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public enum UDPFlowProtocol: String, Codable, CaseIterable, Sendable {
    case dns
    case quic
    case dhcp
    case ntp
    case mdns
    case snmp
    case unknown

    public var displayName: String {
        switch self {
        case .dns:
            "DNS"
        case .quic:
            "QUIC"
        case .dhcp:
            "DHCP"
        case .ntp:
            "NTP"
        case .mdns:
            "mDNS"
        case .snmp:
            "SNMP"
        case .unknown:
            "Unknown"
        }
    }
}

public enum UDPFlowTermination: String, Codable, CaseIterable, Sendable {
    case active
    case timeout
    case evicted
    case closed

    public var displayName: String {
        switch self {
        case .active:
            "Active"
        case .timeout:
            "Timeout"
        case .evicted:
            "Evicted"
        case .closed:
            "Closed"
        }
    }
}

public enum UDPFlowDirection: String, Codable, Sendable {
    case sourceToDestination
    case destinationToSource
}

public struct UDPDatagramSample: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let size: Int
    public let direction: UDPFlowDirection

    public init(id: UUID = UUID(), timestamp: Date, size: Int, direction: UDPFlowDirection) {
        self.id = id
        self.timestamp = timestamp
        self.size = size
        self.direction = direction
    }
}

public struct UDPFlowMetadata: Identifiable, Codable, Sendable {
    public let id: UUID
    public let sourceIP: String
    public let destinationIP: String
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public var bytesFromSource: UInt64
    public var bytesToSource: UInt64
    public var datagramsFromSource: UInt64
    public var datagramsToSource: UInt64
    public var startTime: Date
    public var lastActivity: Date
    public var endTime: Date?
    public var termination: UDPFlowTermination
    public var detectedProtocol: UDPFlowProtocol
    public var quicInspectionOutcome: QUICInspectionOutcome?
    public var quicFlowMetadata: QUICFlowMetadata?
    public var recentDatagrams: [UDPDatagramSample]

    public init(
        id: UUID = UUID(),
        sourceIP: String,
        destinationIP: String,
        sourcePort: UInt16,
        destinationPort: UInt16,
        bytesFromSource: UInt64 = 0,
        bytesToSource: UInt64 = 0,
        datagramsFromSource: UInt64 = 0,
        datagramsToSource: UInt64 = 0,
        startTime: Date = Date(),
        lastActivity: Date = Date(),
        endTime: Date? = nil,
        termination: UDPFlowTermination = .active,
        detectedProtocol: UDPFlowProtocol = .unknown,
        quicInspectionOutcome: QUICInspectionOutcome? = nil,
        quicFlowMetadata: QUICFlowMetadata? = nil,
        recentDatagrams: [UDPDatagramSample] = []
    ) {
        self.id = id
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.bytesFromSource = bytesFromSource
        self.bytesToSource = bytesToSource
        self.datagramsFromSource = datagramsFromSource
        self.datagramsToSource = datagramsToSource
        self.startTime = startTime
        self.lastActivity = lastActivity
        self.endTime = endTime
        self.termination = termination
        self.detectedProtocol = detectedProtocol
        self.quicInspectionOutcome = quicInspectionOutcome
        self.quicFlowMetadata = quicFlowMetadata
        self.recentDatagrams = recentDatagrams
    }
}

public extension UDPFlowMetadata {
    var totalBytes: UInt64 {
        bytesFromSource + bytesToSource
    }

    var totalDatagrams: UInt64 {
        datagramsFromSource + datagramsToSource
    }

    var duration: TimeInterval {
        let end = endTime ?? Date()
        return max(0, end.timeIntervalSince(startTime))
    }

    var throughputBytesPerSecond: Double {
        let elapsed = max(duration, 0.001)
        return Double(totalBytes) / elapsed
    }

    var averageDatagramSize: Double {
        guard totalDatagrams > 0 else { return 0 }
        return Double(totalBytes) / Double(totalDatagrams)
    }

    var isActive: Bool {
        termination == .active
    }

    var isBidirectional: Bool {
        datagramsFromSource > 0 && datagramsToSource > 0
    }

    var hasQUICDiagnostics: Bool {
        quicInspectionOutcome != nil || quicFlowMetadata != nil
    }

    var wellKnownPortDescription: String? {
        if let name = Self.wellKnownPortName(sourcePort) {
            return "Source: \(name)"
        }
        if let name = Self.wellKnownPortName(destinationPort) {
            return "Destination: \(name)"
        }
        return nil
    }

    static func wellKnownPortName(_ port: UInt16) -> String? {
        switch port {
        case 53:
            "DNS"
        case 67, 68:
            "DHCP"
        case 123:
            "NTP"
        case 161, 162:
            "SNMP"
        case 443:
            "QUIC"
        case 500, 4500:
            "IPsec"
        case 514:
            "Syslog"
        case 520:
            "RIP"
        case 1900:
            "SSDP"
        case 5353:
            "mDNS"
        default:
            nil
        }
    }
}
