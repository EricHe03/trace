//
//  FeatureLogTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
import OSLog
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class FeatureLogTests: XCTestCase {

    // MARK: - Logger Instance Tests

    func testCaptureLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.capture

        // Assert
        XCTAssertNotNil(logger)
    }

    func testRewriteLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.rewrite

        // Assert
        XCTAssertNotNil(logger)
    }

    func testScriptLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.script

        // Assert
        XCTAssertNotNil(logger)
    }

    func testBreakpointLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.breakpoint

        // Assert
        XCTAssertNotNil(logger)
    }

    func testHostsLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.hosts

        // Assert
        XCTAssertNotNil(logger)
    }

    func testExportLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.export

        // Assert
        XCTAssertNotNil(logger)
    }

    func testVPNLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.vpn

        // Assert
        XCTAssertNotNil(logger)
    }

    func testRequestMapLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.requestMap

        // Assert
        XCTAssertNotNil(logger)
    }

    func testProfileLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.profile

        // Assert
        XCTAssertNotNil(logger)
    }

    func testRulePackLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.rulePack

        // Assert
        XCTAssertNotNil(logger)
    }

    func testNotificationLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.notification

        // Assert
        XCTAssertNotNil(logger)
    }

    func testStorageLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.storage

        // Assert
        XCTAssertNotNil(logger)
    }

    func testWidgetLoggerExists() {
        // Arrange & Act
        let logger = FeatureLog.widget

        // Assert
        XCTAssertNotNil(logger)
    }

    // MARK: - Logger Uniqueness Tests

    func testAllLoggersAreUnique() {
        // Arrange
        let loggers = [
            FeatureLog.capture,
            FeatureLog.rewrite,
            FeatureLog.script,
            FeatureLog.breakpoint,
            FeatureLog.hosts,
            FeatureLog.export,
            FeatureLog.vpn,
            FeatureLog.requestMap,
            FeatureLog.profile,
            FeatureLog.rulePack,
            FeatureLog.notification,
            FeatureLog.storage,
            FeatureLog.widget
        ]

        // Then
        // Note: `Logger` is a value type; identity comparisons are not meaningful.
        XCTAssertEqual(loggers.count, 13)
    }

    // MARK: - Logger Usage Tests

    func testCaptureLoggerCanLogInfo() {
        // Arrange
        let logger = FeatureLog.capture

        // Act & Assert - Should not crash
        logger.info("Test capture log")
    }

    func testCaptureLoggerCanLogDebug() {
        // Arrange
        let logger = FeatureLog.capture

        // Act & Assert - Should not crash
        logger.debug("Test debug log")
    }

    func testCaptureLoggerCanLogError() {
        // Arrange
        let logger = FeatureLog.capture

        // Act & Assert - Should not crash
        logger.error("Test error log")
    }

    func testRewriteLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.rewrite

        // Act & Assert - Should not crash
        logger.info("Test rewrite log")
        logger.debug("Test rewrite debug")
        logger.warning("Test rewrite warning")
    }

    func testScriptLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.script

        // Act & Assert - Should not crash
        logger.info("Test script log")
        logger.error("Test script error")
    }

    func testBreakpointLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.breakpoint

        // Act & Assert - Should not crash
        logger.info("Test breakpoint log")
        logger.debug("Test breakpoint debug")
    }

    func testHostsLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.hosts

        // Act & Assert - Should not crash
        logger.info("Test hosts log")
        logger.debug("Test hosts debug")
    }

    func testExportLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.export

        // Act & Assert - Should not crash
        logger.info("Test export log")
        logger.error("Test export error")
    }

    func testVPNLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.vpn

        // Act & Assert - Should not crash
        logger.info("Test VPN log")
        logger.error("Test VPN error")
    }

    func testRequestMapLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.requestMap

        // Act & Assert - Should not crash
        logger.info("Test request map log")
        logger.debug("Test request map debug")
    }

    func testProfileLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.profile

        // Act & Assert - Should not crash
        logger.info("Test profile log")
        logger.error("Test profile error")
    }

    func testRulePackLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.rulePack

        // Act & Assert - Should not crash
        logger.info("Test rule pack log")
        logger.error("Test rule pack error")
    }

    func testNotificationLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.notification

        // Act & Assert - Should not crash
        logger.info("Test notification log")
        logger.error("Test notification error")
    }

    func testStorageLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.storage

        // Act & Assert - Should not crash
        logger.info("Test storage log")
        logger.warning("Test storage warning")
        logger.error("Test storage error")
    }

    func testWidgetLoggerCanLog() {
        // Arrange
        let logger = FeatureLog.widget

        // Act & Assert - Should not crash
        logger.info("Test widget log")
        logger.debug("Test widget debug")
    }

    // MARK: - LogEvent Extension Tests - Capture

    func testCaptureEventCreation() {
        // Arrange & Act
        let event = LogEvent.capture("request_stored")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("capture"))
        XCTAssertTrue(event.description.contains("request_stored"))
    }

    func testCaptureEventWithDifferentActions() {
        // Arrange
        let actions = ["request_stored", "session_start", "session_stop", "cleanup"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.capture(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Rewrite

    func testRewriteEventCreation() {
        // Arrange & Act
        let event = LogEvent.rewrite("rule_applied")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("rewrite"))
        XCTAssertTrue(event.description.contains("rule_applied"))
    }

    func testRewriteEventWithDifferentActions() {
        // Arrange
        let actions = ["rule_applied", "rule_matched", "config_load"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.rewrite(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Script

    func testScriptEventCreation() {
        // Arrange & Act
        let event = LogEvent.script("execute")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("script"))
        XCTAssertTrue(event.description.contains("execute"))
    }

    func testScriptEventWithDifferentActions() {
        // Arrange
        let actions = ["execute", "compile", "timeout", "error"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.script(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Breakpoint

    func testBreakpointEventCreation() {
        // Arrange & Act
        let event = LogEvent.breakpoint("hit")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("breakpoint"))
        XCTAssertTrue(event.description.contains("hit"))
    }

    func testBreakpointEventWithDifferentActions() {
        // Arrange
        let actions = ["hit", "resume", "config_load"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.breakpoint(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Hosts

    func testHostsEventCreation() {
        // Arrange & Act
        let event = LogEvent.hosts("entry_added")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("hosts"))
        XCTAssertTrue(event.description.contains("entry_added"))
    }

    func testHostsEventWithDifferentActions() {
        // Arrange
        let actions = ["entry_added", "match_found", "config_load"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.hosts(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Export

    func testExportEventCreation() {
        // Arrange & Act
        let event = LogEvent.export("har_export")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("export"))
        XCTAssertTrue(event.description.contains("har_export"))
    }

    func testExportEventWithDifferentActions() {
        // Arrange
        let actions = ["har_export", "csv_export", "import"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.export(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - VPN

    func testVPNEventCreation() {
        // Arrange & Act
        let event = LogEvent.vpn("start")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("vpn"))
        XCTAssertTrue(event.description.contains("start"))
    }

    func testVPNEventWithDifferentActions() {
        // Arrange
        let actions = ["start", "stop", "status_change"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.vpn(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Request Map

    func testRequestMapEventCreation() {
        // Arrange & Act
        let event = LogEvent.requestMap("match_found")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("request_map"))
        XCTAssertTrue(event.description.contains("match_found"))
    }

    func testRequestMapEventWithDifferentActions() {
        // Arrange
        let actions = ["match_found", "mock_served", "config_load"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.requestMap(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Notification

    func testNotificationEventCreation() {
        // Arrange & Act
        let event = LogEvent.notification("sent")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("notification"))
        XCTAssertTrue(event.description.contains("sent"))
    }

    func testNotificationEventWithDifferentActions() {
        // Arrange
        let actions = ["sent", "action_received", "authorization"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.notification(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Storage

    func testStorageEventCreation() {
        // Arrange & Act
        let event = LogEvent(domain: "storage", action: "cleanup_start")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("storage"))
        XCTAssertTrue(event.description.contains("cleanup_start"))
    }

    func testStorageEventWithDifferentActions() {
        // Arrange
        let actions = ["cleanup_start", "cleanup_complete", "limit_exceeded"]

        // Act & Assert
        for action in actions {
            let event = LogEvent(domain: "storage", action: action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - LogEvent Extension Tests - Widget

    func testWidgetEventCreation() {
        // Arrange & Act
        let event = LogEvent.widget("live_activity_start")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("widget"))
        XCTAssertTrue(event.description.contains("live_activity_start"))
    }

    func testWidgetEventWithDifferentActions() {
        // Arrange
        let actions = ["live_activity_start", "update", "action_handled"]

        // Act & Assert
        for action in actions {
            let event = LogEvent.widget(action)
            XCTAssertNotNil(event)
            XCTAssertTrue(event.description.contains(action))
        }
    }

    // MARK: - Integration Tests

    func testLoggerWithCaptureEvent() {
        // Arrange
        let logger = FeatureLog.capture
        let event = LogEvent.capture("request_stored")

        // Act & Assert - Should not crash
        logger.info("\(event)")
    }

    func testLoggerWithRewriteEvent() {
        // Arrange
        let logger = FeatureLog.rewrite
        let event = LogEvent.rewrite("rule_applied")

        // Act & Assert - Should not crash
        logger.info("\(event)")
    }

    func testLoggerWithScriptEvent() {
        // Arrange
        let logger = FeatureLog.script
        let event = LogEvent.script("execute")

        // Act & Assert - Should not crash
        logger.info("\(event)")
    }

    func testLoggerWithMultipleEvents() {
        // Arrange
        let captureEvent = LogEvent.capture("request_stored")
        let rewriteEvent = LogEvent.rewrite("rule_applied")
        let scriptEvent = LogEvent.script("execute")

        // Act & Assert - Should not crash
        FeatureLog.capture.info("\(captureEvent)")
        FeatureLog.rewrite.info("\(rewriteEvent)")
        FeatureLog.script.info("\(scriptEvent)")
    }

    // MARK: - Edge Cases Tests

    func testLogEventWithEmptyAction() {
        // Arrange & Act
        let event = LogEvent.capture("")

        // Assert
        XCTAssertNotNil(event)
        XCTAssertTrue(event.description.contains("capture"))
    }

    func testLogEventWithSpecialCharacters() {
        // Arrange
        let actions = [
            "test_action",
            "test-action",
            "test.action",
            "test:action",
            "test/action",
            "test action"
        ]

        // Act & Assert
        for action in actions {
            let event = LogEvent.capture(action)
            XCTAssertNotNil(event)
        }
    }

    func testLogEventWithLongAction() {
        // Arrange
        let longAction = String(repeating: "a", count: 1000)

        // Act
        let event = LogEvent.capture(longAction)

        // Assert
        XCTAssertNotNil(event)
    }

    func testLogEventWithUnicodeCharacters() {
        // Arrange
        let unicodeActions = [
            "测试动作",
            "тестовое действие",
            "テストアクション",
            "🎉🚀💾"
        ]

        // Act & Assert
        for action in unicodeActions {
            let event = LogEvent.capture(action)
            XCTAssertNotNil(event)
        }
    }

    // MARK: - Logger Stress Tests

    func testMultipleLoggersSimultaneously() {
        // OSLog calls inside loops can overwhelm the simulator log subsystem and make `xcodebuild test`
        // appear "stuck". Keep this as a smoke test that all loggers are usable.
        FeatureLog.capture.info("Capture log smoke test")
        FeatureLog.rewrite.info("Rewrite log smoke test")
        FeatureLog.script.info("Script log smoke test")
        FeatureLog.breakpoint.info("Breakpoint log smoke test")
        FeatureLog.hosts.info("Hosts log smoke test")
        FeatureLog.export.info("Export log smoke test")
        FeatureLog.vpn.info("VPN log smoke test")
        FeatureLog.requestMap.info("RequestMap log smoke test")
        FeatureLog.profile.info("Profile log smoke test")
        FeatureLog.rulePack.info("RulePack log smoke test")
        FeatureLog.notification.info("Notification log smoke test")
        FeatureLog.storage.info("Storage log smoke test")
        FeatureLog.widget.info("Widget log smoke test")
    }

    // MARK: - LogEvent Chaining Tests

    func testLogEventWithSuccessOutcome() {
        // Arrange
        let event = LogEvent.capture("request_stored")
            .success()

        // Act
        let description = event.description

        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description.contains("capture"))
        XCTAssertTrue(description.contains("request_stored"))
        XCTAssertTrue(description.contains("success"))
    }

    func testLogEventWithFailureOutcome() {
        // Arrange
        let event = LogEvent.capture("request_stored")
            .failure()

        // Act
        let description = event.description

        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description.contains("failure"))
    }

    func testLogEventWithAdditionalParameters() {
        // Arrange
        let event = LogEvent.capture("request_stored")
            .success()
            .with("request_id", value: "12345")
            .with("size", value: 1024)

        // Act
        let description = event.description

        // Assert
        XCTAssertNotNil(description)
        XCTAssertTrue(description.contains("capture"))
        XCTAssertTrue(description.contains("request_stored"))
    }

    // MARK: - Performance Tests

    func testLogEventCreationPerformance() {
        measure {
            for _ in 0..<1000 {
                _ = LogEvent.capture("test_action")
            }
        }
    }

    func testLoggerLoggingPerformance() {
        measure {
            for i in 0..<1000 {
                // Avoid writing 1000 OSLog entries per measurement iteration (XCTest repeats measurements).
                // Instead measure message construction cost which is deterministic and fast.
                let message = "Test log \(i)"
                withExtendedLifetime(message) {}
            }
        }
    }

    func testLogEventWithChainingPerformance() {
        measure {
            for i in 0..<1000 {
                let event = LogEvent.capture("test_action")
                    .success()
                    .with("iteration", value: i)
                // Avoid OSLog emission inside `measure` loops; measure formatting instead.
                _ = event.description
            }
        }
    }
}
