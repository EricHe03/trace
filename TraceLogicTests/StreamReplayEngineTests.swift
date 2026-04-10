//
//  StreamReplayEngineTests.swift
//  TraceTests
//
//  Created by Justin on 2026/03/03.
//

import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOWebSocket
@testable import TraceCore
@testable import TraceProxy
import XCTest

final class StreamReplayEngineTests: XCTestCase {
    private let storage = AppGroupStorage.shared

    override func setUp() {
        super.setUp()
        try? storage.clearAllWebSocketConnections()
        try? storage.clearAllSSEConnections()
        _ = try? storage.deleteStreamSessions(olderThan: .distantFuture)
    }

    override func tearDown() {
        try? storage.clearAllWebSocketConnections()
        try? storage.clearAllSSEConnections()
        _ = try? storage.deleteStreamSessions(olderThan: .distantFuture)
        super.tearDown()
    }

    func testReplayFramesRespectOriginalTimingMode() throws {
        let sessionID = UUID()
        try seedWebSocketSession(sessionID: sessionID)

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let event1 = makeWebSocketEvent(
            sessionID: sessionID,
            sequence: 1,
            timestamp: t0,
            text: "hello"
        )
        let event2 = makeWebSocketEvent(
            sessionID: sessionID,
            sequence: 2,
            timestamp: t0.addingTimeInterval(0.120),
            text: "world"
        )
        try storage.appendStreamEvent(event1)
        try storage.appendStreamEvent(event2)

        let spec = StreamReplaySpec(
            sessionID: sessionID,
            eventIDs: [event1.id, event2.id],
            timingMode: .originalTiming,
            startedAt: Date()
        )
        let frames = try loadFrames(spec: spec, direction: .sent)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].delayBeforeSend.nanoseconds, 0)
        XCTAssertGreaterThanOrEqual(frames[1].delayBeforeSend.nanoseconds, 100_000_000)
        XCTAssertLessThanOrEqual(frames[1].delayBeforeSend.nanoseconds, 150_000_000)
    }

    func testReplayFramesUseStepModeWithoutDelay() throws {
        let sessionID = UUID()
        try seedWebSocketSession(sessionID: sessionID)

        let t0 = Date(timeIntervalSince1970: 1_700_000_100)
        let event1 = makeWebSocketEvent(
            sessionID: sessionID,
            sequence: 1,
            timestamp: t0,
            text: "one"
        )
        let event2 = makeWebSocketEvent(
            sessionID: sessionID,
            sequence: 2,
            timestamp: t0.addingTimeInterval(2),
            text: "two"
        )
        try storage.appendStreamEvent(event1)
        try storage.appendStreamEvent(event2)

        let spec = StreamReplaySpec(
            sessionID: sessionID,
            eventIDs: [event1.id, event2.id],
            timingMode: .step,
            startedAt: Date()
        )
        let frames = try loadFrames(spec: spec, direction: .sent)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].delayBeforeSend.nanoseconds, 0)
        XCTAssertEqual(frames[1].delayBeforeSend.nanoseconds, 0)
    }

    func testReplayFramesFilterDirectionAndEventIDs() throws {
        let sessionID = UUID()
        try seedWebSocketSession(sessionID: sessionID)

        let sentEvent = makeWebSocketEvent(
            sessionID: sessionID,
            sequence: 1,
            timestamp: Date(),
            text: "sent",
            direction: .sent
        )
        let receivedEvent = makeWebSocketEvent(
            sessionID: sessionID,
            sequence: 2,
            timestamp: Date(),
            text: "received",
            direction: .received
        )
        try storage.appendStreamEvent(sentEvent)
        try storage.appendStreamEvent(receivedEvent)

        let spec = StreamReplaySpec(
            sessionID: sessionID,
            eventIDs: [sentEvent.id, receivedEvent.id],
            timingMode: .step
        )
        let sentFrames = try loadFrames(spec: spec, direction: .sent)
        let receivedFrames = try loadFrames(spec: spec, direction: .received)

        XCTAssertEqual(sentFrames.count, 1)
        XCTAssertEqual(receivedFrames.count, 1)
    }

    func testPerMessageDeflateCodecRoundTrip() throws {
        let input = Data("fragmented websocket payload".utf8)
        guard let encoded = WebSocketPerMessageDeflateCodec.encode(input) else {
            throw XCTSkip("zlib/permessage-deflate codec unavailable in this environment")
        }
        guard let decoded = WebSocketPerMessageDeflateCodec.decode(encoded) else {
            XCTFail("Failed to decode permessage-deflate payload")
            return
        }
        XCTAssertEqual(decoded, input)
    }

    func testReplayWebSocketFramesEncodePerMessageDeflateWhenMetadataIsTrue() throws {
        let original = Data("hello".utf8)
        guard WebSocketPerMessageDeflateCodec.encode(original) != nil else {
            throw XCTSkip("zlib/permessage-deflate codec unavailable in this environment")
        }

        let sessionID = UUID()
        try seedWebSocketSession(sessionID: sessionID)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var event = makeWebSocketEvent(
            sessionID: sessionID,
            sequence: 1,
            timestamp: timestamp,
            text: "hello"
        )
        event.metadata["permessage_deflate"] = "true"
        try storage.appendStreamEvent(event)

        let spec = StreamReplaySpec(
            sessionID: sessionID,
            eventIDs: [event.id],
            timingMode: .step
        )
        let frames = try loadFrames(spec: spec, direction: .sent)
        XCTAssertEqual(frames.count, 1)

        let frame = frames[0].frame
        XCTAssertEqual(frame.opcode, .text)
        XCTAssertTrue(frame.rsv1)

        let wirePayload = framePayloadData(frame)
        guard let decoded = WebSocketPerMessageDeflateCodec.decode(wirePayload) else {
            return XCTFail("Expected replay payload to decode")
        }
        XCTAssertEqual(decoded, original)
    }

    private func loadFrames(
        spec: StreamReplaySpec,
        direction: StreamEventDirection
    ) throws -> [ReplayWebSocketFrame] {
        let resources = NIORuntime.shared.acquire(for: .tests)
        defer { try? NIORuntime.shared.release(for: .tests) }

        return try StreamReplayEngine(storage: storage)
            .loadReplayWebSocketFrames(
                spec,
                direction: direction,
                allocator: ByteBufferAllocator(),
                maskKey: nil,
                eventLoop: resources.eventLoopGroup.next()
            )
            .wait()
    }

    private func framePayloadData(_ frame: WebSocketFrame) -> Data {
        var payload = frame.unmaskedData
        return payload.readData(length: payload.readableBytes) ?? Data()
    }

    private func seedWebSocketSession(sessionID: UUID) throws {
        try storage.upsertStreamSession(
            StreamSession(
                id: sessionID,
                protocolType: .websocket,
                url: "wss://echo.example/ws",
                status: .open,
                requestHeaders: [],
                responseHeaders: []
            )
        )
    }

    private func makeWebSocketEvent(
        sessionID: UUID,
        sequence: Int64,
        timestamp: Date,
        text: String,
        direction: StreamEventDirection = .sent
    ) -> StreamEvent {
        StreamEvent(
            id: UUID(),
            sessionID: sessionID,
            sequence: sequence,
            timestamp: timestamp,
            direction: direction,
            kind: .message,
            payload: .text(text, contentType: "text/plain; charset=utf-8"),
            metadata: [
                "message_type": "text",
                "payload_length": String(text.utf8.count)
            ]
        )
    }
}

