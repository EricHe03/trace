//
//  WebSocketConnection.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Status of a WebSocket connection
public enum WebSocketConnectionStatus: String, Codable, CaseIterable {
    case connecting
    case open
    case closing
    case closed
    case failed

    public var displayName: String {
        switch self {
        case .connecting: "Connecting"
        case .open: "Open"
        case .closing: "Closing"
        case .closed: "Closed"
        case .failed: "Failed"
        }
    }

    public var color: StatusColor {
        switch self {
        case .connecting: .info
        case .open: .success
        case .closing: .warning
        case .closed: .unknown
        case .failed: .clientError
        }
    }
}

/// Represents a WebSocket connection capture
public struct WebSocketConnection: Identifiable, Codable, Equatable {
    public let id: UUID
    public var url: String
    public var startTime: Date
    public var endTime: Date?
    public var messages: [WebSocketMessage]
    public var status: WebSocketConnectionStatus
    public var requestHeaders: [TraceHTTPHeader]
    public var responseHeaders: [TraceHTTPHeader]
    public var closeCode: Int?
    public var closeReason: String?

    public init(
        id: UUID = UUID(),
        url: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        messages: [WebSocketMessage] = [],
        status: WebSocketConnectionStatus = .connecting,
        requestHeaders: [TraceHTTPHeader] = [],
        responseHeaders: [TraceHTTPHeader] = [],
        closeCode: Int? = nil,
        closeReason: String? = nil
    ) {
        self.id = id
        self.url = url
        self.startTime = startTime
        self.endTime = endTime
        self.messages = messages
        self.status = status
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.closeCode = closeCode
        self.closeReason = closeReason
    }

    public var host: String {
        if let url = URL(string: url) {
            return url.host ?? url.absoluteString
        }
        return url
    }

    public var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    public var messageCount: Int {
        messages.count
    }

    public var sentMessageCount: Int {
        messages.count(where: { $0.direction == .sent })
    }

    public var receivedMessageCount: Int {
        messages.count(where: { $0.direction == .received })
    }

    public var isActive: Bool {
        status == .connecting || status == .open
    }

    public mutating func addMessage(_ message: WebSocketMessage) {
        messages.append(message)
    }

    public mutating func close(code: Int? = nil, reason: String? = nil) {
        status = .closed
        endTime = Date()
        closeCode = code
        closeReason = reason
    }
}

// MARK: - Equatable conformance

public extension WebSocketConnection {
    static func == (lhs: WebSocketConnection, rhs: WebSocketConnection) -> Bool {
        lhs.id == rhs.id
    }
}
