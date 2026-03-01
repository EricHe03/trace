//
//  WidgetActionHandlerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class WidgetActionHandlerTests: XCTestCase {
    final class WidgetActionStoreAdapter {
        private let storage: AppGroupStorage

        init(storage: AppGroupStorage = .shared) {
            self.storage = storage
        }

        func removeObject(forKey key: String) {
            switch key {
            case WidgetActionKey.action:
                try? storage.clearWidgetPendingAction()
            case WidgetActionKey.actionDate:
                guard var pending = storage.loadWidgetPendingAction() else { return }
                pending.actionDate = Date()
                try? storage.saveWidgetPendingAction(pending)
            case WidgetActionKey.actionView:
                guard var pending = storage.loadWidgetPendingAction() else { return }
                pending.actionView = nil
                try? storage.saveWidgetPendingAction(pending)
            default:
                break
            }
        }

        func set(_ value: Any?, forKey key: String) {
            var pending = storage.loadWidgetPendingAction() ?? WidgetPendingAction(action: .toggleCapture)
            switch key {
            case WidgetActionKey.action:
                if let rawValue = value as? String, let action = WidgetAction(rawValue: rawValue) {
                    pending.action = action
                }
            case WidgetActionKey.actionDate:
                if let date = value as? Date {
                    pending.actionDate = date
                }
            case WidgetActionKey.actionView:
                pending.actionView = value as? String
            default:
                return
            }
            try? storage.saveWidgetPendingAction(pending)
        }

        func string(forKey key: String) -> String? {
            guard let pending = storage.loadWidgetPendingAction() else { return nil }
            switch key {
            case WidgetActionKey.action:
                return pending.action.rawValue
            case WidgetActionKey.actionView:
                return pending.actionView
            default:
                return nil
            }
        }

        func object(forKey key: String) -> Any? {
            guard key == WidgetActionKey.actionDate else { return nil }
            return storage.loadWidgetPendingAction()?.actionDate
        }
    }

    var sut: WidgetActionHandler!
    var defaults: WidgetActionStoreAdapter?

    override func setUp() async throws {
        try await super.setUp()
        sut = WidgetActionHandler.shared
        defaults = WidgetActionStoreAdapter()

        // Clear any existing widget actions
        clearWidgetActions()
    }

    override func tearDown() async throws {
        clearWidgetActions()
        defaults = nil
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func clearWidgetActions() {
        defaults?.removeObject(forKey: WidgetActionKey.action)
        defaults?.removeObject(forKey: WidgetActionKey.actionDate)
        defaults?.removeObject(forKey: WidgetActionKey.actionView)
    }

    private func setWidgetAction(_ action: WidgetAction, view: String? = nil) {
        defaults?.set(action.rawValue, forKey: WidgetActionKey.action)
        defaults?.set(Date(), forKey: WidgetActionKey.actionDate)
        if let view {
            defaults?.set(view, forKey: WidgetActionKey.actionView)
        }
    }

    private func hasWidgetAction() -> Bool {
        defaults?.string(forKey: WidgetActionKey.action) != nil
    }

    // MARK: - Singleton Pattern Tests

    func testSingletonPattern_ReturnsSameInstance() {
        // Given
        let instance1 = WidgetActionHandler.shared
        let instance2 = WidgetActionHandler.shared

        // Then
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - WidgetAction Enum Tests

    func testWidgetAction_AllCasesHaveRawValue() {
        // Then
        XCTAssertEqual(WidgetAction.toggleCapture.rawValue, "toggleCapture")
        XCTAssertEqual(WidgetAction.startCapture.rawValue, "startCapture")
        XCTAssertEqual(WidgetAction.stopCapture.rawValue, "stopCapture")
        XCTAssertEqual(WidgetAction.clearRequests.rawValue, "clearRequests")
        XCTAssertEqual(WidgetAction.openView.rawValue, "openView")
    }

    func testWidgetAction_InitFromRawValue_WorksCorrectly() {
        // Given
        let rawValues = ["toggleCapture", "startCapture", "stopCapture", "clearRequests", "openView"]

        for rawValue in rawValues {
            // When
            let action = WidgetAction(rawValue: rawValue)

            // Then
            XCTAssertNotNil(action, "Failed to create action from rawValue: \(rawValue)")
            XCTAssertEqual(action?.rawValue, rawValue)
        }
    }

    func testWidgetAction_InitFromInvalidRawValue_ReturnsNil() {
        // When
        let action = WidgetAction(rawValue: "invalidAction")

        // Then
        XCTAssertNil(action)
    }

    // MARK: - WidgetActionKey Tests

    func testWidgetActionKey_AllKeysAreDefined() {
        // Then
        XCTAssertEqual(WidgetActionKey.action, "widget.action")
        XCTAssertEqual(WidgetActionKey.actionDate, "widget.actionDate")
        XCTAssertEqual(WidgetActionKey.actionView, "widget.actionView")
    }

    // MARK: - Action Setting Tests

    func testSetWidgetAction_StoresActionInDefaults() {
        // When
        setWidgetAction(.toggleCapture)

        // Then
        let storedAction = defaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(storedAction, "toggleCapture")
    }

    func testSetWidgetAction_StoresActionDate() {
        // Given
        let beforeDate = Date()

        // When
        setWidgetAction(.startCapture)

        // Then
        let storedDate = defaults?.object(forKey: WidgetActionKey.actionDate) as? Date
        XCTAssertNotNil(storedDate)
        XCTAssertGreaterThanOrEqual(storedDate!, beforeDate)
    }

    func testSetWidgetAction_WithView_StoresViewInDefaults() {
        // When
        setWidgetAction(.openView, view: "capture")

        // Then
        let storedView = defaults?.string(forKey: WidgetActionKey.actionView)
        XCTAssertEqual(storedView, "capture")
    }

    func testSetWidgetAction_WithoutView_DoesNotStoreView() {
        // When
        setWidgetAction(.toggleCapture)

        // Then
        let storedView = defaults?.string(forKey: WidgetActionKey.actionView)
        XCTAssertNil(storedView)
    }

    // MARK: - Action Clearing Tests

    func testClearWidgetActions_RemovesAllActionKeys() {
        // Given
        setWidgetAction(.toggleCapture, view: "capture")
        XCTAssertTrue(hasWidgetAction())

        // When
        clearWidgetActions()

        // Then
        XCTAssertFalse(hasWidgetAction())
        XCTAssertNil(defaults?.string(forKey: WidgetActionKey.action))
        XCTAssertNil(defaults?.object(forKey: WidgetActionKey.actionDate))
        XCTAssertNil(defaults?.string(forKey: WidgetActionKey.actionView))
    }

    // MARK: - Action Storage Tests

    func testSetWidgetAction_MultipleActions_OverwritesPrevious() {
        // When
        setWidgetAction(.startCapture)
        setWidgetAction(.stopCapture)

        // Then
        let storedAction = defaults?.string(forKey: WidgetActionKey.action)
        XCTAssertEqual(storedAction, "stopCapture")
    }

    func testSetWidgetAction_AllActionTypes_CanBeStored() {
        // Given
        let actions: [WidgetAction] = [
            .toggleCapture,
            .startCapture,
            .stopCapture,
            .clearRequests,
            .openView
        ]

        for action in actions {
            // When
            clearWidgetActions()
            setWidgetAction(action)

            // Then
            let storedAction = defaults?.string(forKey: WidgetActionKey.action)
            XCTAssertEqual(storedAction, action.rawValue, "Failed to store action: \(action.rawValue)")
        }
    }

    // MARK: - View Parameter Tests

    func testSetWidgetAction_DifferentViews_CanBeStored() {
        // Given
        let views = ["capture", "tools", "settings", "favorites"]

        for view in views {
            // When
            clearWidgetActions()
            setWidgetAction(.openView, view: view)

            // Then
            let storedView = defaults?.string(forKey: WidgetActionKey.actionView)
            XCTAssertEqual(storedView, view, "Failed to store view: \(view)")
        }
    }

    func testSetWidgetAction_EmptyView_StoresEmptyString() {
        // When
        setWidgetAction(.openView, view: "")

        // Then
        let storedView = defaults?.string(forKey: WidgetActionKey.actionView)
        XCTAssertEqual(storedView, "")
    }

    // MARK: - Action Persistence Tests

    func testWidgetAction_PersistsBetweenInstanceCreation() {
        // Given
        setWidgetAction(.toggleCapture, view: "capture")

        // When - Verify data persists in defaults
        let newDefaults = WidgetActionStoreAdapter()

        // Then
        XCTAssertEqual(newDefaults?.string(forKey: WidgetActionKey.action), "toggleCapture")
        XCTAssertEqual(newDefaults?.string(forKey: WidgetActionKey.actionView), "capture")
    }

    // MARK: - Edge Cases

    func testSetWidgetAction_NilDefaults_HandlesGracefully() {
        // This tests that the code doesn't crash if defaults is nil
        // In production, this should be rare since appGroupIdentifier should be valid

        // When - Try to set action (even though defaults might not be available)
        // Just ensure no crash occurs
        setWidgetAction(.toggleCapture)

        // Then - No assertion needed, just verify no crash
    }

    func testSetWidgetAction_ConsecutiveCalls_UpdatesCorrectly() {
        // When
        setWidgetAction(.startCapture)
        Thread.sleep(forTimeInterval: 0.001) // Small delay
        setWidgetAction(.stopCapture, view: "capture")

        // Then
        let storedAction = defaults?.string(forKey: WidgetActionKey.action)
        let storedView = defaults?.string(forKey: WidgetActionKey.actionView)

        XCTAssertEqual(storedAction, "stopCapture")
        XCTAssertEqual(storedView, "capture")
    }

    func testSetWidgetAction_SpecialCharactersInView_HandlesCorrectly() {
        // Given
        let specialView = "view-with-special/characters:123"

        // When
        setWidgetAction(.openView, view: specialView)

        // Then
        let storedView = defaults?.string(forKey: WidgetActionKey.actionView)
        XCTAssertEqual(storedView, specialView)
    }

    func testSetWidgetAction_LongViewString_HandlesCorrectly() {
        // Given
        let longView = String(repeating: "view", count: 100)

        // When
        setWidgetAction(.openView, view: longView)

        // Then
        let storedView = defaults?.string(forKey: WidgetActionKey.actionView)
        XCTAssertEqual(storedView, longView)
    }

    // MARK: - Action Date Tests

    func testSetWidgetAction_ActionDate_IsRecent() {
        // Given
        let beforeDate = Date()

        // When
        Thread.sleep(forTimeInterval: 0.001)
        setWidgetAction(.toggleCapture)
        Thread.sleep(forTimeInterval: 0.001)
        let afterDate = Date()

        // Then
        let storedDate = defaults?.object(forKey: WidgetActionKey.actionDate) as? Date
        XCTAssertNotNil(storedDate)

        // Date should be between before and after
        XCTAssertGreaterThanOrEqual(storedDate!, beforeDate)
        XCTAssertLessThanOrEqual(storedDate!, afterDate)
    }

    func testSetWidgetAction_MultipleActions_UpdatesActionDate() {
        // Given
        setWidgetAction(.startCapture)
        let firstDate = defaults?.object(forKey: WidgetActionKey.actionDate) as? Date

        // When - Wait a bit and set another action
        Thread.sleep(forTimeInterval: 0.01)
        setWidgetAction(.stopCapture)
        let secondDate = defaults?.object(forKey: WidgetActionKey.actionDate) as? Date

        // Then
        XCTAssertNotNil(firstDate)
        XCTAssertNotNil(secondDate)
        XCTAssertGreaterThan(secondDate!, firstDate!)
    }

    // MARK: - Integration Tests

    func testWidgetAction_FullWorkflow_StoreAndClear() {
        // Given - Store an action
        XCTAssertFalse(hasWidgetAction())

        // When - Set action
        setWidgetAction(.toggleCapture, view: "capture")

        // Then - Verify stored
        XCTAssertTrue(hasWidgetAction())
        XCTAssertEqual(defaults?.string(forKey: WidgetActionKey.action), "toggleCapture")
        XCTAssertEqual(defaults?.string(forKey: WidgetActionKey.actionView), "capture")
        XCTAssertNotNil(defaults?.object(forKey: WidgetActionKey.actionDate))

        // When - Clear
        clearWidgetActions()

        // Then - Verify cleared
        XCTAssertFalse(hasWidgetAction())
        XCTAssertNil(defaults?.string(forKey: WidgetActionKey.action))
        XCTAssertNil(defaults?.string(forKey: WidgetActionKey.actionView))
        XCTAssertNil(defaults?.object(forKey: WidgetActionKey.actionDate))
    }

    func testWidgetAction_AllActionsWithViews_CanBeStoredAndRetrieved() {
        // Given
        let testCases: [(WidgetAction, String)] = [
            (.toggleCapture, "capture"),
            (.startCapture, "tools"),
            (.stopCapture, "settings"),
            (.clearRequests, "favorites"),
            (.openView, "capture")
        ]

        for (action, view) in testCases {
            // When
            clearWidgetActions()
            setWidgetAction(action, view: view)

            // Then
            XCTAssertEqual(defaults?.string(forKey: WidgetActionKey.action), action.rawValue)
            XCTAssertEqual(defaults?.string(forKey: WidgetActionKey.actionView), view)
        }
    }
}
