//
//  TraceWidgetTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
import WidgetKit
@testable import TraceWidget
@testable import TraceCore

final class TraceWidgetTests: XCTestCase {
    var userDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()

        // Set up test user defaults
        let suiteName = AppGroupConfiguration.appGroupIdentifier
        userDefaults = UserDefaults(suiteName: suiteName)

        // Clear any existing widget data
        clearWidgetData()
    }

    override func tearDown() async throws {
        clearWidgetData()
        userDefaults = nil
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func clearWidgetData() {
        userDefaults?.removeObject(forKey: "widget.isCapturing")
        userDefaults?.removeObject(forKey: "widget.requestCount")
        userDefaults?.removeObject(forKey: "widget.dataTransferred")
        userDefaults?.removeObject(forKey: "widget.recentRequests")
    }

    private func setWidgetData(
        isCapturing: Bool,
        requestCount: Int,
        dataTransferred: String,
        recentRequests: [WidgetRecentRequest] = []
    ) {
        userDefaults?.set(isCapturing, forKey: "widget.isCapturing")
        userDefaults?.set(requestCount, forKey: "widget.requestCount")
        userDefaults?.set(dataTransferred, forKey: "widget.dataTransferred")

        if let encoded = try? JSONEncoder().encode(recentRequests) {
            userDefaults?.set(encoded, forKey: "widget.recentRequests")
        }
    }

    // MARK: - WidgetData Tests

    func testWidgetData_Placeholder_HasCorrectDefaults() {
        // When
        let placeholder = WidgetData.placeholder

        // Then
        XCTAssertEqual(placeholder.isCapturing, false)
        XCTAssertEqual(placeholder.requestCount, 88)
        XCTAssertEqual(placeholder.dataTransferred, "1.2 MB")
        XCTAssertEqual(placeholder.recentRequests.count, 2)

        // Verify first request
        let firstRequest = placeholder.recentRequests[0]
        XCTAssertEqual(firstRequest.method, "GET")
        XCTAssertEqual(firstRequest.host, "api.example.com")
        XCTAssertEqual(firstRequest.path, "/users")
        XCTAssertEqual(firstRequest.statusCode, 200)

        // Verify second request
        let secondRequest = placeholder.recentRequests[1]
        XCTAssertEqual(secondRequest.method, "POST")
        XCTAssertEqual(secondRequest.host, "api.example.com")
        XCTAssertEqual(secondRequest.path, "/data")
        XCTAssertEqual(secondRequest.statusCode, 201)
    }

    // MARK: - WidgetRequest Tests

    func testWidgetRequest_StatusColor_2xx_ReturnsGreen() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "example.com",
            path: "/",
            statusCode: 200,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.statusColor, .green)
    }

    func testWidgetRequest_StatusColor_3xx_ReturnsBlue() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "example.com",
            path: "/",
            statusCode: 304,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.statusColor, .blue)
    }

    func testWidgetRequest_StatusColor_4xx_ReturnsOrange() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "example.com",
            path: "/",
            statusCode: 404,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.statusColor, .orange)
    }

    func testWidgetRequest_StatusColor_5xx_ReturnsRed() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "example.com",
            path: "/",
            statusCode: 500,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.statusColor, .red)
    }

    func testWidgetRequest_StatusColor_Nil_ReturnsGray() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "example.com",
            path: "/",
            statusCode: nil,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.statusColor, .gray)
    }

    func testWidgetRequest_StatusColor_OutOfRange_ReturnsGray() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "example.com",
            path: "/",
            statusCode: 100,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.statusColor, .gray)
    }

    func testWidgetRequest_MethodColor_GET_ReturnsGreen() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "example.com",
            path: "/",
            statusCode: 200,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.methodColor, .green)
    }

    func testWidgetRequest_MethodColor_POST_ReturnsBlue() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "POST",
            host: "example.com",
            path: "/",
            statusCode: 201,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.methodColor, .blue)
    }

    func testWidgetRequest_MethodColor_PUT_ReturnsYellow() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "PUT",
            host: "example.com",
            path: "/",
            statusCode: 200,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.methodColor, .yellow)
    }

    func testWidgetRequest_MethodColor_DELETE_ReturnsRed() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "DELETE",
            host: "example.com",
            path: "/",
            statusCode: 204,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.methodColor, .red)
    }

    func testWidgetRequest_MethodColor_PATCH_ReturnsOrange() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "PATCH",
            host: "example.com",
            path: "/",
            statusCode: 200,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.methodColor, .orange)
    }

    func testWidgetRequest_MethodColor_Unknown_ReturnsGray() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "OPTIONS",
            host: "example.com",
            path: "/",
            statusCode: 200,
            timestamp: Date()
        )

        // Then
        XCTAssertEqual(request.methodColor, .gray)
    }

    func testWidgetRequest_Codable_EncodesAndDecodes() {
        // Given
        let originalRequest = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "api.example.com",
            path: "/users/123",
            statusCode: 200,
            timestamp: Date()
        )

        // When
        let encoded = try? JSONEncoder().encode(originalRequest)
        XCTAssertNotNil(encoded)

        let decoded = try? JSONDecoder().decode(WidgetRequest.self, from: encoded!)

        // Then
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.id, originalRequest.id)
        XCTAssertEqual(decoded?.method, originalRequest.method)
        XCTAssertEqual(decoded?.host, originalRequest.host)
        XCTAssertEqual(decoded?.path, originalRequest.path)
        XCTAssertEqual(decoded?.statusCode, originalRequest.statusCode)
    }

    // MARK: - ConfigurationAppIntent Tests

    @available(iOS 16.0, *)
    func testConfigurationAppIntent_DefaultValues_AreCorrect() {
        // When
        let config = ConfigurationAppIntent()

        // Then
        XCTAssertEqual(config.showRequestDetails, true)
        XCTAssertEqual(config.showDataTransfer, true)
        XCTAssertEqual(config.maxRequestsToShow, 5)
    }

    @available(iOS 16.0, *)
    func testConfigurationAppIntent_Perform_ReturnsResult() async throws {
        // Given
        let config = ConfigurationAppIntent()

        // When
        let result = try await config.perform()

        // Then - Should not throw and return a result
        XCTAssertNotNil(result)
    }

    // MARK: - Widget Action Recording Tests

    func testRecordWidgetAction_StartCapture_WritesToDefaults() {
        // When
        recordWidgetAction(.startCapture)

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.startCapture.rawValue)

        let actionDate = userDefaults?.object(forKey: WidgetActionKey.actionDate) as? Date
        XCTAssertNotNil(actionDate)
    }

    func testRecordWidgetAction_StopCapture_WritesToDefaults() {
        // When
        recordWidgetAction(.stopCapture)

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.stopCapture.rawValue)
    }

    func testRecordWidgetAction_ToggleCapture_WritesToDefaults() {
        // When
        recordWidgetAction(.toggleCapture)

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.toggleCapture.rawValue)
    }

    func testRecordWidgetAction_ClearRequests_WritesToDefaults() {
        // When
        recordWidgetAction(.clearRequests)

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.clearRequests.rawValue)
    }

    @available(iOS 16.0, *)
    func testRecordWidgetAction_OpenView_WritesViewToDefaults() {
        // When
        recordWidgetAction(.openView, view: .capture)

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.openView.rawValue)

        let view = userDefaults?.string(forKey: WidgetActionKey.actionView)
        XCTAssertEqual(view, TraceAppView.capture.rawValue)
    }

    @available(iOS 16.0, *)
    func testRecordWidgetAction_WithoutView_RemovesViewFromDefaults() {
        // Given - Set a view first
        userDefaults?.set(TraceAppView.capture.rawValue, forKey: WidgetActionKey.actionView)

        // When - Record action without view
        recordWidgetAction(.startCapture)

        // Then
        let view = userDefaults?.string(forKey: WidgetActionKey.actionView)
        XCTAssertNil(view)
    }

    // MARK: - TraceAppView Tests

    @available(iOS 16.0, *)
    func testTraceAppView_AllCases_HaveDisplayRepresentation() {
        // Given
        let views: [TraceAppView] = [.capture, .favorites, .settings, .tools]

        for view in views {
            // When
            let representation = TraceAppView.caseDisplayRepresentations[view]

            // Then
            XCTAssertNotNil(representation)
        }
    }

    @available(iOS 16.0, *)
    func testTraceAppView_RawValues_AreCorrect() {
        // Then
        XCTAssertEqual(TraceAppView.capture.rawValue, "capture")
        XCTAssertEqual(TraceAppView.favorites.rawValue, "favorites")
        XCTAssertEqual(TraceAppView.settings.rawValue, "settings")
        XCTAssertEqual(TraceAppView.tools.rawValue, "tools")
    }

    // MARK: - App Intent Tests

    @available(iOS 16.0, *)
    @MainActor
    func testStartCaptureIntent_Perform_RecordsAction() async throws {
        // Given
        let intent = StartCaptureIntent()

        // When
        _ = try await intent.perform()

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.startCapture.rawValue)
    }

    @available(iOS 16.0, *)
    @MainActor
    func testStopCaptureIntent_Perform_RecordsAction() async throws {
        // Given
        let intent = StopCaptureIntent()

        // When
        _ = try await intent.perform()

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.stopCapture.rawValue)
    }

    @available(iOS 16.0, *)
    @MainActor
    func testClearRequestsIntent_Perform_RecordsAction() async throws {
        // Given
        let intent = ClearRequestsIntent()

        // When
        _ = try await intent.perform()

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.clearRequests.rawValue)
    }

    @available(iOS 16.0, *)
    @MainActor
    func testOpenTraceAppIntent_Perform_RecordsAction() async throws {
        // Given
        let intent = OpenTraceAppIntent()
        intent.targetView = .settings

        // When
        _ = try await intent.perform()

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.openView.rawValue)

        let view = userDefaults?.string(forKey: WidgetActionKey.actionView)
        XCTAssertEqual(view, TraceAppView.settings.rawValue)
    }

    @available(iOS 18.0, *)
    @MainActor
    func testToggleCaptureIntent_Perform_RecordsAction() async throws {
        // Given
        let intent = ToggleCaptureIntent()

        // When
        _ = try await intent.perform()

        // Then
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.toggleCapture.rawValue)
    }

    // MARK: - Intent Metadata Tests

    @available(iOS 16.0, *)
    func testStartCaptureIntent_Metadata_IsCorrect() {
        // Then
        XCTAssertEqual(StartCaptureIntent.title, "Start Network Capture")
        XCTAssertEqual(StartCaptureIntent.openAppWhenRun, true)
    }

    @available(iOS 16.0, *)
    func testStopCaptureIntent_Metadata_IsCorrect() {
        // Then
        XCTAssertEqual(StopCaptureIntent.title, "Stop Network Capture")
        XCTAssertEqual(StopCaptureIntent.openAppWhenRun, true)
    }

    @available(iOS 16.0, *)
    func testClearRequestsIntent_Metadata_IsCorrect() {
        // Then
        XCTAssertEqual(ClearRequestsIntent.title, "Clear Requests")
        XCTAssertEqual(ClearRequestsIntent.openAppWhenRun, true)
    }

    @available(iOS 16.0, *)
    func testOpenTraceAppIntent_Metadata_IsCorrect() {
        // Then
        XCTAssertEqual(OpenTraceAppIntent.title, "Open Trace")
        XCTAssertEqual(OpenTraceAppIntent.openAppWhenRun, true)
    }

    @available(iOS 18.0, *)
    func testToggleCaptureIntent_Metadata_IsCorrect() {
        // Then
        XCTAssertEqual(ToggleCaptureIntent.title, "Toggle Network Capture")
        XCTAssertEqual(ToggleCaptureIntent.openAppWhenRun, true)
    }

    // MARK: - Widget Configuration Tests

    func testTraceWidget_Kind_IsCorrect() {
        // Given
        let widget = TraceWidget()

        // Then
        XCTAssertEqual(widget.kind, "TraceWidget")
    }

    // MARK: - Edge Cases

    func testWidgetRequest_WithSpecialCharactersInHost_HandlesCorrectly() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "api-v2.example-site.com",
            path: "/users/123",
            statusCode: 200,
            timestamp: Date()
        )

        // When
        let encoded = try? JSONEncoder().encode(request)
        let decoded = try? JSONDecoder().decode(WidgetRequest.self, from: encoded!)

        // Then
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.host, "api-v2.example-site.com")
    }

    func testWidgetRequest_WithComplexPath_HandlesCorrectly() {
        // Given
        let complexPath = "/api/v2/users/123/posts/456/comments?filter=recent&limit=10"
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "example.com",
            path: complexPath,
            statusCode: 200,
            timestamp: Date()
        )

        // When
        let encoded = try? JSONEncoder().encode(request)
        let decoded = try? JSONDecoder().decode(WidgetRequest.self, from: encoded!)

        // Then
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.path, complexPath)
    }

    func testWidgetRequest_WithUnicodeInHost_HandlesCorrectly() {
        // Given
        let request = WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "例え.jp",
            path: "/",
            statusCode: 200,
            timestamp: Date()
        )

        // When
        let encoded = try? JSONEncoder().encode(request)
        let decoded = try? JSONDecoder().decode(WidgetRequest.self, from: encoded!)

        // Then
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.host, "例え.jp")
    }

    func testWidgetRequest_AllStatusCodeRanges_MapToCorrectColors() {
        // Given
        let testCases: [(Int?, Color)] = [
            (nil, .gray),
            (100, .gray),
            (199, .gray),
            (200, .green),
            (201, .green),
            (299, .green),
            (300, .blue),
            (304, .blue),
            (399, .blue),
            (400, .orange),
            (404, .orange),
            (499, .orange),
            (500, .red),
            (503, .red),
            (599, .red),
            (600, .gray)
        ]

        for (statusCode, expectedColor) in testCases {
            // When
            let request = WidgetRequest(
                id: UUID(),
                method: "GET",
                host: "example.com",
                path: "/",
                statusCode: statusCode,
                timestamp: Date()
            )

            // Then
            XCTAssertEqual(
                request.statusColor,
                expectedColor,
                "Status code \(statusCode?.description ?? "nil") should map to \(expectedColor)"
            )
        }
    }

    func testWidgetRequest_AllHTTPMethods_MapToCorrectColors() {
        // Given
        let testCases: [(String, Color)] = [
            ("GET", .green),
            ("POST", .blue),
            ("PUT", .yellow),
            ("DELETE", .red),
            ("PATCH", .orange),
            ("HEAD", .gray),
            ("OPTIONS", .gray),
            ("TRACE", .gray),
            ("CONNECT", .gray)
        ]

        for (method, expectedColor) in testCases {
            // When
            let request = WidgetRequest(
                id: UUID(),
                method: method,
                host: "example.com",
                path: "/",
                statusCode: 200,
                timestamp: Date()
            )

            // Then
            XCTAssertEqual(
                request.methodColor,
                expectedColor,
                "Method \(method) should map to \(expectedColor)"
            )
        }
    }

    // MARK: - Integration Tests

    @available(iOS 16.0, *)
    @MainActor
    func testWidgetWorkflow_StartCaptureToStopCapture_RecordsCorrectActions() async throws {
        // Given
        let startIntent = StartCaptureIntent()
        let stopIntent = StopCaptureIntent()

        // When - Start capture
        _ = try await startIntent.perform()

        // Then
        var action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.startCapture.rawValue)

        // When - Stop capture
        _ = try await stopIntent.perform()

        // Then
        action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.stopCapture.rawValue)
    }

    @available(iOS 16.0, *)
    @MainActor
    func testWidgetWorkflow_MultipleActions_OverwritesPrevious() async throws {
        // Given
        let startIntent = StartCaptureIntent()
        let clearIntent = ClearRequestsIntent()
        let stopIntent = StopCaptureIntent()

        // When
        _ = try await startIntent.perform()
        _ = try await clearIntent.perform()
        _ = try await stopIntent.perform()

        // Then - Should have the last action
        let action = userDefaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(action, WidgetAction.stopCapture.rawValue)
    }
}
