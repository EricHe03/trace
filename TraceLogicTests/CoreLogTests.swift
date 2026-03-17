//
//  CoreLogTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import OSLog
@testable import TraceCore
import XCTest

final class CoreLogTests: XCTestCase {
    // MARK: - Logger Creation Tests

    func testStorageLoggerCreation() {
        let logger = CoreLog.storage
        XCTAssertNotNil(logger)
    }

    func testLifecycleLoggerCreation() {
        let logger = CoreLog.lifecycle
        XCTAssertNotNil(logger)
    }

    // MARK: - Logger Subsystem Tests

    func testLoggerSubsystemNaming() {
        // Test that loggers use the correct subsystem
        // CoreLog should use com.trace.TraceCore
        let expectedSubsystem = "com.trace.TraceCore"

        // Verify through TraceLog.Module
        let coreModule = TraceLog.Module.core
        XCTAssertEqual(coreModule.subsystem, expectedSubsystem)
    }

    // MARK: - Logger Category Tests

    func testStorageLoggerCategory() {
        // Storage logger should use the Storage category
        let expectedCategory = TraceLog.Category.storage.rawValue
        XCTAssertEqual(expectedCategory, "Storage")
    }

    func testLifecycleLoggerCategory() {
        // Lifecycle logger should use the Lifecycle category
        let expectedCategory = TraceLog.Category.lifecycle.rawValue
        XCTAssertEqual(expectedCategory, "Lifecycle")
    }

    // MARK: - LogEvent Domain Extension Tests

    func testStorageLogEventCreation() {
        let event = LogEvent.storage("save")
        let description = event.description

        XCTAssertTrue(description.contains("event=storage.save"))
    }

    func testStorageLogEventWithOutcome() {
        let event = LogEvent.storage("load")
            .success()
        let description = event.description

        XCTAssertTrue(description.contains("event=storage.load"))
        XCTAssertTrue(description.contains("outcome=success"))
    }

    func testStorageLogEventWithMetadata() {
        let event = LogEvent.storage("save")
            .success()
            .count(5)
            .with("file", value: "test.json")
        let description = event.description

        XCTAssertTrue(description.contains("event=storage.save"))
        XCTAssertTrue(description.contains("outcome=success"))
        XCTAssertTrue(description.contains("count=5"))
        XCTAssertTrue(description.contains("file=test.json"))
    }

    func testLifecycleLogEventCreation() {
        let event = LogEvent.lifecycle("init")
        let description = event.description

        XCTAssertTrue(description.contains("event=lifecycle.init"))
    }

    func testLifecycleLogEventWithOutcome() {
        let event = LogEvent.lifecycle("teardown")
            .failure()
        let description = event.description

        XCTAssertTrue(description.contains("event=lifecycle.teardown"))
        XCTAssertTrue(description.contains("outcome=failure"))
    }

    func testLifecycleLogEventWithError() {
        struct TestError: Error, CustomStringConvertible {
            var description: String {
                "test error"
            }
        }

        let event = LogEvent.lifecycle("init")
            .failure()
            .error(TestError())
        let description = event.description

        XCTAssertTrue(description.contains("event=lifecycle.init"))
        XCTAssertTrue(description.contains("outcome=failure"))
        XCTAssertTrue(description.contains("error="))
    }

    // MARK: - Module Integration Tests

    func testCoreModuleEnumValue() {
        let module = TraceLog.Module.core
        XCTAssertEqual(module.rawValue, "TraceCore")
    }

    func testCategoryEnumValues() {
        XCTAssertEqual(TraceLog.Category.storage.rawValue, "Storage")
        XCTAssertEqual(TraceLog.Category.lifecycle.rawValue, "Lifecycle")
    }

    // MARK: - Logging Behavior Tests

    func testLoggerAcceptsAllLevels() {
        // Test that logger can be called with all log levels without crashing
        let logger = CoreLog.storage

        logger.debug("debug message")
        logger.info("info message")
        logger.warning("warning message")
        logger.error("error message")
        logger.fault("fault message")
    }

    func testLoggerAcceptsLogEvents() {
        // Test that logger can log LogEvent objects
        let logger = CoreLog.storage
        let event = LogEvent.storage("test").success()

        logger.info(event)
        logger.debug(event)
        logger.warning(event)
        logger.error(event)
        logger.fault(event)
    }

    // MARK: - Edge Cases

    func testEmptyActionLogEvent() {
        let event = LogEvent.storage("")
        let description = event.description

        XCTAssertTrue(description.contains("event=storage."))
    }

    func testVeryLongActionName() {
        let longAction = String(repeating: "a", count: 1000)
        let event = LogEvent.storage(longAction)
        let description = event.description

        XCTAssertTrue(description.contains("event=storage."))
        XCTAssertTrue(description.contains(longAction))
    }

    func testSpecialCharactersInLogEvent() {
        let event = LogEvent.storage("test")
            .with("key", value: "value=with=equals")
            .with("key2", value: "value with spaces")
        let description = event.description

        XCTAssertTrue(description.contains("key=value=with=equals"))
        XCTAssertTrue(description.contains("key2=value with spaces"))
    }

    func testMultipleMetadataFields() {
        let event = LogEvent.storage("test")
            .success()
            .count(10)
            .with("file", value: "test.json")
            .with("path", value: "/tmp/test")
            .duration(ms: 150)
        let description = event.description

        XCTAssertTrue(description.contains("event=storage.test"))
        XCTAssertTrue(description.contains("outcome=success"))
        XCTAssertTrue(description.contains("count=10"))
        XCTAssertTrue(description.contains("file=test.json"))
        XCTAssertTrue(description.contains("path=/tmp/test"))
        XCTAssertTrue(description.contains("duration_ms=150"))
    }

    // MARK: - Concurrent Logging Tests

    func testConcurrentLogging() async {
        let logger = CoreLog.storage

        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 100 {
                group.addTask {
                    let event = LogEvent.storage("test").count(i)
                    logger.info(event)
                }
            }
        }
    }

    // MARK: - Performance Tests

    func testLogEventCreationPerformance() {
        measure {
            for i in 0 ..< 1000 {
                let event = LogEvent.storage("test")
                    .success()
                    .count(i)
                    .with("key", value: "value")
                _ = event.description
            }
        }
    }

    func testLoggingPerformance() {
        let logger = CoreLog.storage

        measure {
            for i in 0 ..< 1000 {
                let event = LogEvent.storage("test").count(i)
                logger.info(event)
            }
        }
    }
}
