//
//  RequestExecutorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

// MARK: - Mock URLProtocol for Testing

class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        // Check for error first
        if let error = MockURLProtocol.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        // Use request handler
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op
    }
}

@MainActor
final class RequestExecutorTests: XCTestCase {

    var executor: RequestExecutor!
    var mockSession: URLSession!

    override func setUp() {
        super.setUp()

        // Configure mock URLSession
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: configuration)

        executor = RequestExecutor()

        // Reset mock state
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.error = nil
    }

    override func tearDown() {
        executor = nil
        mockSession = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.error = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertFalse(executor.isLoading)
        XCTAssertNil(executor.lastResponse)
    }

    // MARK: - RequestBuilder Tests

    func testRequestBuilderInit() {
        let builder = RequestBuilder(
            url: "https://api.example.com",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: "{\"test\": true}"
        )

        XCTAssertEqual(builder.url, "https://api.example.com")
        XCTAssertEqual(builder.method, .post)
        XCTAssertEqual(builder.headers["Content-Type"], "application/json")
        XCTAssertEqual(builder.body, "{\"test\": true}")
    }

    func testRequestBuilderFromNetworkRequest() {
        let networkRequest = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.5,
            requestHeaders: [TraceHTTPHeader(key: "Authorization", value: "Bearer token")],
            responseHeaders: [],
            requestBody: BodyStorage.from(string: "{\"data\": true}"),
            responseBody: .empty
        )

        let builder = RequestBuilder(from: networkRequest)

        XCTAssertEqual(builder.url, networkRequest.url)
        XCTAssertEqual(builder.method, networkRequest.method)
        XCTAssertEqual(builder.headers["Authorization"], "Bearer token")
        XCTAssertEqual(builder.body, "{\"data\": true}")
    }

    func testRequestBuilderToCURL() {
        let builder = RequestBuilder(
            url: "https://api.example.com/users",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: "{\"name\": \"John\"}"
        )

        let curl = builder.toCURL()

        XCTAssertTrue(curl.contains("curl -X POST"))
        XCTAssertTrue(curl.contains("Content-Type: application/json"))
        XCTAssertTrue(curl.contains("https://api.example.com/users"))
    }

    func testRequestBuilderToHTTPRaw() {
        let builder = RequestBuilder(
            url: "https://api.example.com/users",
            method: .get,
            headers: ["Accept": "application/json"],
            body: nil
        )

        let raw = builder.toHTTPRaw()

        XCTAssertTrue(raw.contains("GET https://api.example.com/users HTTP/1.1"))
        XCTAssertTrue(raw.contains("Accept: application/json"))
    }

    func testRequestBuilderCurlWithBodyEscaping() {
        let builder = RequestBuilder(
            url: "https://example.com",
            method: .post,
            headers: [:],
            body: "data with 'quotes'"
        )

        let curl = builder.toCURL()

        XCTAssertTrue(curl.contains("data with"))
    }

    // MARK: - Execute Tests

    func testExecuteInvalidURL() async {
        let builder = RequestBuilder(
            url: "not a valid url",
            method: .get,
            headers: [:],
            body: nil
        )

        do {
            _ = try await executor.execute(builder)
            XCTFail("Should have thrown an error")
        } catch let error as RequestExecutionError {
            XCTAssertEqual(error.errorDescription, "Invalid URL")
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testExecuteSuccessfulRequest() async throws {
        // Setup mock response
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = "{\"success\": true}".data(using: .utf8)
            return (response, data)
        }

        let builder = RequestBuilder(
            url: "https://api.example.com/test",
            method: .get,
            headers: [:],
            body: nil
        )

        // Create request executor with mock session
        let mockExecutor = RequestExecutor(session: mockSession)

        let response = try await mockExecutor.execute(builder)

        XCTAssertEqual(response.statusCode, 200)
        let contentTypeHeader = response.responseHeaders.first { $0.key.lowercased() == "content-type" }
        XCTAssertEqual(contentTypeHeader?.value, "application/json")
        XCTAssertNotNil(response.responseBody.getString())
    }

    func testExecuteWithPostBody() async throws {
        var receivedRequest: URLRequest?

        MockURLProtocol.requestHandler = { request in
            receivedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, nil)
        }

        let builder = RequestBuilder(
            url: "https://api.example.com/users",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: "{\"name\": \"Test\"}"
        )

        let mockExecutor = RequestExecutor(session: mockSession)
        let response = try await mockExecutor.execute(builder)

        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(receivedRequest?.httpMethod, "POST")
        XCTAssertTrue(receivedRequest?.httpBody != nil || receivedRequest?.httpBodyStream != nil)
    }

    func testExecuteHandlesNetworkError() async {
        MockURLProtocol.error = URLError(.notConnectedToInternet)

        let builder = RequestBuilder(
            url: "https://api.example.com/test",
            method: .get,
            headers: [:],
            body: nil
        )

        let mockExecutor = RequestExecutor(session: mockSession)

        do {
            _ = try await mockExecutor.execute(builder)
            XCTFail("Should have thrown an error")
        } catch {
            // Expected error
            XCTAssertNotNil(error)
        }
    }

    func testExecuteHandles404() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            let data = "Not Found".data(using: .utf8)
            return (response, data)
        }

        let builder = RequestBuilder(
            url: "https://api.example.com/notfound",
            method: .get,
            headers: [:],
            body: nil
        )

        let mockExecutor = RequestExecutor(session: mockSession)
        let response = try await mockExecutor.execute(builder)

        XCTAssertEqual(response.statusCode, 404)
    }

    // MARK: - Quick Request Tests

    func testGetRequestBuilder() {
        let builder = RequestBuilder(
            url: "https://example.com",
            method: .get,
            headers: [:],
            body: nil
        )

        XCTAssertEqual(builder.method, .get)
        XCTAssertNil(builder.body)
    }

    func testPostRequestBuilder() {
        let builder = RequestBuilder(
            url: "https://example.com",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: "{}"
        )

        XCTAssertEqual(builder.method, .post)
        XCTAssertNotNil(builder.body)
    }

    // MARK: - Replay Tests

    func testReplayRequest() {
        let originalRequest = NetworkRequest(
            url: "https://example.com",
            method: .post,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.5,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            responseHeaders: [],
            requestBody: BodyStorage.from(string: "{\"test\": true}"),
            responseBody: .empty
        )

        let builder = RequestBuilder(from: originalRequest)

        XCTAssertEqual(builder.url, originalRequest.url)
        XCTAssertEqual(builder.method, originalRequest.method)
    }

    // MARK: - Headers Tests

    func testRequestBuilderPreservesHeaders() {
        let headers = [
            "Authorization": "Bearer token123",
            "Content-Type": "application/json",
            "X-Custom-Header": "value"
        ]

        let builder = RequestBuilder(
            url: "https://example.com",
            method: .get,
            headers: headers,
            body: nil
        )

        XCTAssertEqual(builder.headers.count, 3)
        XCTAssertEqual(builder.headers["Authorization"], "Bearer token123")
        XCTAssertEqual(builder.headers["Content-Type"], "application/json")
        XCTAssertEqual(builder.headers["X-Custom-Header"], "value")
    }

    // MARK: - Body Tests

    func testRequestBuilderWithBody() {
        let body = "{\"key\": \"value\"}"
        let builder = RequestBuilder(
            url: "https://example.com",
            method: .post,
            headers: [:],
            body: body
        )

        XCTAssertEqual(builder.body, body)
    }

    func testRequestBuilderWithoutBody() {
        let builder = RequestBuilder(
            url: "https://example.com",
            method: .get,
            headers: [:],
            body: nil
        )

        XCTAssertNil(builder.body)
    }

    // MARK: - Observable Properties Tests

    func testIsLoadingProperty() {
        XCTAssertFalse(executor.isLoading)
    }

    func testLastResponseProperty() {
        XCTAssertNil(executor.lastResponse)
    }

    // MARK: - HTTP Methods Tests

    func testDifferentHTTPMethods() {
        let getMethods: [HTTPMethod] = [.get, .post, .put, .delete, .patch, .head, .options]

        for method in getMethods {
            let builder = RequestBuilder(
                url: "https://example.com",
                method: method,
                headers: [:],
                body: nil
            )

            XCTAssertEqual(builder.method, method)
        }
    }

    // MARK: - URL Validation Tests

    func testValidURLs() {
        let validURLs = [
            "https://example.com",
            "http://example.com",
            "https://api.example.com/v1/users",
            "https://example.com:8080/path",
            "https://example.com/path?query=value"
        ]

        for urlString in validURLs {
            let builder = RequestBuilder(url: urlString, method: .get, headers: [:], body: nil)
            XCTAssertNotNil(URL(string: builder.url), "URL should be valid: \(urlString)")
        }
    }

    // MARK: - cURL Export Tests

    func testCurlExportWithMultipleHeaders() {
        let builder = RequestBuilder(
            url: "https://api.example.com",
            method: .post,
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer token",
                "X-Request-ID": "123"
            ],
            body: "{}"
        )

        let curl = builder.toCURL()

        XCTAssertTrue(curl.contains("Content-Type: application/json"))
        XCTAssertTrue(curl.contains("Authorization: Bearer token"))
        XCTAssertTrue(curl.contains("X-Request-ID: 123"))
    }

    func testCurlExportForGET() {
        let builder = RequestBuilder(
            url: "https://api.example.com/users",
            method: .get,
            headers: [:],
            body: nil
        )

        let curl = builder.toCURL()

        XCTAssertTrue(curl.contains("curl -X GET"))
        XCTAssertFalse(curl.contains("--data-raw"))
    }

    func testCurlExportForPOST() {
        let builder = RequestBuilder(
            url: "https://api.example.com/users",
            method: .post,
            headers: [:],
            body: "{\"name\": \"test\"}"
        )

        let curl = builder.toCURL()

        XCTAssertTrue(curl.contains("curl -X POST"))
        XCTAssertTrue(curl.contains("--data-raw"))
    }

    // MARK: - HTTP Raw Export Tests

    func testHTTPRawExportStructure() {
        let builder = RequestBuilder(
            url: "https://api.example.com/users",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: "{\"data\": true}"
        )

        let raw = builder.toHTTPRaw()

        XCTAssertTrue(raw.contains("POST"))
        XCTAssertTrue(raw.contains("HTTP/1.1"))
        XCTAssertTrue(raw.contains("\r\n\r\n"))
        XCTAssertTrue(raw.contains("{\"data\": true}"))
    }

    func testHTTPRawExportWithoutBody() {
        let builder = RequestBuilder(
            url: "https://example.com",
            method: .get,
            headers: ["Accept": "application/json"],
            body: nil
        )

        let raw = builder.toHTTPRaw()

        XCTAssertTrue(raw.contains("GET"))
        XCTAssertTrue(raw.contains("Accept: application/json"))
        XCTAssertTrue(raw.hasSuffix("\r\n\r\n") || raw.hasSuffix("\r\n"))
    }
}
