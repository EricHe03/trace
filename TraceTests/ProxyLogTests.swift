//
//  ProxyLogTests.swift
//  TraceTests
//
//  Created by Claude on 2026-02-01.
//

import XCTest
import OSLog
@testable import TraceProxy
@testable import TraceCore

final class ProxyLogTests: XCTestCase {
    // MARK: - Logger Initialization Tests

    func testMitmLoggerExists() {
        // Given / When
        let logger = ProxyLog.mitm

        // Then
        XCTAssertNotNil(logger)
    }

    func testInterceptorLoggerExists() {
        // Given / When
        let logger = ProxyLog.interceptor

        // Then
        XCTAssertNotNil(logger)
    }

    func testThrottlingLoggerExists() {
        // Given / When
        let logger = ProxyLog.throttling

        // Then
        XCTAssertNotNil(logger)
    }

    func testMetricsLoggerExists() {
        // Given / When
        let logger = ProxyLog.metrics

        // Then
        XCTAssertNotNil(logger)
    }

    // MARK: - Event Builder Tests

    func testProxyEventCreation() {
        // Given
        let action = "accept"

        // When
        let event = LogEvent.proxy(action)

        // Then
        XCTAssertEqual(event.domain, "proxy")
        XCTAssertEqual(event.action, action)
    }

    func testProxyEventWithDifferentActions() {
        // Given
        let actions = ["accept", "close", "forward", "reject"]

        for action in actions {
            // When
            let event = LogEvent.proxy(action)

            // Then
            XCTAssertEqual(event.domain, "proxy")
            XCTAssertEqual(event.action, action)
        }
    }

    func testInterceptEventCreation() {
        // Given
        let action = "request"

        // When
        let event = LogEvent.intercept(action)

        // Then
        XCTAssertEqual(event.domain, "intercept")
        XCTAssertEqual(event.action, action)
    }

    func testInterceptEventWithDifferentActions() {
        // Given
        let actions = ["request", "response", "bypass", "modify"]

        for action in actions {
            // When
            let event = LogEvent.intercept(action)

            // Then
            XCTAssertEqual(event.domain, "intercept")
            XCTAssertEqual(event.action, action)
        }
    }

    func testThrottleEventCreation() {
        // Given
        let action = "apply"

        // When
        let event = LogEvent.throttle(action)

        // Then
        XCTAssertEqual(event.domain, "throttle")
        XCTAssertEqual(event.action, action)
    }

    func testThrottleEventWithDifferentActions() {
        // Given
        let actions = ["apply", "delay", "profile_change", "remove"]

        for action in actions {
            // When
            let event = LogEvent.throttle(action)

            // Then
            XCTAssertEqual(event.domain, "throttle")
            XCTAssertEqual(event.action, action)
        }
    }

    // MARK: - Event Formatting Tests

    func testEventFormattedStringWithMetadata() {
        // Given
        let event = LogEvent.proxy("accept")

        // When
        let formatted = event.formatted

        // Then
        XCTAssertTrue(formatted.hasPrefix("event=proxy.accept"))
    }

    func testEventFormattedStringForIntercept() {
        // Given
        let event = LogEvent.intercept("request")

        // When
        let formatted = event.formatted

        // Then
        XCTAssertTrue(formatted.hasPrefix("event=intercept.request"))
    }

    func testEventFormattedStringForThrottle() {
        // Given
        let event = LogEvent.throttle("delay")

        // When
        let formatted = event.formatted

        // Then
        XCTAssertTrue(formatted.hasPrefix("event=throttle.delay"))
    }

    // MARK: - Edge Cases

    func testProxyEventWithEmptyAction() {
        // Given
        let action = ""

        // When
        let event = LogEvent.proxy(action)

        // Then
        XCTAssertEqual(event.domain, "proxy")
        XCTAssertEqual(event.action, "")
    }

    func testInterceptEventWithSpecialCharacters() {
        // Given
        let action = "action_with_underscores"

        // When
        let event = LogEvent.intercept(action)

        // Then
        XCTAssertEqual(event.domain, "intercept")
        XCTAssertEqual(event.action, action)
    }

    func testThrottleEventWithLongAction() {
        // Given
        let action = String(repeating: "a", count: 1000)

        // When
        let event = LogEvent.throttle(action)

        // Then
        XCTAssertEqual(event.domain, "throttle")
        XCTAssertEqual(event.action, action)
    }
}
