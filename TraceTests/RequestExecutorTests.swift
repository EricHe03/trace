//
//  RequestExecutorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
import NIOHTTP1
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

private final class MockRequestExecutorTransport: RequestExecutorTransport {
    var requestHandler: ((RequestExecutorTransportRequest) throws -> RequestExecutorTransportResponse)?
    var error: Error?
    private(set) var receivedRequests: [RequestExecutorTransportRequest] = []

    func execute(_ request: RequestExecutorTransportRequest) async throws -> RequestExecutorTransportResponse {
        receivedRequests.append(request)

        if let error {
            throw error
        }

        guard let requestHandler else {
            throw URLError(.unknown)
        }

        return try requestHandler(request)
    }
}

@MainActor
final class RequestExecutorTests: XCTestCase {

    private var executor: RequestExecutor!
    private var mockTransport: MockRequestExecutorTransport!
    private var mockHTTP3Transport: MockRequestExecutorTransport!

    override func setUp() {
        super.setUp()
        mockTransport = MockRequestExecutorTransport()
        mockHTTP3Transport = MockRequestExecutorTransport()
        executor = RequestExecutor(transport: mockTransport, http3Transport: mockHTTP3Transport)
    }

    override func tearDown() {
        executor = nil
        mockTransport = nil
        mockHTTP3Transport = nil
        super.tearDown()
    }

    private func makeTransportResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        redirects: [RedirectInfo] = []
    ) throws -> RequestExecutorTransportResponse {
        RequestExecutorTransportResponse(
            finalURL: url,
            statusCode: statusCode,
            statusMessage: HTTPURLResponse.localizedString(forStatusCode: statusCode),
            protocolVersion: .http11,
            responseHeaders: headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) },
            body: body,
            redirects: redirects,
            responseCookies: []
        )
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertFalse(executor.isLoading)
        XCTAssertNil(executor.lastResponse)
    }

    func testShouldFollowRedirectStatus_AllowsRedirectCodes() {
        XCTAssertTrue(AsyncHTTPClientRequestTransport.shouldFollowRedirectStatus(.movedPermanently))
        XCTAssertTrue(AsyncHTTPClientRequestTransport.shouldFollowRedirectStatus(.found))
        XCTAssertTrue(AsyncHTTPClientRequestTransport.shouldFollowRedirectStatus(.seeOther))
        XCTAssertTrue(AsyncHTTPClientRequestTransport.shouldFollowRedirectStatus(.temporaryRedirect))
        XCTAssertTrue(AsyncHTTPClientRequestTransport.shouldFollowRedirectStatus(.permanentRedirect))
    }

    func testShouldFollowRedirectStatus_RejectsNonRedirectCodes() {
        XCTAssertFalse(AsyncHTTPClientRequestTransport.shouldFollowRedirectStatus(.ok))
        XCTAssertFalse(AsyncHTTPClientRequestTransport.shouldFollowRedirectStatus(.notModified))
        XCTAssertFalse(AsyncHTTPClientRequestTransport.shouldFollowRedirectStatus(.useProxy))
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
        mockTransport.requestHandler = { request in
            try self.makeTransportResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("{\"success\": true}".utf8)
            )
        }

        let builder = RequestBuilder(
            url: "https://api.example.com/test",
            method: .get,
            headers: [:],
            body: nil
        )

        let response = try await executor.execute(builder)

        XCTAssertEqual(response.statusCode, 200)
        let contentTypeHeader = response.responseHeaders.first { $0.key.lowercased() == "content-type" }
        XCTAssertEqual(contentTypeHeader?.value, "application/json")
        XCTAssertNotNil(response.responseBody.getString())
    }

    func testExecuteStoresLargeManualResponseBodyAsFileForSharing() async throws {
        let largeBody = Data(repeating: 0x5A, count: (2 * 1024 * 1024) + (128 * 1024))

        mockTransport.requestHandler = { request in
            try self.makeTransportResponse(
                url: request.url,
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: largeBody
            )
        }

        let builder = RequestBuilder(
            url: "https://example.com/large.bin",
            method: .get,
            headers: [:],
            body: nil
        )

        let response = try await executor.execute(builder)
        defer { response.responseBody.deleteFile() }

        XCTAssertTrue(response.responseBody.isFile)
        XCTAssertFalse(response.responseBody.isTruncated)
        XCTAssertEqual(response.responseBody.totalSize, largeBody.count)
        XCTAssertEqual(response.responseBody.getData()?.count, largeBody.count)
    }

    func testExecuteWithPostBody() async throws {
        var receivedRequest: RequestExecutorTransportRequest?

        mockTransport.requestHandler = { request in
            receivedRequest = request
            return try self.makeTransportResponse(
                url: request.url,
                statusCode: 201,
                headers: ["Content-Type": "application/json"]
            )
        }

        let builder = RequestBuilder(
            url: "https://api.example.com/users",
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: "{\"name\": \"Test\"}"
        )

        let response = try await executor.execute(builder)

        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(receivedRequest?.methodRaw, "POST")
        XCTAssertNotNil(receivedRequest?.body)
    }

    func testExecuteRoutesHTTP3HintToHTTP3Transport() async throws {
        mockTransport.requestHandler = { _ in
            XCTFail("HTTP/1.1+ transport should not be used for HTTP/3 requests")
            throw URLError(.badServerResponse)
        }

        mockHTTP3Transport.requestHandler = { request in
            XCTAssertEqual(request.requestedProtocolVersion, .http3)
            XCTAssertFalse(request.enforceRequestedProtocolVersion)
            return RequestExecutorTransportResponse(
                finalURL: request.url,
                statusCode: 200,
                statusMessage: "OK",
                protocolVersion: .http3,
                responseHeaders: [],
                body: Data(),
                redirects: [],
                responseCookies: []
            )
        }

        var builder = RequestBuilder(
            url: "https://api.example.com/h3",
            method: .get,
            headers: [:],
            body: nil
        )
        builder.protocolVersion = .http3

        _ = try await executor.execute(builder)

        XCTAssertTrue(mockTransport.receivedRequests.isEmpty)
        XCTAssertEqual(mockHTTP3Transport.receivedRequests.count, 1)
    }

    func testExecutePropagatesHTTP3OnlyConstraint() async throws {
        mockHTTP3Transport.requestHandler = { request in
            XCTAssertEqual(request.requestedProtocolVersion, .http3)
            XCTAssertTrue(request.enforceRequestedProtocolVersion)
            return RequestExecutorTransportResponse(
                finalURL: request.url,
                statusCode: 200,
                statusMessage: "OK",
                protocolVersion: .http3,
                responseHeaders: [],
                body: Data(),
                redirects: [],
                responseCookies: []
            )
        }

        var builder = RequestBuilder(
            url: "https://api.example.com/h3-only",
            method: .get,
            headers: [:],
            body: nil
        )
        builder.protocolVersion = .http3
        builder.enforceProtocolVersion = true

        _ = try await executor.execute(builder)

        XCTAssertEqual(mockHTTP3Transport.receivedRequests.count, 1)
    }

    func testExecuteHandlesNetworkError() async {
        mockTransport.error = URLError(.notConnectedToInternet)

        let builder = RequestBuilder(
            url: "https://api.example.com/test",
            method: .get,
            headers: [:],
            body: nil
        )

        do {
            _ = try await executor.execute(builder)
            XCTFail("Should have thrown an error")
        } catch {
            // Expected error
            XCTAssertNotNil(error)
        }
    }

    func testExecuteRetriesOnceForLocalNetworkPermissionLikeError() async throws {
        var attempts = 0

        mockTransport.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                throw URLError(.notConnectedToInternet)
            }
            return try self.makeTransportResponse(url: request.url, statusCode: 200, body: Data())
        }

        let builder = RequestBuilder(
            url: "http://192.168.1.88:8080/test",
            method: .get,
            headers: [:],
            body: nil
        )

        let response = try await executor.execute(builder)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(attempts, 2)
    }

    func testExecuteDoesNotRetryForPublicHostOfflineError() async {
        var attempts = 0
        mockTransport.requestHandler = { request in
            attempts += 1
            _ = request
            throw URLError(.notConnectedToInternet)
        }

        let builder = RequestBuilder(
            url: "https://api.example.com/test",
            method: .get,
            headers: [:],
            body: nil
        )

        do {
            _ = try await executor.execute(builder)
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    func testExecuteDoesNotRetryForPublicHostPermissionDeniedLikeError() async {
        var attempts = 0
        mockTransport.requestHandler = { request in
            attempts += 1
            _ = request
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
            )
        }

        let builder = RequestBuilder(
            url: "https://api.example.com/test",
            method: .get,
            headers: [:],
            body: nil
        )

        do {
            _ = try await executor.execute(builder)
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    func testExecuteCancellationDuringPermissionRetryDoesNotRunSecondAttempt() async {
        var attempts = 0
        let firstAttemptExpectation = expectation(description: "First attempt executed")

        mockTransport.requestHandler = { request in
            attempts += 1
            _ = request
            if attempts == 1 {
                firstAttemptExpectation.fulfill()
            }
            throw URLError(.notConnectedToInternet)
        }

        let builder = RequestBuilder(
            url: "http://192.168.1.88:8080/test",
            method: .get,
            headers: [:],
            body: nil
        )

        let task = Task {
            try await executor.execute(builder)
        }

        await fulfillment(of: [firstAttemptExpectation], timeout: 1.0)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation-related error")
        } catch let error as RequestExecutionError {
            switch error {
            case let .transport(underlying):
                XCTAssertTrue(underlying is CancellationError)
            default:
                XCTFail("Unexpected request execution error: \(error)")
            }
        } catch is CancellationError {
            // Accept direct cancellation as well.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 1)
    }

    func testExecuteHandles404() async throws {
        mockTransport.requestHandler = { request in
            try self.makeTransportResponse(
                url: request.url,
                statusCode: 404,
                body: Data("Not Found".utf8)
            )
        }

        let builder = RequestBuilder(
            url: "https://api.example.com/notfound",
            method: .get,
            headers: [:],
            body: nil
        )

        let response = try await executor.execute(builder)

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
        let getMethods: [TraceCore.HTTPMethod] = [.get, .post, .put, .delete, .patch, .head, .options]

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
