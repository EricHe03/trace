//
//  StreamSessionRuntime.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/03.
//

import Foundation
import TraceCore

final class StreamSessionRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var session: StreamSession
    private var nextSequence: Int64 = 1

    init(
        sessionID: UUID = UUID(),
        protocolType: StreamProtocolType,
        url: String,
        requestHeaders: [TraceHTTPHeader],
        responseHeaders: [TraceHTTPHeader] = [],
        metadata: [String: String] = [:],
        startTime: Date = Date()
    ) {
        session = StreamSession(
            id: sessionID,
            protocolType: protocolType,
            url: url,
            startTime: startTime,
            status: .connecting,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            metadata: metadata,
            eventCount: 0,
            bytesIn: 0,
            bytesOut: 0
        )
    }

    func snapshot() -> StreamSession {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func updateResponseHeaders(_ headers: [TraceHTTPHeader]) {
        lock.lock()
        defer { lock.unlock() }
        session.responseHeaders = headers
    }

    func mergeMetadata(_ metadata: [String: String]) {
        guard !metadata.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in metadata {
            session.metadata[key] = value
        }
    }

    func setStatus(_ status: StreamSessionStatus, endTime: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        session.status = status
        session.endTime = endTime
    }

    func reserveSequence() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence += 1
        return sequence
    }

    func makeEvent(
        direction: StreamEventDirection,
        kind: StreamEventKind,
        payload: StreamEventPayload,
        timestamp: Date = Date(),
        wasModified: Bool = false,
        wasBlocked: Bool = false,
        metadata: [String: String] = [:]
    ) -> StreamEvent {
        let sequence = reserveSequence()
        return StreamEvent(
            sessionID: snapshot().id,
            sequence: sequence,
            timestamp: timestamp,
            direction: direction,
            kind: kind,
            payload: payload,
            wasModified: wasModified,
            wasBlocked: wasBlocked,
            metadata: metadata
        )
    }

    func recordPersistedEvent(_ event: StreamEvent) {
        lock.lock()
        defer { lock.unlock() }

        session.eventCount += 1
        switch event.direction {
        case .received:
            session.bytesIn += event.payload.byteCount
        case .sent:
            session.bytesOut += event.payload.byteCount
        case .system:
            break
        }
    }
}
