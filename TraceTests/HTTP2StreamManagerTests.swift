//
//  HTTP2StreamManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/16.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceNetworking

final class HTTP2StreamManagerTests: XCTestCase {

    // MARK: - HTTP2StreamState Tests

    func testHTTP2StreamStateInitialization() {
        let state = HTTP2StreamState(streamId: 1)

        XCTAssertEqual(state.streamId, 1)
        XCTAssertEqual(state.state, .idle)
        XCTAssertNil(state.requestHeaders)
        XCTAssertNil(state.responseHeaders)
        XCTAssertFalse(state.requestComplete)
        XCTAssertFalse(state.responseComplete)
        XCTAssertEqual(state.requestBodyBytesSeen, 0)
        XCTAssertEqual(state.responseBodyBytesSeen, 0)
    }

    func testHTTP2StreamStateRequestId() {
        let state1 = HTTP2StreamState(streamId: 1)
        let state2 = HTTP2StreamState(streamId: 1)

        // Each stream state should have a unique request ID
        XCTAssertNotEqual(state1.requestId, state2.requestId)
    }

    func testHTTP2StreamStateInternal() {
        var state = HTTP2StreamState(streamId: 1)

        // Test state transitions
        state.state = .open
        XCTAssertEqual(state.state.toHTTP2StreamState(), .open)

        state.state = .halfClosedLocal
        XCTAssertEqual(state.state.toHTTP2StreamState(), .halfClosedLocal)

        state.state = .halfClosedRemote
        XCTAssertEqual(state.state.toHTTP2StreamState(), .halfClosedRemote)

        state.state = .closed
        XCTAssertEqual(state.state.toHTTP2StreamState(), .closed)
    }

    // MARK: - HTTP2Frame Tests

    func testHTTP2FrameHeaderParsing() {
        // Frame header: 9 bytes
        // Length: 3 bytes, Type: 1 byte, Flags: 1 byte, Stream ID: 4 bytes
        let headerData = Data([
            0x00, 0x00, 0x05, // Length: 5
            0x01,             // Type: HEADERS
            0x04,             // Flags: END_HEADERS
            0x00, 0x00, 0x00, 0x01 // Stream ID: 1
        ])

        let header = HTTP2FrameHeader.parse(from: headerData)

        XCTAssertNotNil(header)
        XCTAssertEqual(header?.length, 5)
        XCTAssertEqual(header?.frameType, .headers)
        XCTAssertEqual(header?.streamId, 1)
        XCTAssertTrue(header?.frameFlags.contains(.endHeaders) ?? false)
    }

    func testHTTP2FrameTypes() {
        XCTAssertEqual(HTTP2FrameType.data.rawValue, 0x00)
        XCTAssertEqual(HTTP2FrameType.headers.rawValue, 0x01)
        XCTAssertEqual(HTTP2FrameType.priority.rawValue, 0x02)
        XCTAssertEqual(HTTP2FrameType.rstStream.rawValue, 0x03)
        XCTAssertEqual(HTTP2FrameType.settings.rawValue, 0x04)
        XCTAssertEqual(HTTP2FrameType.pushPromise.rawValue, 0x05)
        XCTAssertEqual(HTTP2FrameType.ping.rawValue, 0x06)
        XCTAssertEqual(HTTP2FrameType.goaway.rawValue, 0x07)
        XCTAssertEqual(HTTP2FrameType.windowUpdate.rawValue, 0x08)
        XCTAssertEqual(HTTP2FrameType.continuation.rawValue, 0x09)
    }

    func testHTTP2FrameFlags() {
        var flags = HTTP2FrameFlags()

        flags.insert(.endStream)
        XCTAssertTrue(flags.contains(.endStream))

        flags.insert(.endHeaders)
        XCTAssertTrue(flags.contains(.endHeaders))

        flags.insert(.padded)
        XCTAssertTrue(flags.contains(.padded))

        flags.insert(.priority)
        XCTAssertTrue(flags.contains(.priority))

        flags.insert(.ack)
        XCTAssertTrue(flags.contains(.ack))
    }

    func testHTTP2FrameFlagsStringArray() {
        var flags = HTTP2FrameFlags()
        flags.insert(.endStream)
        flags.insert(.endHeaders)

        let stringArray = flags.toStringArray()

        XCTAssertTrue(stringArray.contains("END_STREAM"))
        XCTAssertTrue(stringArray.contains("END_HEADERS"))
    }

    // MARK: - HTTP2Settings Tests

    func testHTTP2SettingsDefaults() {
        let settings = HTTP2Settings()

        XCTAssertEqual(settings.headerTableSize, 4096)
        XCTAssertTrue(settings.enablePush)
        XCTAssertNil(settings.maxConcurrentStreams)
        XCTAssertEqual(settings.initialWindowSize, 65535)
        XCTAssertEqual(settings.maxFrameSize, 16384)
        XCTAssertNil(settings.maxHeaderListSize)
    }

    func testHTTP2SettingsParsing() {
        // Settings frame payload: 6 bytes per setting (2-byte ID + 4-byte value)
        // SETTINGS_MAX_CONCURRENT_STREAMS (0x03) = 100
        let settingsData = Data([
            0x00, 0x03, // ID: MAX_CONCURRENT_STREAMS
            0x00, 0x00, 0x00, 0x64 // Value: 100
        ])

        let settings = HTTP2Settings.parse(from: settingsData)

        XCTAssertNotNil(settings)
        XCTAssertEqual(settings?.maxConcurrentStreams, 100)
    }

    func testHTTP2SettingsMultipleValues() {
        // Multiple settings in one frame
        let settingsData = Data([
            0x00, 0x01, // HEADER_TABLE_SIZE
            0x00, 0x00, 0x10, 0x00, // 4096
            0x00, 0x03, // MAX_CONCURRENT_STREAMS
            0x00, 0x00, 0x00, 0xC8, // 200
            0x00, 0x04, // INITIAL_WINDOW_SIZE
            0x00, 0x01, 0x00, 0x00 // 65536
        ])

        let settings = HTTP2Settings.parse(from: settingsData)

        XCTAssertNotNil(settings)
        XCTAssertEqual(settings?.headerTableSize, 4096)
        XCTAssertEqual(settings?.maxConcurrentStreams, 200)
        XCTAssertEqual(settings?.initialWindowSize, 65536)
    }

    // MARK: - HTTP2Priority Tests

    func testHTTP2PriorityParsing() {
        // Priority data: 5 bytes
        // Stream Dependency (4 bytes with E bit) + Weight (1 byte)
        let priorityData = Data([
            0x80, 0x00, 0x00, 0x00, // Stream 0, Exclusive
            0x10 // Weight: 16
        ])

        let priority = HTTP2Priority.parse(from: priorityData)

        XCTAssertNotNil(priority)
        XCTAssertTrue(priority?.exclusive ?? false)
        XCTAssertEqual(priority?.streamDependency, 0)
        XCTAssertEqual(priority?.weight, 16)
    }

    func testHTTP2PriorityNonExclusive() {
        let priorityData = Data([
            0x00, 0x00, 0x00, 0x03, // Stream 3, Non-exclusive
            0x20 // Weight: 32
        ])

        let priority = HTTP2Priority.parse(from: priorityData)

        XCTAssertNotNil(priority)
        XCTAssertFalse(priority?.exclusive ?? true)
        XCTAssertEqual(priority?.streamDependency, 3)
        XCTAssertEqual(priority?.weight, 32)
    }

    // MARK: - HTTP2ConnectionInfo Tests

    func testHTTP2ConnectionInfoInitialization() {
        let info = HTTP2ConnectionInfo(
            settingsReceived: ["MAX_CONCURRENT_STREAMS": 100],
            settingsSent: ["INITIAL_WINDOW_SIZE": 65535],
            goAwayReceived: false,
            lastStreamId: nil,
            connectionStartTime: Date(),
            connectionEndTime: nil,
            hpackTableSnapshot: nil,
            hpackTableEvents: nil
        )

        XCTAssertEqual(info.settingsReceived["MAX_CONCURRENT_STREAMS"], 100)
        XCTAssertEqual(info.settingsSent["INITIAL_WINDOW_SIZE"], 65535)
        XCTAssertFalse(info.goAwayReceived)
        XCTAssertNil(info.lastStreamId)
    }

    func testHTTP2ConnectionInfoWithGoAway() {
        let info = HTTP2ConnectionInfo(
            settingsReceived: [:],
            settingsSent: [:],
            goAwayReceived: true,
            lastStreamId: 5,
            connectionStartTime: Date(),
            connectionEndTime: Date(),
            hpackTableSnapshot: nil,
            hpackTableEvents: nil
        )

        XCTAssertTrue(info.goAwayReceived)
        XCTAssertEqual(info.lastStreamId, 5)
        XCTAssertNotNil(info.connectionEndTime)
    }

    // MARK: - HTTP2StreamInfo Tests

    func testHTTP2StreamInfoInitialization() {
        let headers = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/api/users"),
            TraceHTTPHeader(key: ":authority", value: "api.example.com")
        ]

        let streamInfo = HTTP2StreamInfo(
            streamId: 1,
            headers: headers,
            dataFrames: [],
            state: .open,
            priority: nil,
            windowSize: 65535,
            totalDataSize: 0,
            startTime: Date(),
            endTime: nil
        )

        XCTAssertEqual(streamInfo.streamId, 1)
        XCTAssertEqual(streamInfo.headers.count, 3)
        XCTAssertEqual(streamInfo.state, .open)
        XCTAssertEqual(streamInfo.windowSize, 65535)
    }

    func testHTTP2StreamInfoWithPriority() {
        let priority = HTTP2StreamInfo.StreamPriority(
            exclusive: true,
            dependsOn: 0,
            weight: 16
        )

        let streamInfo = HTTP2StreamInfo(
            streamId: 3,
            headers: [],
            dataFrames: [],
            state: .open,
            priority: priority,
            windowSize: 65535,
            totalDataSize: 0,
            startTime: Date(),
            endTime: nil
        )

        XCTAssertNotNil(streamInfo.priority)
        XCTAssertTrue(streamInfo.priority?.exclusive ?? false)
        XCTAssertEqual(streamInfo.priority?.weight, 16)
    }

    func testHTTP2StreamInfoState() {
        XCTAssertEqual(HTTP2StreamInfo.StreamState.idle.rawValue, "idle")
        XCTAssertEqual(HTTP2StreamInfo.StreamState.open.rawValue, "open")
        XCTAssertEqual(HTTP2StreamInfo.StreamState.halfClosedLocal.rawValue, "halfClosedLocal")
        XCTAssertEqual(HTTP2StreamInfo.StreamState.halfClosedRemote.rawValue, "halfClosedRemote")
        XCTAssertEqual(HTTP2StreamInfo.StreamState.closed.rawValue, "closed")
    }

    // MARK: - HTTP2DataFrame Tests

    func testHTTP2DataFrameInitialization() {
        let dataFrame = HTTP2DataFrame(
            frameType: "DATA",
            flags: ["END_STREAM"],
            payloadSize: 1024,
            timestamp: Date(),
            rawData: nil
        )

        XCTAssertEqual(dataFrame.frameType, "DATA")
        XCTAssertEqual(dataFrame.flags, ["END_STREAM"])
        XCTAssertEqual(dataFrame.payloadSize, 1024)
        XCTAssertNil(dataFrame.rawData)
    }

    func testHTTP2DataFrameCodable() throws {
        let dataFrame = HTTP2DataFrame(
            frameType: "HEADERS",
            flags: ["END_HEADERS", "END_STREAM"],
            payloadSize: 256,
            timestamp: Date(),
            rawData: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(dataFrame)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HTTP2DataFrame.self, from: data)

        XCTAssertEqual(decoded.frameType, dataFrame.frameType)
        XCTAssertEqual(decoded.payloadSize, dataFrame.payloadSize)
        XCTAssertEqual(decoded.flags.count, dataFrame.flags.count)
    }

    // MARK: - Stream ID Tests

    func testStreamIdOddForClientInitiated() {
        // Client-initiated streams use odd stream IDs (1, 3, 5, ...)
        let clientStreamIds = [1, 3, 5, 7, 9]

        for id in clientStreamIds {
            XCTAssertTrue(id % 2 == 1, "Client stream ID should be odd")
        }
    }

    func testStreamIdEvenForServerInitiated() {
        // Server-initiated streams use even stream IDs (2, 4, 6, ...)
        let serverStreamIds = [2, 4, 6, 8, 10]

        for id in serverStreamIds {
            XCTAssertTrue(id % 2 == 0, "Server stream ID should be even")
        }
    }

    func testStreamIdZeroForConnectionLevel() {
        // Stream ID 0 is reserved for connection-level frames
        let connectionStreamId: UInt32 = 0
        XCTAssertEqual(connectionStreamId, 0)
    }

    // MARK: - Pseudo Header Tests

    func testPseudoHeadersDetection() {
        let headers = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "example.com"),
            TraceHTTPHeader(key: "content-type", value: "application/json"),
            TraceHTTPHeader(key: "accept", value: "*/*")
        ]

        let pseudoHeaders = headers.filter { $0.key.hasPrefix(":") }
        let regularHeaders = headers.filter { !$0.key.hasPrefix(":") }

        XCTAssertEqual(pseudoHeaders.count, 4)
        XCTAssertEqual(regularHeaders.count, 2)
    }

    func testResponsePseudoHeaders() {
        let headers = [
            TraceHTTPHeader(key: ":status", value: "200"),
            TraceHTTPHeader(key: "content-type", value: "application/json"),
            TraceHTTPHeader(key: "content-length", value: "1234")
        ]

        let statusHeader = headers.first { $0.key == ":status" }

        XCTAssertNotNil(statusHeader)
        XCTAssertEqual(statusHeader?.value, "200")
    }

    // MARK: - Edge Cases

    func testEmptySettingsFrame() {
        let emptyData = Data()
        let settings = HTTP2Settings.parse(from: emptyData)

        // Empty settings frame should return default settings
        XCTAssertNotNil(settings)
    }

    func testInvalidFrameHeader() {
        // Too short to be a valid frame header
        let shortData = Data([0x00, 0x00])
        let header = HTTP2FrameHeader.parse(from: shortData)

        XCTAssertNil(header)
    }

    func testMaxStreamId() {
        // Maximum stream ID is 2^31 - 1
        let maxStreamId: UInt32 = 0x7FFFFFFF

        let state = HTTP2StreamState(streamId: maxStreamId)
        XCTAssertEqual(state.streamId, maxStreamId)
    }

    // MARK: - HTTP2StreamManager Basic Tests

    func testHTTP2StreamManagerInitialization() async {
        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 443)

        let streamCount = await manager.getStreamCount()
        XCTAssertEqual(streamCount, 0)
    }

    func testHTTP2StreamManagerSetCallbacks() async {
        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 443)

        var capturedRequest: NetworkRequest?
        await manager.setOnRequestComplete { request in
            capturedRequest = request
        }

        // Callbacks should be set without crashing
        XCTAssertNil(capturedRequest)
    }

    func testHTTP2StreamManagerFinalizeConnection() async {
        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 443)

        // Should finalize without errors
        await manager.finalizeConnection()

        let streamCount = await manager.getStreamCount()
        XCTAssertEqual(streamCount, 0)
    }

    // MARK: - HTTP2StreamManager Flow Tests

    func testHTTP2StreamManager_BasicRequestResponseFlow_EmitsFinalRequest() async throws {
        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 8443)

        var capturedRequest: NetworkRequest?
        var didFulfill = false
        let expectation = expectation(description: "Request emitted")
        await manager.setOnRequestComplete { request in
            guard request.http2Streams?.first?.endTime != nil, !didFulfill else { return }
            didFulfill = true
            capturedRequest = request
            expectation.fulfill()
        }

        let requestHeaders = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/v1/users"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "api.example.com"),
            TraceHTTPHeader(key: "user-agent", value: "TraceTest/1.0")
        ]
        let responseHeaders = [
            TraceHTTPHeader(key: ":status", value: "200"),
            TraceHTTPHeader(key: "content-type", value: "application/json")
        ]

        let requestFrame = try makeHeadersFrame(headers: requestHeaders, streamId: 1, flags: [.endHeaders, .endStream])
        let responseFrame = try makeHeadersFrame(headers: responseHeaders, streamId: 1, flags: [.endHeaders, .endStream])

        await manager.handleClientHeaders(requestFrame)
        await manager.handleServerHeaders(responseFrame)

        await fulfillment(of: [expectation], timeout: 1.0)

        guard let request = capturedRequest else {
            XCTFail("Expected request to be captured")
            return
        }

        XCTAssertEqual(request.protocolVersion, .http2)
        XCTAssertEqual(request.url, "https://api.example.com:8443/v1/users")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.statusCode, 200)
        XCTAssertEqual(request.responseHeaders.first?.key, "content-type")
        XCTAssertEqual(request.responseHeaders.first?.value, "application/json")
        XCTAssertTrue(request.requestHeaders.contains(where: { $0.key == "user-agent" }))
        XCTAssertEqual(request.http2Streams?.first?.streamId, 1)
    }

    func testHTTP2StreamManager_AppendsRequestTrailers() async throws {
        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 443)

        var capturedRequest: NetworkRequest?
        var didFulfill = false
        let expectation = expectation(description: "Request emitted")
        await manager.setOnRequestComplete { request in
            guard request.http2Streams?.first?.endTime != nil, !didFulfill else { return }
            didFulfill = true
            capturedRequest = request
            expectation.fulfill()
        }

        let initialHeaders = [
            TraceHTTPHeader(key: ":method", value: "POST"),
            TraceHTTPHeader(key: ":path", value: "/upload"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "api.example.com"),
            TraceHTTPHeader(key: "content-type", value: "application/octet-stream")
        ]
        let trailerHeaders = [
            TraceHTTPHeader(key: "x-request-id", value: "trailer-123")
        ]
        let responseHeaders = [
            TraceHTTPHeader(key: ":status", value: "204")
        ]

        let initialFrame = try makeHeadersFrame(headers: initialHeaders, streamId: 3, flags: [.endHeaders])
        let trailerFrame = try makeHeadersFrame(headers: trailerHeaders, streamId: 3, flags: [.endHeaders, .endStream])
        let responseFrame = try makeHeadersFrame(headers: responseHeaders, streamId: 3, flags: [.endHeaders, .endStream])

        await manager.handleClientHeaders(initialFrame)
        await manager.handleClientHeaders(trailerFrame)
        await manager.handleServerHeaders(responseFrame)

        await fulfillment(of: [expectation], timeout: 1.0)

        guard let request = capturedRequest else {
            XCTFail("Expected request to be captured")
            return
        }

        XCTAssertTrue(request.requestHeaders.contains(where: { $0.key == "x-request-id" && $0.value == "trailer-123" }))
    }

    func testHTTP2StreamManager_AppendsResponseTrailers() async throws {
        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 443)

        var capturedRequest: NetworkRequest?
        var didFulfill = false
        let expectation = expectation(description: "Request emitted")
        await manager.setOnRequestComplete { request in
            guard request.http2Streams?.first?.endTime != nil, !didFulfill else { return }
            didFulfill = true
            capturedRequest = request
            expectation.fulfill()
        }

        let requestHeaders = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/stream"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "api.example.com")
        ]
        let responseHeaders = [
            TraceHTTPHeader(key: ":status", value: "200"),
            TraceHTTPHeader(key: "content-type", value: "text/plain")
        ]
        let trailerHeaders = [
            TraceHTTPHeader(key: "x-response-trailer", value: "trailer-456")
        ]

        let requestFrame = try makeHeadersFrame(headers: requestHeaders, streamId: 5, flags: [.endHeaders, .endStream])
        let responseFrame = try makeHeadersFrame(headers: responseHeaders, streamId: 5, flags: [.endHeaders])
        let trailerFrame = try makeHeadersFrame(headers: trailerHeaders, streamId: 5, flags: [.endHeaders, .endStream])

        await manager.handleClientHeaders(requestFrame)
        await manager.handleServerHeaders(responseFrame)
        await manager.handleServerHeaders(trailerFrame)

        await fulfillment(of: [expectation], timeout: 1.0)

        guard let request = capturedRequest else {
            XCTFail("Expected request to be captured")
            return
        }

        XCTAssertTrue(request.responseHeaders.contains(where: { $0.key == "x-response-trailer" && $0.value == "trailer-456" }))
    }

    func testHTTP2StreamManager_GoawayEmitsAndRemovesHigherStreams() async throws {
        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 443)

        var capturedRequests: [NetworkRequest] = []
        var didFulfill = false
        let expectation = expectation(description: "Request emitted")
        expectation.expectedFulfillmentCount = 1
        await manager.setOnRequestComplete { request in
            capturedRequests.append(request)
            guard request.http2Streams?.first?.streamId == 3, !didFulfill else { return }
            didFulfill = true
            expectation.fulfill()
        }

        let headers = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/goaway"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "api.example.com")
        ]

        let stream1 = try makeHeadersFrame(headers: headers, streamId: 1, flags: [.endHeaders])
        let stream3 = try makeHeadersFrame(headers: headers, streamId: 3, flags: [.endHeaders])

        await manager.handleClientHeaders(stream1)
        await manager.handleClientHeaders(stream3)

        let goawayPayload = makeGoawayPayload(lastStreamId: 1, errorCode: 0)
        let goawayFrame = try makeFrame(type: .goaway, flags: [], streamId: 0, payload: goawayPayload)
        await manager.handleGoaway(goawayFrame)

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertTrue(capturedRequests.contains(where: { $0.http2Streams?.first?.streamId == 3 }))
        XCTAssertEqual(capturedRequests.first?.statusMessage, "response pending")
    }

    func testHTTP2StreamManager_RstStreamEmitsSnapshot() async throws {
        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 443)

        var capturedRequest: NetworkRequest?
        var didFulfill = false
        let expectation = expectation(description: "Request emitted")
        await manager.setOnRequestComplete { request in
            guard !didFulfill else { return }
            didFulfill = true
            capturedRequest = request
            expectation.fulfill()
        }

        let headers = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/reset"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "api.example.com")
        ]

        let requestFrame = try makeHeadersFrame(headers: headers, streamId: 7, flags: [.endHeaders])
        await manager.handleClientHeaders(requestFrame)

        let rstPayload = Data([0x00, 0x00, 0x00, 0x08])
        let rstFrame = try makeFrame(type: .rstStream, flags: [], streamId: 7, payload: rstPayload)
        await manager.handleRstStream(rstFrame)

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(capturedRequest?.http2Streams?.first?.streamId, 7)
        XCTAssertEqual(capturedRequest?.statusMessage, "response pending")
    }

    func testHTTP2StreamManager_TruncatesBodiesWhenLimitReached() async throws {
        let storage = AppGroupStorage.shared
        let original = storage.loadConfiguration()

        do {
            var limited = original
            limited.captureBody = true
            limited.maxBodySize = 8
            try storage.saveConfiguration(limited)
        } catch {
            throw XCTSkip("App group storage unavailable: \(error.localizedDescription)")
        }

        defer {
            try? storage.saveConfiguration(original)
        }

        let manager = HTTP2StreamManager(targetHost: "api.example.com", targetPort: 443)

        var capturedRequest: NetworkRequest?
        var didFulfill = false
        let expectation = expectation(description: "Request emitted")
        await manager.setOnRequestComplete { request in
            guard request.http2Streams?.first?.endTime != nil, !didFulfill else { return }
            didFulfill = true
            capturedRequest = request
            expectation.fulfill()
        }

        let requestHeaders = [
            TraceHTTPHeader(key: ":method", value: "POST"),
            TraceHTTPHeader(key: ":path", value: "/upload"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "api.example.com"),
            TraceHTTPHeader(key: "content-type", value: "application/octet-stream")
        ]
        let responseHeaders = [
            TraceHTTPHeader(key: ":status", value: "200"),
            TraceHTTPHeader(key: "content-type", value: "application/octet-stream")
        ]

        let requestFrame = try makeHeadersFrame(headers: requestHeaders, streamId: 9, flags: [.endHeaders])
        let responseFrame = try makeHeadersFrame(headers: responseHeaders, streamId: 9, flags: [.endHeaders])

        let requestPayload = Data(repeating: 0x41, count: 20)
        let responsePayload = Data(repeating: 0x42, count: 20)
        let requestData = try makeDataFrame(payload: requestPayload, streamId: 9, flags: [.endStream])
        let responseData = try makeDataFrame(payload: responsePayload, streamId: 9, flags: [.endStream])

        await manager.handleClientHeaders(requestFrame)
        await manager.handleClientData(requestData)
        await manager.handleServerHeaders(responseFrame)
        await manager.handleServerData(responseData)

        await fulfillment(of: [expectation], timeout: 1.0)

        guard let request = capturedRequest else {
            XCTFail("Expected request to be captured")
            return
        }

        switch request.requestBody {
        case let .truncated(preview, totalSize, _, _):
            XCTAssertEqual(totalSize, 20)
            XCTAssertEqual(preview.count, 8)
        default:
            XCTFail("Expected request body to be truncated")
        }

        switch request.responseBody {
        case let .truncated(preview, totalSize, _, _):
            XCTAssertEqual(totalSize, 20)
            XCTAssertEqual(preview.count, 8)
        default:
            XCTFail("Expected response body to be truncated")
        }
    }
}

private func makeHeadersFrame(
    headers: [TraceHTTPHeader],
    streamId: UInt32,
    flags: HTTP2FrameFlags
) throws -> HTTP2Frame {
    let coder = HPACKCoder()
    let payload = try coder.encode(headers)
    return try makeFrame(type: .headers, flags: flags, streamId: streamId, payload: payload)
}

private func makeDataFrame(
    payload: Data,
    streamId: UInt32,
    flags: HTTP2FrameFlags
) throws -> HTTP2Frame {
    try makeFrame(type: .data, flags: flags, streamId: streamId, payload: payload)
}

private func makeFrame(
    type: HTTP2FrameType,
    flags: HTTP2FrameFlags,
    streamId: UInt32,
    payload: Data
) throws -> HTTP2Frame {
    let data = makeHTTP2Frame(type: type, flags: flags, streamId: streamId, payload: payload)
    guard let frame = HTTP2Frame.parse(from: data) else {
        throw NSError(domain: "HTTP2StreamManagerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse frame"])
    }
    return frame
}

private func makeGoawayPayload(lastStreamId: UInt32, errorCode: UInt32) -> Data {
    var payload = Data(count: 8)
    payload[0] = UInt8((lastStreamId >> 24) & 0x7F)
    payload[1] = UInt8((lastStreamId >> 16) & 0xFF)
    payload[2] = UInt8((lastStreamId >> 8) & 0xFF)
    payload[3] = UInt8(lastStreamId & 0xFF)
    payload[4] = UInt8((errorCode >> 24) & 0xFF)
    payload[5] = UInt8((errorCode >> 16) & 0xFF)
    payload[6] = UInt8((errorCode >> 8) & 0xFF)
    payload[7] = UInt8(errorCode & 0xFF)
    return payload
}
