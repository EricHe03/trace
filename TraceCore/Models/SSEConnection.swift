//
//  SSEConnection.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Status of an SSE connection
public enum SSEConnectionStatus: String, Codable, CaseIterable {
    case connecting
    case streaming
    case closed
    case failed

    public var displayName: String {
        switch self {
        case .connecting: "Connecting"
        case .streaming: "Streaming"
        case .closed: "Closed"
        case .failed: "Failed"
        }
    }

    public var color: StatusColor {
        switch self {
        case .connecting: .info
        case .streaming: .success
        case .closed: .unknown
        case .failed: .clientError
        }
    }
}

/// Represents an SSE connection capture
public struct SSEConnection: Identifiable, Codable, Equatable {
    public let id: UUID
    public var url: String
    public var startTime: Date
    public var endTime: Date?
    public var events: [ServerSentEvent]
    public var status: SSEConnectionStatus
    public var requestHeaders: [TraceHTTPHeader]
    public var responseHeaders: [TraceHTTPHeader]
    public var totalBytesReceived: Int
    public var isTruncated: Bool

    public init(
        id: UUID = UUID(),
        url: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        events: [ServerSentEvent] = [],
        status: SSEConnectionStatus = .connecting,
        requestHeaders: [TraceHTTPHeader] = [],
        responseHeaders: [TraceHTTPHeader] = [],
        totalBytesReceived: Int = 0,
        isTruncated: Bool = false
    ) {
        self.id = id
        self.url = url
        self.startTime = startTime
        self.endTime = endTime
        self.events = events
        self.status = status
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.totalBytesReceived = totalBytesReceived
        self.isTruncated = isTruncated
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

    public var eventCount: Int {
        events.count
    }

    public var totalBytesString: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytesReceived), countStyle: .file)
    }

    public mutating func addEvent(_ event: ServerSentEvent) {
        events.append(event)
    }

    public var isActive: Bool {
        status == .connecting || status == .streaming
    }

    public mutating func close() {
        status = .closed
        endTime = Date()
    }
}

// MARK: - Equatable conformance

public extension SSEConnection {
    static func == (lhs: SSEConnection, rhs: SSEConnection) -> Bool {
        lhs.id == rhs.id
    }
}
