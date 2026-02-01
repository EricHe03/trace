//
//  WebSocketConnectionTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class WebSocketConnectionTests: XCTestCase {

    // MARK: - WebSocketConnectionStatus Tests

    func testWebSocketConnectionStatusRawValues() {
        XCTAssertEqual(WebSocketConnectionStatus.connecting.rawValue, "connecting")
        XCTAssertEqual(WebSocketConnectionStatus.open.rawValue, "open")
        XCTAssertEqual(WebSocketConnectionStatus.closing.rawValue, "closing")
        XCTAssertEqual(WebSocketConnectionStatus.closed.rawValue, "closed")
        XCTAssertEqual(WebSocketConnectionStatus.failed.rawValue, "failed")
    }

    func testWebSocketConnectionStatusDisplayNames() {
        XCTAssertEqual(WebSocketConnectionStatus.connecting.displayName, "Connecting")
        XCTAssertEqual(WebSocketConnectionStatus.open.displayName, "Open")
        XCTAssertEqual(WebSocketConnectionStatus.closing.displayName, "Closing")
        XCTAssertEqual(WebSocketConnectionStatus.closed.displayName, "Closed")
        XCTAssertEqual(WebSocketConnectionStatus.failed.displayName, "Failed")
    }

    func testWebSocketConnectionStatusColors() {
        XCTAssertEqual(WebSocketConnectionStatus.connecting.color, .info)
        XCTAssertEqual(WebSocketConnectionStatus.open.color, .success)
        XCTAssertEqual(WebSocketConnectionStatus.closing.color, .warning)
        XCTAssertEqual(WebSocketConnectionStatus.closed.color, .unknown)
        XCTAssertEqual(WebSocketConnectionStatus.failed.color, .clientError)
    }

    func testWebSocketConnectionStatusCodable() throws {
        for status in WebSocketConnectionStatus.allCases {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(WebSocketConnectionStatus.self, from: encoded)
            XCTAssertEqual(status, decoded)
        }
    }

    func testWebSocketConnectionStatusCaseIterable() {
        let allCases = WebSocketConnectionStatus.allCases
        XCTAssertEqual(allCases.count, 5)
        XCTAssertTrue(allCases.contains(.connecting))
        XCTAssertTrue(allCases.contains(.open))
        XCTAssertTrue(allCases.contains(.closing))
        XCTAssertTrue(allCases.contains(.closed))
        XCTAssertTrue(allCases.contains(.failed))
    }

    // MARK: - WebSocketConnection Initializer Tests

    func testWebSocketConnectionInitWithDefaults() {
        let connection = WebSocketConnection(url: "wss://example.com/ws")

        XCTAssertNotNil(connection.id)
        XCTAssertEqual(connection.url, "wss://example.com/ws")
        XCTAssertNotNil(connection.startTime)
        XCTAssertNil(connection.endTime)
        XCTAssertTrue(connection.messages.isEmpty)
        XCTAssertEqual(connection.status, .connecting)
        XCTAssertTrue(connection.requestHeaders.isEmpty)
        XCTAssertTrue(connection.responseHeaders.isEmpty)
        XCTAssertNil(connection.closeCode)
        XCTAssertNil(connection.closeReason)
    }

    func testWebSocketConnectionInitWithAllParameters() {
        let id = UUID()
        let startTime = Date()
        let endTime = Date().addingTimeInterval(10)
        let messages = [
            WebSocketMessage(direction: .sent, payload: Data(), messageType: .text),
            WebSocketMessage(direction: .received, payload: Data(), messageType: .text)
        ]
        let requestHeaders = [TraceHTTPHeader(key: "Upgrade", value: "websocket")]
        let responseHeaders = [TraceHTTPHeader(key: "Connection", value: "Upgrade")]

        let connection = WebSocketConnection(
            id: id,
            url: "wss://example.com/ws",
            startTime: startTime,
            endTime: endTime,
            messages: messages,
            status: .open,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            closeCode: 1000,
            closeReason: "Normal closure"
        )

        XCTAssertEqual(connection.id, id)
        XCTAssertEqual(connection.url, "wss://example.com/ws")
        XCTAssertEqual(connection.startTime, startTime)
        XCTAssertEqual(connection.endTime, endTime)
        XCTAssertEqual(connection.messages.count, 2)
        XCTAssertEqual(connection.status, .open)
        XCTAssertEqual(connection.requestHeaders.count, 1)
        XCTAssertEqual(connection.responseHeaders.count, 1)
        XCTAssertEqual(connection.closeCode, 1000)
        XCTAssertEqual(connection.closeReason, "Normal closure")
    }

    // MARK: - WebSocketConnection Computed Properties Tests

    func testHostFromValidURL() {
        let connection = WebSocketConnection(url: "wss://api.example.com/socket")
        XCTAssertEqual(connection.host, "api.example.com")
    }

    func testHostFromURLWithoutHost() {
        let connection = WebSocketConnection(url: "invalid-url")
        XCTAssertEqual(connection.host, "invalid-url")
    }

    func testDurationWhenClosed() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(5.5)
        var connection = WebSocketConnection(url: "wss://example.com/ws", startTime: startTime)
        connection.endTime = endTime

        XCTAssertNotNil(connection.duration)
        XCTAssertEqual(connection.duration, 5.5, accuracy: 0.001)
    }

    func testDurationWhenActive() {
        let connection = WebSocketConnection(url: "wss://example.com/ws")
        XCTAssertNil(connection.duration)
    }

    func testMessageCount() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")
        XCTAssertEqual(connection.messageCount, 0)

        connection.messages.append(WebSocketMessage(direction: .sent, payload: Data(), messageType: .text))
        connection.messages.append(WebSocketMessage(direction: .received, payload: Data(), messageType: .text))
        XCTAssertEqual(connection.messageCount, 2)
    }

    func testSentMessageCount() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")
        connection.messages = [
            WebSocketMessage(direction: .sent, payload: Data(), messageType: .text),
            WebSocketMessage(direction: .sent, payload: Data(), messageType: .text),
            WebSocketMessage(direction: .received, payload: Data(), messageType: .text)
        ]

        XCTAssertEqual(connection.sentMessageCount, 2)
    }

    func testReceivedMessageCount() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")
        connection.messages = [
            WebSocketMessage(direction: .received, payload: Data(), messageType: .text),
            WebSocketMessage(direction: .received, payload: Data(), messageType: .text),
            WebSocketMessage(direction: .sent, payload: Data(), messageType: .text)
        ]

        XCTAssertEqual(connection.receivedMessageCount, 2)
    }

    func testIsActiveForConnecting() {
        let connection = WebSocketConnection(url: "wss://example.com/ws", status: .connecting)
        XCTAssertTrue(connection.isActive)
    }

    func testIsActiveForOpen() {
        let connection = WebSocketConnection(url: "wss://example.com/ws", status: .open)
        XCTAssertTrue(connection.isActive)
    }

    func testIsActiveForClosing() {
        let connection = WebSocketConnection(url: "wss://example.com/ws", status: .closing)
        XCTAssertFalse(connection.isActive)
    }

    func testIsActiveForClosed() {
        let connection = WebSocketConnection(url: "wss://example.com/ws", status: .closed)
        XCTAssertFalse(connection.isActive)
    }

    func testIsActiveForFailed() {
        let connection = WebSocketConnection(url: "wss://example.com/ws", status: .failed)
        XCTAssertFalse(connection.isActive)
    }

    // MARK: - WebSocketConnection Mutating Methods Tests

    func testAddMessage() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")
        XCTAssertEqual(connection.messages.count, 0)

        let message = WebSocketMessage(
            direction: .sent,
            payload: "Hello".data(using: .utf8)!,
            messageType: .text
        )
        connection.addMessage(message)

        XCTAssertEqual(connection.messages.count, 1)
        XCTAssertEqual(connection.messages.first?.direction, .sent)
    }

    func testAddMultipleMessages() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")

        connection.addMessage(WebSocketMessage(direction: .sent, payload: Data(), messageType: .text))
        connection.addMessage(WebSocketMessage(direction: .received, payload: Data(), messageType: .text))
        connection.addMessage(WebSocketMessage(direction: .sent, payload: Data(), messageType: .binary))

        XCTAssertEqual(connection.messages.count, 3)
    }

    func testCloseWithoutCodeOrReason() {
        let startTime = Date()
        var connection = WebSocketConnection(url: "wss://example.com/ws", startTime: startTime, status: .open)

        connection.close()

        XCTAssertEqual(connection.status, .closed)
        XCTAssertNotNil(connection.endTime)
        XCTAssertGreaterThanOrEqual(connection.endTime!, startTime)
        XCTAssertNil(connection.closeCode)
        XCTAssertNil(connection.closeReason)
    }

    func testCloseWithCode() {
        var connection = WebSocketConnection(url: "wss://example.com/ws", status: .open)

        connection.close(code: 1000)

        XCTAssertEqual(connection.status, .closed)
        XCTAssertEqual(connection.closeCode, 1000)
        XCTAssertNil(connection.closeReason)
    }

    func testCloseWithReason() {
        var connection = WebSocketConnection(url: "wss://example.com/ws", status: .open)

        connection.close(reason: "Going away")

        XCTAssertEqual(connection.status, .closed)
        XCTAssertNil(connection.closeCode)
        XCTAssertEqual(connection.closeReason, "Going away")
    }

    func testCloseWithCodeAndReason() {
        var connection = WebSocketConnection(url: "wss://example.com/ws", status: .open)

        connection.close(code: 1001, reason: "Going away")

        XCTAssertEqual(connection.status, .closed)
        XCTAssertNotNil(connection.endTime)
        XCTAssertEqual(connection.closeCode, 1001)
        XCTAssertEqual(connection.closeReason, "Going away")
    }

    // MARK: - WebSocketConnection Codable Tests

    func testWebSocketConnectionEncodeDecode() throws {
        let original = WebSocketConnection(
            url: "wss://example.com/ws",
            messages: [
                WebSocketMessage(direction: .sent, payload: Data(), messageType: .text),
                WebSocketMessage(direction: .received, payload: Data(), messageType: .binary)
            ],
            status: .open,
            requestHeaders: [TraceHTTPHeader(key: "Upgrade", value: "websocket")],
            responseHeaders: [TraceHTTPHeader(key: "Connection", value: "Upgrade")],
            closeCode: 1000,
            closeReason: "Normal"
        )

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WebSocketConnection.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.messages.count, original.messages.count)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.requestHeaders.count, original.requestHeaders.count)
        XCTAssertEqual(decoded.responseHeaders.count, original.responseHeaders.count)
        XCTAssertEqual(decoded.closeCode, original.closeCode)
        XCTAssertEqual(decoded.closeReason, original.closeReason)
    }

    func testWebSocketConnectionEncodeDecodeRoundTrip() throws {
        let original = WebSocketConnection(url: "wss://example.com/ws")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WebSocketConnection.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.url, original.url)
    }

    func testWebSocketConnectionWithEmptyArrays() throws {
        let original = WebSocketConnection(
            url: "wss://example.com/ws",
            messages: [],
            requestHeaders: [],
            responseHeaders: []
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WebSocketConnection.self, from: encoded)

        XCTAssertTrue(decoded.messages.isEmpty)
        XCTAssertTrue(decoded.requestHeaders.isEmpty)
        XCTAssertTrue(decoded.responseHeaders.isEmpty)
    }

    func testWebSocketConnectionWithNilOptionals() throws {
        let original = WebSocketConnection(
            url: "wss://example.com/ws",
            endTime: nil,
            closeCode: nil,
            closeReason: nil
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WebSocketConnection.self, from: encoded)

        XCTAssertNil(decoded.endTime)
        XCTAssertNil(decoded.closeCode)
        XCTAssertNil(decoded.closeReason)
    }

    // MARK: - WebSocketConnection Equatable Tests

    func testWebSocketConnectionEquality() {
        let id = UUID()
        let connection1 = WebSocketConnection(id: id, url: "wss://example.com/ws")
        let connection2 = WebSocketConnection(id: id, url: "wss://different.com/ws")

        XCTAssertEqual(connection1, connection2)
    }

    func testWebSocketConnectionInequality() {
        let connection1 = WebSocketConnection(url: "wss://example.com/ws")
        let connection2 = WebSocketConnection(url: "wss://example.com/ws")

        XCTAssertNotEqual(connection1, connection2)
    }

    // MARK: - Edge Cases

    func testWebSocketConnectionWithEmptyURL() {
        let connection = WebSocketConnection(url: "")
        XCTAssertEqual(connection.url, "")
        XCTAssertEqual(connection.host, "")
    }

    func testWebSocketConnectionWithWSURL() {
        let connection = WebSocketConnection(url: "ws://example.com/socket")
        XCTAssertEqual(connection.host, "example.com")
    }

    func testWebSocketConnectionWithWSSURL() {
        let connection = WebSocketConnection(url: "wss://secure.example.com/socket")
        XCTAssertEqual(connection.host, "secure.example.com")
    }

    func testWebSocketConnectionIdentifiable() {
        let connection1 = WebSocketConnection(url: "wss://example.com/ws")
        let connection2 = WebSocketConnection(url: "wss://example.com/ws")

        XCTAssertNotEqual(connection1.id, connection2.id)
    }

    func testWebSocketConnectionStatusTransitions() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")

        connection.status = .connecting
        XCTAssertTrue(connection.isActive)

        connection.status = .open
        XCTAssertTrue(connection.isActive)

        connection.status = .closing
        XCTAssertFalse(connection.isActive)

        connection.status = .closed
        XCTAssertFalse(connection.isActive)

        connection.status = .failed
        XCTAssertFalse(connection.isActive)
    }

    func testWebSocketConnectionWithLongURL() {
        let longURL = "wss://example.com/" + String(repeating: "a", count: 10000)
        let connection = WebSocketConnection(url: longURL)
        XCTAssertEqual(connection.url, longURL)
    }

    func testWebSocketConnectionWithStandardCloseCodes() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")

        // Normal closure
        connection.close(code: 1000)
        XCTAssertEqual(connection.closeCode, 1000)

        // Going away
        connection.closeCode = 1001
        XCTAssertEqual(connection.closeCode, 1001)

        // Protocol error
        connection.closeCode = 1002
        XCTAssertEqual(connection.closeCode, 1002)
    }

    func testWebSocketConnectionWithEmptyCloseReason() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")
        connection.close(code: 1000, reason: "")
        XCTAssertEqual(connection.closeReason, "")
    }

    func testWebSocketConnectionWithLongCloseReason() {
        let longReason = String(repeating: "reason", count: 100)
        var connection = WebSocketConnection(url: "wss://example.com/ws")
        connection.close(code: 1000, reason: longReason)
        XCTAssertEqual(connection.closeReason, longReason)
    }

    func testWebSocketConnectionMessageCounters() {
        var connection = WebSocketConnection(url: "wss://example.com/ws")

        // Add mixed messages
        connection.addMessage(WebSocketMessage(direction: .sent, payload: Data(), messageType: .text))
        connection.addMessage(WebSocketMessage(direction: .sent, payload: Data(), messageType: .text))
        connection.addMessage(WebSocketMessage(direction: .received, payload: Data(), messageType: .text))
        connection.addMessage(WebSocketMessage(direction: .sent, payload: Data(), messageType: .binary))
        connection.addMessage(WebSocketMessage(direction: .received, payload: Data(), messageType: .binary))

        XCTAssertEqual(connection.messageCount, 5)
        XCTAssertEqual(connection.sentMessageCount, 3)
        XCTAssertEqual(connection.receivedMessageCount, 2)
    }
}
