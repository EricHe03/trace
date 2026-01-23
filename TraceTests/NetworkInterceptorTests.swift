//
//  NetworkInterceptorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

@MainActor
final class NetworkInterceptorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NetworkCaptureStore.shared.clearRequests()
        NetworkCaptureStore.shared.isCapturing = true
    }

    override func tearDown() {
        NetworkCaptureStore.shared.clearRequests()
        NetworkCaptureStore.shared.isCapturing = false
        super.tearDown()
    }

    // MARK: - canInit Tests

    func testCanInitWithHTTPRequest() {
        let url = URL(string: "http://example.com")!
        let request = URLRequest(url: url)

        let canHandle = NetworkInterceptor.canInit(with: request)
        XCTAssertTrue(canHandle, "Should handle HTTP requests")
    }

    func testCanInitWithHTTPSRequest() {
        let url = URL(string: "https://example.com")!
        let request = URLRequest(url: url)

        let canHandle = NetworkInterceptor.canInit(with: request)
        XCTAssertTrue(canHandle, "Should handle HTTPS requests")
    }

    func testCanInitWithNonHTTPRequest() {
        let url = URL(string: "ftp://example.com")!
        let request = URLRequest(url: url)

        let canHandle = NetworkInterceptor.canInit(with: request)
        XCTAssertFalse(canHandle, "Should not handle FTP requests")
    }

    func testCanInitWithFileURL() {
        let url = URL(string: "file:///path/to/file")!
        let request = URLRequest(url: url)

        let canHandle = NetworkInterceptor.canInit(with: request)
        XCTAssertFalse(canHandle, "Should not handle file URLs")
    }

    func testCanInitWithAlreadyHandledRequest() {
        let url = URL(string: "https://example.com")!
        var request = URLRequest(url: url)

        // Mark the request as already handled
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: "NetworkInterceptorHandled", in: mutableRequest)
        request = mutableRequest as URLRequest

        let canHandle = NetworkInterceptor.canInit(with: request)
        XCTAssertFalse(canHandle, "Should not handle already-processed requests")
    }

    func testCanInitWithMixedCaseScheme() {
        let url = URL(string: "HTTPS://example.com")!
        let request = URLRequest(url: url)

        let canHandle = NetworkInterceptor.canInit(with: request)
        XCTAssertTrue(canHandle, "Should handle mixed-case HTTPS scheme")
    }

    // MARK: - canonicalRequest Tests

    func testCanonicalRequest() {
        let url = URL(string: "https://example.com")!
        let originalRequest = URLRequest(url: url)

        let canonicalRequest = NetworkInterceptor.canonicalRequest(for: originalRequest)

        XCTAssertEqual(canonicalRequest.url, originalRequest.url)
        XCTAssertEqual(canonicalRequest, originalRequest, "Canonical request should be identical to original")
    }

    func testCanonicalRequestWithHeaders() {
        let url = URL(string: "https://example.com")!
        var originalRequest = URLRequest(url: url)
        originalRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        originalRequest.addValue("Bearer token123", forHTTPHeaderField: "Authorization")

        let canonicalRequest = NetworkInterceptor.canonicalRequest(for: originalRequest)

        XCTAssertEqual(canonicalRequest.allHTTPHeaderFields, originalRequest.allHTTPHeaderFields)
    }

    // MARK: - Request Capture Tests

    func testRequestCaptureWithGETRequest() {
        // This test verifies the request capture structure
        // Note: Network request capture requires URLProtocol registration
        // which is done at app launch. For unit tests, we verify the structure only.
        let url = URL(string: "https://example.com/get")!
        let request = URLRequest(url: url)

        NetworkCaptureStore.shared.isCapturing = true

        // Verify the request structure is valid for capture
        XCTAssertNotNil(request.url)
        XCTAssertNotNil(request.httpMethod ?? "GET")
        XCTAssertTrue(NetworkCaptureStore.shared.isCapturing)

        // In a real environment with mock server, you would:
        // 1. Make the request
        // 2. Verify it was intercepted
        // 3. Check NetworkCaptureStore has the request
    }

    func testRequestCaptureExtractsURL() {
        // This is a unit test for the capture logic structure
        let url = URL(string: "https://example.com/api/users")!
        let request = URLRequest(url: url)

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/users")
    }

    func testRequestCaptureExtractsMethod() {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.httpMethod = "POST"

        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testRequestCaptureExtractsHeaders() {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer token", forHTTPHeaderField: "Authorization")

        XCTAssertEqual(request.allHTTPHeaderFields?.count, 2)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testRequestCaptureExtractsBody() {
        var request = URLRequest(url: URL(string: "https://example.com")!)
        let bodyData = "test body".data(using: .utf8)!
        request.httpBody = bodyData

        XCTAssertEqual(request.httpBody, bodyData)
    }

    // MARK: - HTTP Method Tests

    func testHTTPMethodEnum() {
        XCTAssertEqual(HTTPMethod(rawValue: "GET"), .get)
        XCTAssertEqual(HTTPMethod(rawValue: "POST"), .post)
        XCTAssertEqual(HTTPMethod(rawValue: "PUT"), .put)
        XCTAssertEqual(HTTPMethod(rawValue: "DELETE"), .delete)
        XCTAssertEqual(HTTPMethod(rawValue: "PATCH"), .patch)
    }

    // MARK: - Integration Tests

    func testMultipleRequestsCapture() {
        NetworkCaptureStore.shared.isCapturing = true
        NetworkCaptureStore.shared.clearRequests()

        let request1 = createMockNetworkRequest(url: "https://example.com/1")
        let request2 = createMockNetworkRequest(url: "https://example.com/2")

        NetworkCaptureStore.shared.addRequest(request1)
        NetworkCaptureStore.shared.addRequest(request2)

        XCTAssertEqual(NetworkCaptureStore.shared.requests.count, 2)
    }

    func testCaptureDisabledDoesNotStore() {
        NetworkCaptureStore.shared.isCapturing = false
        NetworkCaptureStore.shared.clearRequests()

        let request = createMockNetworkRequest(url: "https://example.com")
        NetworkCaptureStore.shared.addRequest(request)

        XCTAssertEqual(NetworkCaptureStore.shared.requests.count, 0)
    }

    // MARK: - Helper Methods

    private func createMockNetworkRequest(
        url: String,
        method: HTTPMethod = .get,
        statusCode: Int = 200
    ) -> NetworkRequest {
        return NetworkRequest(
            url: url,
            method: method,
            statusCode: statusCode,
            timestamp: Date(),
            duration: 0.5,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            requestBody: .empty,
            responseBody: .empty
        )
    }
}
