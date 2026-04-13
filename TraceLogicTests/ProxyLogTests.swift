//
//  ProxyLogTests.swift
//  TraceTests
//
//  Created by Justin on 2026-02-01.
//

import OSLog
@testable import TraceCore
@testable import TraceProxy
import XCTest

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
        XCTAssertTrue(String(describing: event).hasPrefix("event=proxy.\(action)"))
    }

    func testProxyEventWithDifferentActions() {
        // Given
        let actions = ["accept", "close", "forward", "reject"]

        for action in actions {
            // When
            let event = LogEvent.proxy(action)

            // Then
            XCTAssertTrue(String(describing: event).hasPrefix("event=proxy.\(action)"))
        }
    }

    func testInterceptEventCreation() {
        // Given
        let action = "request"

        // When
        let event = LogEvent.intercept(action)

        // Then
        XCTAssertTrue(String(describing: event).hasPrefix("event=intercept.\(action)"))
    }

    func testInterceptEventWithDifferentActions() {
        // Given
        let actions = ["request", "response", "bypass", "modify"]

        for action in actions {
            // When
            let event = LogEvent.intercept(action)

            // Then
            XCTAssertTrue(String(describing: event).hasPrefix("event=intercept.\(action)"))
        }
    }

    // MARK: - Event Formatting Tests

    func testEventFormattedStringWithMetadata() {
        // Given
        let event = LogEvent.proxy("accept")

        // When
        let formatted = String(describing: event)

        // Then
        XCTAssertTrue(formatted.hasPrefix("event=proxy.accept"))
    }

    func testEventFormattedStringForIntercept() {
        // Given
        let event = LogEvent.intercept("request")

        // When
        let formatted = String(describing: event)

        // Then
        XCTAssertTrue(formatted.hasPrefix("event=intercept.request"))
    }

    // MARK: - Edge Cases

    func testProxyEventWithEmptyAction() {
        // Given
        let action = ""

        // When
        let event = LogEvent.proxy(action)

        // Then
        XCTAssertTrue(String(describing: event).hasPrefix("event=proxy."))
    }

    func testInterceptEventWithSpecialCharacters() {
        // Given
        let action = "action_with_underscores"

        // When
        let event = LogEvent.intercept(action)

        // Then
        XCTAssertTrue(String(describing: event).hasPrefix("event=intercept.\(action)"))
    }

}
