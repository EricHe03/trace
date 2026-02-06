//
//  SSEHandlerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/16.
//

import Network
import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceNetworking

final class SSEHandlerTests: XCTestCase {

    // MARK: - SSEParser Tests

    func testParseSimpleEvent() {
        let parser = SSEParser()
        let data = "data: Hello, World!\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "Hello, World!")
    }

    func testParseEventWithType() {
        let parser = SSEParser()
        let data = "event: message\ndata: Test data\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventType, "message")
        XCTAssertEqual(events.first?.data, "Test data")
    }

    func testParseEventWithId() {
        let parser = SSEParser()
        let data = "id: 123\ndata: Event with ID\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventId, "123")
        XCTAssertEqual(events.first?.data, "Event with ID")
    }

    func testParseEventWithAllFields() {
        let parser = SSEParser()
        let data = "id: 456\nevent: custom\ndata: Full event\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        let event = events.first
        XCTAssertEqual(event?.eventId, "456")
        XCTAssertEqual(event?.eventType, "custom")
        XCTAssertEqual(event?.data, "Full event")
    }

    func testParseMultipleEvents() {
        let parser = SSEParser()
        let data = "data: Event 1\n\ndata: Event 2\n\ndata: Event 3\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].data, "Event 1")
        XCTAssertEqual(events[1].data, "Event 2")
        XCTAssertEqual(events[2].data, "Event 3")
    }

    func testParseMultilineData() {
        let parser = SSEParser()
        let data = "data: Line 1\ndata: Line 2\ndata: Line 3\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "Line 1\nLine 2\nLine 3")
    }

    func testParseEmptyData() {
        let parser = SSEParser()
        let data = ""

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 0)
    }

    func testParseIncompleteEvent() {
        let parser = SSEParser()
        let data = "data: Incomplete"

        // Incomplete event should not be returned
        let events = parser.parse(data)
        XCTAssertEqual(events.count, 0)

        // Complete the event
        let events2 = parser.parse("\n\n")
        XCTAssertEqual(events2.count, 1)
        XCTAssertEqual(events2.first?.data, "Incomplete")
    }

    func testParseWithComment() {
        let parser = SSEParser()
        let data = ": This is a comment\ndata: Actual data\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "Actual data")
    }

    func testParseWithRetry() {
        let parser = SSEParser()
        let data = "retry: 5000\ndata: With retry\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "With retry")
    }

    func testParseEventWithEmptyLines() {
        let parser = SSEParser()
        let data = "data: Before\n\ndata: After\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 2)
    }

    func testParseJSONData() {
        let parser = SSEParser()
        let data = "data: {\"key\": \"value\", \"number\": 42}\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "{\"key\": \"value\", \"number\": 42}")
    }

    func testParseWithWhitespace() {
        let parser = SSEParser()
        let data = "data:    Trimmed data   \n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        // SSE spec: one space after colon is removed if present
        XCTAssertEqual(events.first?.data, "   Trimmed data   ")
    }

    func testParseSequentialChunks() {
        let parser = SSEParser()

        // Simulate chunked transfer
        let events1 = parser.parse("data: Part")
        XCTAssertEqual(events1.count, 0)

        let events2 = parser.parse(" 1\n")
        XCTAssertEqual(events2.count, 0)

        let events3 = parser.parse("\n")
        XCTAssertEqual(events3.count, 1)
        XCTAssertEqual(events3.first?.data, "Part 1")
    }

    func testParseWithDifferentNewlines() {
        let parser = SSEParser()
        let data = "data: Event\r\n\r\n"

        let events = parser.parse(data)

        // Should handle \r\n line endings
        XCTAssertGreaterThanOrEqual(events.count, 1)
    }

    func testParseCRLFSplitAcrossChunks() {
        let parser = SSEParser()

        let events1 = parser.parse("data: Hello\r")
        XCTAssertEqual(events1.count, 0)

        let events2 = parser.parse("\n\n")
        XCTAssertEqual(events2.count, 1)
        XCTAssertEqual(events2.first?.data, "Hello")
    }

    func testParseUnknownFieldIsIgnored() {
        let parser = SSEParser()
        let data = "foo: bar\ndata: Valid\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "Valid")
    }

    func testParseEventWithoutData_IsDropped() {
        let parser = SSEParser()
        let data = "event: ping\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 0)
    }

    func testParseRetryInvalid_IsIgnored() {
        let parser = SSEParser()
        let data = "retry: nope\ndata: Payload\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "Payload")
        XCTAssertNil(events.first?.retry)
    }

    func testParseEventWithUnicodeData() {
        let parser = SSEParser()
        let data = "data: Hello 世界\n\n"

        let events = parser.parse(data)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "Hello 世界")
    }

    // MARK: - SSEConnection Tests

    func testSSEConnectionInitialization() {
        let id = UUID()
        let connection = SSEConnection(
            id: id,
            url: "https://api.example.com/events",
            startTime: Date(),
            status: .streaming,
            requestHeaders: [TraceHTTPHeader(key: "Accept", value: "text/event-stream")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/event-stream")],
            totalBytesReceived: 0
        )

        XCTAssertEqual(connection.id, id)
        XCTAssertEqual(connection.url, "https://api.example.com/events")
        XCTAssertEqual(connection.status, .streaming)
        XCTAssertEqual(connection.events.count, 0)
        XCTAssertEqual(connection.totalBytesReceived, 0)
    }

    func testSSEConnectionAddEvent() {
        var connection = SSEConnection(
            id: UUID(),
            url: "https://api.example.com/events",
            startTime: Date(),
            status: .streaming,
            requestHeaders: [],
            responseHeaders: [],
            totalBytesReceived: 0
        )

        let event = ServerSentEvent(
            eventId: "1",
            eventType: "message",
            data: "Test event",
            timestamp: Date()
        )

        connection.addEvent(event)

        XCTAssertEqual(connection.events.count, 1)
        XCTAssertEqual(connection.events.first?.data, "Test event")
    }

    func testSSEConnectionClose() {
        var connection = SSEConnection(
            id: UUID(),
            url: "https://api.example.com/events",
            startTime: Date(),
            status: .streaming,
            requestHeaders: [],
            responseHeaders: [],
            totalBytesReceived: 100
        )

        connection.close()

        XCTAssertEqual(connection.status, .closed)
        XCTAssertNotNil(connection.endTime)
    }

    func testSSEConnectionDuration() {
        let startTime = Date()
        var connection = SSEConnection(
            id: UUID(),
            url: "https://api.example.com/events",
            startTime: startTime,
            status: .streaming,
            requestHeaders: [],
            responseHeaders: [],
            totalBytesReceived: 0
        )

        // Simulate passage of time
        connection.endTime = startTime.addingTimeInterval(5.0)

        XCTAssertNotNil(connection.duration)
        XCTAssertEqual(connection.duration ?? 0, 5.0, accuracy: 0.1)
    }

    func testSSEConnectionCodable() throws {
        let connection = SSEConnection(
            id: UUID(),
            url: "https://api.example.com/events",
            startTime: Date(),
            status: .streaming,
            requestHeaders: [TraceHTTPHeader(key: "Accept", value: "text/event-stream")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/event-stream")],
            totalBytesReceived: 1024
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(connection)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SSEConnection.self, from: data)

        XCTAssertEqual(decoded.id, connection.id)
        XCTAssertEqual(decoded.url, connection.url)
        XCTAssertEqual(decoded.status, connection.status)
        XCTAssertEqual(decoded.totalBytesReceived, connection.totalBytesReceived)
    }

    // MARK: - ServerSentEvent Tests

    func testServerSentEventInitialization() {
        let event = ServerSentEvent(
            eventId: "123",
            eventType: "notification",
            data: "New message",
            timestamp: Date()
        )

        XCTAssertEqual(event.eventId, "123")
        XCTAssertEqual(event.eventType, "notification")
        XCTAssertEqual(event.data, "New message")
    }

    func testServerSentEventCodable() throws {
        let event = ServerSentEvent(
            eventId: "456",
            eventType: "update",
            data: "{\"status\": \"ok\"}",
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ServerSentEvent.self, from: data)

        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.eventId, event.eventId)
        XCTAssertEqual(decoded.eventType, event.eventType)
        XCTAssertEqual(decoded.data, event.data)
    }

    func testServerSentEventWithoutOptionalFields() {
        let event = ServerSentEvent(
            eventId: nil,
            eventType: nil,
            data: "Simple event",
            timestamp: Date()
        )

        XCTAssertNil(event.eventId)
        XCTAssertNil(event.eventType)
        XCTAssertEqual(event.data, "Simple event")
    }

    // MARK: - SSE Status Tests

    func testSSEConnectionStatus() {
        XCTAssertEqual(SSEConnectionStatus.streaming.displayName, "Streaming")
        XCTAssertEqual(SSEConnectionStatus.closed.displayName, "Closed")
        XCTAssertEqual(SSEConnectionStatus.failed.displayName, "Failed")
    }

    // MARK: - Truncation Tests

    func testSSEConnectionTruncation() {
        var connection = SSEConnection(
            id: UUID(),
            url: "https://api.example.com/events",
            startTime: Date(),
            status: .streaming,
            requestHeaders: [],
            responseHeaders: [],
            totalBytesReceived: 0
        )

        XCTAssertFalse(connection.isTruncated)

        connection.isTruncated = true
        XCTAssertTrue(connection.isTruncated)
    }

    // MARK: - Integration Tests

    func testSSEParserWithRealSSEDevEndpoint() throws {
        if ProcessInfo.processInfo.environment["TRACE_RUN_LIVE_SSE_TESTS"] != "1" {
            throw XCTSkip("Set TRACE_RUN_LIVE_SSE_TESTS=1 to run live SSE integration test.")
        }
        // This is an integration test that uses sse.dev to test real SSE responses
        // sse.dev is a website for testing Server-Sent Events
        let parser = SSEParser()
        let expectation = XCTestExpectation(description: "Receive SSE events from sse.dev")

        guard let url = URL(string: "https://sse.dev/test") else {
            XCTFail("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                XCTFail("Network error: \(error.localizedDescription)")
                expectation.fulfill()
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                XCTFail("Invalid response type")
                expectation.fulfill()
                return
            }

            XCTAssertEqual(httpResponse.statusCode, 200)
            XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")

            guard let data = data else {
                XCTFail("No data received")
                expectation.fulfill()
                return
            }

            guard let responseString = String(data: data, encoding: .utf8) else {
                XCTFail("Could not decode response data")
                expectation.fulfill()
                return
            }

            // Parse the SSE data
            let events = parser.parse(responseString)

            // Verify we received at least one event
            XCTAssertGreaterThan(events.count, 0, "Should receive at least one SSE event from sse.dev")

            // Verify event structure
            if let firstEvent = events.first {
                XCTAssertFalse(firstEvent.data.isEmpty, "Event data should not be empty")
            }

            expectation.fulfill()
        }

        task.resume()

        wait(for: [expectation], timeout: 15.0)
    }

#if DEBUG
    // MARK: - SSE Handler Flow Tests

    func testSSEHandler_ParsesEventsAcrossChunks() {
        let handler = makeTestSSEHandler()

        handler.testParseSSEData("data: Hel".data(using: .utf8)!)
        handler.testParseSSEData("lo\n\n".data(using: .utf8)!)

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.data, "Hello")
        XCTAssertEqual(snapshot.totalBytesReceived, "data: Hel".count + "lo\n\n".count)
    }

    func testSSEHandler_TruncatesAfterMaxEvents() {
        let handler = makeTestSSEHandler()

        for i in 0 ..< 1000 {
            handler.testParseSSEData("data: event-\(i)\n\n".data(using: .utf8)!)
        }
        handler.testParseSSEData("data: overflow\n\n".data(using: .utf8)!)

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.events.count, 1000)
        XCTAssertTrue(snapshot.isTruncated)
    }

    func testSSEHandler_ParsesGzipCompressedSSEPayload() {
        let handler = makeTestSSEHandler(
            responseHeaders: [TraceHTTPHeader(key: "Content-Encoding", value: "gzip")]
        )

        let payload = Data("data: compressed-event\n\n".utf8)
        guard let compressed = CompressionHelper.compress(data: payload, algorithm: "gzip") else {
            XCTFail("Failed to gzip payload in test setup")
            return
        }

        handler.testParseSSEData(compressed)

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.data, "compressed-event")
    }

    func testSSEHandler_ParsesChunkedSSEPayloadAcrossFrames() {
        let handler = makeTestSSEHandler(
            responseHeaders: [TraceHTTPHeader(key: "Transfer-Encoding", value: "chunked")]
        )

        let payload = Data("data: chunked-event\n\n".utf8)
        let chunkedPayload = makeChunkedPayload(from: payload, preferredChunkSizes: [5, 2, 7])
        let splitIndex = chunkedPayload.count / 2

        handler.testParseSSEData(Data(chunkedPayload.prefix(splitIndex)))
        handler.testParseSSEData(Data(chunkedPayload.dropFirst(splitIndex)))

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.data, "chunked-event")
    }

    func testSSEHandler_ParsesChunkedGzipCompressedSSEPayload() {
        let handler = makeTestSSEHandler(
            responseHeaders: [
                TraceHTTPHeader(key: "Transfer-Encoding", value: "chunked"),
                TraceHTTPHeader(key: "Content-Encoding", value: "gzip")
            ]
        )

        let payload = Data("data: chunked-gzip-event\n\n".utf8)
        guard let compressed = CompressionHelper.compress(data: payload, algorithm: "gzip") else {
            XCTFail("Failed to gzip payload in test setup")
            return
        }

        let chunkedPayload = makeChunkedPayload(from: compressed, preferredChunkSizes: [3, 11, 5])
        let firstSplit = chunkedPayload.count / 3
        let secondSplit = (chunkedPayload.count * 2) / 3
        handler.testParseSSEData(Data(chunkedPayload.prefix(firstSplit)))
        handler.testParseSSEData(Data(chunkedPayload[firstSplit ..< secondSplit]))
        handler.testParseSSEData(Data(chunkedPayload.dropFirst(secondSplit)))

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.data, "chunked-gzip-event")
    }

    func testSSEHandler_FallsBackToRawParsingWhenChunkedDecodingFails() {
        let handler = makeTestSSEHandler(
            responseHeaders: [TraceHTTPHeader(key: "Transfer-Encoding", value: "chunked")]
        )

        // This payload is intentionally not chunk-framed. The handler should fall back to raw parsing.
        handler.testParseSSEData(Data("data: fallback-one\r\n\r\n".utf8))
        handler.testParseSSEData(Data("data: fallback-two\r\n\r\n".utf8))

        let snapshot = handler.testConnectionSnapshot()
        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(snapshot.events[0].data, "fallback-one")
        XCTAssertEqual(snapshot.events[1].data, "fallback-two")
    }
#endif
}

#if DEBUG
private func makeTestSSEHandler(responseHeaders: [TraceHTTPHeader] = []) -> SSEHandler {
    let client = NWConnection(
        host: NWEndpoint.Host("localhost"),
        port: NWEndpoint.Port(integerLiteral: 80),
        using: .tcp
    )
    return SSEHandler(
        clientConnection: client,
        serverConnection: nil,
        url: "https://example.com/events",
        requestHeaders: [],
        responseHeaders: responseHeaders
    )
}

private func makeChunkedPayload(from body: Data, preferredChunkSizes: [Int]) -> Data {
    guard !body.isEmpty else {
        return Data("0\r\n\r\n".utf8)
    }

    var result = Data()
    var cursor = 0
    var chunkIndex = 0
    while cursor < body.count {
        let remaining = body.count - cursor
        let preferred = chunkIndex < preferredChunkSizes.count ? preferredChunkSizes[chunkIndex] : remaining
        let chunkSize = min(max(1, preferred), remaining)
        let sizeLine = String(chunkSize, radix: 16, uppercase: true)
        result.append(Data(sizeLine.utf8))
        result.append(Data("\r\n".utf8))
        result.append(body.subdata(in: cursor ..< (cursor + chunkSize)))
        result.append(Data("\r\n".utf8))
        cursor += chunkSize
        chunkIndex += 1
    }

    result.append(Data("0\r\n\r\n".utf8))
    return result
}
#endif
