//
//  NIOMITMWebSocketRelayHandlerBehaviorTests.swift
//  TraceTests
//
//  Created by Codex on 2026/03/05.
//

import XCTest
import NIOCore
import NIOEmbedded
import NIOWebSocket
@testable import TraceProxy

final class NIOMITMWebSocketRelayHandlerBehaviorTests: XCTestCase {
    func testMaskedClientFrameForwardsWithCorrectPayload() throws {
        let upstreamChannel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try upstreamChannel.finish(acceptAlreadyClosed: true)) }
        try upstreamChannel.pipeline.addHandler(WebSocketFrameEncoder()).wait()

        let clientChannel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try clientChannel.finish(acceptAlreadyClosed: true)) }

        let captureState = NIOMITMWebSocketCaptureState(
            url: "wss://example.com/socket",
            requestHeaders: []
        )
        let relay = NIOMITMWebSocketRelayHandler(
            peerChannel: upstreamChannel,
            direction: .sent,
            captureState: captureState
        )
        try clientChannel.pipeline.addHandler(relay).wait()

        let payload = "test message"
        let maskKey: WebSocketMaskingKey = [0x11, 0x22, 0x33, 0x44]
        var masked = clientChannel.allocator.buffer(capacity: payload.utf8.count)
        masked.writeBytes(payload.utf8)
        masked.webSocketMask(maskKey)

        let inboundFrame = WebSocketFrame(
            fin: true,
            opcode: .text,
            maskKey: maskKey,
            data: masked
        )

        try clientChannel.writeInbound(inboundFrame)
        upstreamChannel.embeddedEventLoop.run()

        var outbound = upstreamChannel.allocator.buffer(capacity: 0)
        while var part = try upstreamChannel.readOutbound(as: ByteBuffer.self) {
            outbound.writeBuffer(&part)
        }

        let decodeChannel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try decodeChannel.finish(acceptAlreadyClosed: true)) }
        try decodeChannel.pipeline.addHandler(
            ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1 << 20))
        ).wait()

        try decodeChannel.writeInbound(outbound)
        let decodedFrame = try decodeChannel.readInbound(as: WebSocketFrame.self)
        XCTAssertNotNil(decodedFrame)

        guard let decodedFrame else { return }
        XCTAssertEqual(decodedFrame.opcode, .text)
        XCTAssertEqual(decodedFrame.maskKey, maskKey)

        var decodedPayload = decodedFrame.unmaskedData
        let decodedBytes = decodedPayload.readBytes(length: decodedPayload.readableBytes) ?? []
        XCTAssertEqual(String(bytes: decodedBytes, encoding: .utf8), payload)
    }
}

