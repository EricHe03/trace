//
//  NotificationSettingsTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/16.
//

import XCTest
@testable import Trace
@testable import TraceFeatures

final class NotificationSettingsTests: XCTestCase {

    // Use a fresh instance for each test to avoid side effects
    var settings: NotificationSettings!

    override func setUp() {
        super.setUp()
        // Clear any stored settings before each test
        UserDefaults.standard.removeObject(forKey: "notificationSettings")
        settings = NotificationSettings.load()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "notificationSettings")
        settings = nil
        super.tearDown()
    }

    // MARK: - Default Values Tests

    func testDefaultEnableErrorNotifications() {
        XCTAssertTrue(settings.enableErrorNotifications)
    }

    func testDefaultEnableSlowRequestNotifications() {
        XCTAssertTrue(settings.enableSlowRequestNotifications)
    }

    func testDefaultEnableLargeDataNotifications() {
        XCTAssertFalse(settings.enableLargeDataNotifications)
    }

    func testDefaultSlowRequestThreshold() {
        XCTAssertEqual(settings.slowRequestThreshold, 3.0)
    }

    func testDefaultLargeDataThreshold() {
        XCTAssertEqual(settings.largeDataThreshold, 5_000_000)
    }

    // MARK: - Persistence Tests

    func testEnableErrorNotificationsPersists() {
        settings.enableErrorNotifications = false

        let reloaded = NotificationSettings.load()
        XCTAssertFalse(reloaded.enableErrorNotifications)
    }

    func testEnableSlowRequestNotificationsPersists() {
        settings.enableSlowRequestNotifications = false

        let reloaded = NotificationSettings.load()
        XCTAssertFalse(reloaded.enableSlowRequestNotifications)
    }

    func testEnableLargeDataNotificationsPersists() {
        settings.enableLargeDataNotifications = true

        let reloaded = NotificationSettings.load()
        XCTAssertTrue(reloaded.enableLargeDataNotifications)
    }

    func testSlowRequestThresholdPersists() {
        settings.slowRequestThreshold = 10.0

        let reloaded = NotificationSettings.load()
        XCTAssertEqual(reloaded.slowRequestThreshold, 10.0)
    }

    func testLargeDataThresholdPersists() {
        settings.largeDataThreshold = 10_000_000

        let reloaded = NotificationSettings.load()
        XCTAssertEqual(reloaded.largeDataThreshold, 10_000_000)
    }

    // MARK: - Multiple Property Changes Tests

    func testMultiplePropertyChangesPersist() {
        settings.enableErrorNotifications = false
        settings.enableSlowRequestNotifications = false
        settings.enableLargeDataNotifications = true
        settings.slowRequestThreshold = 5.0
        settings.largeDataThreshold = 1_000_000

        let reloaded = NotificationSettings.load()
        XCTAssertFalse(reloaded.enableErrorNotifications)
        XCTAssertFalse(reloaded.enableSlowRequestNotifications)
        XCTAssertTrue(reloaded.enableLargeDataNotifications)
        XCTAssertEqual(reloaded.slowRequestThreshold, 5.0)
        XCTAssertEqual(reloaded.largeDataThreshold, 1_000_000)
    }

    // MARK: - Edge Cases Tests

    func testSlowRequestThresholdZero() {
        settings.slowRequestThreshold = 0.0

        let reloaded = NotificationSettings.load()
        XCTAssertEqual(reloaded.slowRequestThreshold, 0.0)
    }

    func testSlowRequestThresholdVerySmall() {
        settings.slowRequestThreshold = 0.001

        let reloaded = NotificationSettings.load()
        XCTAssertEqual(reloaded.slowRequestThreshold, 0.001, accuracy: 0.0001)
    }

    func testSlowRequestThresholdVeryLarge() {
        settings.slowRequestThreshold = 3600.0 // 1 hour

        let reloaded = NotificationSettings.load()
        XCTAssertEqual(reloaded.slowRequestThreshold, 3600.0)
    }

    func testLargeDataThresholdZero() {
        settings.largeDataThreshold = 0

        let reloaded = NotificationSettings.load()
        XCTAssertEqual(reloaded.largeDataThreshold, 0)
    }

    func testLargeDataThresholdVeryLarge() {
        settings.largeDataThreshold = Int64.max

        let reloaded = NotificationSettings.load()
        XCTAssertEqual(reloaded.largeDataThreshold, Int64.max)
    }

    // MARK: - Singleton Tests

    func testSharedInstanceExists() {
        XCTAssertNotNil(NotificationSettings.shared)
    }

    func testSharedInstanceReturnsSameInstance() {
        let instance1 = NotificationSettings.shared
        let instance2 = NotificationSettings.shared

        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Codable Tests

    func testSettingsAreCodable() throws {
        settings.enableErrorNotifications = false
        settings.slowRequestThreshold = 7.5
        settings.largeDataThreshold = 8_000_000

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NotificationSettings.self, from: data)

        XCTAssertEqual(decoded.enableErrorNotifications, settings.enableErrorNotifications)
        XCTAssertEqual(decoded.slowRequestThreshold, settings.slowRequestThreshold)
        XCTAssertEqual(decoded.largeDataThreshold, settings.largeDataThreshold)
    }

    // MARK: - Load with Corrupted Data Tests

    func testLoadWithCorruptedData() {
        // Store invalid data
        UserDefaults.standard.set(Data([0, 1, 2, 3]), forKey: "notificationSettings")

        // Should return default settings
        let loaded = NotificationSettings.load()
        XCTAssertTrue(loaded.enableErrorNotifications)
        XCTAssertEqual(loaded.slowRequestThreshold, 3.0)
    }

    func testLoadWithEmptyData() {
        // Store empty data
        UserDefaults.standard.set(Data(), forKey: "notificationSettings")

        // Should return default settings
        let loaded = NotificationSettings.load()
        XCTAssertTrue(loaded.enableErrorNotifications)
    }

    // MARK: - Toggle Tests

    func testToggleErrorNotifications() {
        let original = settings.enableErrorNotifications
        settings.enableErrorNotifications = !original

        XCTAssertEqual(settings.enableErrorNotifications, !original)

        settings.enableErrorNotifications = original
        XCTAssertEqual(settings.enableErrorNotifications, original)
    }

    func testToggleSlowRequestNotifications() {
        let original = settings.enableSlowRequestNotifications
        settings.enableSlowRequestNotifications = !original

        XCTAssertEqual(settings.enableSlowRequestNotifications, !original)
    }

    func testToggleLargeDataNotifications() {
        let original = settings.enableLargeDataNotifications
        settings.enableLargeDataNotifications = !original

        XCTAssertEqual(settings.enableLargeDataNotifications, !original)
    }
}
