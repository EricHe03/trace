//
//  StreamReplayEngineTests.swift
//  TraceTests
//
//  Created by Codex on 2026/03/03.
//

import XCTest
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import TraceCore
@testable import TraceProxy

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

final class NIOMITMWebSocketRelayHandlerTests: XCTestCase {
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents: [StreamEvent] = []

        func append(_ event: StreamEvent) {
            lock.lock()
            storedEvents.append(event)
            lock.unlock()
        }

        func events() -> [StreamEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storedEvents
        }
    }

    func testFragmentedTextMessageIsInterceptedAndModifiedAsSingleFrame() throws {
        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let collector = EventCollector()
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .sent,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, event, eventLoop in
                collector.append(event)
                return eventLoop.makeSucceededFuture(
                    .modify(
                        StreamMutation(
                            payload: .text("patched", contentType: "text/plain"),
                            metadata: ["source": "unit_test"]
                        )
                    )
                )
            }
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: false, opcode: .text, payload: Data("hel".utf8))
        )
        XCTAssertNil(try peer.readOutbound(as: WebSocketFrame.self))

        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .continuation, payload: Data("lo".utf8))
        )

        guard let forwarded = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected forwarded frame after fragmented message interception")
        }
        XCTAssertEqual(forwarded.opcode, .text)
        XCTAssertTrue(forwarded.fin)
        XCTAssertEqual(String(data: framePayloadData(forwarded), encoding: .utf8), "patched")

        let intercepted = collector.events()
        XCTAssertEqual(intercepted.count, 1)
        XCTAssertEqual(intercepted.first?.metadata["is_fragmented"], "true")
        XCTAssertEqual(intercepted.first?.payload.text, "hello")
    }

    func testInvalidFragmentSequenceTriggersProtocolClose() throws {
        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .sent,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            }
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: false, opcode: .text, payload: Data("start".utf8))
        )

        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .binary, payload: Data([0x01, 0x02]))
        )

        guard let closeFrame = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected close frame for invalid fragment sequence")
        }
        XCTAssertEqual(closeFrame.opcode, .connectionClose)
        let payload = framePayloadData(closeFrame)
        XCTAssertGreaterThanOrEqual(payload.count, 2)
        XCTAssertEqual(payload.prefix(2), Data([0x03, 0xEA])) // 1002 protocol error
    }

    func testPerMessageDeflatePayloadIsDecodedForInterceptionAndReencodedAfterMutation() throws {
        let original = Data("hello".utf8)
        guard let compressed = WebSocketPerMessageDeflateCodec.encode(original) else {
            throw XCTSkip("permessage-deflate codec unavailable in this environment")
        }

        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let collector = EventCollector()
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .received,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, event, eventLoop in
                collector.append(event)
                return eventLoop.makeSucceededFuture(
                    .modify(
                        StreamMutation(
                            payload: .text("patched", contentType: "text/plain; charset=utf-8")
                        )
                    )
                )
            },
            perMessageDeflateEnabled: true
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .text, payload: compressed, rsv1: true)
        )

        guard let forwarded = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected forwarded frame for compressed payload")
        }
        XCTAssertEqual(forwarded.opcode, .text)
        XCTAssertTrue(forwarded.rsv1)

        let forwardedPayload = framePayloadData(forwarded)
        guard let decoded = WebSocketPerMessageDeflateCodec.decode(forwardedPayload) else {
            return XCTFail("Expected forwarded compressed payload to decode")
        }
        XCTAssertEqual(decoded, Data("patched".utf8))

        let intercepted = collector.events()
        XCTAssertEqual(intercepted.first?.payload.text, "hello")
    }

    func testPerMessageDeflateInjectedFramePreservesRSV1WhenCompressed() throws {
        let original = Data("hello".utf8)
        guard let compressed = WebSocketPerMessageDeflateCodec.encode(original) else {
            throw XCTSkip("permessage-deflate codec unavailable in this environment")
        }

        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .received,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(
                    .inject(
                        [
                            StreamMutation(
                                payload: .text("injected", contentType: "text/plain; charset=utf-8"),
                                metadata: ["source": "unit_test"]
                            )
                        ]
                    )
                )
            },
            perMessageDeflateEnabled: true
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .text, payload: compressed, rsv1: true)
        )

        _ = try peer.readOutbound(as: WebSocketFrame.self) // original
        guard let injectedFrame = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected injected frame after original message")
        }

        XCTAssertTrue(injectedFrame.rsv1)
        let payload = framePayloadData(injectedFrame)
        guard let decoded = WebSocketPerMessageDeflateCodec.decode(payload) else {
            return XCTFail("Expected injected compressed payload to decode")
        }
        XCTAssertEqual(decoded, Data("injected".utf8))
    }

    func testUnexpectedContinuationFrameTriggersProtocolClose() throws {
        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .sent,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            }
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .continuation, payload: Data("orphan".utf8))
        )

        guard let closeFrame = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected protocol close frame for orphan continuation")
        }
        XCTAssertEqual(closeFrame.opcode, .connectionClose)
        XCTAssertEqual(closeCode(from: closeFrame), 1002)
    }

    func testFragmentedControlFrameTriggersProtocolClose() throws {
        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .sent,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            }
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: false, opcode: .ping, payload: Data([0x01]))
        )

        guard let closeFrame = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected protocol close frame for fragmented control frame")
        }
        XCTAssertEqual(closeFrame.opcode, .connectionClose)
        XCTAssertEqual(closeCode(from: closeFrame), 1002)
    }

    func testOversizedControlFrameTriggersProtocolClose() throws {
        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .sent,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            }
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .ping, payload: Data(repeating: 0x41, count: 126))
        )

        guard let closeFrame = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected protocol close frame for oversized control frame")
        }
        XCTAssertEqual(closeFrame.opcode, .connectionClose)
        XCTAssertEqual(closeCode(from: closeFrame), 1002)
    }

    func testCloseFrameWithInvalidPayloadLengthTriggersProtocolClose() throws {
        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .sent,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            }
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .connectionClose, payload: Data([0x03]))
        )

        guard let closeFrame = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected protocol close frame for invalid close payload length")
        }
        XCTAssertEqual(closeFrame.opcode, .connectionClose)
        XCTAssertEqual(closeCode(from: closeFrame), 1002)
    }

    func testCloseFrameWithInvalidReasonUTF8TriggersInvalidPayloadClose() throws {
        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .sent,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            }
        )

        var closePayload = Data([0x03, 0xE8]) // 1000
        closePayload.append(0xFF) // Invalid UTF-8 byte in reason

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .connectionClose, payload: closePayload)
        )

        guard let closeFrame = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected close frame for invalid close reason UTF-8")
        }
        XCTAssertEqual(closeFrame.opcode, .connectionClose)
        XCTAssertEqual(closeCode(from: closeFrame), 1007)
    }

    func testRSV1WithoutNegotiatedDeflateTriggersProtocolClose() throws {
        let inbound = EmbeddedChannel()
        let peer = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try inbound.finish(acceptAlreadyClosed: true))
            XCTAssertNoThrow(try peer.finish(acceptAlreadyClosed: true))
        }

        let runtime = StreamSessionRuntime(
            protocolType: .websocket,
            url: "wss://echo.example/ws",
            requestHeaders: []
        )
        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://echo.example/ws",
            requestHeaders: [],
            sessionID: runtime.snapshot().id
        )
        let handler = NIOMITMWebSocketRelayHandler(
            peerChannel: peer,
            direction: .sent,
            captureState: captureState,
            streamRuntime: runtime,
            interceptDecisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            },
            perMessageDeflateEnabled: false
        )

        try inbound.pipeline.addHandler(handler).wait()
        try inbound.writeInbound(
            makeFrame(fin: true, opcode: .text, payload: Data("hello".utf8), rsv1: true)
        )

        guard let closeFrame = try peer.readOutbound(as: WebSocketFrame.self) else {
            return XCTFail("Expected protocol close frame for unexpected RSV1")
        }
        XCTAssertEqual(closeFrame.opcode, .connectionClose)
        XCTAssertEqual(closeCode(from: closeFrame), 1002)
    }

    private func makeFrame(
        fin: Bool,
        opcode: WebSocketOpcode,
        payload: Data,
        rsv1: Bool = false
    ) -> WebSocketFrame {
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        if !payload.isEmpty {
            buffer.writeBytes(payload)
        }
        return WebSocketFrame(
            fin: fin,
            rsv1: rsv1,
            rsv2: false,
            rsv3: false,
            opcode: opcode,
            maskKey: nil,
            data: buffer
        )
    }

    private func framePayloadData(_ frame: WebSocketFrame) -> Data {
        var payload = frame.unmaskedData
        return payload.readData(length: payload.readableBytes) ?? Data()
    }

    private func closeCode(from frame: WebSocketFrame) -> UInt16? {
        let payload = framePayloadData(frame)
        guard payload.count >= 2 else {
            return nil
        }
        return (UInt16(payload[0]) << 8) | UInt16(payload[1])
    }
}
