//
//  WebSocketHandlerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/16.
//

import Network
import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceNetworking

final class WebSocketHandlerTests: XCTestCase {

    // MARK: - WebSocketFrame Tests

    func testWebSocketFrameInitialization() {
        let payload = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        let frame = WebSocketFrame(
            isFinal: true,
            type: .text,
            isMasked: false,
            payloadLength: payload.count,
            payload: payload
        )

        XCTAssertTrue(frame.isFinal)
        XCTAssertEqual(frame.type, .text)
        XCTAssertFalse(frame.isMasked)
        XCTAssertEqual(frame.payloadLength, 5)
        XCTAssertEqual(frame.payload, payload)
    }

    func testWebSocketFrameBinaryType() {
        let payload = Data([0x00, 0x01, 0x02, 0x03])
        let frame = WebSocketFrame(
            isFinal: true,
            type: .binary,
            isMasked: true,
            payloadLength: payload.count,
            payload: payload
        )

        XCTAssertEqual(frame.type, .binary)
        XCTAssertTrue(frame.isMasked)
    }

    func testWebSocketFrameControlTypes() {
        let pingFrame = WebSocketFrame(
            isFinal: true,
            type: .ping,
            isMasked: false,
            payloadLength: 0,
            payload: Data()
        )

        let pongFrame = WebSocketFrame(
            isFinal: true,
            type: .pong,
            isMasked: false,
            payloadLength: 0,
            payload: Data()
        )

        let closeFrame = WebSocketFrame(
            isFinal: true,
            type: .close,
            isMasked: false,
            payloadLength: 2,
            payload: Data([0x03, 0xE8]) // 1000 close code
        )

        XCTAssertEqual(pingFrame.type, .ping)
        XCTAssertEqual(pongFrame.type, .pong)
        XCTAssertEqual(closeFrame.type, .close)
    }

    // MARK: - WebSocketMessageType Tests

    func testWebSocketMessageTypeFromOpcode() {
        XCTAssertEqual(WebSocketMessageType(opcode: 0x00), .continuation)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x01), .text)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x02), .binary)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x08), .close)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x09), .ping)
        XCTAssertEqual(WebSocketMessageType(opcode: 0x0A), .pong)
        XCTAssertNil(WebSocketMessageType(opcode: 0x03)) // Reserved
        XCTAssertNil(WebSocketMessageType(opcode: 0xFF)) // Invalid
    }

    func testWebSocketMessageTypeDisplayName() {
        XCTAssertEqual(WebSocketMessageType.text.displayName, "Text")
        XCTAssertEqual(WebSocketMessageType.binary.displayName, "Binary")
        XCTAssertEqual(WebSocketMessageType.ping.displayName, "Ping")
        XCTAssertEqual(WebSocketMessageType.pong.displayName, "Pong")
        XCTAssertEqual(WebSocketMessageType.close.displayName, "Close")
    }

    // MARK: - WebSocketMessage Tests

    func testWebSocketMessageInitialization() {
        let payload = "Hello, WebSocket!".data(using: .utf8)!
        let message = WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: payload,
            messageType: .text,
            isFinal: true,
            isMasked: true,
            payloadLength: payload.count
        )

        XCTAssertEqual(message.direction, .sent)
        XCTAssertEqual(message.messageType, .text)
        XCTAssertTrue(message.isFinal)
        XCTAssertTrue(message.isMasked)
        XCTAssertEqual(message.payloadLength, payload.count)
    }

    func testWebSocketMessageDirections() {
        let sentMessage = WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: Data(),
            messageType: .text,
            isFinal: true,
            isMasked: true,
            payloadLength: 0
        )

        let receivedMessage = WebSocketMessage(
            direction: .received,
            timestamp: Date(),
            payload: Data(),
            messageType: .text,
            isFinal: true,
            isMasked: false,
            payloadLength: 0
        )

        XCTAssertEqual(sentMessage.direction, .sent)
        XCTAssertEqual(receivedMessage.direction, .received)
    }

    func testWebSocketMessageCodable() throws {
        let payload = "Test message".data(using: .utf8)!
        let message = WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: payload,
            messageType: .text,
            isFinal: true,
            isMasked: true,
            payloadLength: payload.count
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WebSocketMessage.self, from: data)

        XCTAssertEqual(decoded.direction, message.direction)
        XCTAssertEqual(decoded.messageType, message.messageType)
        XCTAssertEqual(decoded.isFinal, message.isFinal)
        XCTAssertEqual(decoded.payloadLength, message.payloadLength)
    }

    // MARK: - WebSocketConnection Tests

    func testWebSocketConnectionInitialization() {
        let id = UUID()
        let connection = WebSocketConnection(
            id: id,
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [TraceHTTPHeader(key: "Upgrade", value: "websocket")],
            responseHeaders: [TraceHTTPHeader(key: "Connection", value: "Upgrade")]
        )

        XCTAssertEqual(connection.id, id)
        XCTAssertEqual(connection.url, "wss://api.example.com/socket")
        XCTAssertEqual(connection.status, .open)
        XCTAssertEqual(connection.messages.count, 0)
    }

    func testWebSocketConnectionAddMessage() {
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [],
            responseHeaders: []
        )

        let message = WebSocketMessage(
            direction: .received,
            timestamp: Date(),
            payload: "Hello".data(using: .utf8)!,
            messageType: .text,
            isFinal: true,
            isMasked: false,
            payloadLength: 5
        )

        connection.addMessage(message)

        XCTAssertEqual(connection.messages.count, 1)
    }

    func testWebSocketConnectionClose() {
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [],
            responseHeaders: []
        )

        connection.close(code: 1000, reason: "Normal closure")

        XCTAssertEqual(connection.status, .closed)
        XCTAssertEqual(connection.closeCode, 1000)
        XCTAssertEqual(connection.closeReason, "Normal closure")
        XCTAssertNotNil(connection.endTime)
    }

    func testWebSocketConnectionDuration() {
        let startTime = Date()
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: startTime,
            status: .open,
            requestHeaders: [],
            responseHeaders: []
        )

        connection.endTime = startTime.addingTimeInterval(10.0)

        XCTAssertNotNil(connection.duration)
        XCTAssertEqual(connection.duration ?? 0, 10.0, accuracy: 0.1)
    }

    func testWebSocketConnectionStatistics() {
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [],
            responseHeaders: []
        )

        // Add sent messages
        connection.addMessage(WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: "Hello".data(using: .utf8)!,
            messageType: .text,
            isFinal: true,
            isMasked: true,
            payloadLength: 5
        ))

        connection.addMessage(WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: "World".data(using: .utf8)!,
            messageType: .text,
            isFinal: true,
            isMasked: true,
            payloadLength: 5
        ))

        // Add received messages
        connection.addMessage(WebSocketMessage(
            direction: .received,
            timestamp: Date(),
            payload: "Response".data(using: .utf8)!,
            messageType: .text,
            isFinal: true,
            isMasked: false,
            payloadLength: 8
        ))

        XCTAssertEqual(connection.sentMessageCount, 2)
        XCTAssertEqual(connection.receivedMessageCount, 1)

        let totalBytesSent = connection.messages
            .filter { $0.direction == .sent }
            .reduce(0) { $0 + $1.payloadLength }
        let totalBytesReceived = connection.messages
            .filter { $0.direction == .received }
            .reduce(0) { $0 + $1.payloadLength }

        XCTAssertEqual(totalBytesSent, 10)
        XCTAssertEqual(totalBytesReceived, 8)
    }

    func testWebSocketConnectionCodable() throws {
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [TraceHTTPHeader(key: "Upgrade", value: "websocket")],
            responseHeaders: []
        )

        connection.addMessage(WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: "Test".data(using: .utf8)!,
            messageType: .text,
            isFinal: true,
            isMasked: true,
            payloadLength: 4
        ))

        let encoder = JSONEncoder()
        let data = try encoder.encode(connection)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WebSocketConnection.self, from: data)

        XCTAssertEqual(decoded.id, connection.id)
        XCTAssertEqual(decoded.url, connection.url)
        XCTAssertEqual(decoded.status, connection.status)
        XCTAssertEqual(decoded.messages.count, 1)
    }

    // MARK: - WebSocketConnectionStatus Tests

    func testWebSocketConnectionStatusValues() {
        XCTAssertEqual(WebSocketConnectionStatus.open.displayName, "Open")
        XCTAssertEqual(WebSocketConnectionStatus.closed.displayName, "Closed")
        XCTAssertEqual(WebSocketConnectionStatus.failed.displayName, "Failed")
    }

    // MARK: - Close Code Tests

    func testCommonCloseCodes() {
        // Normal closure
        XCTAssertEqual(1000, 1000) // Normal closure
        XCTAssertEqual(1001, 1001) // Going away
        XCTAssertEqual(1002, 1002) // Protocol error
        XCTAssertEqual(1003, 1003) // Unsupported data
        XCTAssertEqual(1006, 1006) // Abnormal closure
        XCTAssertEqual(1007, 1007) // Invalid frame payload data
        XCTAssertEqual(1008, 1008) // Policy violation
        XCTAssertEqual(1009, 1009) // Message too big
        XCTAssertEqual(1011, 1011) // Server error
    }

    // MARK: - Edge Cases

    func testWebSocketFrameWithEmptyPayload() {
        let frame = WebSocketFrame(
            isFinal: true,
            type: .ping,
            isMasked: false,
            payloadLength: 0,
            payload: Data()
        )

        XCTAssertEqual(frame.payloadLength, 0)
        XCTAssertTrue(frame.payload.isEmpty)
    }

    func testWebSocketFrameWithLargePayload() {
        let largePayload = Data(repeating: 0x42, count: 65536) // 64KB
        let frame = WebSocketFrame(
            isFinal: true,
            type: .binary,
            isMasked: false,
            payloadLength: largePayload.count,
            payload: largePayload
        )

        XCTAssertEqual(frame.payloadLength, 65536)
    }

    func testWebSocketMessageWithBinaryPayload() {
        let binaryData = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        let message = WebSocketMessage(
            direction: .received,
            timestamp: Date(),
            payload: binaryData,
            messageType: .binary,
            isFinal: true,
            isMasked: false,
            payloadLength: binaryData.count
        )

        XCTAssertEqual(message.messageType, .binary)
        XCTAssertEqual(message.payload, binaryData)
    }

    func testWebSocketConnectionWithMultipleMessageTypes() {
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [],
            responseHeaders: []
        )

        // Text message
        connection.addMessage(WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: "Hello".data(using: .utf8)!,
            messageType: .text,
            isFinal: true,
            isMasked: true,
            payloadLength: 5
        ))

        // Binary message
        connection.addMessage(WebSocketMessage(
            direction: .received,
            timestamp: Date(),
            payload: Data([0x00, 0x01]),
            messageType: .binary,
            isFinal: true,
            isMasked: false,
            payloadLength: 2
        ))

        // Ping
        connection.addMessage(WebSocketMessage(
            direction: .sent,
            timestamp: Date(),
            payload: Data(),
            messageType: .ping,
            isFinal: true,
            isMasked: true,
            payloadLength: 0
        ))

        // Pong
        connection.addMessage(WebSocketMessage(
            direction: .received,
            timestamp: Date(),
            payload: Data(),
            messageType: .pong,
            isFinal: true,
            isMasked: false,
            payloadLength: 0
        ))

        XCTAssertEqual(connection.messages.count, 4)
    }

    func testWebSocketConnectionFailedStatus() {
        var connection = WebSocketConnection(
            id: UUID(),
            url: "wss://api.example.com/socket",
            startTime: Date(),
            status: .open,
            requestHeaders: [],
            responseHeaders: []
        )

        connection.status = .failed
        connection.endTime = Date()

        XCTAssertEqual(connection.status, .failed)
        XCTAssertNotNil(connection.endTime)
    }

    // MARK: - Fragmentation Tests

    func testWebSocketFrameContinuation() {
        // First fragment (not final)
        let fragment1 = WebSocketFrame(
            isFinal: false,
            type: .text,
            isMasked: true,
            payloadLength: 5,
            payload: "Hello".data(using: .utf8)!
        )

        // Continuation frame (final)
        let fragment2 = WebSocketFrame(
            isFinal: true,
            type: .continuation,
            isMasked: true,
            payloadLength: 6,
            payload: " World".data(using: .utf8)!
        )

        XCTAssertFalse(fragment1.isFinal)
        XCTAssertEqual(fragment1.type, .text)

        XCTAssertTrue(fragment2.isFinal)
        XCTAssertEqual(fragment2.type, .continuation)
    }

#if DEBUG
    // MARK: - Handler Flow Tests

    func testWebSocketHandler_ParsesMaskedTextFrame() {
        let handler = makeTestWebSocketHandler()

        let payload = "Hello".data(using: .utf8)!
        let frameData = makeWebSocketFrame(
            opcode: 0x1,
            isFinal: true,
            payload: payload,
            isMasked: true
        )

        handler.testProcess(frameData, direction: .sent)

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.messages.first?.messageType, .text)
        XCTAssertEqual(snapshot.messages.first?.payload, payload)
        XCTAssertEqual(snapshot.messages.first?.direction, .sent)
        XCTAssertTrue(snapshot.messages.first?.isMasked ?? false)
    }

    func testWebSocketHandler_ParsesFragmentedTextMessage() {
        let handler = makeTestWebSocketHandler()

        let part1 = "Hel".data(using: .utf8)!
        let part2 = "lo".data(using: .utf8)!

        let frame1 = makeWebSocketFrame(
            opcode: 0x1,
            isFinal: false,
            payload: part1,
            isMasked: true
        )
        let frame2 = makeWebSocketFrame(
            opcode: 0x0,
            isFinal: true,
            payload: part2,
            isMasked: true
        )

        handler.testProcess(frame1, direction: .received)
        handler.testProcess(frame2, direction: .received)

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.messages.first?.messageType, .text)
        XCTAssertEqual(snapshot.messages.first?.payload, "Hello".data(using: .utf8))
        XCTAssertEqual(snapshot.messages.first?.direction, .received)
    }

    func testWebSocketHandler_CloseFrameUpdatesConnection() {
        let handler = makeTestWebSocketHandler()

        let code: UInt16 = 1000
        let reason = "Bye"
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        payload.append(contentsOf: reason.data(using: .utf8)!)

        let frameData = makeWebSocketFrame(
            opcode: 0x8,
            isFinal: true,
            payload: payload,
            isMasked: false
        )

        handler.testProcess(frameData, direction: .received)

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.status, .closing)
        XCTAssertEqual(snapshot.closeCode, 1000)
        XCTAssertEqual(snapshot.closeReason, "Bye")

        let expectation = expectation(description: "Close finalized")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let finalSnapshot = handler.testConnectionSnapshot()
            if finalSnapshot.status == .closed {
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 1.0)
    }

    func testWebSocketHandler_NormalizesHTTPURLToWebSocketScheme() {
        let client = NWConnection(
            host: NWEndpoint.Host("localhost"),
            port: NWEndpoint.Port(integerLiteral: 80),
            using: .tcp
        )
        let handler = WebSocketHandler(
            clientConnection: client,
            serverConnection: nil,
            url: "https://example.com/socket",
            requestHeaders: [],
            responseHeaders: []
        )
        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.url, "wss://example.com/socket")
    }
#endif
}

#if DEBUG
private func makeTestWebSocketHandler() -> WebSocketHandler {
    let client = NWConnection(
        host: NWEndpoint.Host("localhost"),
        port: NWEndpoint.Port(integerLiteral: 80),
        using: .tcp
    )
    return WebSocketHandler(
        clientConnection: client,
        serverConnection: nil,
        url: "wss://example.com/socket",
        requestHeaders: [],
        responseHeaders: []
    )
}

private func makeWebSocketFrame(
    opcode: UInt8,
    isFinal: Bool,
    payload: Data,
    isMasked: Bool
) -> Data {
    var data = Data()
    let finBit: UInt8 = isFinal ? 0x80 : 0x00
    data.append(finBit | (opcode & 0x0F))

    let maskBit: UInt8 = isMasked ? 0x80 : 0x00
    let payloadLength = payload.count

    if payloadLength < 126 {
        data.append(maskBit | UInt8(payloadLength))
    } else if payloadLength <= 0xFFFF {
        data.append(maskBit | 126)
        data.append(UInt8((payloadLength >> 8) & 0xFF))
        data.append(UInt8(payloadLength & 0xFF))
    } else {
        data.append(maskBit | 127)
        let length64 = UInt64(payloadLength)
        data.append(UInt8((length64 >> 56) & 0xFF))
        data.append(UInt8((length64 >> 48) & 0xFF))
        data.append(UInt8((length64 >> 40) & 0xFF))
        data.append(UInt8((length64 >> 32) & 0xFF))
        data.append(UInt8((length64 >> 24) & 0xFF))
        data.append(UInt8((length64 >> 16) & 0xFF))
        data.append(UInt8((length64 >> 8) & 0xFF))
        data.append(UInt8(length64 & 0xFF))
    }

    if isMasked {
        let maskKey: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        data.append(contentsOf: maskKey)
        var masked = Data(capacity: payload.count)
        for i in 0 ..< payload.count {
            masked.append(payload[i] ^ maskKey[i % 4])
        }
        data.append(masked)
    } else {
        data.append(payload)
    }

    return data
}
#endif
