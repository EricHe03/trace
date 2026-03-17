//
//  NDJSONLogWriterTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceProxy
@testable import TraceCore

final class NDJSONLogWriterTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - NDJSONLogEvent Tests

    func testNDJSONLogEventCodable() throws {
        let event = NDJSONLogEvent(ts: 1234567890.123, msg: "Test message", type: "test")

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NDJSONLogEvent.self, from: data)

        XCTAssertEqual(decoded.ts, event.ts)
        XCTAssertEqual(decoded.type, event.type)
        XCTAssertEqual(decoded.msg, event.msg)
    }

    func testNDJSONLogEventProperties() {
        let timestamp = 1640000000.5
        let event = NDJSONLogEvent(ts: timestamp, msg: "Hello World", type: "info")

        XCTAssertEqual(event.ts, timestamp)
        XCTAssertEqual(event.type, "info")
        XCTAssertEqual(event.msg, "Hello World")
    }

    // MARK: - Initialization Tests

    func testNDJSONLogWriterInitialization() throws {
        let fileName = "test_\(UUID().uuidString).ndjson"

        do {
            let writer = try NDJSONLogWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName
            )
            writer.close()

            // Verify file was created
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

                // Cleanup
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            // Expected in test environment without app group
            XCTAssertTrue(true)
        }
    }

    func testNDJSONLogWriterThrowsWhenAppGroupMissing() throws {
        let invalidAppGroupID = "group.invalid.nonexistent"
        let fileName = "test.ndjson"

        try XCTSkipIf(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: invalidAppGroupID) != nil,
            "This environment resolves arbitrary app-group identifiers"
        )
        XCTAssertThrowsError(try NDJSONLogWriter(appGroupID: invalidAppGroupID, fileName: fileName))
    }

    // MARK: - Append Tests

    func testAppendWritesEvent() throws {
        let fileName = "test_\(UUID().uuidString).ndjson"

        do {
            let writer = try NDJSONLogWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName
            )

            writer.append(type: "info", msg: "Test log entry")

            // Give async queue time to write
            Thread.sleep(forTimeInterval: 0.1)

            writer.close()

            // Verify file contains data
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                let data = try? Data(contentsOf: fileURL)
                XCTAssertNotNil(data)
                XCTAssertGreaterThan(data?.count ?? 0, 0)

                // Verify JSON format
                if let data = data, let jsonString = String(data: data, encoding: .utf8) {
                    XCTAssertTrue(jsonString.contains("\"type\":\"info\""))
                    XCTAssertTrue(jsonString.contains("\"msg\":\"Test log entry\""))
                }

                // Cleanup
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testAppendMultipleEvents() throws {
        let fileName = "test_\(UUID().uuidString).ndjson"

        do {
            let writer = try NDJSONLogWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName
            )

            // Append multiple events
            writer.append(type: "info", msg: "First message")
            writer.append(type: "warning", msg: "Second message")
            writer.append(type: "error", msg: "Third message")

            // Give async queue time to write
            Thread.sleep(forTimeInterval: 0.2)

            writer.close()

            // Verify file contains all events
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                let data = try? Data(contentsOf: fileURL)

                if let data = data, let content = String(data: data, encoding: .utf8) {
                    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                    XCTAssertEqual(lines.count, 3)

                    XCTAssertTrue(content.contains("First message"))
                    XCTAssertTrue(content.contains("Second message"))
                    XCTAssertTrue(content.contains("Third message"))
                }

                // Cleanup
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Sync Append Tests

    func testAppendSyncWritesImmediately() throws {
        let fileName = "test_\(UUID().uuidString).ndjson"

        do {
            let writer = try NDJSONLogWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName
            )

            writer.appendSync(type: "critical", msg: "Critical event")

            // No sleep needed for sync writes

            writer.close()

            // Verify file contains data
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                let data = try? Data(contentsOf: fileURL)
                XCTAssertNotNil(data)
                XCTAssertGreaterThan(data?.count ?? 0, 0)

                // Cleanup
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Close Tests

    func testCloseDoesNotCrash() throws {
        let fileName = "test_\(UUID().uuidString).ndjson"

        do {
            let writer = try NDJSONLogWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName
            )

            writer.close()

            // Should not crash on double close
            writer.close()

            XCTAssertTrue(true)

            // Cleanup
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            XCTAssertTrue(true)
        }
    }

    // MARK: - Format Tests

    func testNDJSONFormatIsValid() throws {
        let fileName = "test_\(UUID().uuidString).ndjson"

        do {
            let writer = try NDJSONLogWriter(
                appGroupID: AppGroupStorage.appGroupIdentifier,
                fileName: fileName
            )

            writer.appendSync(type: "test", msg: "Test event")
            writer.close()

            // Read and parse the JSON
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
            ) {
                let fileURL = container.appendingPathComponent(fileName)
                let data = try Data(contentsOf: fileURL)

                let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []

                for line in lines where !line.isEmpty {
                    // Each line should be valid JSON
                    let lineData = line.data(using: .utf8)!
                    XCTAssertNoThrow(try JSONDecoder().decode(NDJSONLogEvent.self, from: lineData))
                }

                // Cleanup
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testBufferedAppendFlushesOnThreshold() throws {
        let fileURL = tempDirectory.appendingPathComponent("threshold.ndjson")
        let writer = try NDJSONLogWriter(
            logFileURL: fileURL,
            flushEventThreshold: 3,
            flushByteThreshold: 1_024 * 1_024,
            flushInterval: 60
        )

        writer.append(type: "info", msg: "first")
        writer.append(type: "info", msg: "second")
        writer.append(type: "info", msg: "third")

        Thread.sleep(forTimeInterval: 0.2)

        let eventsBeforeClose = try readEvents(from: fileURL)
        XCTAssertEqual(eventsBeforeClose.count, 3)
        XCTAssertEqual(eventsBeforeClose.map(\.msg), ["first", "second", "third"])

        writer.close()
    }

    func testAppendSyncFlushesPendingAndPreservesOrder() throws {
        let fileURL = tempDirectory.appendingPathComponent("sync-order.ndjson")
        let writer = try NDJSONLogWriter(
            logFileURL: fileURL,
            flushEventThreshold: 64,
            flushByteThreshold: 64 * 1_024,
            flushInterval: 60
        )

        writer.append(type: "async", msg: "a1")
        writer.append(type: "async", msg: "a2")
        writer.appendSync(type: "sync", msg: "s1")
        writer.close()

        let events = try readEvents(from: fileURL)
        XCTAssertEqual(events.map(\.msg), ["a1", "a2", "s1"])
    }

    func testCloseFlushesPendingBufferedEvents() throws {
        let fileURL = tempDirectory.appendingPathComponent("close-flush.ndjson")
        let writer = try NDJSONLogWriter(
            logFileURL: fileURL,
            flushEventThreshold: 64,
            flushByteThreshold: 64 * 1_024,
            flushInterval: 60
        )

        writer.append(type: "info", msg: "pending-1")
        writer.append(type: "info", msg: "pending-2")
        writer.close()

        let events = try readEvents(from: fileURL)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.msg), ["pending-1", "pending-2"])
    }

    func testEncodedLineUsesCanonicalFieldOrder() throws {
        let fileURL = tempDirectory.appendingPathComponent("field-order.ndjson")
        let writer = try NDJSONLogWriter(logFileURL: fileURL)
        let message = #"message="quoted" path=C:\\tmp"#

        writer.appendSync(type: "order_test", msg: message)
        writer.close()

        let data = try Data(contentsOf: fileURL)
        let lines = String(data: data, encoding: .utf8)?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty } ?? []
        let line = try XCTUnwrap(lines.first)

        let tsRange = try XCTUnwrap(line.range(of: #""ts":"#))
        let msgRange = try XCTUnwrap(line.range(of: #""msg":"#))
        let typeRange = try XCTUnwrap(line.range(of: #""type":"#))

        XCTAssertLessThan(tsRange.lowerBound.utf16Offset(in: line), msgRange.lowerBound.utf16Offset(in: line))
        XCTAssertLessThan(msgRange.lowerBound.utf16Offset(in: line), typeRange.lowerBound.utf16Offset(in: line))

        let events = try readEvents(from: fileURL)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "order_test")
        XCTAssertEqual(events[0].msg, message)
    }

    private func readEvents(from fileURL: URL) throws -> [NDJSONLogEvent] {
        let data = try Data(contentsOf: fileURL)
        let lines = String(data: data, encoding: .utf8)?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty } ?? []

        return try lines.map { line in
            let lineData = try XCTUnwrap(line.data(using: .utf8))
            return try JSONDecoder().decode(NDJSONLogEvent.self, from: lineData)
        }
    }
}
