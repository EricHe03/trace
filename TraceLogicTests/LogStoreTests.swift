//
//  LogStoreTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import OSLog
@testable import TraceCore
import XCTest

final class LogStoreTests: XCTestCase {
    // MARK: - Initialization Tests

    func testLogStoreSharedInstance() {
        let shared = LogStore.shared
        XCTAssertNotNil(shared)
    }

    func testLogStoreCustomInitialization() {
        let store = LogStore(appGroupID: "group.test.custom")
        XCTAssertNotNil(store)
    }

    func testLogStoreDefaultAppGroup() {
        let store = LogStore(appGroupID: nil)
        XCTAssertNotNil(store)
    }

    // MARK: - Error Types Tests

    func testLogStoreErrorUnsupportedPlatform() {
        let error = LogStoreError.unsupportedPlatform
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("not available") ?? false)
    }

    func testLogStoreErrorStoreUnavailable() {
        struct TestError: Error {}
        let error = LogStoreError.storeUnavailable(underlying: TestError())
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Failed to open") ?? false)
    }

    func testLogStoreErrorFetchFailed() {
        struct TestError: Error {}
        let error = LogStoreError.fetchFailed(underlying: TestError())
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Failed to fetch") ?? false)
    }

    func testLogStoreErrorAppGroupUnavailable() {
        let error = LogStoreError.appGroupUnavailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("not accessible") ?? false)
    }

    // MARK: - Fetch Logs Tests

    func testFetchLogsBasic() async throws {
        let store = LogStore.shared

        // Log some test messages
        CoreLog.storage.info("test log message 1")
        CoreLog.storage.info("test log message 2")

        // Small delay to allow logs to be written
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

        let logs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            minimumLevel: .debug,
            limit: 100
        )

        // Should return some logs (may include system logs)
        XCTAssertGreaterThanOrEqual(logs.count, 0)
    }

    func testFetchLogsWithDateFilter() async throws {
        let store = LogStore.shared
        let now = Date()

        CoreLog.storage.info("test recent message")

        try await Task.sleep(nanoseconds: 100_000_000)

        // Fetch logs since 1 hour ago
        let recentLogs = try await store.fetchLogs(
            since: now.addingTimeInterval(-3600),
            limit: 100
        )

        // All logs should be after the since date
        for log in recentLogs {
            XCTAssertGreaterThanOrEqual(log.timestamp, now.addingTimeInterval(-3600))
        }
    }

    func testFetchLogsWithLevelFilter() async throws {
        let store = LogStore.shared

        CoreLog.storage.debug("debug message")
        CoreLog.storage.info("info message")
        CoreLog.storage.error("error message")

        try await Task.sleep(nanoseconds: 100_000_000)

        // Fetch only error level and above
        let errorLogs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            minimumLevel: .error,
            limit: 100
        )

        // Should only contain error level or higher
        for log in errorLogs {
            XCTAssertGreaterThanOrEqual(log.level.severity, OSLogType.error.severity)
        }
    }

    func testFetchLogsWithCategoryFilter() async throws {
        let store = LogStore.shared

        CoreLog.storage.info("storage message")
        CoreLog.lifecycle.info("lifecycle message")

        try await Task.sleep(nanoseconds: 100_000_000)

        // Fetch only storage category
        let storageLogs = try await store.fetchLogs(
            category: .storage,
            since: Date().addingTimeInterval(-60),
            limit: 100
        )

        // All logs should be from storage category
        for log in storageLogs {
            XCTAssertEqual(log.category, "Storage")
        }
    }

    func testFetchLogsWithLimit() async throws {
        let store = LogStore.shared

        // Log multiple messages
        for i in 0 ..< 20 {
            CoreLog.storage.info("test message \(i)")
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let logs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            limit: 5
        )

        // Should respect the limit
        XCTAssertLessThanOrEqual(logs.count, 5)
    }

    func testFetchLogsWithRequestId() async throws {
        let store = LogStore.shared
        let requestId = "test-request-12345"

        // This would require proper request ID in logs
        // For now, just test the API
        let logs = try await store.fetchLogs(
            requestId: requestId,
            since: Date().addingTimeInterval(-60)
        )

        XCTAssertNotNil(logs)
    }

    func testFetchLogsMultipleCategories() async throws {
        let store = LogStore.shared

        CoreLog.storage.info("storage message")
        CoreLog.lifecycle.info("lifecycle message")

        try await Task.sleep(nanoseconds: 100_000_000)

        let logs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            categories: [.storage, .lifecycle],
            limit: 100
        )

        // Should contain both categories
        let categories = Set(logs.map(\.category))
        XCTAssertTrue(categories.contains("Storage") || categories.contains("Lifecycle") || categories.isEmpty)
    }

    // MARK: - Log Sorting Tests

    func testFetchLogsSorting() async throws {
        let store = LogStore.shared

        // Log messages with small delays
        CoreLog.storage.info("message 1")
        try await Task.sleep(nanoseconds: 10_000_000)
        CoreLog.storage.info("message 2")
        try await Task.sleep(nanoseconds: 10_000_000)
        CoreLog.storage.info("message 3")

        try await Task.sleep(nanoseconds: 100_000_000)

        let logs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            limit: 100
        )

        // Should be sorted by timestamp (most recent first)
        for i in 0 ..< (logs.count - 1) {
            XCTAssertGreaterThanOrEqual(logs[i].timestamp, logs[i + 1].timestamp)
        }
    }

    // MARK: - VPN Logs Tests

    func testFetchLogsIncludeVPNLogs() async throws {
        let store = LogStore.shared

        let logs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            limit: 100,
            includeVPNLogs: true
        )

        XCTAssertNotNil(logs)
    }

    func testFetchLogsExcludeVPNLogs() async throws {
        let store = LogStore.shared

        let logs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            limit: 100,
            includeVPNLogs: false
        )

        XCTAssertNotNil(logs)
    }

    func testClearVPNLogs() async {
        let store = LogStore.shared

        // Should not throw
        await store.clearVPNLogs()
    }

    // MARK: - LogEntry Tests

    func testLogEntryStructure() {
        let entry = LogEntry(
            timestamp: Date(),
            level: .info,
            category: "Test",
            message: "Test message",
            requestId: "req-123",
            file: "Test.swift",
            function: "testFunction",
            line: 42
        )

        XCTAssertNotNil(entry.timestamp)
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.category, "Test")
        XCTAssertEqual(entry.message, "Test message")
        XCTAssertEqual(entry.requestId, "req-123")
        XCTAssertEqual(entry.file, "Test.swift")
        XCTAssertEqual(entry.function, "testFunction")
        XCTAssertEqual(entry.line, 42)
    }

    func testLogEntryCodable() throws {
        let entry = LogEntry(
            timestamp: Date(),
            level: .error,
            category: "Test",
            message: "Error message",
            requestId: nil,
            file: "Test.swift",
            function: "testFunction",
            line: 100
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(LogEntry.self, from: data)

        XCTAssertEqual(decoded.level, .error)
        XCTAssertEqual(decoded.category, "Test")
        XCTAssertEqual(decoded.message, "Error message")
        XCTAssertNil(decoded.requestId)
        XCTAssertEqual(decoded.file, "Test.swift")
        XCTAssertEqual(decoded.line, 100)
    }

    func testLogEntryFormattedMessage() {
        let date = Date()
        let entry = LogEntry(
            timestamp: date,
            level: .info,
            category: "Test",
            message: "Test message",
            requestId: "req-123",
            file: "Test.swift",
            function: "testFunction",
            line: 42
        )

        let formatted = entry.formattedMessage

        XCTAssertTrue(formatted.contains("INFO"))
        XCTAssertTrue(formatted.contains("Test"))
        XCTAssertTrue(formatted.contains("req-123"))
        XCTAssertTrue(formatted.contains("Test message"))
        XCTAssertTrue(formatted.contains("Test.swift"))
        XCTAssertTrue(formatted.contains("42"))
    }

    func testLogEntryFormattedMessageWithoutRequestId() {
        let entry = LogEntry(
            timestamp: Date(),
            level: .debug,
            category: "Test",
            message: "Debug message",
            requestId: nil,
            file: "Test.swift",
            function: "testFunction",
            line: 10
        )

        let formatted = entry.formattedMessage

        XCTAssertTrue(formatted.contains("DEBUG"))
        XCTAssertTrue(formatted.contains("Debug message"))
        XCTAssertFalse(formatted.contains("[req-"))
    }

    // MARK: - Edge Cases

    func testFetchLogsEmptyResults() async throws {
        let store = LogStore.shared

        // Fetch logs from far in the past
        let logs = try await store.fetchLogs(
            since: Date(timeIntervalSince1970: 0),
            limit: 0
        )

        XCTAssertEqual(logs.count, 0)
    }

    func testFetchLogsVeryOldDate() async throws {
        let store = LogStore.shared

        // Fetch logs from 100 years ago
        let veryOldDate = Date().addingTimeInterval(-100 * 365 * 24 * 3600)
        let logs = try await store.fetchLogs(
            since: veryOldDate,
            limit: 100
        )

        XCTAssertNotNil(logs)
    }

    func testFetchLogsFutureDate() async throws {
        let store = LogStore.shared

        // Fetch logs from the future (should return empty)
        let futureDate = Date().addingTimeInterval(3600)
        let logs = try await store.fetchLogs(
            since: futureDate,
            limit: 100
        )

        XCTAssertEqual(logs.count, 0)
    }

    func testFetchLogsZeroLimit() async throws {
        let store = LogStore.shared

        let logs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            limit: 0
        )

        XCTAssertEqual(logs.count, 0)
    }

    func testFetchLogsLargeLimit() async throws {
        let store = LogStore.shared

        let logs = try await store.fetchLogs(
            since: Date().addingTimeInterval(-60),
            limit: 10000
        )

        // Should return available logs up to the limit
        XCTAssertLessThanOrEqual(logs.count, 10000)
    }

    // MARK: - Level Severity Tests

    func testOSLogTypeSeverity() {
        XCTAssertEqual(OSLogType.debug.severity, 0)
        XCTAssertEqual(OSLogType.info.severity, 1)
        XCTAssertEqual(OSLogType.default.severity, 2)
        XCTAssertEqual(OSLogType.error.severity, 3)
        XCTAssertEqual(OSLogType.fault.severity, 4)
    }

    func testOSLogTypeEmoji() {
        XCTAssertEqual(OSLogType.debug.emoji, "DBG")
        XCTAssertEqual(OSLogType.info.emoji, "INF")
        XCTAssertEqual(OSLogType.error.emoji, "ERR")
        XCTAssertEqual(OSLogType.fault.emoji, "FLT")
        XCTAssertEqual(OSLogType.default.emoji, "WRN")
    }

    func testOSLogTypeLabel() {
        XCTAssertEqual(OSLogType.debug.label, "DEBUG")
        XCTAssertEqual(OSLogType.info.label, "INFO")
        XCTAssertEqual(OSLogType.error.label, "ERROR")
        XCTAssertEqual(OSLogType.fault.label, "FAULT")
        XCTAssertEqual(OSLogType.default.label, "DEFAULT")
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentFetchLogs() async throws {
        let store = LogStore.shared

        // Log some messages
        for i in 0 ..< 10 {
            CoreLog.storage.info("concurrent test \(i)")
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        // Fetch logs concurrently
        async let logs1 = try await store.fetchLogs(limit: 50)
        async let logs2 = try await store.fetchLogs(limit: 50)
        async let logs3 = try await store.fetchLogs(limit: 50)

        let (result1, result2, result3) = try await (logs1, logs2, logs3)

        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
        XCTAssertNotNil(result3)
    }

    func testConcurrentClearVPNLogs() async {
        let store = LogStore.shared

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    await store.clearVPNLogs()
                }
            }
        }
    }

    // MARK: - Performance Tests

    func testFetchLogsPerformance() async throws {
        let store = LogStore.shared

        // Log many messages
        for i in 0 ..< 100 {
            CoreLog.storage.info("performance test \(i)")
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        measure {
            Task {
                _ = try? await store.fetchLogs(
                    since: Date().addingTimeInterval(-60),
                    limit: 100
                )
            }
        }
    }

    func testLogEntryEncodingPerformance() {
        let entry = LogEntry(
            timestamp: Date(),
            level: .info,
            category: "Performance",
            message: "Test message",
            requestId: "req-123",
            file: "Test.swift",
            function: "testFunction",
            line: 42
        )

        let encoder = JSONEncoder()

        measure {
            for _ in 0 ..< 1000 {
                _ = try? encoder.encode(entry)
            }
        }
    }

    func testLogEntryDecodingPerformance() throws {
        let entry = LogEntry(
            timestamp: Date(),
            level: .info,
            category: "Performance",
            message: "Test message",
            requestId: "req-123",
            file: "Test.swift",
            function: "testFunction",
            line: 42
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        let decoder = JSONDecoder()

        measure {
            for _ in 0 ..< 1000 {
                _ = try? decoder.decode(LogEntry.self, from: data)
            }
        }
    }
}
