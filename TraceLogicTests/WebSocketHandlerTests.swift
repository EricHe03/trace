//
//  WebSocketHandlerTests.swift
//  TraceTests
//
//  Updated for NIO WebSocket model-based capture.
//

import XCTest
import NIOWebSocket
@testable import TraceCore

final class WebSocketHandlerTests: XCTestCase {
    func testWebSocketMessageTypeFromOpcodeRoundTrip() {
        let opcodes: [(UInt8, WebSocketMessageType)] = [
            (0x0, .continuation),
            (0x1, .text),
            (0x2, .binary),
            (0x8, .close),
            (0x9, .ping),
            (0xA, .pong)
        ]

        for (opcode, expected) in opcodes {
            XCTAssertEqual(WebSocketMessageType(opcode: opcode), expected)
            XCTAssertEqual(expected.opcode, opcode)
        }

        XCTAssertNil(WebSocketMessageType(opcode: 0x3))
    }

    func testWebSocketConnectionTracksSentAndReceivedMessages() {
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [],
            responseHeaders: []
        )

        connection.addMessage(
            WebSocketMessage(
                direction: .sent,
                payload: Data("ping".utf8),
                messageType: .text,
                isFinal: true,
                isMasked: true
            )
        )
        connection.addMessage(
            WebSocketMessage(
                direction: .received,
                payload: Data("pong".utf8),
                messageType: .text,
                isFinal: true,
                isMasked: false
            )
        )

        XCTAssertEqual(connection.messageCount, 2)
        XCTAssertEqual(connection.sentMessageCount, 1)
        XCTAssertEqual(connection.receivedMessageCount, 1)
    }

    func testWebSocketMessagePreviewForTextAndBinary() {
        let text = WebSocketMessage(
            direction: .sent,
            payload: Data("hello websocket".utf8),
            messageType: .text
        )
        XCTAssertEqual(text.textPayload, "hello websocket")
        XCTAssertTrue(text.preview.contains("hello websocket"))

        let binary = WebSocketMessage(
            direction: .received,
            payload: Data([0x01, 0xAB, 0xFF]),
            messageType: .binary
        )
        XCTAssertEqual(binary.textPayload, nil)
        XCTAssertTrue(binary.preview.contains("01 ab ff"))
    }

    func testWebSocketConnectionCloseStoresMetadata() {
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [],
            responseHeaders: []
        )

        connection.close(code: 1000, reason: "normal")

        XCTAssertEqual(connection.status, .closed)
        XCTAssertEqual(connection.closeCode, 1000)
        XCTAssertEqual(connection.closeReason, "normal")
        XCTAssertNotNil(connection.endTime)
        XCTAssertNotNil(connection.duration)
    }

    func testNIOWebSocketOpcodeMappingMatchesModelEnum() {
        XCTAssertEqual(WebSocketMessageType(opcode: UInt8(webSocketOpcode: .text)), .text)
        XCTAssertEqual(WebSocketMessageType(opcode: UInt8(webSocketOpcode: .binary)), .binary)
        XCTAssertEqual(WebSocketMessageType(opcode: UInt8(webSocketOpcode: .connectionClose)), .close)
        XCTAssertEqual(WebSocketMessageType(opcode: UInt8(webSocketOpcode: .ping)), .ping)
        XCTAssertEqual(WebSocketMessageType(opcode: UInt8(webSocketOpcode: .pong)), .pong)
    }
}
