//
//  StreamModels.swift
//  TraceCore
//
//  Created by Justin on 2026/03/03.
//

import Foundation

public enum StreamProtocolType: String, Codable, CaseIterable, Sendable {
    case sse
    case websocket
}

public enum StreamSessionStatus: String, Codable, CaseIterable, Sendable {
    case connecting
    case open
    case streaming
    case replaying
    case closing
    case closed
    case failed
}

public enum StreamEventDirection: String, Codable, CaseIterable, Sendable {
    case sent
    case received
    case system
}

public enum StreamEventKind: String, Codable, CaseIterable, Sendable {
    case open
    case message
    case ping
    case pong
    case close
    case error
    case replay
    case sseEvent
    case sseComment
    case sseRetry
}

public struct StreamEventPayload: Codable, Equatable, Sendable {
    public var text: String?
    public var binary: Data?
    public var contentType: String?
    public var encoding: String?

    public init(
        text: String? = nil,
        binary: Data? = nil,
        contentType: String? = nil,
        encoding: String? = nil
    ) {
        self.text = text
        self.binary = binary
        self.contentType = contentType
        self.encoding = encoding
    }

    public static func text(_ value: String, contentType: String? = nil) -> StreamEventPayload {
        StreamEventPayload(text: value, binary: nil, contentType: contentType, encoding: nil)
    }

    public static func binary(_ value: Data, contentType: String? = nil, encoding: String? = nil) -> StreamEventPayload {
        StreamEventPayload(text: nil, binary: value, contentType: contentType, encoding: encoding)
    }

    public var byteCount: Int {
        if let binary {
            return binary.count
        }
        return text?.utf8.count ?? 0
    }
}

public struct StreamSession: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var protocolType: StreamProtocolType
    public var url: String
    public var startTime: Date
    public var endTime: Date?
    public var status: StreamSessionStatus
    public var requestHeaders: [TraceHTTPHeader]
    public var responseHeaders: [TraceHTTPHeader]
    public var metadata: [String: String]
    public var eventCount: Int
    public var bytesIn: Int
    public var bytesOut: Int

    public init(
        id: UUID = UUID(),
        protocolType: StreamProtocolType,
        url: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        status: StreamSessionStatus = .connecting,
        requestHeaders: [TraceHTTPHeader] = [],
        responseHeaders: [TraceHTTPHeader] = [],
        metadata: [String: String] = [:],
        eventCount: Int = 0,
        bytesIn: Int = 0,
        bytesOut: Int = 0
    ) {
        self.id = id
        self.protocolType = protocolType
        self.url = url
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.metadata = metadata
        self.eventCount = eventCount
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct StreamEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var sequence: Int64
    public var timestamp: Date
    public var direction: StreamEventDirection
    public var kind: StreamEventKind
    public var payload: StreamEventPayload
    public var wasModified: Bool
    public var wasBlocked: Bool
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sequence: Int64,
        timestamp: Date = Date(),
        direction: StreamEventDirection,
        kind: StreamEventKind,
        payload: StreamEventPayload = StreamEventPayload(),
        wasModified: Bool = false,
        wasBlocked: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestamp = timestamp
        self.direction = direction
        self.kind = kind
        self.payload = payload
        self.wasModified = wasModified
        self.wasBlocked = wasBlocked
        self.metadata = metadata
    }
}

public enum StreamReplayTimingMode: String, Codable, CaseIterable, Sendable {
    case originalTiming
    case step
}

public enum StreamReplayStatus: String, Codable, CaseIterable, Sendable {
    case running
    case succeeded
    case failed
}

public struct StreamReplaySpec: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var eventIDs: [UUID]
    public var timingMode: StreamReplayTimingMode
    public var startedAt: Date

    public init(
        sessionID: UUID,
        eventIDs: [UUID],
        timingMode: StreamReplayTimingMode = .originalTiming,
        startedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.eventIDs = eventIDs
        self.timingMode = timingMode
        self.startedAt = startedAt
    }
}

public struct StreamReplayResult: Codable, Equatable, Sendable {
    public var replayID: UUID
    public var sessionID: UUID
    public var succeeded: Bool
    public var replayedEvents: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var errorMessage: String?

    public init(
        replayID: UUID = UUID(),
        sessionID: UUID,
        succeeded: Bool,
        replayedEvents: Int,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.replayID = replayID
        self.sessionID = sessionID
        self.succeeded = succeeded
        self.replayedEvents = replayedEvents
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.errorMessage = errorMessage
    }
}

public struct StreamReplayRecord: Codable, Equatable, Sendable {
    public var replayID: UUID
    public var sessionID: UUID
    public var status: StreamReplayStatus
    public var spec: StreamReplaySpec
    public var result: StreamReplayResult?
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        replayID: UUID,
        sessionID: UUID,
        status: StreamReplayStatus,
        spec: StreamReplaySpec,
        result: StreamReplayResult? = nil,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.replayID = replayID
        self.sessionID = sessionID
        self.status = status
        self.spec = spec
        self.result = result
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct StreamMutation: Codable, Equatable, Sendable {
    public var payload: StreamEventPayload?
    public var metadata: [String: String]

    public init(payload: StreamEventPayload? = nil, metadata: [String: String] = [:]) {
        self.payload = payload
        self.metadata = metadata
    }
}

public enum StreamInterceptionDecision: Equatable, Sendable {
    case forward
    case modify(StreamMutation)
    case block
    case drop
    case inject([StreamMutation])
    case replay(StreamReplaySpec)
}

public enum StreamScriptAction: String, Codable, CaseIterable, Sendable {
    case forward
    case block
    case drop
}

public struct StreamScriptContext: Codable, Equatable, Sendable {
    public var session: StreamSession
    public var event: StreamEvent

    public init(session: StreamSession, event: StreamEvent) {
        self.session = session
        self.event = event
    }
}

public struct StreamScriptExecutionResult: Codable, Equatable, Sendable {
    public var action: StreamScriptAction
    public var event: StreamEvent

    public init(action: StreamScriptAction = .forward, event: StreamEvent) {
        self.action = action
        self.event = event
    }
}
