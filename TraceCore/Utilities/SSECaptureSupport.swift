//
//  SSECaptureSupport.swift
//  TraceCore
//
//  Created by Justin on 2026/02/06.
//

import Foundation

/// Controls how frequently in-flight SSE captures should emit snapshot updates.
public struct SSECapturePublishThrottle {
    private let minEventDelta: Int
    private let minInterval: TimeInterval
    private var lastPublishedEventCount: Int
    private var lastPublishedAt: Date
    private var hasPublished: Bool

    public init(minEventDelta: Int = 25, minInterval: TimeInterval = 2.0) {
        self.minEventDelta = max(1, minEventDelta)
        self.minInterval = max(0, minInterval)
        self.lastPublishedEventCount = 0
        self.lastPublishedAt = .distantPast
        self.hasPublished = false
    }

    /// Returns true when a snapshot should be emitted.
    /// Terminal statuses always emit immediately.
    public mutating func shouldPublish(connection: SSEConnection, now: Date = Date()) -> Bool {
        if !hasPublished {
            markPublished(connection, at: now)
            return true
        }

        if connection.status != .streaming {
            markPublished(connection, at: now)
            return true
        }

        if connection.eventCount - lastPublishedEventCount >= minEventDelta {
            markPublished(connection, at: now)
            return true
        }

        if now.timeIntervalSince(lastPublishedAt) >= minInterval {
            markPublished(connection, at: now)
            return true
        }

        return false
    }

    private mutating func markPublished(_ connection: SSEConnection, at now: Date) {
        hasPublished = true
        lastPublishedEventCount = connection.eventCount
        lastPublishedAt = now
    }
}

/// Converts parsed SSE events back into text/event-stream payload format.
public enum SSEPayloadSerializer {
    public static func serialize(events: [ServerSentEvent]) -> String {
        guard !events.isEmpty else { return "" }

        var payload = ""
        for event in events {
            if let eventId = event.eventId, !eventId.isEmpty {
                payload += "id: \(eventId)\n"
            }
            if let eventType = event.eventType, !eventType.isEmpty {
                payload += "event: \(eventType)\n"
            }
            if let retry = event.retry {
                payload += "retry: \(retry)\n"
            }
            for line in event.data.split(separator: "\n", omittingEmptySubsequences: false) {
                payload += "data: \(line)\n"
            }
            payload += "\n"
        }
        return payload
    }
}
