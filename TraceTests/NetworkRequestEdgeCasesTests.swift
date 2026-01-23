//
//  NetworkRequestEdgeCasesTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import Trace
@testable import TraceCore

final class NetworkRequestEdgeCasesTests: XCTestCase {
    // MARK: - Extremely Long URL Tests

    func testLongURL_IsHandled() {
        let longPath = "/" + String(repeating: "a", count: 5000)
        let url = "https://example.com" + longPath

        let request = makeNetworkRequest(url: url)

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.url.count, url.count)
    }

    func testVeryLongURL_MultiMegabyte() {
        // 2MB URL (extreme edge case)
        let longPath = "/" + String(repeating: "x", count: 2_000_000)
        let url = "https://example.com" + longPath

        let request = makeNetworkRequest(url: url)

        XCTAssertEqual(request.url.count, url.count)
    }

    // MARK: - Many Headers Tests

    func testManyHeaders_Handled() {
        let headerCount = 1000
        let request = makeRequestWithNHeaders(count: headerCount)

        XCTAssertEqual(request.requestHeaders.count, headerCount)
    }

    func testThousandsOfHeaders() {
        let headers = (0 ..< 5000).map { i in
            TraceHTTPHeader(key: "X-Header-\(i)", value: "value-\(i)")
        }
        let request = makeNetworkRequest(requestHeaders: headers)

        XCTAssertEqual(request.requestHeaders.count, 5000)
    }

    // MARK: - Duplicate Headers Tests

    func testDuplicateHeaderKeys_ArePreserved() {
        let headers = [
            TraceHTTPHeader(key: "Set-Cookie", value: "session=abc123"),
            TraceHTTPHeader(key: "Set-Cookie", value: "token=xyz789"),
            TraceHTTPHeader(key: "Set-Cookie", value: "preference=dark_mode")
        ]
        let request = makeNetworkRequest(responseHeaders: headers)

        XCTAssertEqual(request.responseHeaders.count, 3)

        let cookieHeaders = request.responseHeaders.filter { $0.key == "Set-Cookie" }
        XCTAssertEqual(cookieHeaders.count, 3)
    }

    func testDuplicateHeaderKeys_DifferentCase() {
        let headers = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "content-type", value: "text/plain"),
            TraceHTTPHeader(key: "CONTENT-TYPE", value: "text/html")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        XCTAssertEqual(request.requestHeaders.count, 3)
    }

    // MARK: - Special Characters in URLs Tests

    func testURLWithUnicodeCharacters() {
        let url = "https://example.com/search?q=hello%20世界&emoji=🌍"
        let request = makeNetworkRequest(url: url)

        XCTAssertEqual(request.url, url)
    }

    func testURLWithSpecialCharacters() {
        let url = "https://example.com/path?param1=value&param2=a+b&param3=c%20d&special=!@#$%^&*()"
        let request = makeNetworkRequest(url: url)

        XCTAssertEqual(request.url, url)
    }

    func testURLWithFragment() {
        let url = "https://example.com/page#section"
        let request = makeNetworkRequest(url: url)

        XCTAssertEqual(request.url, url)
    }

    func testURLWithPort() {
        let url = "https://example.com:8443/api/v1"
        let request = makeNetworkRequest(url: url)

        XCTAssertEqual(request.url, url)
    }

    func testURLWithIPAddress() {
        let url = "http://192.168.1.1:8080/admin"
        let request = makeNetworkRequest(url: url)

        XCTAssertEqual(request.url, url)
    }

    func testURLWithIPv6Address() {
        let url = "http://[2001:0db8:85a3:0000:0000:8a2e:0370:7334]:8080/api"
        let request = makeNetworkRequest(url: url)

        XCTAssertEqual(request.url, url)
    }

    // MARK: - Large Response Body Tests

    func testLargeResponseBody_100MB() {
        let largeData = generateLargePayload(sizeInBytes: 100 * 1024 * 1024) // 100 MB
        let body = makeBodyStorage(data: largeData)

        let request = makeNetworkRequest(responseBody: body)

        XCTAssertGreaterThan(request.responseBody.totalSize, 0)
    }

    func testLargeRequestBody() {
        let largeData = generateLargePayload(sizeInBytes: 50 * 1024 * 1024) // 50 MB
        let body = makeBodyStorage(data: largeData)

        let request = makeNetworkRequest(requestBody: body)

        XCTAssertGreaterThan(request.requestBody.totalSize, 0)
    }

    // MARK: - Empty Values Tests

    func testEmptyHeaderValues() {
        let headers = [
            TraceHTTPHeader(key: "X-Empty", value: ""),
            TraceHTTPHeader(key: "X-Whitespace", value: "   "),
            TraceHTTPHeader(key: "X-Normal", value: "value")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        XCTAssertEqual(request.requestHeaders.count, 3)
        XCTAssertEqual(request.requestHeaders[0].value, "")
        XCTAssertEqual(request.requestHeaders[1].value, "   ")
    }

    func testEmptyURL() {
        let request = makeNetworkRequest(url: "")

        XCTAssertEqual(request.url, "")
    }

    func testEmptyStatusMessage() {
        let request = makeNetworkRequest(statusCode: 200, statusMessage: "")

        XCTAssertEqual(request.statusMessage, "")
    }

    // MARK: - ID Uniqueness Tests

    func testUniqueIDs_AcrossMultipleRequests() {
        let requests = (0 ..< 1000).map { _ in
            makeNetworkRequest()
        }

        let uniqueIDs = Set(requests.map(\.id))
        XCTAssertEqual(uniqueIDs.count, 1000, "All request IDs should be unique")
    }

    func testRequestID_IsNotNil() {
        let request = makeNetworkRequest()

        XCTAssertNotNil(request.id)
    }

    // MARK: - Status Code Edge Cases Tests

    func testUnusualStatusCodes() {
        let statusCodes = [
            0, // Invalid
            100, // Informational
            101, // Switching Protocols
            102, // Processing
            103, // Early Hints
            206, // Partial Content
            226, // IM Used
            300, // Multiple Choices
            308, // Permanent Redirect
            418, // I'm a teapot
            451, // Unavailable For Legal Reasons
            506, // Variant Also Negotiates
            599 // Custom
        ]

        for code in statusCodes {
            let request = makeNetworkRequest(statusCode: code)
            XCTAssertEqual(request.statusCode, code)
        }
    }

    func testNegativeStatusCode() {
        let request = makeNetworkRequest(statusCode: -1)

        XCTAssertEqual(request.statusCode, -1)
    }

    func testVeryLargeStatusCode() {
        let request = makeNetworkRequest(statusCode: 99999)

        XCTAssertEqual(request.statusCode, 99999)
    }

    // MARK: - Timestamp Edge Cases Tests

    func testVeryOldTimestamp() {
        let oldDate = Date(timeIntervalSince1970: 0) // Unix epoch
        let request = makeNetworkRequest(timestamp: oldDate)

        XCTAssertEqual(request.timestamp, oldDate)
    }

    func testFutureTimestamp() {
        let futureDate = Date(timeIntervalSinceNow: 365 * 24 * 60 * 60) // 1 year from now
        let request = makeNetworkRequest(timestamp: futureDate)

        XCTAssertEqual(request.timestamp, futureDate)
    }

    // MARK: - Duration Edge Cases Tests

    func testZeroDuration() {
        let request = makeNetworkRequest(duration: 0.0)

        XCTAssertEqual(request.duration, 0.0)
    }

    func testNegativeDuration() {
        let request = makeNetworkRequest(duration: -1.0)

        XCTAssertEqual(request.duration, -1.0)
    }

    func testVeryLongDuration() {
        let duration: TimeInterval = 3600.0 // 1 hour
        let request = makeNetworkRequest(duration: duration)

        XCTAssertEqual(request.duration, duration)
    }

    func testMicrosecondDuration() {
        let duration: TimeInterval = 0.001 // 1 millisecond
        let request = makeNetworkRequest(duration: duration)

        XCTAssertEqual(request.duration, duration)
    }

    // MARK: - Header Key Edge Cases Tests

    func testHeadersWithSpecialCharacters() {
        let headers = [
            TraceHTTPHeader(key: "X-Custom-Header-With-Dashes", value: "value1"),
            TraceHTTPHeader(key: "X_Custom_Header_With_Underscores", value: "value2"),
            TraceHTTPHeader(key: "X.Custom.Header.With.Dots", value: "value3")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        XCTAssertEqual(request.requestHeaders.count, 3)
    }

    func testHeadersWithUnicodeKeys() {
        let headers = [
            TraceHTTPHeader(key: "X-Unicode-世界", value: "value"),
            TraceHTTPHeader(key: "X-Emoji-🌍", value: "value")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        XCTAssertEqual(request.requestHeaders.count, 2)
    }

    // MARK: - Protocol Version Tests

    func testProtocolVersionDetection_HTTP2PseudoHeaders() {
        let headers = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "example.com")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        XCTAssertEqual(request.protocolVersion, .http2)
    }

    func testProtocolVersionDetection_HTTP11() {
        let headers = [
            TraceHTTPHeader(key: "Host", value: "example.com"),
            TraceHTTPHeader(key: "User-Agent", value: "Trace/1.0")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        XCTAssertEqual(request.protocolVersion, .http11)
    }

    // MARK: - Equality and Hashing Tests

    func testEquality_SameID_AreEqual() {
        let id = UUID()
        let request1 = makeNetworkRequest(id: id, url: "https://a.com")
        let request2 = makeNetworkRequest(id: id, url: "https://b.com")

        XCTAssertEqual(request1, request2)
    }

    func testEquality_DifferentID_AreNotEqual() {
        let request1 = makeNetworkRequest(url: "https://example.com")
        let request2 = makeNetworkRequest(url: "https://example.com")

        XCTAssertNotEqual(request1, request2)
    }

    func testHashing_SameID_SameHash() {
        let id = UUID()
        let request1 = makeNetworkRequest(id: id)
        let request2 = makeNetworkRequest(id: id)

        XCTAssertEqual(request1.hashValue, request2.hashValue)
    }

    // MARK: - Throttling Metadata Tests

    func testThrottlingMetadata_WhenSet() {
        var request = makeNetworkRequest()
        request.wasThrottled = true
        request.throttlingProfile = "3G"

        XCTAssertTrue(request.wasThrottled)
        XCTAssertEqual(request.throttlingProfile, "3G")
    }

    func testThrottlingMetadata_DefaultValues() {
        let request = makeNetworkRequest()

        XCTAssertFalse(request.wasThrottled)
        XCTAssertNil(request.throttlingProfile)
    }

    // MARK: - Duplicate Detection Tests

    func testDuplicateDetection_Flags() {
        var request = makeNetworkRequest()
        request.isDuplicate = true
        request.duplicateOfRequestId = UUID()

        XCTAssertTrue(request.isDuplicate)
        XCTAssertNotNil(request.duplicateOfRequestId)
    }

    // MARK: - Response Size Calculation Tests

    func testResponseSize_WithContentLength() {
        let headers = [
            TraceHTTPHeader(key: "Content-Length", value: "1234")
        ]
        let request = makeNetworkRequest(responseHeaders: headers)

        XCTAssertEqual(request.responseSize, 1234)
    }

    func testResponseSize_WithoutContentLength() {
        let bodyData = Data(count: 500)
        let body = makeBodyStorage(data: bodyData)
        let request = makeNetworkRequest(responseBody: body)

        XCTAssertNotNil(request.responseSize)
    }

    func testRequestSize_WithContentLength() {
        let headers = [
            TraceHTTPHeader(key: "Content-Length", value: "567")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        XCTAssertEqual(request.requestSize, 567)
    }

    // MARK: - Host and Path Extraction Tests

    func testHost_ExtractsCorrectly() {
        let request = makeNetworkRequest(url: "https://api.example.com:8443/v1/users")

        XCTAssertEqual(request.host, "api.example.com")
    }

    func testPath_ExtractsCorrectly() {
        let request = makeNetworkRequest(url: "https://api.example.com/v1/users?id=123")

        XCTAssertEqual(request.path, "/v1/users")
    }

    func testPath_RootPath() {
        let request = makeNetworkRequest(url: "https://example.com")

        XCTAssertEqual(request.path, "/")
    }

    func testHost_WithInvalidURL() {
        let request = makeNetworkRequest(url: "not-a-valid-url")

        // Should fall back to the URL string
        XCTAssertEqual(request.host, "not-a-valid-url")
    }

    // MARK: - Status Color Tests

    func testStatusColor_Success() {
        let request = makeNetworkRequest(statusCode: 200)
        XCTAssertEqual(request.statusColor, .success)
    }

    func testStatusColor_Redirect() {
        let request = makeNetworkRequest(statusCode: 301)
        XCTAssertEqual(request.statusColor, .redirect)
    }

    func testStatusColor_ClientError() {
        let request = makeNetworkRequest(statusCode: 404)
        XCTAssertEqual(request.statusColor, .clientError)
    }

    func testStatusColor_ServerError() {
        let request = makeNetworkRequest(statusCode: 500)
        XCTAssertEqual(request.statusColor, .serverError)
    }

    func testStatusColor_Unknown() {
        let request = makeNetworkRequest(statusCode: nil)
        XCTAssertEqual(request.statusColor, .unknown)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentRequestCreation() {
        let iterations = 1000
        var requests: [NetworkRequest] = []
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let request = makeNetworkRequest(
                url: "https://example.com/\(i)",
                method: i % 2 == 0 ? .get : .post
            )

            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        XCTAssertEqual(requests.count, iterations)

        let uniqueIDs = Set(requests.map(\.id))
        XCTAssertEqual(uniqueIDs.count, iterations, "All IDs should be unique")
    }
}
