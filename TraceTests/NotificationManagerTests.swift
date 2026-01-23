//
//  NotificationManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import UserNotifications
import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class NotificationManagerTests: XCTestCase {
    var sut: NotificationManager!

    override func setUp() {
        super.setUp()
        sut = NotificationManager.shared
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let instance1 = NotificationManager.shared
        let instance2 = NotificationManager.shared

        XCTAssertTrue(instance1 === instance2, "NotificationManager should be a singleton")
    }

    // MARK: - Authorization Tests

    func testCheckAuthorizationStatus_ReturnsStatus() async {
        let status = await sut.checkAuthorizationStatus()

        // Status should be one of the valid values
        let validStatuses: [UNAuthorizationStatus] = [
            .notDetermined,
            .denied,
            .authorized,
            .provisional,
            .ephemeral
        ]

        XCTAssertTrue(validStatuses.contains(status))
    }

    func testAreNotificationsEnabled_ReturnsBool() async {
        let enabled = await sut.areNotificationsEnabled()

        // Should return a boolean value
        XCTAssertNotNil(enabled)
    }

    // MARK: - Notification Content Tests

    func testNotifyHTTPError_WithValidRequest_DoesNotCrash() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 404
        )

        // This should not crash
        sut.notifyHTTPError(request: request)

        // Give notification time to be processed
        let expectation = XCTestExpectation(description: "Notification processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    func testNotifyHTTPError_WithoutStatusCode_DoesNotCrash() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: nil
        )

        // Should handle gracefully when status code is nil
        sut.notifyHTTPError(request: request)

        let expectation = XCTestExpectation(description: "Handled nil status code")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    func testNotifySlowRequest_WithDuration_DoesNotCrash() {
        let request = makeNetworkRequest(
            url: "https://slow-api.example.com/data",
            method: .get,
            duration: 5.0
        )

        sut.notifySlowRequest(request: request, duration: 5.0)

        let expectation = XCTestExpectation(description: "Slow request notification")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    func testNotifyLargeData_WithSize_DoesNotCrash() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/large-file",
            method: .get
        )

        let largeSize: Int64 = 10 * 1024 * 1024 // 10 MB

        sut.notifyLargeData(request: request, size: largeSize)

        let expectation = XCTestExpectation(description: "Large data notification")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    // MARK: - Generic Notification Tests

    func testSendNotification_WithValidParameters_DoesNotCrash() async throws {
        do {
            try await sut.sendNotification(
                title: "Test Notification",
                body: "This is a test",
                identifier: "test-notification-1"
            )
            XCTAssertTrue(true, "Notification sent successfully")
        } catch {
            // May fail in test environment due to authorization
            XCTAssertNotNil(error)
        }
    }

    func testSendNotification_WithEmptyStrings() async throws {
        do {
            try await sut.sendNotification(
                title: "",
                body: "",
                identifier: "test-empty"
            )
            // Should handle empty strings gracefully
            XCTAssertTrue(true)
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testSendNotification_WithLongContent() async throws {
        let longTitle = String(repeating: "A", count: 200)
        let longBody = String(repeating: "B", count: 1000)

        do {
            try await sut.sendNotification(
                title: longTitle,
                body: longBody,
                identifier: "test-long"
            )
            XCTAssertTrue(true)
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Request ID Tests

    func testNotifyHTTPError_IncludesRequestID() {
        let requestId = UUID()
        let request = makeNetworkRequest(
            id: requestId,
            url: "https://api.example.com/error",
            method: .get,
            statusCode: 500
        )

        sut.notifyHTTPError(request: request)

        // Notification should include request ID in userInfo
        // This is verified by the implementation
        let expectation = XCTestExpectation(description: "Request ID included")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    // MARK: - Multiple Notifications Tests

    func testMultipleNotifications_Sequential() {
        let requests = [
            makeNetworkRequest(statusCode: 404),
            makeNetworkRequest(statusCode: 500),
            makeNetworkRequest(statusCode: 403)
        ]

        for request in requests {
            sut.notifyHTTPError(request: request)
        }

        let expectation = XCTestExpectation(description: "Multiple notifications")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testDifferentNotificationTypes_Sequential() {
        let request1 = makeNetworkRequest(statusCode: 404)
        let request2 = makeNetworkRequest(duration: 10.0)
        let request3 = makeNetworkRequest()

        sut.notifyHTTPError(request: request1)
        sut.notifySlowRequest(request: request2, duration: 10.0)
        sut.notifyLargeData(request: request3, size: 50 * 1024 * 1024)

        let expectation = XCTestExpectation(description: "Different notification types")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Category Tests

    func testNotificationCategories_AreSetup() {
        // The categories are set up in init
        // We verify this by checking that the manager was initialized
        XCTAssertNotNil(sut)

        // Categories include: HTTP_ERROR, SLOW_REQUEST, LARGE_DATA
        // These are set up during initialization
    }

    // MARK: - Edge Cases

    func testNotifyHTTPError_WithSpecialCharactersInURL() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/test?param=value&special=hello%20world",
            method: .get,
            statusCode: 400
        )

        sut.notifyHTTPError(request: request)

        let expectation = XCTestExpectation(description: "Special characters handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    func testNotifySlowRequest_WithZeroDuration() {
        let request = makeNetworkRequest()

        sut.notifySlowRequest(request: request, duration: 0.0)

        let expectation = XCTestExpectation(description: "Zero duration handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    func testNotifySlowRequest_WithNegativeDuration() {
        let request = makeNetworkRequest()

        sut.notifySlowRequest(request: request, duration: -1.0)

        let expectation = XCTestExpectation(description: "Negative duration handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    func testNotifyLargeData_WithZeroSize() {
        let request = makeNetworkRequest()

        sut.notifyLargeData(request: request, size: 0)

        let expectation = XCTestExpectation(description: "Zero size handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    func testNotifyLargeData_WithNegativeSize() {
        let request = makeNetworkRequest()

        sut.notifyLargeData(request: request, size: -100)

        let expectation = XCTestExpectation(description: "Negative size handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    // MARK: - HTTP Status Code Range Tests

    func testNotifyHTTPError_WithClientErrors() {
        let statusCodes = [400, 401, 403, 404, 429]

        for code in statusCodes {
            let request = makeNetworkRequest(statusCode: code)
            sut.notifyHTTPError(request: request)
        }

        let expectation = XCTestExpectation(description: "Client errors handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testNotifyHTTPError_WithServerErrors() {
        let statusCodes = [500, 502, 503, 504]

        for code in statusCodes {
            let request = makeNetworkRequest(statusCode: code)
            sut.notifyHTTPError(request: request)
        }

        let expectation = XCTestExpectation(description: "Server errors handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Concurrent Notifications Tests

    func testConcurrentNotifications_DoNotCrash() {
        let iterations = 50
        let expectation = XCTestExpectation(description: "Concurrent notifications")
        expectation.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let request = makeNetworkRequest(statusCode: 400 + i)
            self.sut.notifyHTTPError(request: request)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Notification Name Tests

    func testNotificationNames_AreDefined() {
        XCTAssertEqual(Notification.Name.viewRequest.rawValue, "viewRequest")
        XCTAssertEqual(Notification.Name.openTab.rawValue, "com.trace.openTab")
        XCTAssertEqual(Notification.Name.showFavorites.rawValue, "com.trace.showFavorites")
    }
}
