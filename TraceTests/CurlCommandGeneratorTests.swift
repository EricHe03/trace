//
//  CurlCommandGeneratorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class CurlCommandGeneratorTests: XCTestCase {
    // MARK: - Basic Request Generation Tests

    func testGenerate_BasicGETRequest() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/users",
            method: .get
        )

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("curl -X GET"))
        XCTAssertTrue(curl.contains("https://api.example.com/users"))
    }

    func testGenerate_BasicPOSTRequest() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/users",
            method: .post,
            requestBody: makeBodyStorage(string: "{\"name\": \"John\"}")
        )

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("curl -X POST"))
        XCTAssertTrue(curl.contains("https://api.example.com/users"))
        XCTAssertTrue(curl.contains("--data-raw"))
    }

    // MARK: - HTTP Methods Tests

    func testGenerate_AllHTTPMethods() {
        let methods: [HTTPMethod] = [.get, .post, .put, .delete, .patch, .head, .options]

        for method in methods {
            let request = makeNetworkRequest(method: method)
            let curl = CurlCommandGenerator.generate(from: request)

            XCTAssertTrue(
                curl.contains("curl -X \(method.rawValue)"),
                "Should contain method \(method.rawValue)"
            )
        }
    }

    // MARK: - Header Tests

    func testGenerate_IncludesStandardHeaders() {
        let headers = [
            TraceHTTPHeader(key: "Authorization", value: "Bearer token123"),
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("Authorization: Bearer token123"))
        XCTAssertTrue(curl.contains("Content-Type: application/json"))
    }

    func testGenerate_FiltersExcludedHeaders() {
        let headers = [
            TraceHTTPHeader(key: "Authorization", value: "Bearer token"),
            TraceHTTPHeader(key: "Accept-Encoding", value: "gzip"),
            TraceHTTPHeader(key: "Cache-Control", value: "no-cache")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("Authorization"))
        XCTAssertFalse(curl.contains("Accept-Encoding"), "Should filter out accept-encoding")
        XCTAssertFalse(curl.contains("Cache-Control"), "Should filter out cache-control")
    }

    func testGenerate_FiltersPrefixHeaders() {
        let headers = [
            TraceHTTPHeader(key: "Authorization", value: "Bearer token"),
            TraceHTTPHeader(key: "sec-ch-ua", value: "test"),
            TraceHTTPHeader(key: "sec-fetch-mode", value: "cors"),
            TraceHTTPHeader(key: ":authority", value: "example.com")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("Authorization"))
        XCTAssertFalse(curl.contains("sec-ch-ua"), "Should filter sec-ch-ua headers")
        XCTAssertFalse(curl.contains("sec-fetch"), "Should filter sec-fetch headers")
        XCTAssertFalse(curl.contains(":authority"), "Should filter pseudo-headers")
    }

    func testGenerate_CaseInsensitiveHeaderFiltering() {
        let headers = [
            TraceHTTPHeader(key: "ACCEPT-ENCODING", value: "gzip"),
            TraceHTTPHeader(key: "content-type", value: "application/json")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertFalse(curl.contains("ACCEPT-ENCODING"))
        XCTAssertTrue(curl.contains("content-type"))
    }

    // MARK: - Body Tests

    func testGenerate_WithTextBody() {
        let bodyString = "Hello, World!"
        let request = makeNetworkRequest(
            method: .post,
            requestBody: makeBodyStorage(string: bodyString)
        )

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("--data-raw"))
        XCTAssertTrue(curl.contains("Hello, World!"))
    }

    func testGenerate_WithJSONBody() {
        let jsonString = makeJSON(["key": "value", "number": 42])
        let request = makeNetworkRequest(
            method: .post,
            requestBody: makeBodyStorage(string: jsonString)
        )

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("--data-raw"))
        XCTAssertTrue(curl.contains("key"))
    }

    func testGenerate_WithoutBody() {
        let request = makeNetworkRequest(method: .get)

        let curl = CurlCommandGenerator.generate(from: request)

        // GET request should not have --data-raw flag unless explicitly provided
        XCTAssertTrue(curl.contains("curl -X GET"))
    }

    // MARK: - Special Characters Tests

    func testGenerate_EscapesSingleQuotes() {
        let bodyWithQuote = "It's a test"
        let request = makeNetworkRequest(
            method: .post,
            requestBody: makeBodyStorage(string: bodyWithQuote)
        )

        let curl = CurlCommandGenerator.generate(from: request)

        // Single quote should be escaped
        XCTAssertTrue(curl.contains("--data-raw"))
        // curl escaping: 'It'\''s a test'
        XCTAssertTrue(curl.contains("'\\''"))
    }

    func testGenerate_HandlesSpecialCharactersInURL() {
        let url = "https://api.example.com/search?q=hello+world&filter=active"
        let request = makeNetworkRequest(url: url)

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains(url))
    }

    func testGenerate_HandlesUnicodeInBody() {
        let bodyString = "Hello 世界"
        let request = makeNetworkRequest(
            method: .post,
            requestBody: makeBodyStorage(string: bodyString)
        )

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("--data-raw"))
    }

    // MARK: - Format Tests

    func testGenerate_FormatsWithBackslashes() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/test",
            method: .post,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        )

        let curl = CurlCommandGenerator.generate(from: request)

        // Should have backslashes for line continuation
        XCTAssertTrue(curl.contains("\\"))
        // Should have CRLF line endings
        XCTAssertTrue(curl.contains("\\\n"))
    }

    func testGenerate_IsValidCurlCommand() {
        let request = makeNetworkRequest(
            url: "https://example.com/api",
            method: .get
        )

        let curl = CurlCommandGenerator.generate(from: request)

        // Basic structure validation
        XCTAssertTrue(curl.hasPrefix("curl"))
        XCTAssertTrue(curl.contains("https://example.com/api"))
    }

    // MARK: - Complex Request Tests

    func testGenerate_ComplexRequestWithMultipleHeaders() {
        let headers = [
            TraceHTTPHeader(key: "Authorization", value: "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"),
            TraceHTTPHeader(key: "Accept", value: "application/json"),
            TraceHTTPHeader(key: "User-Agent", value: "Trace/1.0"),
            TraceHTTPHeader(key: "X-Request-ID", value: "12345")
        ]
        let body = makeJSON(["username": "john", "password": "secret"])
        let request = makeNetworkRequest(
            url: "https://api.example.com/login",
            method: .post,
            requestHeaders: headers,
            requestBody: makeBodyStorage(string: body)
        )

        let curl = CurlCommandGenerator.generate(from: request)

        // Verify all important parts are present
        XCTAssertTrue(curl.contains("curl -X POST"))
        XCTAssertTrue(curl.contains("https://api.example.com/login"))
        XCTAssertTrue(curl.contains("Authorization"))
        XCTAssertTrue(curl.contains("Accept"))
        XCTAssertTrue(curl.contains("User-Agent"))
        XCTAssertTrue(curl.contains("X-Request-ID"))
        XCTAssertTrue(curl.contains("--data-raw"))
    }

    func testGenerate_POSTRequestWithFormData() {
        let bodyString = "field1=value1&field2=value2"
        let request = makeNetworkRequest(
            url: "https://example.com/form",
            method: .post,
            requestHeaders: [
                TraceHTTPHeader(key: "Content-Type", value: "application/x-www-form-urlencoded")
            ],
            requestBody: makeBodyStorage(string: bodyString)
        )

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("curl -X POST"))
        XCTAssertTrue(curl.contains("--data-raw"))
        XCTAssertTrue(curl.contains("field1=value1"))
    }

    func testGenerate_PUTRequestWithJSON() {
        let json = makeJSON(["id": 123, "status": "updated"])
        let request = makeNetworkRequest(
            url: "https://api.example.com/users/123",
            method: .put,
            requestHeaders: [
                TraceHTTPHeader(key: "Content-Type", value: "application/json")
            ],
            requestBody: makeBodyStorage(string: json)
        )

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("curl -X PUT"))
        XCTAssertTrue(curl.contains("https://api.example.com/users/123"))
    }

    func testGenerate_DELETERequestWithQueryParams() {
        let url = "https://api.example.com/users/123?force=true"
        let request = makeNetworkRequest(url: url, method: .delete)

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("curl -X DELETE"))
        XCTAssertTrue(curl.contains(url))
    }

    // MARK: - Edge Cases

    func testGenerate_EmptyURL() {
        let request = makeNetworkRequest(url: "")

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("curl"))
    }

    func testGenerate_LongURL() {
        let longPath = "/" + String(repeating: "a", count: 500)
        let url = "https://example.com" + longPath
        let request = makeNetworkRequest(url: url)

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains(url))
    }

    func testGenerate_MultipleHeadersWithSameName() {
        let headers = [
            TraceHTTPHeader(key: "Accept", value: "application/json"),
            TraceHTTPHeader(key: "Accept-Encoding", value: "gzip")
        ]
        let request = makeNetworkRequest(requestHeaders: headers)

        let curl = CurlCommandGenerator.generate(from: request)

        XCTAssertTrue(curl.contains("Accept"))
        // Accept-Encoding should be filtered
        XCTAssertFalse(curl.contains("Accept-Encoding"))
    }
}
