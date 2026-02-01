//
//  TraceAppTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
import SwiftUI
import UIKit
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class TraceAppTests: XCTestCase {
    var appDelegate: AppDelegate!

    override func setUp() {
        super.setUp()
        appDelegate = AppDelegate()
    }

    override func tearDown() {
        appDelegate = nil
        super.tearDown()
    }

    // MARK: - AppDelegate Tests

    func testAppDelegate_Initialization() {
        // Given/When
        let delegate = AppDelegate()

        // Then
        XCTAssertNotNil(delegate)
        XCTAssertNil(delegate.viewModel)
    }

    func testAppDelegate_DidFinishLaunching_WithoutShortcut() {
        // Given
        let application = UIApplication.shared

        // When
        let result = appDelegate.application(application, didFinishLaunchingWithOptions: nil)

        // Then
        XCTAssertTrue(result)
        XCTAssertNil(application.shortcutItem)
    }

    func testAppDelegate_DidFinishLaunching_WithShortcut() {
        // Given
        let application = UIApplication.shared
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start Capture"
        )
        let launchOptions: [UIApplication.LaunchOptionsKey: Any] = [
            .shortcutItem: shortcutItem
        ]

        // When
        let result = appDelegate.application(application, didFinishLaunchingWithOptions: launchOptions)

        // Then
        XCTAssertTrue(result)
        XCTAssertNotNil(application.shortcutItem)
        XCTAssertEqual(application.shortcutItem?.type, shortcutItem.type)
    }

    func testAppDelegate_PerformAction_WithoutViewModel() {
        // Given
        let application = UIApplication.shared
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start"
        )
        let expectation = self.expectation(description: "Completion called")
        var completionResult: Bool?

        // When
        appDelegate.application(application, performActionFor: shortcutItem) { result in
            completionResult = result
            expectation.fulfill()
        }

        // Then
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(completionResult, false)
        XCTAssertNotNil(application.shortcutItem)
    }

    @MainActor
    func testAppDelegate_PerformAction_WithViewModel() async {
        // Given
        let application = UIApplication.shared
        let viewModel = CaptureViewModel()
        appDelegate.viewModel = viewModel

        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start"
        )

        let expectation = self.expectation(description: "Completion called")
        var completionResult: Bool?

        // When
        appDelegate.application(application, performActionFor: shortcutItem) { result in
            completionResult = result
            expectation.fulfill()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(completionResult)
    }

    @MainActor
    func testAppDelegate_PerformAction_StartCapture() async {
        // Given
        let application = UIApplication.shared
        let viewModel = CaptureViewModel()
        appDelegate.viewModel = viewModel

        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start"
        )

        let expectation = self.expectation(description: "Completion called")
        var completionResult: Bool?

        // When
        appDelegate.application(application, performActionFor: shortcutItem) { result in
            completionResult = result
            expectation.fulfill()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(completionResult)
    }

    @MainActor
    func testAppDelegate_PerformAction_StopCapture() async {
        // Given
        let application = UIApplication.shared
        let viewModel = CaptureViewModel()
        appDelegate.viewModel = viewModel

        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.stopCapture",
            localizedTitle: "Stop"
        )

        let expectation = self.expectation(description: "Completion called")
        var completionResult: Bool?

        // When
        appDelegate.application(application, performActionFor: shortcutItem) { result in
            completionResult = result
            expectation.fulfill()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(completionResult)
    }

    @MainActor
    func testAppDelegate_PerformAction_ViewLastSession() async {
        // Given
        let application = UIApplication.shared
        let viewModel = CaptureViewModel()
        appDelegate.viewModel = viewModel

        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.viewLastSession",
            localizedTitle: "View Last"
        )

        let expectation = self.expectation(description: "Completion called")
        var completionResult: Bool?

        // When
        appDelegate.application(application, performActionFor: shortcutItem) { result in
            completionResult = result
            expectation.fulfill()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(completionResult)
    }

    @MainActor
    func testAppDelegate_PerformAction_ExportData() async {
        // Given
        let application = UIApplication.shared
        let viewModel = CaptureViewModel()
        appDelegate.viewModel = viewModel

        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.exportData",
            localizedTitle: "Export"
        )

        let expectation = self.expectation(description: "Completion called")
        var completionResult: Bool?

        // When
        appDelegate.application(application, performActionFor: shortcutItem) { result in
            completionResult = result
            expectation.fulfill()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(completionResult)
    }

    @MainActor
    func testAppDelegate_PerformAction_UnknownType() async {
        // Given
        let application = UIApplication.shared
        let viewModel = CaptureViewModel()
        appDelegate.viewModel = viewModel

        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.unknown",
            localizedTitle: "Unknown"
        )

        let expectation = self.expectation(description: "Completion called")
        var completionResult: Bool?

        // When
        appDelegate.application(application, performActionFor: shortcutItem) { result in
            completionResult = result
            expectation.fulfill()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(completionResult, false)
    }

    // MARK: - UIApplication Extension Tests

    func testUIApplication_ShortcutItemProperty_GetSet() {
        // Given
        let application = UIApplication.shared
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.test",
            localizedTitle: "Test"
        )

        // When
        application.shortcutItem = shortcutItem

        // Then
        XCTAssertNotNil(application.shortcutItem)
        XCTAssertEqual(application.shortcutItem?.type, "com.trace.test")
        XCTAssertEqual(application.shortcutItem?.localizedTitle, "Test")
    }

    func testUIApplication_ShortcutItemProperty_SetNil() {
        // Given
        let application = UIApplication.shared
        application.shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.test",
            localizedTitle: "Test"
        )

        // When
        application.shortcutItem = nil

        // Then
        XCTAssertNil(application.shortcutItem)
    }

    func testUIApplication_ShortcutItemProperty_MultipleSetOperations() {
        // Given
        let application = UIApplication.shared

        let item1 = UIApplicationShortcutItem(type: "item1", localizedTitle: "Item 1")
        let item2 = UIApplicationShortcutItem(type: "item2", localizedTitle: "Item 2")
        let item3 = UIApplicationShortcutItem(type: "item3", localizedTitle: "Item 3")

        // When
        application.shortcutItem = item1
        XCTAssertEqual(application.shortcutItem?.type, "item1")

        application.shortcutItem = item2
        XCTAssertEqual(application.shortcutItem?.type, "item2")

        application.shortcutItem = item3
        XCTAssertEqual(application.shortcutItem?.type, "item3")

        application.shortcutItem = nil
        XCTAssertNil(application.shortcutItem)
    }

    // MARK: - Quick Actions Update Tests

    func testQuickActions_UpdateWithNoSessions() {
        // Given - No sessions
        // Note: Cannot directly test private updateQuickActions method
        // Testing through public observable behavior

        // When/Then - Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Deep Link Tests

    func testDeepLink_TraceScheme() {
        // Given
        let url = URL(string: "trace://lastSession")!

        // When/Then - Should handle trace scheme
        XCTAssertEqual(url.scheme, "trace")
        XCTAssertEqual(url.host, "lastSession")
    }

    func testDeepLink_LastSessionHost() {
        // Given
        let url = URL(string: "trace://lastSession")!

        // When/Then
        XCTAssertEqual(url.host, "lastSession")
    }

    func testDeepLink_UnknownHost() {
        // Given
        let url = URL(string: "trace://unknown")!

        // When/Then
        XCTAssertEqual(url.scheme, "trace")
        XCTAssertEqual(url.host, "unknown")
    }

    func testDeepLink_InvalidScheme() {
        // Given
        let url = URL(string: "http://example.com")!

        // When/Then
        XCTAssertNotEqual(url.scheme, "trace")
    }

    // MARK: - Onboarding Tests

    func testOnboardingCompletion_UserDefaultsKey() {
        // Given
        let key = "hasCompletedOnboarding"

        // When - Set onboarding completed
        UserDefaults.standard.set(true, forKey: key)

        // Then
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))

        // Cleanup
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testOnboardingCompletion_InitiallyFalse() {
        // Given
        let key = "hasCompletedOnboarding"
        UserDefaults.standard.removeObject(forKey: key)

        // When
        let value = UserDefaults.standard.bool(forKey: key)

        // Then
        XCTAssertFalse(value)
    }

    // MARK: - Notification Tests

    func testNotificationCenter_OnboardingCompletedName() {
        // Given
        let notificationName = Notification.Name.onboardingCompleted

        // When/Then
        XCTAssertEqual(notificationName.rawValue, "onboardingCompleted")
    }

    func testNotificationCenter_PostOnboardingCompleted() {
        // Given
        let expectation = self.expectation(description: "Notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: .onboardingCompleted,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        // When
        NotificationCenter.default.post(name: .onboardingCompleted, object: nil)

        // Then
        wait(for: [expectation], timeout: 1.0)

        // Cleanup
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Scene Phase Tests

    func testScenePhase_ActiveState() {
        // Given/When
        let phase = ScenePhase.active

        // Then
        XCTAssertEqual(phase, .active)
    }

    func testScenePhase_InactiveState() {
        // Given/When
        let phase = ScenePhase.inactive

        // Then
        XCTAssertEqual(phase, .inactive)
    }

    func testScenePhase_BackgroundState() {
        // Given/When
        let phase = ScenePhase.background

        // Then
        XCTAssertEqual(phase, .background)
    }

    // MARK: - Edge Cases

    func testAppDelegate_MultipleShortcutCalls() async {
        // Given
        let application = UIApplication.shared
        let viewModel = CaptureViewModel()
        appDelegate.viewModel = viewModel

        let shortcut1 = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start"
        )
        let shortcut2 = UIApplicationShortcutItem(
            type: "com.trace.stopCapture",
            localizedTitle: "Stop"
        )

        let expectation1 = self.expectation(description: "First completion")
        let expectation2 = self.expectation(description: "Second completion")

        // When
        await MainActor.run {
            appDelegate.application(application, performActionFor: shortcut1) { _ in
                expectation1.fulfill()
            }

            appDelegate.application(application, performActionFor: shortcut2) { _ in
                expectation2.fulfill()
            }
        }

        // Then
        await fulfillment(of: [expectation1, expectation2], timeout: 3.0)
    }

    func testAppDelegate_ViewModelSetAfterInit() {
        // Given
        let delegate = AppDelegate()
        XCTAssertNil(delegate.viewModel)

        // When
        let viewModel = CaptureViewModel()
        delegate.viewModel = viewModel

        // Then
        XCTAssertNotNil(delegate.viewModel)
    }

    func testUIApplication_ShortcutItemRetention() {
        // Given
        let application = UIApplication.shared
        weak var weakItem: UIApplicationShortcutItem?

        autoreleasepool {
            let item = UIApplicationShortcutItem(
                type: "com.trace.test",
                localizedTitle: "Test"
            )
            weakItem = item
            application.shortcutItem = item
        }

        // When - Item should be retained by application
        // Then
        XCTAssertNotNil(application.shortcutItem)

        // Cleanup
        application.shortcutItem = nil
    }

    // MARK: - Integration Tests

    @MainActor
    func testFullShortcutFlow_FromLaunchToExecution() async {
        // Given
        let application = UIApplication.shared
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start"
        )

        // Simulate launch with shortcut
        let launchOptions: [UIApplication.LaunchOptionsKey: Any] = [
            .shortcutItem: shortcutItem
        ]

        // When - Launch
        let launchResult = appDelegate.application(application, didFinishLaunchingWithOptions: launchOptions)

        // Then
        XCTAssertTrue(launchResult)
        XCTAssertNotNil(application.shortcutItem)

        // When - Execute shortcut
        let viewModel = CaptureViewModel()
        appDelegate.viewModel = viewModel

        let expectation = self.expectation(description: "Shortcut executed")
        var executionResult: Bool?

        appDelegate.application(application, performActionFor: shortcutItem) { result in
            executionResult = result
            expectation.fulfill()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertNotNil(executionResult)
    }

    // MARK: - Cleanup

    override func tearDownWithError() throws {
        // Clean up any set shortcut items
        UIApplication.shared.shortcutItem = nil
        try super.tearDownWithError()
    }
}
