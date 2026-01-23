//
//  NetworkEvent.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Network event that can represent HTTP requests, WebSockets, or SSE connections
public enum NetworkEvent: Identifiable, @unchecked Sendable {
    case httpRequest(NetworkRequest)
    case webSocket(WebSocketConnection)
    case sse(SSEConnection)

    public var id: UUID {
        switch self {
        case let .httpRequest(request):
            request.id
        case let .webSocket(connection):
            connection.id
        case let .sse(connection):
            connection.id
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
        }
    }

    public var subtitle: String {
        switch self {
        case let .httpRequest(request):
            "\(request.method.rawValue) • \(request.statusCode?.description ?? "Pending")"
        case let .webSocket(connection):
            "WebSocket • \(connection.messageCount) messages"
        case let .sse(connection):
            "SSE • \(connection.eventCount) events"
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
        }
    }
}

// MARK: - NetworkEventType

public enum NetworkEventType: String, CaseIterable, Identifiable {
    case http = "HTTP/HTTPS"
    case webSocket = "WebSocket"
    case sse = "SSE"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .http:
            "network"
        case .webSocket:
            "cable.connector"
        case .sse:
            "antenna.radiowaves.left.and.right"
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
