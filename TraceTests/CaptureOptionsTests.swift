//
//  CaptureOptionsTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class CaptureOptionsTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit() {
        let options = CaptureOptions(
            captureHeaders: true,
            captureBody: false,
            maxBodySize: 5 * 1024 * 1024
        )

        XCTAssertTrue(options.captureHeaders)
        XCTAssertFalse(options.captureBody)
        XCTAssertEqual(options.maxBodySize, 5 * 1024 * 1024)
    }

    func testDefaultValues() {
        let options = CaptureOptions.default

        XCTAssertTrue(options.captureHeaders)
        XCTAssertTrue(options.captureBody)
        XCTAssertEqual(options.maxBodySize, 10 * 1024 * 1024)
    }

    // MARK: - Normalized Tests

    func testNormalizedWithValidValues() {
        let options = CaptureOptions(
            captureHeaders: true,
            captureBody: true,
            maxBodySize: 5 * 1024 * 1024
        )

        let normalized = options.normalized()

        XCTAssertTrue(normalized.captureHeaders)
        XCTAssertTrue(normalized.captureBody)
        XCTAssertEqual(normalized.maxBodySize, 5 * 1024 * 1024)
    }

    func testNormalizedWithNegativeMaxBodySize() {
        let options = CaptureOptions(
            captureHeaders: true,
            captureBody: true,
            maxBodySize: -1000
        )

        let normalized = options.normalized()

        XCTAssertEqual(normalized.maxBodySize, 0)
    }

    func testNormalizedWithZeroMaxBodySize() {
        let options = CaptureOptions(
            captureHeaders: true,
            captureBody: true,
            maxBodySize: 0
        )

        let normalized = options.normalized()

        XCTAssertEqual(normalized.maxBodySize, 0)
    }

    // MARK: - Codable Tests

    func testCodable() throws {
        let options = CaptureOptions(
            captureHeaders: false,
            captureBody: true,
            maxBodySize: 2 * 1024 * 1024
        )

        let encoded = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(CaptureOptions.self, from: encoded)

        XCTAssertEqual(decoded.captureHeaders, options.captureHeaders)
        XCTAssertEqual(decoded.captureBody, options.captureBody)
        XCTAssertEqual(decoded.maxBodySize, options.maxBodySize)
    }

    // MARK: - Equatable Tests

    func testEquatable() {
        let options1 = CaptureOptions(
            captureHeaders: true,
            captureBody: true,
            maxBodySize: 5000
        )
        let options2 = CaptureOptions(
            captureHeaders: true,
            captureBody: true,
            maxBodySize: 5000
        )
        let options3 = CaptureOptions(
            captureHeaders: false,
            captureBody: true,
            maxBodySize: 5000
        )

        XCTAssertEqual(options1, options2)
        XCTAssertNotEqual(options1, options3)
    }

    // MARK: - Edge Cases

    func testExtremeMaxBodySize() {
        let options = CaptureOptions(
            captureHeaders: true,
            captureBody: true,
            maxBodySize: Int.max
        )

        let normalized = options.normalized()

        XCTAssertEqual(normalized.maxBodySize, Int.max)
    }

    func testAllFlagsDisabled() {
        let options = CaptureOptions(
            captureHeaders: false,
            captureBody: false,
            maxBodySize: 0
        )

        XCTAssertFalse(options.captureHeaders)
        XCTAssertFalse(options.captureBody)
        XCTAssertEqual(options.maxBodySize, 0)
    }
}
