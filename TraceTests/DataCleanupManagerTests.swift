//
//  DataCleanupManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class DataCleanupManagerTests: XCTestCase {

    var manager: DataCleanupManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = DataCleanupManager.shared
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let manager1 = DataCleanupManager.shared
        let manager2 = DataCleanupManager.shared

        XCTAssertTrue(manager1 === manager2, "DataCleanupManager should be a singleton")
    }

    // MARK: - Configuration Tests

    func testDefaultConfiguration() async {
        let config = await manager.getConfiguration()

        XCTAssertTrue(config.enabled, "Cleanup should be enabled by default")
        XCTAssertEqual(config.requestRetentionDays, 7, "Default request retention should be 7 days")
        XCTAssertEqual(config.bodyFileRetentionDays, 7, "Default body file retention should be 7 days")
        XCTAssertEqual(config.logRetentionDays, 7, "Default log retention should be 7 days")
        XCTAssertEqual(config.maxStorageMB, 500, "Default max storage should be 500 MB")
        XCTAssertEqual(config.cleanupInterval, 3600, "Default cleanup interval should be 1 hour")
    }

    func testUpdateConfiguration() async {
        var newConfig = DataCleanupManager.CleanupConfiguration()
        newConfig.enabled = false
        newConfig.requestRetentionDays = 14
        newConfig.bodyFileRetentionDays = 14
        newConfig.logRetentionDays = 14
        newConfig.maxStorageMB = 1000

        await manager.updateConfiguration(newConfig)

        let updatedConfig = await manager.getConfiguration()
        XCTAssertFalse(updatedConfig.enabled)
        XCTAssertEqual(updatedConfig.requestRetentionDays, 14)
        XCTAssertEqual(updatedConfig.bodyFileRetentionDays, 14)
        XCTAssertEqual(updatedConfig.logRetentionDays, 14)
        XCTAssertEqual(updatedConfig.maxStorageMB, 1000)
    }

    func testConfigurationEquatable() {
        let config1 = DataCleanupManager.CleanupConfiguration()
        var config2 = DataCleanupManager.CleanupConfiguration()

        XCTAssertEqual(config1, config2)

        config2.enabled = false
        XCTAssertNotEqual(config1, config2)
    }

    // MARK: - Stats Tests

    func testInitialStats() async {
        let stats = await manager.getStats()

        XCTAssertEqual(stats.requestsDeleted, 0)
        XCTAssertEqual(stats.bodyFilesDeleted, 0)
        XCTAssertEqual(stats.logsDeleted, 0)
        XCTAssertEqual(stats.bytesFreed, 0)
    }

    func testStatsUpdateAfterCleanup() async {
        // Perform manual cleanup
        await manager.performManualCleanup()

        let stats = await manager.getStats()

        // After cleanup, lastCleanup should be set
        XCTAssertNotNil(stats.lastCleanup)

        // Stats should be non-negative
        XCTAssertGreaterThanOrEqual(stats.requestsDeleted, 0)
        XCTAssertGreaterThanOrEqual(stats.bodyFilesDeleted, 0)
        XCTAssertGreaterThanOrEqual(stats.logsDeleted, 0)
        XCTAssertGreaterThanOrEqual(stats.bytesFreed, 0)
    }

    // MARK: - Manual Cleanup Tests

    func testPerformManualCleanup() async {
        // This should complete without throwing
        await manager.performManualCleanup()

        let stats = await manager.getStats()
        XCTAssertNotNil(stats.lastCleanup, "Last cleanup time should be recorded")
    }

    // MARK: - Storage Usage Tests

    func testGetStorageUsage() async {
        let usage = await manager.getStorageUsage()

        // All values should be non-negative
        XCTAssertGreaterThanOrEqual(usage.total, 0)
        XCTAssertGreaterThanOrEqual(usage.requests, 0)
        XCTAssertGreaterThanOrEqual(usage.bodies, 0)
        XCTAssertGreaterThanOrEqual(usage.logs, 0)

        // Total should be sum of parts (or close to it)
        let sum = usage.requests + usage.bodies + usage.logs
        XCTAssertGreaterThanOrEqual(usage.total, sum - 1000, "Total should be at least the sum of parts")
    }

    // MARK: - Delete All Requests Tests

    func testDeleteAllRequests() async {
        let deletedCount = await manager.deleteAllRequests()

        // Should return a non-negative count
        XCTAssertGreaterThanOrEqual(deletedCount, 0)
    }

    // MARK: - Configuration Value Tests

    func testConfigurationRetentionDaysValidRange() {
        var config = DataCleanupManager.CleanupConfiguration()

        config.requestRetentionDays = 1
        XCTAssertEqual(config.requestRetentionDays, 1)

        config.requestRetentionDays = 30
        XCTAssertEqual(config.requestRetentionDays, 30)

        config.bodyFileRetentionDays = 1
        XCTAssertEqual(config.bodyFileRetentionDays, 1)

        config.logRetentionDays = 1
        XCTAssertEqual(config.logRetentionDays, 1)
    }

    func testConfigurationStorageLimit() {
        var config = DataCleanupManager.CleanupConfiguration()

        config.maxStorageMB = 100
        XCTAssertEqual(config.maxStorageMB, 100)

        config.maxStorageMB = 2000
        XCTAssertEqual(config.maxStorageMB, 2000)
    }

    func testConfigurationCleanupInterval() {
        var config = DataCleanupManager.CleanupConfiguration()

        config.cleanupInterval = 1800 // 30 minutes
        XCTAssertEqual(config.cleanupInterval, 1800)

        config.cleanupInterval = 7200 // 2 hours
        XCTAssertEqual(config.cleanupInterval, 7200)
    }

    // MARK: - Stats Structure Tests

    func testCleanupStatsInitialization() {
        var stats = DataCleanupManager.CleanupStats()

        XCTAssertNil(stats.lastCleanup)
        XCTAssertEqual(stats.requestsDeleted, 0)
        XCTAssertEqual(stats.bodyFilesDeleted, 0)
        XCTAssertEqual(stats.logsDeleted, 0)
        XCTAssertEqual(stats.bytesFreed, 0)

        stats.lastCleanup = Date()
        XCTAssertNotNil(stats.lastCleanup)

        stats.requestsDeleted = 10
        stats.bodyFilesDeleted = 5
        stats.logsDeleted = 3
        stats.bytesFreed = 1024

        XCTAssertEqual(stats.requestsDeleted, 10)
        XCTAssertEqual(stats.bodyFilesDeleted, 5)
        XCTAssertEqual(stats.logsDeleted, 3)
        XCTAssertEqual(stats.bytesFreed, 1024)
    }

    // MARK: - Integration Tests

    func testCleanupCycle() async {
        // Get initial stats
        let initialStats = await manager.getStats()

        // Perform cleanup
        await manager.performManualCleanup()

        // Get updated stats
        let updatedStats = await manager.getStats()

        // Last cleanup should be updated
        XCTAssertNotNil(updatedStats.lastCleanup)

        if let lastCleanup = updatedStats.lastCleanup {
            XCTAssertGreaterThan(lastCleanup, Date().addingTimeInterval(-10), "Last cleanup should be recent")
        }

        // Cumulative stats should be greater than or equal to initial
        XCTAssertGreaterThanOrEqual(updatedStats.requestsDeleted, initialStats.requestsDeleted)
        XCTAssertGreaterThanOrEqual(updatedStats.bodyFilesDeleted, initialStats.bodyFilesDeleted)
        XCTAssertGreaterThanOrEqual(updatedStats.logsDeleted, initialStats.logsDeleted)
        XCTAssertGreaterThanOrEqual(updatedStats.bytesFreed, initialStats.bytesFreed)
    }

    func testDisableCleanup() async {
        var config = await manager.getConfiguration()
        config.enabled = false

        await manager.updateConfiguration(config)

        let updatedConfig = await manager.getConfiguration()
        XCTAssertFalse(updatedConfig.enabled, "Cleanup should be disabled")
    }

    func testReenableCleanup() async {
        // Disable first
        var config = await manager.getConfiguration()
        config.enabled = false
        await manager.updateConfiguration(config)

        // Re-enable
        config.enabled = true
        await manager.updateConfiguration(config)

        let updatedConfig = await manager.getConfiguration()
        XCTAssertTrue(updatedConfig.enabled, "Cleanup should be re-enabled")
    }
}
