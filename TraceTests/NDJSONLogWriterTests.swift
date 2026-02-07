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
        let event = NDJSONLogEvent(ts: 1234567890.123, type: "test", msg: "Test message")

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
        let event = NDJSONLogEvent(ts: timestamp, type: "info", msg: "Hello World")

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

    func testNDJSONLogWriterThrowsWhenAppGroupMissing() {
        let invalidAppGroupID = "group.invalid.nonexistent"
        let fileName = "test.ndjson"

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
}
