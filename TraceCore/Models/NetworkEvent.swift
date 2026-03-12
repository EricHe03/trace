//
//  NetworkEvent.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Network event that can represent HTTP requests, WebSockets, SSE connections, or transport packets.
public enum NetworkEvent: Identifiable, @unchecked Sendable {
    case httpRequest(NetworkRequest)
    case webSocket(WebSocketConnection)
    case sse(SSEConnection)
    case transportRequest(TransportRequest)

    public var id: UUID {
        switch self {
        case let .httpRequest(request):
            request.id
        case let .webSocket(connection):
            connection.id
        case let .sse(connection):
            connection.id
        case let .transportRequest(request):
            request.id
        }
    }

    public var timestamp: Date {
        switch self {
        case let .httpRequest(request):
            request.timestamp
        case let .webSocket(connection):
            connection.startTime
        case let .sse(connection):
            connection.startTime
        case let .transportRequest(request):
            request.timestamp
        }
    }

    public var type: NetworkEventType {
        switch self {
        case .httpRequest:
            .http
        case .webSocket:
            .webSocket
        case .sse:
            .sse
        case let .transportRequest(request):
            switch request.applicationProtocol {
            case .dns:
                .dns
            case .mdns:
                .mdns
            case .ntp:
                .ntp
            case .dhcpv4:
                .dhcpv4
            case .dhcpv6:
                .dhcpv6
            case .snmp:
                .snmp
            case .quic:
                .quic
            case .http, .tls:
                .tcp
            case .unknown:
                switch request.transport {
                case .tcp:
                    .tcp
                case .udp:
                    .udp
                case .unknown:
                    .transport
                }
            }
        }
    }

    public var isActive: Bool {
        switch self {
        case .httpRequest:
            false // HTTP requests are instantaneous
        case let .webSocket(connection):
            connection.isActive
        case let .sse(connection):
            connection.isActive
        case .transportRequest:
            false
        }
    }

    public var displayTitle: String {
        switch self {
        case let .httpRequest(request):
            request.url
        case let .webSocket(connection):
            connection.url
        case let .sse(connection):
            connection.url
        case let .transportRequest(request):
            request.endpointSummary
        }
    }

    public var subtitle: String {
        switch self {
        case let .httpRequest(request):
            return "\(request.method.rawValue) • \(request.statusCode?.description ?? "Pending")"
        case let .webSocket(connection):
            return "WebSocket • \(connection.messageCount) messages"
        case let .sse(connection):
            return "SSE • \(connection.eventCount) events"
        case let .transportRequest(request):
            let proto = request.applicationProtocol.displayName
            let protocolBadge = request.protocolBadgeText
            let fallback: String? = switch request.parserOutcome {
            case .fallbackSignatureOnly:
                "fallback"
            case .parsed, .fallbackUnknown:
                nil
            }
            let parts = [request.transport.rawValue.uppercased(), proto, protocolBadge, fallback].compactMap(\.self)
            return parts.joined(separator: " • ")
        }
    }

    public var domain: String? {
        switch self {
        case let .httpRequest(request):
            URL(string: request.url)?.host
        case let .webSocket(connection):
            URL(string: connection.url)?.host
        case let .sse(connection):
            URL(string: connection.url)?.host
        case .transportRequest:
            nil
        }
    }
}

// MARK: - NetworkEventType

public enum NetworkEventType: String, CaseIterable, Identifiable {
    case http = "HTTP/HTTPS"
    case webSocket = "WebSocket"
    case sse = "SSE"
    case tcp = "TCP"
    case udp = "UDP"
    case dns = "DNS"
    case mdns = "mDNS"
    case ntp = "NTP"
    case dhcpv4 = "DHCPv4"
    case dhcpv6 = "DHCPv6"
    case snmp = "SNMP"
    case quic = "QUIC"
    case transport = "Transport"

    public var id: String {
        rawValue
    }

    public var icon: String {
        switch self {
        case .http:
            "network"
        case .webSocket:
            "cable.connector"
        case .sse:
            "antenna.radiowaves.left.and.right"
        case .tcp:
            "arrow.left.and.right.square"
        case .udp:
            "arrow.triangle.2.circlepath"
        case .dns:
            "globe"
        case .mdns:
            "dot.radiowaves.left.and.right"
        case .ntp:
            "clock"
        case .dhcpv4:
            "network.badge.shield.half.filled"
        case .dhcpv6:
            "network.badge.shield.half.filled"
        case .snmp:
            "waveform.path.ecg"
        case .quic:
            "bolt.horizontal.circle"
        case .transport:
            "shippingbox"
        }
    }

    public var color: String {
        switch self {
        case .http:
            "blue"
        case .webSocket:
            "purple"
        case .sse:
            "orange"
        case .tcp:
            "teal"
        case .udp:
            "cyan"
        case .dns:
            "indigo"
        case .mdns:
            "mint"
        case .ntp:
            "yellow"
        case .dhcpv4:
            "brown"
        case .dhcpv6:
            "brown"
        case .snmp:
            "pink"
        case .quic:
            "green"
        case .transport:
            "gray"
        }
    }
}

// MARK: - Comparable & Equatable

extension NetworkEvent: Comparable {
    public static func < (lhs: NetworkEvent, rhs: NetworkEvent) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}

extension NetworkEvent: Equatable {
    public static func == (lhs: NetworkEvent, rhs: NetworkEvent) -> Bool {
        lhs.id == rhs.id
    }
}
