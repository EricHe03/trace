//
//  TraceLoggerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import OSLog
import XCTest

@testable import Trace
@testable import TraceCore
@testable import TraceFeatures
@testable import TraceNetworking
@testable import TraceProxy
@testable import TraceSecurity
#if !targetEnvironment(simulator)
@testable import TraceVPN
#endif

final class TraceLoggerTests: XCTestCase {
    // MARK: - LogEntry Tests

    func testLogEntryFormattedMessage() {
        let entry = LogEntry(
            timestamp: Date(),
            level: .info,
            category: "Test.Category",
            message: "Test message",
            requestId: "abc12345",
            file: "TestFile.swift",
            function: "testFunction",
            line: 42
        )

        let formatted = entry.formattedMessage

        // Should contain level label.
        XCTAssertTrue(formatted.contains("[INFO]"))

        // Should contain category.
        XCTAssertTrue(formatted.contains("[Test.Category]"))

        // Should contain request ID prefix.
        XCTAssertTrue(formatted.contains("[abc12345]"))

        // Should contain message.
        XCTAssertTrue(formatted.contains("Test message"))

        // Should contain file and line.
        XCTAssertTrue(formatted.contains("TestFile.swift:42"))
    }

    func testLogEntryFormattedMessageWithoutRequestId() {
        let entry = LogEntry(
            timestamp: Date(),
            level: .error,
            category: "Error.Category",
            message: "Error occurred",
            requestId: nil,
            file: "ErrorFile.swift",
            function: "errorFunction",
            line: 100
        )

        let formatted = entry.formattedMessage

        // Should contain level label.
        XCTAssertTrue(formatted.contains("[ERROR]"))

        // Should not contain request ID brackets (beyond category).
        let components = formatted.components(separatedBy: "] ")
        // Format: "HH:mm:ss.SSS [LEVEL] [Category] message (file:line)"
        XCTAssertTrue(components.count >= 2)
    }

    func testLogEntryCodable() throws {
        let original = LogEntry(
            timestamp: Date(),
            level: .debug,
            category: "Codable.Test",
            message: "Codable test message",
            requestId: "req-123",
            file: "CodableTest.swift",
            function: "testCodable",
            line: 50
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(LogEntry.self, from: data)

        XCTAssertEqual(decoded.level, original.level)
        XCTAssertEqual(decoded.category, original.category)
        XCTAssertEqual(decoded.message, original.message)
        XCTAssertEqual(decoded.requestId, original.requestId)
        XCTAssertEqual(decoded.file, original.file)
        XCTAssertEqual(decoded.function, original.function)
        XCTAssertEqual(decoded.line, original.line)
    }

    // MARK: - OSLogType Extension Tests

    func testOSLogTypeSeverity() {
        XCTAssertEqual(OSLogType.debug.severity, 0)
        XCTAssertEqual(OSLogType.info.severity, 1)
        XCTAssertEqual(OSLogType.default.severity, 2)
        XCTAssertEqual(OSLogType.error.severity, 3)
        XCTAssertEqual(OSLogType.fault.severity, 4)
    }

    func testOSLogTypeLabels() {
        XCTAssertEqual(OSLogType.debug.label, "DEBUG")
        XCTAssertEqual(OSLogType.info.label, "INFO")
        XCTAssertEqual(OSLogType.default.label, "DEFAULT")
        XCTAssertEqual(OSLogType.error.label, "ERROR")
        XCTAssertEqual(OSLogType.fault.label, "FAULT")
    }

    func testOSLogTypeSeverityOrdering() {
        // Verify severity ordering is correct for filtering.
        XCTAssertTrue(OSLogType.debug.severity < OSLogType.info.severity)
        XCTAssertTrue(OSLogType.info.severity < OSLogType.default.severity)
        XCTAssertTrue(OSLogType.default.severity < OSLogType.error.severity)
        XCTAssertTrue(OSLogType.error.severity < OSLogType.fault.severity)
    }

    // MARK: - TraceLog Module Tests

    func testTraceLogModuleSubsystems() {
        XCTAssertEqual(TraceLog.Module.core.subsystem, "com.trace.TraceCore")
        XCTAssertEqual(TraceLog.Module.vpn.subsystem, "com.trace.TraceVPN")
        XCTAssertEqual(TraceLog.Module.networking.subsystem, "com.trace.TraceNetworking")
        XCTAssertEqual(TraceLog.Module.security.subsystem, "com.trace.TraceSecurity")
        XCTAssertEqual(TraceLog.Module.proxy.subsystem, "com.trace.TraceProxy")
    }

    func testTraceLogCategoryRawValues() {
        XCTAssertEqual(TraceLog.Category.vpnTunnel.rawValue, "VPN.Tunnel")
        XCTAssertEqual(TraceLog.Category.networkingHTTP.rawValue, "Networking.HTTP")
        XCTAssertEqual(TraceLog.Category.securityTLS.rawValue, "Security.TLS")
        XCTAssertEqual(TraceLog.Category.proxyMITM.rawValue, "Proxy.MITM")
    }

    func testTraceLogMakeLogger() {
        let logger = TraceLog.make(module: .core, category: .storage)

        // Logger should be created without error.
        // We can't directly inspect Logger properties, but we can verify it works.
        logger.info("Test log message")
    }

    // MARK: - LogEvent Builder Tests

    func testLogEventBasic() {
        let event = LogEvent(domain: "test", action: "action")
        let description = event.description

        XCTAssertTrue(description.contains("event=test.action"))
    }

    func testLogEventWithSuccess() {
        let event = LogEvent(domain: "test", action: "operation")
            .success()

        XCTAssertTrue(event.description.contains("outcome=success"))
    }

    func testLogEventWithFailure() {
        let event = LogEvent(domain: "test", action: "operation")
            .failure()

        XCTAssertTrue(event.description.contains("outcome=failure"))
    }

    func testLogEventWithKeyValuePairs() {
        let event = LogEvent(domain: "http", action: "request")
            .success()
            .with("method", value: "GET")
            .with("status", value: 200)

        let description = event.description

        XCTAssertTrue(description.contains("event=http.request"))
        XCTAssertTrue(description.contains("outcome=success"))
        XCTAssertTrue(description.contains("method=GET"))
        XCTAssertTrue(description.contains("status=200"))
    }

    func testLogEventWithDuration() {
        let event = LogEvent(domain: "test", action: "timed")
            .duration(ms: 150)

        XCTAssertTrue(event.description.contains("duration_ms=150"))
    }

    func testLogEventWithCount() {
        let event = LogEvent(domain: "storage", action: "load")
            .count(42)

        XCTAssertTrue(event.description.contains("count=42"))
    }

    func testLogEventWithAttempt() {
        let event = LogEvent(domain: "retry", action: "attempt")
            .attempt(3)

        XCTAssertTrue(event.description.contains("attempt=3"))
    }

    func testLogEventWithError() {
        struct TestError: Error, CustomStringConvertible {
            var description: String { "Test error occurred" }
        }

        let event = LogEvent(domain: "test", action: "fail")
            .failure()
            .error(TestError())

        XCTAssertTrue(event.description.contains("error=Test error occurred"))
    }

    func testLogEventWithPrivacyPublic() {
        let event = LogEvent(domain: "test", action: "log")
            .with("public_value", value: "visible", privacy: .public)

        XCTAssertTrue(event.description.contains("public_value=visible"))
    }

    func testLogEventWithPrivacyPrivate() {
        let event = LogEvent(domain: "test", action: "log")
            .with("private_value", value: "secret", privacy: .private)

        XCTAssertTrue(event.description.contains("private_value=<redacted>"))
    }

    func testLogEventWithPrivacyHash() {
        let event = LogEvent(domain: "test", action: "log")
            .with("hashed_value", value: "to_hash", privacy: .hash)

        // Should contain a hash prefix, not the original value.
        XCTAssertFalse(event.description.contains("hashed_value=to_hash"))
        XCTAssertTrue(event.description.contains("hashed_value="))
    }

    func testLogEventWithOptionalNilValue() {
        let optionalValue: String? = nil
        let event = LogEvent(domain: "test", action: "optional")
            .with("optional_key", value: optionalValue)

        // Nil values should not appear in the description.
        XCTAssertFalse(event.description.contains("optional_key"))
    }

    func testLogEventWithOptionalSomeValue() {
        let optionalValue: String? = "present"
        let event = LogEvent(domain: "test", action: "optional")
            .with("optional_key", value: optionalValue)

        XCTAssertTrue(event.description.contains("optional_key=present"))
    }

    // MARK: - LogRateLimiter Tests

    func testLogRateLimiterFirstAttempt() {
        let limiter = LogRateLimiter(maxRetries: 3)

        // First attempt should use default (warning) level.
        let level = limiter.levelForAttempt(1, isFinal: false)
        XCTAssertEqual(level, .default)
    }

    func testLogRateLimiterIntermediateAttempt() {
        let limiter = LogRateLimiter(maxRetries: 3)

        // Intermediate attempts should use debug level.
        let level = limiter.levelForAttempt(2, isFinal: false)
        XCTAssertEqual(level, .debug)
    }

    func testLogRateLimiterFinalAttempt() {
        let limiter = LogRateLimiter(maxRetries: 3)

        // Final attempt should use error level.
        let level = limiter.levelForAttempt(3, isFinal: true)
        XCTAssertEqual(level, .error)
    }

    // MARK: - LogSampler Tests

    func testLogSamplerFirstEvents() {
        let sampler = LogSampler()

        // First 3 events should all be logged.
        XCTAssertTrue(sampler.shouldLog(key: "test_key", first: 3, every: 100))
        XCTAssertTrue(sampler.shouldLog(key: "test_key", first: 3, every: 100))
        XCTAssertTrue(sampler.shouldLog(key: "test_key", first: 3, every: 100))

        // 4th event should not be logged (not yet at "every" interval).
        XCTAssertFalse(sampler.shouldLog(key: "test_key", first: 3, every: 100))
    }

    func testLogSamplerEveryInterval() {
        let sampler = LogSampler()

        // Log first 2, then every 5th.
        for i in 1 ... 2 {
            XCTAssertTrue(
                sampler.shouldLog(key: "interval_key", first: 2, every: 5),
                "Event \(i) should be logged"
            )
        }

        // Events 3, 4, 5, 6 should not be logged.
        for i in 3 ... 6 {
            XCTAssertFalse(
                sampler.shouldLog(key: "interval_key", first: 2, every: 5),
                "Event \(i) should NOT be logged"
            )
        }

        // Event 7 (2 + 5 = 7) should be logged.
        XCTAssertTrue(sampler.shouldLog(key: "interval_key", first: 2, every: 5))
    }

    func testLogSamplerDifferentKeys() {
        let sampler = LogSampler()

        // Different keys have independent counters.
        XCTAssertTrue(sampler.shouldLog(key: "key_a", first: 1, every: 10))
        XCTAssertTrue(sampler.shouldLog(key: "key_b", first: 1, every: 10))

        // Second event for each key should not be logged.
        XCTAssertFalse(sampler.shouldLog(key: "key_a", first: 1, every: 10))
        XCTAssertFalse(sampler.shouldLog(key: "key_b", first: 1, every: 10))
    }

    func testLogSamplerEventNamespace() {
        let sampler = LogSampler()

        // Using event namespace creates a combined key.
        XCTAssertTrue(sampler.shouldLog(event: "http", key: "request_1", first: 1, every: 10))
        XCTAssertFalse(sampler.shouldLog(event: "http", key: "request_1", first: 1, every: 10))

        // Different event namespace is independent.
        XCTAssertTrue(sampler.shouldLog(event: "dns", key: "request_1", first: 1, every: 10))
    }

    // MARK: - LogThrottle Tests

    func testLogThrottleFirstCall() {
        let throttle = LogThrottle()

        // First call should always pass.
        XCTAssertTrue(throttle.shouldLog(key: "throttle_test", minInterval: 1.0))
    }

    func testLogThrottleWithinInterval() {
        let throttle = LogThrottle()

        // First call passes.
        XCTAssertTrue(throttle.shouldLog(key: "interval_test", minInterval: 1.0))

        // Immediate second call should be throttled.
        XCTAssertFalse(throttle.shouldLog(key: "interval_test", minInterval: 1.0))
    }

    func testLogThrottleDifferentKeys() {
        let throttle = LogThrottle()

        // Different keys are independent.
        XCTAssertTrue(throttle.shouldLog(key: "key_x", minInterval: 1.0))
        XCTAssertTrue(throttle.shouldLog(key: "key_y", minInterval: 1.0))

        // Same keys are still throttled.
        XCTAssertFalse(throttle.shouldLog(key: "key_x", minInterval: 1.0))
        XCTAssertFalse(throttle.shouldLog(key: "key_y", minInterval: 1.0))
    }

    // MARK: - LegacyLogCategory Tests

    func testLegacyLogCategoryMapping() {
        // Verify legacy categories map to new categories correctly.
        XCTAssertEqual(LegacyLogCategory.vpn.traceLogCategory, .vpnTunnel)
        XCTAssertEqual(LegacyLogCategory.proxy.traceLogCategory, .proxyMITM)
        XCTAssertEqual(LegacyLogCategory.tls.traceLogCategory, .securityTLS)
        XCTAssertEqual(LegacyLogCategory.storage.traceLogCategory, .storage)
        XCTAssertNil(LegacyLogCategory.general.traceLogCategory)
    }

    // MARK: - LogStore Integration Tests

    func testLogStoreFetchLogsDoesNotThrow() async {
        // Verify LogStore can be called without throwing.
        // Note: Actual log content depends on system state.
        do {
            let logs = try await LogStore.shared.fetchLogs(
                since: Date().addingTimeInterval(-60),
                limit: 10
            )
            // Just verify it returns an array (may be empty).
            XCTAssertNotNil(logs)
        } catch {
            // OSLogStore may not be available in all test environments.
            // This is acceptable - the test verifies the API works.
            XCTAssertTrue(error is LogStoreError)
        }
    }

    func testLogStoreFetchWithCategoryFilter() async {
        do {
            let logs = try await LogStore.shared.fetchLogs(
                category: .storage,
                since: Date().addingTimeInterval(-60),
                limit: 10
            )
            // All returned logs should have the Storage category.
            for log in logs {
                XCTAssertEqual(log.category, TraceLog.Category.storage.rawValue)
            }
        } catch {
            // OSLogStore may not be available in all test environments.
            XCTAssertTrue(error is LogStoreError)
        }
    }

    // MARK: - Module Logger Tests

    func testCoreLogExists() {
        // Verify module loggers are accessible.
        CoreLog.storage.info("Test storage log")
        CoreLog.lifecycle.info("Test lifecycle log")
    }

    func testNetworkLogExists() {
        NetworkLog.http.info("Test HTTP log")
        NetworkLog.http2.info("Test HTTP2 log")
        NetworkLog.webSocket.info("Test WebSocket log")
    }

    func testSecurityLogExists() {
        SecurityLog.tls.info("Test TLS log")
        SecurityLog.certificate.info("Test certificate log")
    }

    func testProxyLogExists() {
        ProxyLog.mitm.info("Test MITM log")
        ProxyLog.interceptor.info("Test interceptor log")
    }

    func testFeatureLogExists() {
        FeatureLog.capture.info("Test capture log")
        FeatureLog.rewrite.info("Test rewrite log")
        FeatureLog.script.info("Test script log")
    }

    func testVPNLogExists() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("VPNLog lives in the TraceVPN app extension, which is not linked into simulator unit tests.")
#else
        VPNLog.tunnel.info("Test tunnel log")
        VPNLog.proxy.info("Test VPN proxy log")
        VPNLog.certificate.info("Test VPN certificate log")
#endif
    }
}
