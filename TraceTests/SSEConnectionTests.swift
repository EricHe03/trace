//
//  SSEConnectionTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class SSEConnectionTests: XCTestCase {

    // MARK: - SSEConnectionStatus Tests

    func testSSEConnectionStatusRawValues() {
        XCTAssertEqual(SSEConnectionStatus.connecting.rawValue, "connecting")
        XCTAssertEqual(SSEConnectionStatus.streaming.rawValue, "streaming")
        XCTAssertEqual(SSEConnectionStatus.closed.rawValue, "closed")
        XCTAssertEqual(SSEConnectionStatus.failed.rawValue, "failed")
    }

    func testSSEConnectionStatusDisplayNames() {
        XCTAssertEqual(SSEConnectionStatus.connecting.displayName, "Connecting")
        XCTAssertEqual(SSEConnectionStatus.streaming.displayName, "Streaming")
        XCTAssertEqual(SSEConnectionStatus.closed.displayName, "Closed")
        XCTAssertEqual(SSEConnectionStatus.failed.displayName, "Failed")
    }

    func testSSEConnectionStatusColors() {
        XCTAssertEqual(SSEConnectionStatus.connecting.color, .info)
        XCTAssertEqual(SSEConnectionStatus.streaming.color, .success)
        XCTAssertEqual(SSEConnectionStatus.closed.color, .unknown)
        XCTAssertEqual(SSEConnectionStatus.failed.color, .clientError)
    }

    func testSSEConnectionStatusCodable() throws {
        for status in SSEConnectionStatus.allCases {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(SSEConnectionStatus.self, from: encoded)
            XCTAssertEqual(status, decoded)
        }
    }

    func testSSEConnectionStatusCaseIterable() {
        let allCases = SSEConnectionStatus.allCases
        XCTAssertEqual(allCases.count, 4)
        XCTAssertTrue(allCases.contains(.connecting))
        XCTAssertTrue(allCases.contains(.streaming))
        XCTAssertTrue(allCases.contains(.closed))
        XCTAssertTrue(allCases.contains(.failed))
    }

    // MARK: - SSEConnection Initializer Tests

    func testSSEConnectionInitWithDefaults() {
        let connection = SSEConnection(url: "https://example.com/events")

        XCTAssertNotNil(connection.id)
        XCTAssertEqual(connection.url, "https://example.com/events")
        XCTAssertNotNil(connection.startTime)
        XCTAssertNil(connection.endTime)
        XCTAssertTrue(connection.events.isEmpty)
        XCTAssertEqual(connection.status, .connecting)
        XCTAssertTrue(connection.requestHeaders.isEmpty)
        XCTAssertTrue(connection.responseHeaders.isEmpty)
        XCTAssertEqual(connection.totalBytesReceived, 0)
        XCTAssertFalse(connection.isTruncated)
    }

    func testSSEConnectionInitWithAllParameters() {
        let id = UUID()
        let startTime = Date()
        let endTime = Date().addingTimeInterval(10)
        let events = [
            ServerSentEvent(data: "test1"),
            ServerSentEvent(data: "test2")
        ]
        let requestHeaders = [TraceHTTPHeader(key: "Accept", value: "text/event-stream")]
        let responseHeaders = [TraceHTTPHeader(key: "Content-Type", value: "text/event-stream")]

        let connection = SSEConnection(
            id: id,
            url: "https://example.com/events",
            startTime: startTime,
            endTime: endTime,
            events: events,
            status: .streaming,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            totalBytesReceived: 1024,
            isTruncated: true
        )

        XCTAssertEqual(connection.id, id)
        XCTAssertEqual(connection.url, "https://example.com/events")
        XCTAssertEqual(connection.startTime, startTime)
        XCTAssertEqual(connection.endTime, endTime)
        XCTAssertEqual(connection.events.count, 2)
        XCTAssertEqual(connection.status, .streaming)
        XCTAssertEqual(connection.requestHeaders.count, 1)
        XCTAssertEqual(connection.responseHeaders.count, 1)
        XCTAssertEqual(connection.totalBytesReceived, 1024)
        XCTAssertTrue(connection.isTruncated)
    }

    // MARK: - SSEConnection Computed Properties Tests

    func testHostFromValidURL() {
        let connection = SSEConnection(url: "https://api.example.com/stream")
        XCTAssertEqual(connection.host, "api.example.com")
    }

    func testHostFromURLWithoutHost() {
        let connection = SSEConnection(url: "invalid-url")
        XCTAssertEqual(connection.host, "invalid-url")
    }

    func testDurationWhenClosed() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(5.5)
        var connection = SSEConnection(url: "https://example.com/events", startTime: startTime)
        connection.endTime = endTime

        XCTAssertNotNil(connection.duration)
        XCTAssertEqual(connection.duration, 5.5, accuracy: 0.001)
    }

    func testDurationWhenActive() {
        let connection = SSEConnection(url: "https://example.com/events")
        XCTAssertNil(connection.duration)
    }

    func testEventCount() {
        var connection = SSEConnection(url: "https://example.com/events")
        XCTAssertEqual(connection.eventCount, 0)

        connection.events.append(ServerSentEvent(data: "test1"))
        connection.events.append(ServerSentEvent(data: "test2"))
        XCTAssertEqual(connection.eventCount, 2)
    }

    func testTotalBytesString() {
        var connection = SSEConnection(url: "https://example.com/events")
        connection.totalBytesReceived = 1024

        let bytesString = connection.totalBytesString
        XCTAssertFalse(bytesString.isEmpty)
        // ByteCountFormatter produces locale-specific output, so we just verify it's not empty
    }

    func testIsActiveForConnecting() {
        let connection = SSEConnection(url: "https://example.com/events", status: .connecting)
        XCTAssertTrue(connection.isActive)
    }

    func testIsActiveForStreaming() {
        let connection = SSEConnection(url: "https://example.com/events", status: .streaming)
        XCTAssertTrue(connection.isActive)
    }

    func testIsActiveForClosed() {
        let connection = SSEConnection(url: "https://example.com/events", status: .closed)
        XCTAssertFalse(connection.isActive)
    }

    func testIsActiveForFailed() {
        let connection = SSEConnection(url: "https://example.com/events", status: .failed)
        XCTAssertFalse(connection.isActive)
    }

    // MARK: - SSEConnection Mutating Methods Tests

    func testAddEvent() {
        var connection = SSEConnection(url: "https://example.com/events")
        XCTAssertEqual(connection.events.count, 0)

        let event = ServerSentEvent(data: "test data")
        connection.addEvent(event)

        XCTAssertEqual(connection.events.count, 1)
        XCTAssertEqual(connection.events.first?.data, "test data")
    }

    func testAddMultipleEvents() {
        var connection = SSEConnection(url: "https://example.com/events")

        connection.addEvent(ServerSentEvent(data: "event1"))
        connection.addEvent(ServerSentEvent(data: "event2"))
        connection.addEvent(ServerSentEvent(data: "event3"))

        XCTAssertEqual(connection.events.count, 3)
        XCTAssertEqual(connection.events[0].data, "event1")
        XCTAssertEqual(connection.events[1].data, "event2")
        XCTAssertEqual(connection.events[2].data, "event3")
    }

    func testClose() {
        let startTime = Date()
        var connection = SSEConnection(url: "https://example.com/events", startTime: startTime, status: .streaming)

        connection.close()

        XCTAssertEqual(connection.status, .closed)
        XCTAssertNotNil(connection.endTime)
        XCTAssertGreaterThanOrEqual(connection.endTime!, startTime)
    }

    // MARK: - SSEConnection Codable Tests

    func testSSEConnectionEncodeDecode() throws {
        let original = SSEConnection(
            url: "https://example.com/events",
            events: [
                ServerSentEvent(data: "event1"),
                ServerSentEvent(eventType: "message", data: "event2")
            ],
            status: .streaming,
            requestHeaders: [TraceHTTPHeader(key: "Accept", value: "text/event-stream")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/event-stream")],
            totalBytesReceived: 2048,
            isTruncated: false
        )

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SSEConnection.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.events.count, original.events.count)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.requestHeaders.count, original.requestHeaders.count)
        XCTAssertEqual(decoded.responseHeaders.count, original.responseHeaders.count)
        XCTAssertEqual(decoded.totalBytesReceived, original.totalBytesReceived)
        XCTAssertEqual(decoded.isTruncated, original.isTruncated)
    }

    func testSSEConnectionEncodeDecodeRoundTrip() throws {
        let original = SSEConnection(url: "https://example.com/events")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSEConnection.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.url, original.url)
    }

    func testSSEConnectionWithEmptyArrays() throws {
        let original = SSEConnection(
            url: "https://example.com/events",
            events: [],
            requestHeaders: [],
            responseHeaders: []
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSEConnection.self, from: encoded)

        XCTAssertTrue(decoded.events.isEmpty)
        XCTAssertTrue(decoded.requestHeaders.isEmpty)
        XCTAssertTrue(decoded.responseHeaders.isEmpty)
    }

    func testSSEConnectionWithNilOptionals() throws {
        let original = SSEConnection(
            url: "https://example.com/events",
            endTime: nil
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSEConnection.self, from: encoded)

        XCTAssertNil(decoded.endTime)
    }

    // MARK: - SSEConnection Equatable Tests

    func testSSEConnectionEquality() {
        let id = UUID()
        let connection1 = SSEConnection(id: id, url: "https://example.com/events")
        let connection2 = SSEConnection(id: id, url: "https://different.com/events")

        XCTAssertEqual(connection1, connection2)
    }

    func testSSEConnectionInequality() {
        let connection1 = SSEConnection(url: "https://example.com/events")
        let connection2 = SSEConnection(url: "https://example.com/events")

        XCTAssertNotEqual(connection1, connection2)
    }

    // MARK: - Edge Cases

    func testSSEConnectionWithEmptyURL() {
        let connection = SSEConnection(url: "")
        XCTAssertEqual(connection.url, "")
        XCTAssertEqual(connection.host, "")
    }

    func testSSEConnectionWithZeroBytes() {
        let connection = SSEConnection(url: "https://example.com/events", totalBytesReceived: 0)
        XCTAssertEqual(connection.totalBytesReceived, 0)
    }

    func testSSEConnectionWithLargeByteCount() {
        let connection = SSEConnection(url: "https://example.com/events", totalBytesReceived: Int.max)
        XCTAssertEqual(connection.totalBytesReceived, Int.max)
    }

    func testSSEConnectionIdentifiable() {
        let connection1 = SSEConnection(url: "https://example.com/events")
        let connection2 = SSEConnection(url: "https://example.com/events")

        XCTAssertNotEqual(connection1.id, connection2.id)
    }

    func testSSEConnectionStatusTransitions() {
        var connection = SSEConnection(url: "https://example.com/events")

        connection.status = .connecting
        XCTAssertTrue(connection.isActive)

        connection.status = .streaming
        XCTAssertTrue(connection.isActive)

        connection.status = .closed
        XCTAssertFalse(connection.isActive)

        connection.status = .failed
        XCTAssertFalse(connection.isActive)
    }

    func testSSEConnectionWithLongURL() {
        let longURL = "https://example.com/" + String(repeating: "a", count: 10000)
        let connection = SSEConnection(url: longURL)
        XCTAssertEqual(connection.url, longURL)
    }
}
