//
//  WebSocketMessageTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class WebSocketMessageTests: XCTestCase {

    // MARK: - Initialization Tests

    func testMessageInitialization() {
        let payload = "Hello, WebSocket!".data(using: .utf8)!
        let timestamp = Date()

        let message = WebSocketMessage(
            direction: .sent,
            timestamp: timestamp,
            payload: payload,
            messageType: .text
        )

        XCTAssertEqual(message.direction, .sent)
        XCTAssertEqual(message.timestamp, timestamp)
        XCTAssertEqual(message.payload, payload)
        XCTAssertEqual(message.messageType, .text)
        XCTAssertTrue(message.isFinal)
        XCTAssertFalse(message.isMasked)
        XCTAssertEqual(message.payloadLength, payload.count)
    }

    func testMessageInitializationWithCustomPayloadLength() {
        let payload = "test".data(using: .utf8)!

        let message = WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: payload,
            messageType: .text,
            payloadLength: 100
        )

        XCTAssertEqual(message.payloadLength, 100)
    }

    func testMessageInitializationDefaults() {
        let payload = "test".data(using: .utf8)!

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        XCTAssertTrue(message.isFinal)
        XCTAssertFalse(message.isMasked)
        XCTAssertEqual(message.payloadLength, payload.count)
    }

    // MARK: - Text Payload Tests

    func testTextPayloadForTextMessage() {
        let text = "Hello, WebSocket!"
        let payload = text.data(using: .utf8)!

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        XCTAssertEqual(message.textPayload, text)
    }

    func testTextPayloadForNonTextMessage() {
        let payload = Data([0x01, 0x02, 0x03])

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .binary
        )

        XCTAssertNil(message.textPayload)
    }

    func testTextPayloadEmptyString() {
        let payload = "".data(using: .utf8)!

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        XCTAssertEqual(message.textPayload, "")
    }

    func testTextPayloadWithUnicode() {
        let text = "Hello 世界 🌍"
        let payload = text.data(using: .utf8)!

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        XCTAssertEqual(message.textPayload, text)
    }

    // MARK: - Hex Payload Tests

    func testHexPayloadSimple() {
        let payload = Data([0x01, 0x02, 0x03])

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .binary
        )

        XCTAssertEqual(message.hexPayload, "01 02 03")
    }

    func testHexPayloadEmpty() {
        let payload = Data()

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .binary
        )

        XCTAssertEqual(message.hexPayload, "")
    }

    func testHexPayloadLargeValues() {
        let payload = Data([0xAB, 0xCD, 0xEF, 0xFF])

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .binary
        )

        XCTAssertEqual(message.hexPayload, "ab cd ef ff")
    }

    // MARK: - Size String Tests

    func testSizeStringSmallPayload() {
        let payload = Data(count: 100)

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .binary
        )

        XCTAssertTrue(message.sizeString.contains("100"))
    }

    func testSizeStringLargePayload() {
        let payload = Data(count: 1024 * 1024) // 1 MB

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .binary
        )

        XCTAssertTrue(message.sizeString.contains("MB") || message.sizeString.contains("1"))
    }

    // MARK: - Preview Tests

    func testPreviewShortTextMessage() {
        let text = "Hello!"
        let payload = text.data(using: .utf8)!

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        XCTAssertEqual(message.preview, "Hello!")
    }

    func testPreviewLongTextMessage() {
        let text = String(repeating: "a", count: 150)
        let payload = text.data(using: .utf8)!

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        XCTAssertTrue(message.preview.hasSuffix("..."))
        XCTAssertTrue(message.preview.count <= 103) // 100 chars + "..."
    }

    func testPreviewBinaryMessage() {
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .binary
        )

        XCTAssertEqual(message.preview, "01 02 03 04 05")
    }

    func testPreviewLongBinaryMessage() {
        let payload = Data(count: 30) // More than 20 bytes

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .binary
        )

        XCTAssertTrue(message.preview.hasSuffix("..."))
    }

    func testPreviewPingMessage() {
        let payload = Data()

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .ping
        )

        XCTAssertEqual(message.preview, "[Ping]")
    }

    func testPreviewPongMessage() {
        let payload = Data()

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .pong
        )

        XCTAssertEqual(message.preview, "[Pong]")
    }

    func testPreviewCloseMessage() {
        let payload = Data()

        let message = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .close
        )

        XCTAssertEqual(message.preview, "[Close Frame]")
    }

    // MARK: - Equatable Tests

    func testEquatableSameId() {
        let id = UUID()
        let payload = "test".data(using: .utf8)!

        let message1 = WebSocketMessage(
            id: id,
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        let message2 = WebSocketMessage(
            id: id,
            direction: .received,
            payload: Data(),
            messageType: .binary
        )

        XCTAssertEqual(message1, message2) // Same ID means equal
    }

    func testEquatableDifferentIds() {
        let payload = "test".data(using: .utf8)!

        let message1 = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        let message2 = WebSocketMessage(
            direction: .sent,
            payload: payload,
            messageType: .text
        )

        XCTAssertNotEqual(message1, message2)
    }
}

// MARK: - WebSocketMessageType Tests

final class WebSocketMessageTypeTests: XCTestCase {

    func testOpcodeValues() {
        XCTAssertEqual(WebSocketMessageType.continuation.opcode, 0x0)
        XCTAssertEqual(WebSocketMessageType.text.opcode, 0x1)
        XCTAssertEqual(WebSocketMessageType.binary.opcode, 0x2)
        XCTAssertEqual(WebSocketMessageType.close.opcode, 0x8)
        XCTAssertEqual(WebSocketMessageType.ping.opcode, 0x9)
        XCTAssertEqual(WebSocketMessageType.pong.opcode, 0xA)
    }

    func testInitFromValidOpcode() {
        XCTAssertEqual(WebSocketMessageType(opcode: 0x0), .continuation)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x1), .text)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x2), .binary)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x8), .close)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x9), .ping)
        XCTAssertEqual(WebSocketMessageType(opcode: 0xA), .pong)
    }

    func testInitFromInvalidOpcode() {
        XCTAssertNil(WebSocketMessageType(opcode: 0x3))
        XCTAssertNil(WebSocketMessageType(opcode: 0x7))
        XCTAssertNil(WebSocketMessageType(opcode: 0xB))
        XCTAssertNil(WebSocketMessageType(opcode: 0xFF))
    }

    func testDisplayNames() {
        XCTAssertEqual(WebSocketMessageType.text.displayName, "Text")
        XCTAssertEqual(WebSocketMessageType.binary.displayName, "Binary")
        XCTAssertEqual(WebSocketMessageType.ping.displayName, "Ping")
        XCTAssertEqual(WebSocketMessageType.pong.displayName, "Pong")
        XCTAssertEqual(WebSocketMessageType.close.displayName, "Close")
        XCTAssertEqual(WebSocketMessageType.continuation.displayName, "Continuation")
    }

    func testCaseIterable() {
        let allCases = WebSocketMessageType.allCases
        XCTAssertEqual(allCases.count, 6)
        XCTAssertTrue(allCases.contains(.text))
        XCTAssertTrue(allCases.contains(.binary))
        XCTAssertTrue(allCases.contains(.ping))
        XCTAssertTrue(allCases.contains(.pong))
        XCTAssertTrue(allCases.contains(.close))
        XCTAssertTrue(allCases.contains(.continuation))
    }

    func testEquatable() {
        XCTAssertEqual(WebSocketMessageType.text, .text)
        XCTAssertNotEqual(WebSocketMessageType.text, .binary)
    }

    func testRawValueRoundTrip() {
        for messageType in WebSocketMessageType.allCases {
            let opcode = messageType.opcode
            let reconstructed = WebSocketMessageType(opcode: opcode)
            XCTAssertEqual(reconstructed, messageType)
        }
    }
}

// MARK: - WebSocketDirection Tests

final class WebSocketDirectionTests: XCTestCase {

    func testDisplayNames() {
        XCTAssertEqual(WebSocketDirection.sent.displayName, "Sent")
        XCTAssertEqual(WebSocketDirection.received.displayName, "Received")
    }

    func testSymbols() {
        XCTAssertEqual(WebSocketDirection.sent.symbol, "↑")
        XCTAssertEqual(WebSocketDirection.received.symbol, "↓")
    }

    func testColors() {
        XCTAssertEqual(WebSocketDirection.sent.color, .info)
        XCTAssertEqual(WebSocketDirection.received.color, .success)
    }

    func testCaseIterable() {
        let allCases = WebSocketDirection.allCases
        XCTAssertEqual(allCases.count, 2)
        XCTAssertTrue(allCases.contains(.sent))
        XCTAssertTrue(allCases.contains(.received))
    }

    func testRawValues() {
        XCTAssertEqual(WebSocketDirection.sent.rawValue, "sent")
        XCTAssertEqual(WebSocketDirection.received.rawValue, "received")
    }
}
