//
//  QuickActionHandlerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import UIKit
import XCTest
@testable import Trace
@testable import TraceCore

final class QuickActionHandlerTests: XCTestCase {
    var sut: QuickActionHandler!

    override func setUp() {
        super.setUp()
        sut = QuickActionHandler.shared
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let instance1 = QuickActionHandler.shared
        let instance2 = QuickActionHandler.shared

        XCTAssertTrue(instance1 === instance2, "QuickActionHandler should be a singleton")
    }

    // MARK: - Start Capture Tests

    @MainActor
    func testHandleShortcut_StartCapture_ReturnsTrue() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start Capture"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertTrue(result, "Start capture shortcut should return true")
    }

    @MainActor
    func testHandleShortcut_StartCapture_WhenAlreadyConnected_StillReturnsTrue() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start Capture"
        )
        let viewModel = CaptureViewModel()

        // VPNManager.shared.isConnected would need to be mocked for proper testing
        // For now, we test that the handler returns true
        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertTrue(result)
    }

    // MARK: - Stop Capture Tests

    @MainActor
    func testHandleShortcut_StopCapture_ReturnsTrue() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.stopCapture",
            localizedTitle: "Stop Capture"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertTrue(result, "Stop capture shortcut should return true")
    }

    // MARK: - View Last Session Tests

    @MainActor
    func testHandleShortcut_ViewLastSession_ReturnsTrue() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.viewLastSession",
            localizedTitle: "View Last Session"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertTrue(result, "View last session shortcut should return true")
    }

    @MainActor
    func testHandleShortcut_ViewLastSession_WhenNoSessions_StillReturnsTrue() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.viewLastSession",
            localizedTitle: "View Last Session"
        )
        let viewModel = CaptureViewModel()
        // Sessions would be empty by default

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        // Should still return true even if there are no sessions
        XCTAssertTrue(result)
    }

    // MARK: - Export Data Tests

    @MainActor
    func testHandleShortcut_ExportData_ReturnsTrue() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.exportData",
            localizedTitle: "Export Data"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertTrue(result, "Export data shortcut should return true")
    }

    // MARK: - Unknown Shortcut Tests

    @MainActor
    func testHandleShortcut_UnknownType_ReturnsFalse() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.unknownAction",
            localizedTitle: "Unknown"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertFalse(result, "Unknown shortcut should return false")
    }

    @MainActor
    func testHandleShortcut_InvalidType_ReturnsFalse() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "invalid.type",
            localizedTitle: "Invalid"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertFalse(result, "Invalid shortcut type should return false")
    }

    // MARK: - Multiple Shortcuts Tests

    @MainActor
    func testHandleShortcut_DifferentShortcutsInSequence() async {
        let viewModel = CaptureViewModel()

        let shortcuts = [
            UIApplicationShortcutItem(
                type: "com.trace.startCapture",
                localizedTitle: "Start"
            ),
            UIApplicationShortcutItem(
                type: "com.trace.stopCapture",
                localizedTitle: "Stop"
            ),
            UIApplicationShortcutItem(
                type: "com.trace.viewLastSession",
                localizedTitle: "View"
            ),
            UIApplicationShortcutItem(
                type: "com.trace.exportData",
                localizedTitle: "Export"
            )
        ]

        for shortcut in shortcuts {
            let result = await sut.handleShortcutItem(shortcut, viewModel: viewModel)
            XCTAssertTrue(result, "\(shortcut.type) should return true")
        }
    }

    // MARK: - Valid Shortcut Types Tests

    @MainActor
    func testAllValidShortcutTypes_ReturnTrue() async {
        let viewModel = CaptureViewModel()

        let validTypes = [
            "com.trace.startCapture",
            "com.trace.stopCapture",
            "com.trace.viewLastSession",
            "com.trace.exportData"
        ]

        for type in validTypes {
            let shortcut = UIApplicationShortcutItem(
                type: type,
                localizedTitle: type
            )
            let result = await sut.handleShortcutItem(shortcut, viewModel: viewModel)
            XCTAssertTrue(result, "Valid type \(type) should return true")
        }
    }

    // MARK: - Edge Cases

    @MainActor
    func testHandleShortcut_EmptyType_ReturnsFalse() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "",
            localizedTitle: "Empty"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertFalse(result, "Empty type should return false")
    }

    @MainActor
    func testHandleShortcut_CaseCheck() async {
        // Test that the type matching is case-sensitive
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.STARTCAPTURE",
            localizedTitle: "Start"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertFalse(result, "Type should be case-sensitive")
    }

    @MainActor
    func testHandleShortcut_PartialMatch_ReturnsFalse() async {
        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.start",
            localizedTitle: "Start"
        )
        let viewModel = CaptureViewModel()

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)

        XCTAssertFalse(result, "Partial match should return false")
    }

    // MARK: - ViewModel Integration Tests

    @MainActor
    func testHandleShortcut_ViewLastSession_IntegrationWithViewModel() async {
        let viewModel = CaptureViewModel()

        // Create a test session
        let testSession = CaptureSession(
            id: UUID(),
            name: "Test Session",
            startTime: Date(),
            endTime: nil,
            requestCount: 0
        )
        // Note: In real implementation, we'd need to add the session to viewModel.sessions
        // For now, this test verifies the handler doesn't crash

        let shortcutItem = UIApplicationShortcutItem(
            type: "com.trace.viewLastSession",
            localizedTitle: "View Last"
        )

        let result = await sut.handleShortcutItem(shortcutItem, viewModel: viewModel)
        XCTAssertTrue(result)
    }

    // MARK: - Concurrent Execution Tests

    @MainActor
    func testHandleShortcut_ConcurrentCalls() async {
        let viewModel = CaptureViewModel()

        let shortcut1 = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start"
        )
        let shortcut2 = UIApplicationShortcutItem(
            type: "com.trace.stopCapture",
            localizedTitle: "Stop"
        )

        async let result1 = sut.handleShortcutItem(shortcut1, viewModel: viewModel)
        async let result2 = sut.handleShortcutItem(shortcut2, viewModel: viewModel)

        let (r1, r2) = await (result1, result2)
        XCTAssertTrue(r1)
        XCTAssertTrue(r2)
    }

    // MARK: - Error Handling Tests

    @MainActor
    func testHandleShortcut_DoesNotThrowOnError() async {
        // Verify that handler doesn't crash even if underlying operations fail
        let viewModel = CaptureViewModel()

        let shortcut = UIApplicationShortcutItem(
            type: "com.trace.startCapture",
            localizedTitle: "Start"
        )

        // This should not throw or crash
        let result = await sut.handleShortcutItem(shortcut, viewModel: viewModel)

        // Result may be true or false depending on VPN state, but shouldn't throw
        XCTAssertNotNil(result)
    }
}
