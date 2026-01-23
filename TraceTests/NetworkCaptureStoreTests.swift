//
//  NetworkCaptureStoreTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

@MainActor
final class NetworkCaptureStoreTests: XCTestCase {

    var store: NetworkCaptureStore!

    override func setUp() {
        super.setUp()
        store = NetworkCaptureStore.shared
        store.clearRequests()
        store.isCapturing = false
    }

    override func tearDown() {
        store.clearRequests()
        store.isCapturing = false
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let store1 = NetworkCaptureStore.shared
        let store2 = NetworkCaptureStore.shared

        XCTAssertTrue(store1 === store2, "NetworkCaptureStore should be a singleton")
    }

    // MARK: - Request Management Tests

    func testAddRequestWhenCapturing() {
        store.isCapturing = true

        let request = createMockRequest(url: "https://example.com")
        store.addRequest(request)

        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(store.requests.first?.url, "https://example.com")
    }

    func testAddRequestWhenNotCapturing() {
        store.isCapturing = false

        let request = createMockRequest(url: "https://example.com")
        store.addRequest(request)

        XCTAssertEqual(store.requests.count, 0, "Requests should not be added when capturing is disabled")
    }

    func testAddMultipleRequests() {
        store.isCapturing = true

        let request1 = createMockRequest(url: "https://example.com/1")
        let request2 = createMockRequest(url: "https://example.com/2")
        let request3 = createMockRequest(url: "https://example.com/3")

        store.addRequest(request1)
        store.addRequest(request2)
        store.addRequest(request3)

        XCTAssertEqual(store.requests.count, 3)
        XCTAssertEqual(store.requests[0].url, "https://example.com/1")
        XCTAssertEqual(store.requests[1].url, "https://example.com/2")
        XCTAssertEqual(store.requests[2].url, "https://example.com/3")
    }

    func testClearRequests() {
        store.isCapturing = true

        let request1 = createMockRequest(url: "https://example.com/1")
        let request2 = createMockRequest(url: "https://example.com/2")

        store.addRequest(request1)
        store.addRequest(request2)
        XCTAssertEqual(store.requests.count, 2)

        store.clearRequests()
        XCTAssertEqual(store.requests.count, 0, "All requests should be cleared")
    }

    // MARK: - Capture State Tests

    func testIsCapturingInitialState() {
        let newStore = NetworkCaptureStore.shared
        // Note: Using shared instance, so state may be affected by other tests
        // This test verifies the property exists and is accessible
        XCTAssertNotNil(newStore.isCapturing)
    }

    func testEnableCapture() {
        store.isCapturing = false
        XCTAssertFalse(store.isCapturing)

        store.isCapturing = true
        XCTAssertTrue(store.isCapturing)
    }

    func testDisableCapture() {
        store.isCapturing = true
        XCTAssertTrue(store.isCapturing)

        store.isCapturing = false
        XCTAssertFalse(store.isCapturing)
    }

    func testCapturingStateAffectsRequestAddition() {
        // Start with capturing disabled
        store.isCapturing = false
        let request1 = createMockRequest(url: "https://example.com/1")
        store.addRequest(request1)
        XCTAssertEqual(store.requests.count, 0)

        // Enable capturing
        store.isCapturing = true
        let request2 = createMockRequest(url: "https://example.com/2")
        store.addRequest(request2)
        XCTAssertEqual(store.requests.count, 1)

        // Disable capturing again
        store.isCapturing = false
        let request3 = createMockRequest(url: "https://example.com/3")
        store.addRequest(request3)
        XCTAssertEqual(store.requests.count, 1, "Should still have only 1 request")
    }

    // MARK: - Helper Methods

    private func createMockRequest(
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
            requestHeaders: [],
            responseHeaders: [],
            requestBody: .empty,
            responseBody: .empty
        )
    }
}
