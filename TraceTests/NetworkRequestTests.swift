//
//  NetworkRequestTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class NetworkRequestTests: XCTestCase {

    // MARK: - Protocol Version Detection Tests

    func testDetectHTTP2WithPseudoHeaders() {
        let requestHeaders = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/api/test"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "example.com")
        ]

        let request = NetworkRequest(
            url: "https://example.com/api/test",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            requestHeaders: requestHeaders
        )

        XCTAssertEqual(request.protocolVersion, .http2)
        XCTAssertTrue(request.isHTTP2)
    }

    func testDetectHTTP2WithUpgradeHeader() {
        let requestHeaders = [
            TraceHTTPHeader(key: "Upgrade", value: "h2c"),
            TraceHTTPHeader(key: "Connection", value: "Upgrade")
        ]

        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            requestHeaders: requestHeaders
        )

        XCTAssertEqual(request.protocolVersion, .http2)
    }

    func testDetectHTTP2WithALPNHeader() {
        let responseHeaders = [
            TraceHTTPHeader(key: "X-Protocol", value: "h2"),
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ]

        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            responseHeaders: responseHeaders
        )

        XCTAssertEqual(request.protocolVersion, .http2)
    }

    func testDetectHTTP11Default() {
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        XCTAssertEqual(request.protocolVersion, .http11)
        XCTAssertFalse(request.isHTTP2)
    }

    func testExplicitProtocolVersion() {
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            protocolVersion: .http3
        )

        XCTAssertEqual(request.protocolVersion, .http3)
    }

    // MARK: - Status Color Tests

    func testStatusColorSuccess() {
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.statusColor, .success)

        let request299 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 299,
            duration: 0.5
        )
        XCTAssertEqual(request299.statusColor, .success)
    }

    func testStatusColorRedirect() {
        let request301 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 301,
            duration: 0.5
        )
        XCTAssertEqual(request301.statusColor, .redirect)

        let request302 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 302,
            duration: 0.5
        )
        XCTAssertEqual(request302.statusColor, .redirect)
    }

    func testStatusColorClientError() {
        let request400 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 400,
            duration: 0.5
        )
        XCTAssertEqual(request400.statusColor, .clientError)

        let request404 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 404,
            duration: 0.5
        )
        XCTAssertEqual(request404.statusColor, .clientError)
    }

    func testStatusColorServerError() {
        let request500 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 500,
            duration: 0.5
        )
        XCTAssertEqual(request500.statusColor, .serverError)

        let request503 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 503,
            duration: 0.5
        )
        XCTAssertEqual(request503.statusColor, .serverError)
    }

    func testStatusColorUnknown() {
        let request100 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 100,
            duration: 0.5
        )
        XCTAssertEqual(request100.statusColor, .unknown)

        let request600 = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 600,
            duration: 0.5
        )
        XCTAssertEqual(request600.statusColor, .unknown)
    }

    // MARK: - URL Parsing Tests

    func testHostExtraction() {
        let request = NetworkRequest(
            url: "https://example.com/path/to/resource",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.host, "example.com")
    }

    func testHostWithPort() {
        let request = NetworkRequest(
            url: "https://example.com:8080/path",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.host, "example.com")
    }

    func testHostWithSubdomain() {
        let request = NetworkRequest(
            url: "https://api.example.com/v1/users",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.host, "api.example.com")
    }

    func testHostFallbackToURLString() {
        let request = NetworkRequest(
            url: "invalid-url",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.host, "invalid-url")
    }

    func testPathExtraction() {
        let request = NetworkRequest(
            url: "https://example.com/api/users",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.path, "/api/users")
    }

    func testPathWithQueryString() {
        let request = NetworkRequest(
            url: "https://example.com/search?q=test",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.path, "/search")
    }

    func testPathDefaultsToRoot() {
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.path, "/")
    }

    func testPathFallbackToURLString() {
        let request = NetworkRequest(
            url: "invalid-url",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )
        XCTAssertEqual(request.path, "invalid-url")
    }

    // MARK: - HTTPMethod Tests

    func testHTTPMethodColors() {
        XCTAssertEqual(HTTPMethod.get.color, .success)
        XCTAssertEqual(HTTPMethod.post.color, .info)
        XCTAssertEqual(HTTPMethod.put.color, .warning)
        XCTAssertEqual(HTTPMethod.delete.color, .clientError)
        XCTAssertEqual(HTTPMethod.patch.color, .warning)
        XCTAssertEqual(HTTPMethod.head.color, .unknown)
        XCTAssertEqual(HTTPMethod.options.color, .unknown)
    }

    // MARK: - HTTPProtocolVersion Tests

    func testProtocolVersionDisplayNames() {
        XCTAssertEqual(HTTPProtocolVersion.http10.displayName, "HTTP/1.0")
        XCTAssertEqual(HTTPProtocolVersion.http11.displayName, "HTTP/1.1")
        XCTAssertEqual(HTTPProtocolVersion.http2.displayName, "HTTP/2")
        XCTAssertEqual(HTTPProtocolVersion.http3.displayName, "HTTP/3")
    }

    func testProtocolVersionShortNames() {
        XCTAssertEqual(HTTPProtocolVersion.http10.shortName, "1.0")
        XCTAssertEqual(HTTPProtocolVersion.http11.shortName, "1.1")
        XCTAssertEqual(HTTPProtocolVersion.http2.shortName, "2")
        XCTAssertEqual(HTTPProtocolVersion.http3.shortName, "3")
    }

    func testProtocolVersionColors() {
        XCTAssertEqual(HTTPProtocolVersion.http10.color, .warning)
        XCTAssertEqual(HTTPProtocolVersion.http11.color, .info)
        XCTAssertEqual(HTTPProtocolVersion.http2.color, .success)
        XCTAssertEqual(HTTPProtocolVersion.http3.color, .success)
    }

    func testProtocolVersionIcons() {
        XCTAssertEqual(HTTPProtocolVersion.http10.icon, "clock.fill")
        XCTAssertEqual(HTTPProtocolVersion.http11.icon, "checkmark.circle.fill")
        XCTAssertEqual(HTTPProtocolVersion.http2.icon, "bolt.fill")
        XCTAssertEqual(HTTPProtocolVersion.http3.icon, "bolt.fill")
    }

    func testProtocolVersionDescriptions() {
        XCTAssertTrue(HTTPProtocolVersion.http10.description.contains("1996"))
        XCTAssertTrue(HTTPProtocolVersion.http11.description.contains("keep-alive"))
        XCTAssertTrue(HTTPProtocolVersion.http2.description.contains("multiplexing"))
        XCTAssertTrue(HTTPProtocolVersion.http3.description.contains("QUIC"))
    }

    // MARK: - TraceHTTPHeader Tests

    func testHeaderEquality() {
        let header1 = TraceHTTPHeader(key: "Content-Type", value: "application/json")
        let header2 = TraceHTTPHeader(key: "Content-Type", value: "application/json")
        let header3 = TraceHTTPHeader(key: "Content-Type", value: "text/html")
        let header4 = TraceHTTPHeader(key: "Accept", value: "application/json")

        XCTAssertEqual(header1, header2)
        XCTAssertNotEqual(header1, header3)
        XCTAssertNotEqual(header1, header4)
    }

    // MARK: - Integration Tests

    func testCompleteRequestWithAllProperties() {
        let timestamp = Date()
        let requestHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Authorization", value: "Bearer token123")
        ]
        let responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "X-Protocol", value: "h2")
        ]

        let requestBody = BodyStorage.from(data: "{\"key\":\"value\"}".data(using: .utf8)!)
        let responseBody = BodyStorage.from(data: "{\"result\":\"success\"}".data(using: .utf8)!)

        let request = NetworkRequest(
            url: "https://api.example.com/v1/users",
            method: .post,
            statusCode: 201,
            statusMessage: "Created",
            timestamp: timestamp,
            duration: 1.5,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody
        )

        XCTAssertEqual(request.url, "https://api.example.com/v1/users")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.statusCode, 201)
        XCTAssertEqual(request.statusMessage, "Created")
        XCTAssertEqual(request.timestamp, timestamp)
        XCTAssertEqual(request.duration, 1.5)
        XCTAssertEqual(request.requestHeaders.count, 2)
        XCTAssertEqual(request.responseHeaders.count, 2)
        XCTAssertFalse(request.requestBody.isEmpty)
        XCTAssertFalse(request.responseBody.isEmpty)
        XCTAssertEqual(request.protocolVersion, .http2)
        XCTAssertEqual(request.statusColor, .success)
        XCTAssertEqual(request.host, "api.example.com")
        XCTAssertEqual(request.path, "/v1/users")
        XCTAssertTrue(request.isHTTP2)
    }
}
