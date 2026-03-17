//
//  TraceLogTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
import OSLog
@testable import TraceCore

final class TraceLogTests: XCTestCase {

    // MARK: - Logger Factory Tests

    func testMakeLoggerWithModuleAndCategory() {
        let logger = TraceLog.make(module: .core, category: .storage)
        XCTAssertNotNil(logger)
    }

    func testMakeLoggerWithStrings() {
        let logger = TraceLog.make(module: "CustomModule", category: "CustomCategory")
        XCTAssertNotNil(logger)
    }

    func testBaseSubsystem() {
        XCTAssertEqual(TraceLog.baseSubsystem, "com.trace")
    }

    // MARK: - Module Tests

    func testModuleRawValues() {
        XCTAssertEqual(TraceLog.Module.core.rawValue, "TraceCore")
        XCTAssertEqual(TraceLog.Module.vpn.rawValue, "TraceVPN")
        XCTAssertEqual(TraceLog.Module.networking.rawValue, "TraceNetworking")
        XCTAssertEqual(TraceLog.Module.security.rawValue, "TraceSecurity")
        XCTAssertEqual(TraceLog.Module.features.rawValue, "TraceFeatures")
        XCTAssertEqual(TraceLog.Module.proxy.rawValue, "TraceProxy")
        XCTAssertEqual(TraceLog.Module.compression.rawValue, "TraceCompression")
        XCTAssertEqual(TraceLog.Module.ui.rawValue, "TraceUI")
        XCTAssertEqual(TraceLog.Module.app.rawValue, "Trace")
        XCTAssertEqual(TraceLog.Module.widget.rawValue, "TraceWidget")
    }

    func testModuleSubsystem() {
        XCTAssertEqual(TraceLog.Module.core.subsystem, "com.trace.TraceCore")
        XCTAssertEqual(TraceLog.Module.vpn.subsystem, "com.trace.TraceVPN")
        XCTAssertEqual(TraceLog.Module.networking.subsystem, "com.trace.TraceNetworking")
        XCTAssertEqual(TraceLog.Module.security.subsystem, "com.trace.TraceSecurity")
    }

    func testModuleCaseIterable() {
        let allModules = TraceLog.Module.allCases
        XCTAssertEqual(allModules.count, 10)
        XCTAssertTrue(allModules.contains(.core))
        XCTAssertTrue(allModules.contains(.vpn))
        XCTAssertTrue(allModules.contains(.networking))
    }

    // MARK: - Category Tests

    func testCategoryRawValues() {
        XCTAssertEqual(TraceLog.Category.vpnTunnel.rawValue, "VPN.Tunnel")
        XCTAssertEqual(TraceLog.Category.vpnProxy.rawValue, "VPN.Proxy")
        XCTAssertEqual(TraceLog.Category.networkingHTTP.rawValue, "Networking.HTTP")
        XCTAssertEqual(TraceLog.Category.networkingHTTP2.rawValue, "Networking.HTTP2")
        XCTAssertEqual(TraceLog.Category.securityTLS.rawValue, "Security.TLS")
        XCTAssertEqual(TraceLog.Category.storage.rawValue, "Storage")
        XCTAssertEqual(TraceLog.Category.lifecycle.rawValue, "Lifecycle")
    }

    func testCategoryCaseIterable() {
        let allCategories = TraceLog.Category.allCases
        XCTAssertGreaterThan(allCategories.count, 20)
        XCTAssertTrue(allCategories.contains(.storage))
        XCTAssertTrue(allCategories.contains(.lifecycle))
    }

    func testCategoryHierarchicalNaming() {
        // Test that categories follow hierarchical naming
        XCTAssertTrue(TraceLog.Category.vpnTunnel.rawValue.hasPrefix("VPN."))
        XCTAssertTrue(TraceLog.Category.networkingHTTP.rawValue.hasPrefix("Networking."))
        XCTAssertTrue(TraceLog.Category.securityTLS.rawValue.hasPrefix("Security."))
        XCTAssertTrue(TraceLog.Category.proxyMITM.rawValue.hasPrefix("Proxy."))
    }

    // MARK: - LogEvent Tests

    func testLogEventBasicCreation() {
        let event = LogEvent(domain: "test", action: "action")
        let description = event.description

        XCTAssertTrue(description.contains("event=test.action"))
    }

    func testLogEventWithSuccess() {
        let event = LogEvent(domain: "test", action: "action").success()
        let description = event.description

        XCTAssertTrue(description.contains("event=test.action"))
        XCTAssertTrue(description.contains("outcome=success"))
    }

    func testLogEventWithFailure() {
        let event = LogEvent(domain: "test", action: "action").failure()
        let description = event.description

        XCTAssertTrue(description.contains("event=test.action"))
        XCTAssertTrue(description.contains("outcome=failure"))
    }

    func testLogEventWithSkipped() {
        let event = LogEvent(domain: "test", action: "action").outcome(.skipped)
        let description = event.description

        XCTAssertTrue(description.contains("event=test.action"))
        XCTAssertTrue(description.contains("outcome=skipped"))
    }

    func testLogEventWithPending() {
        let event = LogEvent(domain: "test", action: "action").outcome(.pending)
        let description = event.description

        XCTAssertTrue(description.contains("event=test.action"))
        XCTAssertTrue(description.contains("outcome=pending"))
    }

    func testLogEventWithKeyValue() {
        let event = LogEvent(domain: "test", action: "action")
            .with("key", value: "value")
        let description = event.description

        XCTAssertTrue(description.contains("key=value"))
    }

    func testLogEventWithMultipleKeyValues() {
        let event = LogEvent(domain: "test", action: "action")
            .with("key1", value: "value1")
            .with("key2", value: "value2")
            .with("key3", value: "value3")
        let description = event.description

        XCTAssertTrue(description.contains("key1=value1"))
        XCTAssertTrue(description.contains("key2=value2"))
        XCTAssertTrue(description.contains("key3=value3"))
    }

    func testLogEventWithPublicPrivacy() {
        let event = LogEvent(domain: "test", action: "action")
            .with("key", value: "value", privacy: .public)
        let description = event.description

        XCTAssertTrue(description.contains("key=value"))
        XCTAssertFalse(description.contains("<redacted>"))
    }

    func testLogEventWithPrivatePrivacy() {
        let event = LogEvent(domain: "test", action: "action")
            .with("key", value: "sensitive", privacy: .private)
        let description = event.description

        XCTAssertTrue(description.contains("key=<redacted>"))
        XCTAssertFalse(description.contains("sensitive"))
    }

    func testLogEventWithHashPrivacy() {
        let event = LogEvent(domain: "test", action: "action")
            .with("key", value: "value", privacy: .hash)
        let description = event.description

        XCTAssertTrue(description.contains("key="))
        XCTAssertFalse(description.contains("key=value"))
        // Hash should be 16 hex characters
        let components = description.components(separatedBy: "key=")
        if components.count > 1 {
            let hashPart = components[1].components(separatedBy: " ")[0]
            XCTAssertEqual(hashPart.count, 16)
        }
    }

    func testLogEventWithOptionalValue() {
        let event1 = LogEvent(domain: "test", action: "action")
            .with("key", value: "value" as String?)
        let description1 = event1.description
        XCTAssertTrue(description1.contains("key=value"))

        let event2 = LogEvent(domain: "test", action: "action")
            .with("key", value: nil as String?)
        let description2 = event2.description
        XCTAssertFalse(description2.contains("key="))
    }

    func testLogEventWithError() {
        struct TestError: Error, CustomStringConvertible {
            var description: String { "test error" }
        }

        let event = LogEvent(domain: "test", action: "action")
            .error(TestError())
        let description = event.description

        XCTAssertTrue(description.contains("error=test error"))
    }

    func testLogEventWithErrorCode() {
        let event = LogEvent(domain: "test", action: "action")
            .errorCode(404)
        let description = event.description

        XCTAssertTrue(description.contains("error_code=404"))
    }

    func testLogEventWithDuration() {
        let event = LogEvent(domain: "test", action: "action")
            .duration(ms: 150)
        let description = event.description

        XCTAssertTrue(description.contains("duration_ms=150"))
    }

    func testLogEventWithDurationSinceDate() {
        let start = Date()
        Thread.sleep(forTimeInterval: 0.1)
        let event = LogEvent(domain: "test", action: "action")
            .duration(since: start)
        let description = event.description

        XCTAssertTrue(description.contains("duration_ms="))
    }

    func testLogEventWithAttempt() {
        let event = LogEvent(domain: "test", action: "action")
            .attempt(3)
        let description = event.description

        XCTAssertTrue(description.contains("attempt=3"))
    }

    func testLogEventWithCount() {
        let event = LogEvent(domain: "test", action: "action")
            .count(42)
        let description = event.description

        XCTAssertTrue(description.contains("count=42"))
    }

    func testLogEventChaining() {
        let event = LogEvent(domain: "test", action: "action")
            .success()
            .count(10)
            .duration(ms: 100)
            .attempt(1)
            .with("key", value: "value")
        let description = event.description

        XCTAssertTrue(description.contains("event=test.action"))
        XCTAssertTrue(description.contains("outcome=success"))
        XCTAssertTrue(description.contains("count=10"))
        XCTAssertTrue(description.contains("duration_ms=100"))
        XCTAssertTrue(description.contains("attempt=1"))
        XCTAssertTrue(description.contains("key=value"))
    }

    // MARK: - LogRateLimiter Tests

    func testLogRateLimiterFirstAttempt() {
        let limiter = LogRateLimiter(maxRetries: 3)
        let level = limiter.levelForAttempt(1, isFinal: false)

        XCTAssertEqual(level, .default)
    }

    func testLogRateLimiterIntermediateAttempt() {
        let limiter = LogRateLimiter(maxRetries: 5)
        let level = limiter.levelForAttempt(3, isFinal: false)

        XCTAssertEqual(level, .debug)
    }

    func testLogRateLimiterFinalAttempt() {
        let limiter = LogRateLimiter(maxRetries: 3)
        let level = limiter.levelForAttempt(3, isFinal: true)

        XCTAssertEqual(level, .error)
    }

    func testLogRateLimiterSequence() {
        let limiter = LogRateLimiter(maxRetries: 4)

        XCTAssertEqual(limiter.levelForAttempt(1, isFinal: false), .default)
        XCTAssertEqual(limiter.levelForAttempt(2, isFinal: false), .debug)
        XCTAssertEqual(limiter.levelForAttempt(3, isFinal: false), .debug)
        XCTAssertEqual(limiter.levelForAttempt(4, isFinal: true), .error)
    }

    // MARK: - LogSampler Tests

    func testLogSamplerSharedInstance() {
        let shared = LogSampler.shared
        XCTAssertNotNil(shared)
    }

    func testLogSamplerFirstEvents() {
        let sampler = LogSampler()

        XCTAssertTrue(sampler.shouldLog(key: "test", first: 3, every: 100))
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 3, every: 100))
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 3, every: 100))
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 3, every: 100))
    }

    func testLogSamplerEveryN() {
        let sampler = LogSampler()

        // First 2 should log
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 2, every: 5))
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 2, every: 5))

        // Next 4 should not log
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 2, every: 5))
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 2, every: 5))
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 2, every: 5))
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 2, every: 5))

        // 5th after first burst should log
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 2, every: 5))
    }

    func testLogSamplerDifferentKeys() {
        let sampler = LogSampler()

        XCTAssertTrue(sampler.shouldLog(key: "key1", first: 1, every: 100))
        XCTAssertTrue(sampler.shouldLog(key: "key2", first: 1, every: 100))
        XCTAssertFalse(sampler.shouldLog(key: "key1", first: 1, every: 100))
        XCTAssertFalse(sampler.shouldLog(key: "key2", first: 1, every: 100))
    }

    func testLogSamplerNamespaced() {
        let sampler = LogSampler()

        XCTAssertTrue(sampler.shouldLog(event: "http", key: "request", first: 2, every: 5))
        XCTAssertTrue(sampler.shouldLog(event: "http", key: "request", first: 2, every: 5))
        XCTAssertFalse(sampler.shouldLog(event: "http", key: "request", first: 2, every: 5))
    }

    func testLogSamplerZeroFirst() {
        let sampler = LogSampler()

        // With first=0, should only log every Nth
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 0, every: 2))
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 0, every: 2))
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 0, every: 2))
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 0, every: 2))
    }

    func testLogSamplerZeroEvery() {
        let sampler = LogSampler()

        // With every=0, should only log first N
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 2, every: 0))
        XCTAssertTrue(sampler.shouldLog(key: "test", first: 2, every: 0))
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 2, every: 0))
        XCTAssertFalse(sampler.shouldLog(key: "test", first: 2, every: 0))
    }

    // MARK: - Logger Extension Tests

    func testLoggerInfoWithEvent() {
        let logger = TraceLog.make(module: .core, category: .storage)
        let event = LogEvent(domain: "test", action: "action").success()

        // Should not crash
        logger.info(event)
    }

    func testLoggerDebugWithEvent() {
        let logger = TraceLog.make(module: .core, category: .storage)
        let event = LogEvent(domain: "test", action: "action")

        logger.debug(event)
    }

    func testLoggerWarningWithEvent() {
        let logger = TraceLog.make(module: .core, category: .storage)
        let event = LogEvent(domain: "test", action: "action")

        logger.warning(event)
    }

    func testLoggerErrorWithEvent() {
        let logger = TraceLog.make(module: .core, category: .storage)
        let event = LogEvent(domain: "test", action: "action").failure()

        logger.error(event)
    }

    func testLoggerFaultWithEvent() {
        let logger = TraceLog.make(module: .core, category: .storage)
        let event = LogEvent(domain: "test", action: "action").failure()

        logger.fault(event)
    }

    // MARK: - Edge Cases

    func testLogEventEmptyDomain() {
        let event = LogEvent(domain: "", action: "action")
        let description = event.description

        XCTAssertTrue(description.contains("event=.action"))
    }

    func testLogEventEmptyAction() {
        let event = LogEvent(domain: "test", action: "")
        let description = event.description

        XCTAssertTrue(description.contains("event=test."))
    }

    func testLogEventSpecialCharacters() {
        let event = LogEvent(domain: "test", action: "action")
            .with("key", value: "value=with=special!@#$")
        let description = event.description

        XCTAssertTrue(description.contains("key=value=with=special!@#$"))
    }

    func testLogEventVeryLongValue() {
        let longValue = String(repeating: "a", count: 10000)
        let event = LogEvent(domain: "test", action: "action")
            .with("key", value: longValue)
        let description = event.description

        XCTAssertTrue(description.contains("key="))
        XCTAssertTrue(description.contains(longValue))
    }

    func testLogEventNumberValues() {
        let event = LogEvent(domain: "test", action: "action")
            .with("int", value: 42)
            .with("double", value: 3.14)
            .with("bool", value: true)
        let description = event.description

        XCTAssertTrue(description.contains("int=42"))
        XCTAssertTrue(description.contains("double=3.14"))
        XCTAssertTrue(description.contains("bool=true"))
    }

    // MARK: - Concurrent Tests

    func testConcurrentLogEventCreation() async {
        await withTaskGroup(of: String.self) { group in
            for i in 0..<100 {
                group.addTask {
                    LogEvent(domain: "test", action: "action")
                        .success()
                        .count(i)
                        .description
                }
            }

            var results: [String] = []
            for await result in group {
                results.append(result)
            }

            XCTAssertEqual(results.count, 100)
        }
    }

    func testConcurrentLogging() async {
        let logger = TraceLog.make(module: .core, category: .storage)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let event = LogEvent(domain: "test", action: "action").count(i)
                    logger.info(event)
                }
            }
        }
    }

    // MARK: - Performance Tests

    func testLogEventCreationPerformance() {
        measure {
            for i in 0..<1000 {
                _ = LogEvent(domain: "test", action: "action")
                    .success()
                    .count(i)
                    .with("key", value: "value")
                    .duration(ms: 100)
                    .description
            }
        }
    }

    func testLoggingPerformance() {
        let logger = TraceLog.make(module: .core, category: .storage)

        measure {
            for i in 0..<1000 {
                let event = LogEvent(domain: "test", action: "action").count(i)
                logger.info(event)
            }
        }
    }

    func testLogRateLimiterPerformance() {
        let limiter = LogRateLimiter(maxRetries: 5)

        measure {
            for i in 1...1000 {
                _ = limiter.levelForAttempt(i % 5 + 1, isFinal: i % 5 == 4)
            }
        }
    }

    func testLogSamplerPerformance() {
        let sampler = LogSampler()

        measure {
            for i in 0..<1000 {
                _ = sampler.shouldLog(key: "test-\(i % 10)", first: 3, every: 100)
            }
        }
    }
}
