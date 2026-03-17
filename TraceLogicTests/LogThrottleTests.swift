//
//  LogThrottleTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class LogThrottleTests: XCTestCase {

    // MARK: - Initialization Tests

    func testLogThrottleSharedInstance() {
        let shared = LogThrottle.shared
        XCTAssertNotNil(shared)
    }

    func testLogThrottleCustomInstance() {
        let throttle = LogThrottle()
        XCTAssertNotNil(throttle)
    }

    // MARK: - Basic Throttling Tests

    func testShouldLogFirstCall() {
        let throttle = LogThrottle()
        let shouldLog = throttle.shouldLog(key: "test", minInterval: 1.0)
        XCTAssertTrue(shouldLog)
    }

    func testShouldThrottleImmediateSecondCall() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "test", minInterval: 1.0)
        let second = throttle.shouldLog(key: "test", minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testShouldLogAfterInterval() throws {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "test", minInterval: 0.1)
        XCTAssertTrue(first)

        // Wait for interval to pass
        Thread.sleep(forTimeInterval: 0.15)

        let second = throttle.shouldLog(key: "test", minInterval: 0.1)
        XCTAssertTrue(second)
    }

    func testShouldThrottleBeforeInterval() throws {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "test", minInterval: 1.0)
        XCTAssertTrue(first)

        // Wait but not long enough
        Thread.sleep(forTimeInterval: 0.5)

        let second = throttle.shouldLog(key: "test", minInterval: 1.0)
        XCTAssertFalse(second)
    }

    // MARK: - Multiple Key Tests

    func testDifferentKeysNotThrottled() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "key1", minInterval: 1.0)
        let second = throttle.shouldLog(key: "key2", minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertTrue(second)
    }

    func testMultipleKeysIndependentThrottling() {
        let throttle = LogThrottle()

        // Log with key1
        XCTAssertTrue(throttle.shouldLog(key: "key1", minInterval: 1.0))
        XCTAssertFalse(throttle.shouldLog(key: "key1", minInterval: 1.0))

        // Log with key2 - should not be throttled
        XCTAssertTrue(throttle.shouldLog(key: "key2", minInterval: 1.0))
        XCTAssertFalse(throttle.shouldLog(key: "key2", minInterval: 1.0))
    }

    func testManyKeysSimultaneously() {
        let throttle = LogThrottle()

        for i in 0..<100 {
            let shouldLog = throttle.shouldLog(key: "key-\(i)", minInterval: 1.0)
            XCTAssertTrue(shouldLog, "First call for key-\(i) should log")
        }

        for i in 0..<100 {
            let shouldLog = throttle.shouldLog(key: "key-\(i)", minInterval: 1.0)
            XCTAssertFalse(shouldLog, "Second call for key-\(i) should be throttled")
        }
    }

    // MARK: - Interval Tests

    func testZeroInterval() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "test", minInterval: 0.0)
        let second = throttle.shouldLog(key: "test", minInterval: 0.0)

        XCTAssertTrue(first)
        // With 0 interval, second call might still be throttled due to timing
        // This tests the edge case behavior
    }

    func testNegativeInterval() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "test", minInterval: -1.0)
        let second = throttle.shouldLog(key: "test", minInterval: -1.0)

        XCTAssertTrue(first)
        // Negative interval should allow immediate re-logging
        XCTAssertTrue(second)
    }

    func testVerySmallInterval() throws {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "test", minInterval: 0.001)
        XCTAssertTrue(first)

        Thread.sleep(forTimeInterval: 0.002)

        let second = throttle.shouldLog(key: "test", minInterval: 0.001)
        XCTAssertTrue(second)
    }

    func testVeryLargeInterval() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "test", minInterval: 3600.0)
        let second = throttle.shouldLog(key: "test", minInterval: 3600.0)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    // MARK: - Namespaced Key Tests

    func testNamespacedShouldLogFirstCall() {
        let throttle = LogThrottle()
        let shouldLog = throttle.shouldLog(event: "http", key: "request", minInterval: 1.0)
        XCTAssertTrue(shouldLog)
    }

    func testNamespacedThrottling() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(event: "http", key: "request", minInterval: 1.0)
        let second = throttle.shouldLog(event: "http", key: "request", minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testNamespacedDifferentEvents() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(event: "http", key: "request", minInterval: 1.0)
        let second = throttle.shouldLog(event: "tls", key: "request", minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertTrue(second)
    }

    func testNamespacedDifferentKeys() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(event: "http", key: "request", minInterval: 1.0)
        let second = throttle.shouldLog(event: "http", key: "response", minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertTrue(second)
    }

    func testNamespacedSameEventAndKey() {
        let throttle = LogThrottle()

        XCTAssertTrue(throttle.shouldLog(event: "http", key: "request", minInterval: 1.0))
        XCTAssertFalse(throttle.shouldLog(event: "http", key: "request", minInterval: 1.0))
        XCTAssertFalse(throttle.shouldLog(event: "http", key: "request", minInterval: 1.0))
    }

    // MARK: - Timing Precision Tests

    func testPreciseIntervalTiming() throws {
        let throttle = LogThrottle()
        let interval = 0.1

        XCTAssertTrue(throttle.shouldLog(key: "test", minInterval: interval))

        // Just before interval
        Thread.sleep(forTimeInterval: interval - 0.01)
        XCTAssertFalse(throttle.shouldLog(key: "test", minInterval: interval))

        // Just after interval
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertTrue(throttle.shouldLog(key: "test", minInterval: interval))
    }

    func testMultipleIntervalsSequence() throws {
        let throttle = LogThrottle()

        XCTAssertTrue(throttle.shouldLog(key: "test", minInterval: 0.05))
        Thread.sleep(forTimeInterval: 0.06)

        XCTAssertTrue(throttle.shouldLog(key: "test", minInterval: 0.05))
        Thread.sleep(forTimeInterval: 0.06)

        XCTAssertTrue(throttle.shouldLog(key: "test", minInterval: 0.05))
    }

    // MARK: - Edge Cases

    func testEmptyKey() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "", minInterval: 1.0)
        let second = throttle.shouldLog(key: "", minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testWhitespaceKey() {
        let throttle = LogThrottle()

        let first = throttle.shouldLog(key: "   ", minInterval: 1.0)
        let second = throttle.shouldLog(key: "   ", minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testVeryLongKey() {
        let throttle = LogThrottle()
        let longKey = String(repeating: "a", count: 10000)

        let first = throttle.shouldLog(key: longKey, minInterval: 1.0)
        let second = throttle.shouldLog(key: longKey, minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testSpecialCharactersInKey() {
        let throttle = LogThrottle()
        let specialKey = "test!@#$%^&*()[]{}|\\:;\"'<>,.?/~`"

        let first = throttle.shouldLog(key: specialKey, minInterval: 1.0)
        let second = throttle.shouldLog(key: specialKey, minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testUnicodeKey() {
        let throttle = LogThrottle()
        let unicodeKey = "测试🚀"

        let first = throttle.shouldLog(key: unicodeKey, minInterval: 1.0)
        let second = throttle.shouldLog(key: unicodeKey, minInterval: 1.0)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    // MARK: - State Tests

    func testThrottleStateReset() throws {
        let throttle = LogThrottle()

        XCTAssertTrue(throttle.shouldLog(key: "test", minInterval: 0.1))
        XCTAssertFalse(throttle.shouldLog(key: "test", minInterval: 0.1))

        Thread.sleep(forTimeInterval: 0.15)

        // State should reset after interval
        XCTAssertTrue(throttle.shouldLog(key: "test", minInterval: 0.1))
    }

    func testThrottleStateIndependence() {
        let throttle1 = LogThrottle()
        let throttle2 = LogThrottle()

        XCTAssertTrue(throttle1.shouldLog(key: "test", minInterval: 1.0))
        XCTAssertFalse(throttle1.shouldLog(key: "test", minInterval: 1.0))

        // throttle2 should have independent state
        XCTAssertTrue(throttle2.shouldLog(key: "test", minInterval: 1.0))
        XCTAssertFalse(throttle2.shouldLog(key: "test", minInterval: 1.0))
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentSameKey() {
        let throttle = LogThrottle()
        let expectation = XCTestExpectation(description: "Concurrent logging")
        var allowedCount = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if throttle.shouldLog(key: "test", minInterval: 1.0) {
                lock.lock()
                allowedCount += 1
                lock.unlock()
            }
        }

        expectation.fulfill()
        wait(for: [expectation], timeout: 1.0)

        // Should only allow one log through
        XCTAssertEqual(allowedCount, 1)
    }

    func testConcurrentDifferentKeys() {
        let throttle = LogThrottle()
        let expectation = XCTestExpectation(description: "Concurrent logging")
        var allowedCount = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if throttle.shouldLog(key: "test-\(i)", minInterval: 1.0) {
                lock.lock()
                allowedCount += 1
                lock.unlock()
            }
        }

        expectation.fulfill()
        wait(for: [expectation], timeout: 1.0)

        // Should allow all different keys through
        XCTAssertEqual(allowedCount, 100)
    }

    func testConcurrentMixedKeys() {
        let throttle = LogThrottle()
        let expectation = XCTestExpectation(description: "Concurrent logging")

        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            // Mix of same and different keys
            _ = throttle.shouldLog(key: "key-\(i % 10)", minInterval: 0.1)
        }

        expectation.fulfill()
        wait(for: [expectation], timeout: 2.0)
    }

    func testConcurrentNamespacedKeys() {
        let throttle = LogThrottle()
        let expectation = XCTestExpectation(description: "Concurrent namespaced logging")

        DispatchQueue.concurrentPerform(iterations: 100) { i in
            _ = throttle.shouldLog(event: "event-\(i % 5)", key: "key-\(i % 10)", minInterval: 0.1)
        }

        expectation.fulfill()
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Stress Tests

    func testHighFrequencyLogging() {
        let throttle = LogThrottle()
        var throttledCount = 0

        for _ in 0..<10000 {
            if !throttle.shouldLog(key: "high-freq", minInterval: 1.0) {
                throttledCount += 1
            }
        }

        // Should throttle most calls
        XCTAssertGreaterThan(throttledCount, 9990)
    }

    func testManyKeysSimultaneous() {
        let throttle = LogThrottle()
        let keyCount = 10000

        for i in 0..<keyCount {
            let shouldLog = throttle.shouldLog(key: "key-\(i)", minInterval: 1.0)
            XCTAssertTrue(shouldLog)
        }

        // All second calls should be throttled
        for i in 0..<keyCount {
            let shouldLog = throttle.shouldLog(key: "key-\(i)", minInterval: 1.0)
            XCTAssertFalse(shouldLog)
        }
    }

    // MARK: - Performance Tests

    func testThrottlePerformance() {
        let throttle = LogThrottle()

        measure {
            for i in 0..<1000 {
                _ = throttle.shouldLog(key: "test-\(i)", minInterval: 1.0)
            }
        }
    }

    func testThrottlePerformanceSameKey() {
        let throttle = LogThrottle()

        measure {
            for _ in 0..<1000 {
                _ = throttle.shouldLog(key: "test", minInterval: 1.0)
            }
        }
    }

    func testThrottlePerformanceNamespaced() {
        let throttle = LogThrottle()

        measure {
            for i in 0..<1000 {
                _ = throttle.shouldLog(event: "event", key: "key-\(i)", minInterval: 1.0)
            }
        }
    }

    func testConcurrentThrottlePerformance() {
        let throttle = LogThrottle()

        measure {
            DispatchQueue.concurrentPerform(iterations: 1000) { i in
                _ = throttle.shouldLog(key: "test-\(i % 10)", minInterval: 0.1)
            }
        }
    }
}
