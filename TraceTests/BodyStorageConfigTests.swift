//
//  BodyStorageConfigTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class BodyStorageConfigTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit() {
        let config = BodyStorageConfig(
            inlineThreshold: 512 * 1024,
            truncationThreshold: 5 * 1024 * 1024,
            previewSize: 256 * 1024
        )

        XCTAssertEqual(config.inlineThreshold, 512 * 1024)
        XCTAssertEqual(config.truncationThreshold, 5 * 1024 * 1024)
        XCTAssertEqual(config.previewSize, 256 * 1024)
    }

    func testDefaultValues() {
        let config = BodyStorageConfig.default

        XCTAssertEqual(config.inlineThreshold, 1024 * 1024)
        XCTAssertEqual(config.truncationThreshold, 10 * 1024 * 1024)
        XCTAssertEqual(config.previewSize, 1024 * 1024)
    }

    // MARK: - Normalized Tests

    func testNormalizedWithValidValues() {
        let config = BodyStorageConfig(
            inlineThreshold: 512 * 1024,
            truncationThreshold: 5 * 1024 * 1024,
            previewSize: 256 * 1024
        )

        let normalized = config.normalized()

        XCTAssertEqual(normalized.inlineThreshold, 512 * 1024)
        XCTAssertEqual(normalized.truncationThreshold, 5 * 1024 * 1024)
        XCTAssertEqual(normalized.previewSize, 256 * 1024)
    }

    func testNormalizedWithNegativeInlineThreshold() {
        let config = BodyStorageConfig(
            inlineThreshold: -100,
            truncationThreshold: 5 * 1024 * 1024,
            previewSize: 256 * 1024
        )

        let normalized = config.normalized()

        XCTAssertEqual(normalized.inlineThreshold, 1)
        XCTAssertGreaterThanOrEqual(normalized.truncationThreshold, normalized.inlineThreshold)
    }

    func testNormalizedWithTruncationSmallerThanInline() {
        let config = BodyStorageConfig(
            inlineThreshold: 5 * 1024 * 1024,
            truncationThreshold: 1 * 1024 * 1024,
            previewSize: 256 * 1024
        )

        let normalized = config.normalized()

        XCTAssertGreaterThanOrEqual(normalized.truncationThreshold, normalized.inlineThreshold)
    }

    func testNormalizedWithPreviewLargerThanTruncation() {
        let config = BodyStorageConfig(
            inlineThreshold: 1 * 1024 * 1024,
            truncationThreshold: 5 * 1024 * 1024,
            previewSize: 10 * 1024 * 1024
        )

        let normalized = config.normalized()

        XCTAssertLessThanOrEqual(normalized.previewSize, normalized.truncationThreshold)
    }

    func testNormalizedWithZeroPreview() {
        let config = BodyStorageConfig(
            inlineThreshold: 1 * 1024 * 1024,
            truncationThreshold: 5 * 1024 * 1024,
            previewSize: 0
        )

        let normalized = config.normalized()

        XCTAssertEqual(normalized.previewSize, 1)
    }

    // MARK: - Codable Tests

    func testCodable() throws {
        let config = BodyStorageConfig(
            inlineThreshold: 512 * 1024,
            truncationThreshold: 5 * 1024 * 1024,
            previewSize: 256 * 1024
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BodyStorageConfig.self, from: encoded)

        XCTAssertEqual(decoded.inlineThreshold, config.inlineThreshold)
        XCTAssertEqual(decoded.truncationThreshold, config.truncationThreshold)
        XCTAssertEqual(decoded.previewSize, config.previewSize)
    }

    // MARK: - Equatable Tests

    func testEquatable() {
        let config1 = BodyStorageConfig(
            inlineThreshold: 1024,
            truncationThreshold: 5000,
            previewSize: 500
        )
        let config2 = BodyStorageConfig(
            inlineThreshold: 1024,
            truncationThreshold: 5000,
            previewSize: 500
        )
        let config3 = BodyStorageConfig(
            inlineThreshold: 2048,
            truncationThreshold: 5000,
            previewSize: 500
        )

        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)
    }

    // MARK: - Edge Cases

    func testExtremeValues() {
        let config = BodyStorageConfig(
            inlineThreshold: Int.max,
            truncationThreshold: Int.max,
            previewSize: Int.max
        )

        let normalized = config.normalized()

        XCTAssertEqual(normalized.inlineThreshold, Int.max)
        XCTAssertEqual(normalized.truncationThreshold, Int.max)
        XCTAssertEqual(normalized.previewSize, Int.max)
    }
}
