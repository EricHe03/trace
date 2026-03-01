//
//  WidgetDataManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class WidgetDataManagerTests: XCTestCase {
    var sut: WidgetDataManager!

    private final class WidgetStateAdapter {
        private let storage: AppGroupStorage

        init(storage: AppGroupStorage = .shared) {
            self.storage = storage
        }

        func bool(forKey key: String) -> Bool {
            let state = storage.loadWidgetState()
            switch key {
            case "widget.isCapturing":
                return state.isCapturing
            default:
                return false
            }
        }

        func integer(forKey key: String) -> Int {
            let state = storage.loadWidgetState()
            switch key {
            case "widget.requestCount":
                return state.requestCount
            default:
                return 0
            }
        }

        func string(forKey key: String) -> String? {
            let state = storage.loadWidgetState()
            switch key {
            case "widget.dataTransferred":
                return state.dataTransferred
            default:
                return nil
            }
        }

        func data(forKey key: String) -> Data? {
            guard key == "widget.recentRequests" else { return nil }
            return try? JSONEncoder().encode(storage.loadWidgetState().recentRequests)
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        sut = WidgetDataManager.shared

        // Clear any existing widget data
        clearWidgetData()
    }

    override func tearDown() async throws {
        clearWidgetData()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func clearWidgetData() {
        try? AppGroupStorage.shared.saveWidgetState(WidgetSharedState())
    }

    private func getWidgetDefaults() -> WidgetStateAdapter? {
        WidgetStateAdapter()
    }

    // MARK: - Singleton Pattern Tests

    func testSingletonPattern_ReturnsSameInstance() {
        // Given
        let instance1 = WidgetDataManager.shared
        let instance2 = WidgetDataManager.shared

        // Then
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Widget Data Update Tests

    func testUpdateWidgetData_IsCapturingTrue_UpdatesDefaults() {
        // Given
        let recentRequests: [WidgetRecentRequest] = []

        // When
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: 0,
            dataTransferred: "0 B",
            recentRequests: recentRequests
        )

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertNotNil(defaults)
        XCTAssertEqual(defaults?.bool(forKey: "widget.isCapturing"), true)
    }

    func testUpdateWidgetData_IsCapturingFalse_UpdatesDefaults() {
        // Given
        let recentRequests: [WidgetRecentRequest] = []

        // When
        sut.updateWidgetData(
            isCapturing: false,
            requestCount: 10,
            dataTransferred: "1.5 MB",
            recentRequests: recentRequests
        )

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertNotNil(defaults)
        XCTAssertEqual(defaults?.bool(forKey: "widget.isCapturing"), false)
    }

    func testUpdateWidgetData_RequestCount_UpdatesDefaults() {
        // Given
        let recentRequests: [WidgetRecentRequest] = []
        let requestCount = 42

        // When
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: requestCount,
            dataTransferred: "1.5 MB",
            recentRequests: recentRequests
        )

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertNotNil(defaults)
        XCTAssertEqual(defaults?.integer(forKey: "widget.requestCount"), requestCount)
    }

    func testUpdateWidgetData_DataTransferred_UpdatesDefaults() {
        // Given
        let recentRequests: [WidgetRecentRequest] = []
        let dataTransferred = "2.3 MB"

        // When
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: 10,
            dataTransferred: dataTransferred,
            recentRequests: recentRequests
        )

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertNotNil(defaults)
        XCTAssertEqual(defaults?.string(forKey: "widget.dataTransferred"), dataTransferred)
    }

    func testUpdateWidgetData_RecentRequests_EncodesCorrectly() {
        // Given
        let networkRequest = makeNetworkRequest(
            url: "https://api.example.com/test",
            method: .get,
            statusCode: 200
        )
        let widgetRequest = WidgetRecentRequest(from: networkRequest)
        let recentRequests = [widgetRequest]

        // When
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: 1,
            dataTransferred: "1 KB",
            recentRequests: recentRequests
        )

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertNotNil(defaults)

        if let data = defaults?.data(forKey: "widget.recentRequests"),
           let decoded = try? JSONDecoder().decode([WidgetRecentRequest].self, from: data)
        {
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0].method, "GET")
            XCTAssertEqual(decoded[0].url, "https://api.example.com/test")
            XCTAssertEqual(decoded[0].statusCode, 200)
        } else {
            XCTFail("Failed to decode recent requests")
        }
    }

    func testUpdateWidgetData_MultipleRecentRequests_EncodesAll() {
        // Given
        let request1 = makeNetworkRequest(url: "https://example.com/1", method: .get, statusCode: 200)
        let request2 = makeNetworkRequest(url: "https://example.com/2", method: .post, statusCode: 201)
        let request3 = makeNetworkRequest(url: "https://example.com/3", method: .put, statusCode: 204)

        let recentRequests = [
            WidgetRecentRequest(from: request1),
            WidgetRecentRequest(from: request2),
            WidgetRecentRequest(from: request3)
        ]

        // When
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: 3,
            dataTransferred: "5 KB",
            recentRequests: recentRequests
        )

        // Then
        let defaults = getWidgetDefaults()
        if let data = defaults?.data(forKey: "widget.recentRequests"),
           let decoded = try? JSONDecoder().decode([WidgetRecentRequest].self, from: data)
        {
            XCTAssertEqual(decoded.count, 3)
            XCTAssertEqual(decoded[0].method, "GET")
            XCTAssertEqual(decoded[1].method, "POST")
            XCTAssertEqual(decoded[2].method, "PUT")
        } else {
            XCTFail("Failed to decode recent requests")
        }
    }

    // MARK: - Capture State Change Tests

    func testNotifyCaptureStateChanged_WhenStarting_UpdatesDefaults() {
        // When
        sut.notifyCaptureStateChanged(isCapturing: true)

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.bool(forKey: "widget.isCapturing"), true)
    }

    func testNotifyCaptureStateChanged_WhenStopping_UpdatesDefaults() {
        // When
        sut.notifyCaptureStateChanged(isCapturing: false)

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.bool(forKey: "widget.isCapturing"), false)
    }

    func testNotifyCaptureStateChanged_MultipleStateChanges_UpdatesCorrectly() {
        // When - Start capturing
        sut.notifyCaptureStateChanged(isCapturing: true)

        // Then
        var defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.bool(forKey: "widget.isCapturing"), true)

        // When - Stop capturing
        sut.notifyCaptureStateChanged(isCapturing: false)

        // Then
        defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.bool(forKey: "widget.isCapturing"), false)

        // When - Start again
        sut.notifyCaptureStateChanged(isCapturing: true)

        // Then
        defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.bool(forKey: "widget.isCapturing"), true)
    }

    // MARK: - Request Count Update Tests

    func testUpdateRequestCount_UpdatesDefaults() {
        // Given
        let requestCount = 25

        // When
        sut.updateRequestCount(requestCount)

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.integer(forKey: "widget.requestCount"), requestCount)
    }

    func testUpdateRequestCount_Zero_UpdatesDefaults() {
        // When
        sut.updateRequestCount(0)

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.integer(forKey: "widget.requestCount"), 0)
    }

    func testUpdateRequestCount_LargeNumber_UpdatesDefaults() {
        // Given
        let largeCount = 999_999

        // When
        sut.updateRequestCount(largeCount)

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.integer(forKey: "widget.requestCount"), largeCount)
    }

    func testUpdateRequestCount_MultipleUpdates_OverwritesPrevious() {
        // When
        sut.updateRequestCount(10)
        sut.updateRequestCount(20)
        sut.updateRequestCount(30)

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.integer(forKey: "widget.requestCount"), 30)
    }

    // MARK: - WidgetRecentRequest Tests

    func testWidgetRecentRequest_FromNetworkRequest_CopiesAllProperties() {
        // Given
        let networkRequest = makeNetworkRequest(
            id: UUID(),
            url: "https://api.example.com/users/123",
            method: .post,
            statusCode: 201,
            timestamp: Date()
        )

        // When
        let widgetRequest = WidgetRecentRequest(from: networkRequest)

        // Then
        XCTAssertEqual(widgetRequest.id, networkRequest.id)
        XCTAssertEqual(widgetRequest.method, networkRequest.method.rawValue)
        XCTAssertEqual(widgetRequest.url, networkRequest.url)
        XCTAssertEqual(widgetRequest.statusCode, networkRequest.statusCode)
        XCTAssertEqual(widgetRequest.timestamp, networkRequest.timestamp)
    }

    func testWidgetRecentRequest_Codable_EncodesAndDecodes() {
        // Given
        let networkRequest = makeNetworkRequest(
            url: "https://example.com/test",
            method: .get,
            statusCode: 200
        )
        let widgetRequest = WidgetRecentRequest(from: networkRequest)

        // When
        let encoded = try? JSONEncoder().encode(widgetRequest)
        XCTAssertNotNil(encoded)

        let decoded = try? JSONDecoder().decode(WidgetRecentRequest.self, from: encoded!)

        // Then
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.id, widgetRequest.id)
        XCTAssertEqual(decoded?.method, widgetRequest.method)
        XCTAssertEqual(decoded?.url, widgetRequest.url)
        XCTAssertEqual(decoded?.statusCode, widgetRequest.statusCode)
    }

    func testWidgetRecentRequest_WithNilStatusCode_EncodesCorrectly() {
        // Given
        let networkRequest = makeNetworkRequest(
            url: "https://example.com/pending",
            method: .get,
            statusCode: nil
        )
        let widgetRequest = WidgetRecentRequest(from: networkRequest)

        // When
        let encoded = try? JSONEncoder().encode(widgetRequest)
        let decoded = try? JSONDecoder().decode(WidgetRecentRequest.self, from: encoded!)

        // Then
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.statusCode)
    }

    func testWidgetRecentRequest_DifferentHTTPMethods_AllSupported() {
        // Given
        let methods: [HTTPMethod] = [.get, .post, .put, .delete, .patch, .head, .options]

        for method in methods {
            // When
            let networkRequest = makeNetworkRequest(url: "https://example.com/test", method: method)
            let widgetRequest = WidgetRecentRequest(from: networkRequest)

            // Then
            XCTAssertEqual(widgetRequest.method, method.rawValue)
        }
    }

    // MARK: - TraceWidgetAttributes Tests

    @available(iOS 16.1, *)
    func testTraceWidgetAttributes_ContentState_InitializesCorrectly() {
        // Given
        let requestCount = 10
        let dataTransferred = "1.5 MB"
        let captureStartTime = Date()
        let lastRequestTime = Date()
        let lastRequestMethod = "GET"
        let lastRequestHost = "example.com"
        let lastRequestStatus = 200

        // When
        let contentState = TraceWidgetAttributes.ContentState(
            requestCount: requestCount,
            dataTransferred: dataTransferred,
            captureStartTime: captureStartTime,
            lastRequestTime: lastRequestTime,
            lastRequestMethod: lastRequestMethod,
            lastRequestHost: lastRequestHost,
            lastRequestStatus: lastRequestStatus
        )

        // Then
        XCTAssertEqual(contentState.requestCount, requestCount)
        XCTAssertEqual(contentState.dataTransferred, dataTransferred)
        XCTAssertEqual(contentState.captureStartTime, captureStartTime)
        XCTAssertEqual(contentState.lastRequestTime, lastRequestTime)
        XCTAssertEqual(contentState.lastRequestMethod, lastRequestMethod)
        XCTAssertEqual(contentState.lastRequestHost, lastRequestHost)
        XCTAssertEqual(contentState.lastRequestStatus, lastRequestStatus)
    }

    @available(iOS 16.1, *)
    func testTraceWidgetAttributes_ContentState_WithNilOptionals_InitializesCorrectly() {
        // Given
        let captureStartTime = Date()

        // When
        let contentState = TraceWidgetAttributes.ContentState(
            requestCount: 0,
            dataTransferred: "0 B",
            captureStartTime: captureStartTime,
            lastRequestTime: nil,
            lastRequestMethod: nil,
            lastRequestHost: nil,
            lastRequestStatus: nil
        )

        // Then
        XCTAssertEqual(contentState.requestCount, 0)
        XCTAssertNil(contentState.lastRequestTime)
        XCTAssertNil(contentState.lastRequestMethod)
        XCTAssertNil(contentState.lastRequestHost)
        XCTAssertNil(contentState.lastRequestStatus)
    }

    @available(iOS 16.1, *)
    func testTraceWidgetAttributes_InitializesWithSessionId() {
        // Given
        let sessionId = UUID()

        // When
        let attributes = TraceWidgetAttributes(sessionId: sessionId)

        // Then
        XCTAssertEqual(attributes.sessionId, sessionId)
    }

    // MARK: - Data Format Tests

    func testUpdateWidgetData_DataTransferredFormats_AllAccepted() {
        // Given
        let formats = ["0 B", "1.5 KB", "2.3 MB", "5.7 GB"]

        for format in formats {
            // When
            sut.updateWidgetData(
                isCapturing: true,
                requestCount: 1,
                dataTransferred: format,
                recentRequests: []
            )

            // Then
            let defaults = getWidgetDefaults()
            XCTAssertEqual(defaults?.string(forKey: "widget.dataTransferred"), format)
        }
    }

    // MARK: - Edge Cases

    func testUpdateWidgetData_EmptyRecentRequests_UpdatesCorrectly() {
        // Given
        let emptyRequests: [WidgetRecentRequest] = []

        // When
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: 0,
            dataTransferred: "0 B",
            recentRequests: emptyRequests
        )

        // Then
        let defaults = getWidgetDefaults()
        if let data = defaults?.data(forKey: "widget.recentRequests"),
           let decoded = try? JSONDecoder().decode([WidgetRecentRequest].self, from: data)
        {
            XCTAssertEqual(decoded.count, 0)
        } else {
            XCTFail("Failed to decode empty recent requests")
        }
    }

    func testUpdateWidgetData_ConsecutiveUpdates_OverwritesPrevious() {
        // Given
        let request1 = makeNetworkRequest(url: "https://example.com/1", method: .get)
        let request2 = makeNetworkRequest(url: "https://example.com/2", method: .post)

        // When - First update
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: 1,
            dataTransferred: "1 KB",
            recentRequests: [WidgetRecentRequest(from: request1)]
        )

        // Second update
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: 2,
            dataTransferred: "2 KB",
            recentRequests: [WidgetRecentRequest(from: request2)]
        )

        // Then - Should have data from second update
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.integer(forKey: "widget.requestCount"), 2)
        XCTAssertEqual(defaults?.string(forKey: "widget.dataTransferred"), "2 KB")

        if let data = defaults?.data(forKey: "widget.recentRequests"),
           let decoded = try? JSONDecoder().decode([WidgetRecentRequest].self, from: data)
        {
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0].url, "https://example.com/2")
        }
    }

    func testUpdateWidgetData_VeryLargeRequestCount_HandlesCorrectly() {
        // Given
        let largeCount = Int.max - 1

        // When
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: largeCount,
            dataTransferred: "999 GB",
            recentRequests: []
        )

        // Then
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.integer(forKey: "widget.requestCount"), largeCount)
    }

    func testWidgetRecentRequest_LongURL_HandlesCorrectly() {
        // Given
        let longURL = "https://example.com/api/" + String(repeating: "path/", count: 100) + "endpoint"
        let networkRequest = makeNetworkRequest(url: longURL, method: .get)

        // When
        let widgetRequest = WidgetRecentRequest(from: networkRequest)

        // Then
        XCTAssertEqual(widgetRequest.url, longURL)

        // Verify it can be encoded/decoded
        let encoded = try? JSONEncoder().encode(widgetRequest)
        XCTAssertNotNil(encoded)

        let decoded = try? JSONDecoder().decode(WidgetRecentRequest.self, from: encoded!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.url, longURL)
    }

    func testWidgetRecentRequest_SpecialCharactersInURL_HandlesCorrectly() {
        // Given
        let specialURL = "https://example.com/search?q=hello%20world&filter=name%3Dvalue"
        let networkRequest = makeNetworkRequest(url: specialURL, method: .get)

        // When
        let widgetRequest = WidgetRecentRequest(from: networkRequest)

        // Then
        XCTAssertEqual(widgetRequest.url, specialURL)
    }

    // MARK: - Integration Tests

    func testUpdateWidgetData_FullWorkflow_UpdatesAllFields() {
        // Given
        let request1 = makeNetworkRequest(url: "https://api.example.com/users", method: .get, statusCode: 200)
        let request2 = makeNetworkRequest(url: "https://api.example.com/posts", method: .post, statusCode: 201)
        let recentRequests = [
            WidgetRecentRequest(from: request1),
            WidgetRecentRequest(from: request2)
        ]

        // When
        sut.updateWidgetData(
            isCapturing: true,
            requestCount: 2,
            dataTransferred: "5.2 KB",
            recentRequests: recentRequests
        )

        // Then - Verify all fields are updated
        let defaults = getWidgetDefaults()
        XCTAssertEqual(defaults?.bool(forKey: "widget.isCapturing"), true)
        XCTAssertEqual(defaults?.integer(forKey: "widget.requestCount"), 2)
        XCTAssertEqual(defaults?.string(forKey: "widget.dataTransferred"), "5.2 KB")

        if let data = defaults?.data(forKey: "widget.recentRequests"),
           let decoded = try? JSONDecoder().decode([WidgetRecentRequest].self, from: data)
        {
            XCTAssertEqual(decoded.count, 2)
            XCTAssertEqual(decoded[0].method, "GET")
            XCTAssertEqual(decoded[0].statusCode, 200)
            XCTAssertEqual(decoded[1].method, "POST")
            XCTAssertEqual(decoded[1].statusCode, 201)
        } else {
            XCTFail("Failed to decode recent requests")
        }
    }
}
