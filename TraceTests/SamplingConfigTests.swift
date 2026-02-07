//
//  SamplingConfigTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class SamplingConfigTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit() {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: 0.5,
            strategy: .random
        )

        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.sampleRate, 0.5)
        XCTAssertEqual(config.strategy, .random)
    }

    func testDefaultValues() {
        let config = SamplingConfig()

        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.sampleRate, 1.0)
        XCTAssertEqual(config.strategy, .random)
    }

    func testStaticDefault() {
        let config = SamplingConfig.default

        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.sampleRate, 1.0)
        XCTAssertEqual(config.strategy, .random)
    }

    // MARK: - Normalized Tests

    func testNormalizedWithValidValues() {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: 0.5,
            strategy: .periodic
        )

        let normalized = config.normalized()

        XCTAssertTrue(normalized.enabled)
        XCTAssertEqual(normalized.sampleRate, 0.5)
        XCTAssertEqual(normalized.strategy, .periodic)
    }

    func testNormalizedWithRateTooLow() {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: -0.5,
            strategy: .random
        )

        let normalized = config.normalized()

        XCTAssertEqual(normalized.sampleRate, 0.0)
    }

    func testNormalizedWithRateTooHigh() {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: 1.5,
            strategy: .random
        )

        let normalized = config.normalized()

        XCTAssertEqual(normalized.sampleRate, 1.0)
    }

    func testNormalizedWithZeroRate() {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: 0.0,
            strategy: .random
        )

        let normalized = config.normalized()

        XCTAssertEqual(normalized.sampleRate, 0.0)
    }

    func testNormalizedWithOneRate() {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: 1.0,
            strategy: .random
        )

        let normalized = config.normalized()

        XCTAssertEqual(normalized.sampleRate, 1.0)
    }

    // MARK: - SamplingStrategy Tests

    func testSamplingStrategyRawValues() {
        XCTAssertEqual(SamplingStrategy.random.rawValue, "random")
        XCTAssertEqual(SamplingStrategy.periodic.rawValue, "periodic")
        XCTAssertEqual(SamplingStrategy.adaptive.rawValue, "adaptive")
    }

    func testSamplingStrategyFromRawValue() {
        XCTAssertEqual(SamplingStrategy(rawValue: "random"), .random)
        XCTAssertEqual(SamplingStrategy(rawValue: "periodic"), .periodic)
        XCTAssertEqual(SamplingStrategy(rawValue: "adaptive"), .adaptive)
    }

    // MARK: - Codable Tests

    func testCodable() throws {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: 0.75,
            strategy: .adaptive
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SamplingConfig.self, from: encoded)

        XCTAssertEqual(decoded.enabled, config.enabled)
        XCTAssertEqual(decoded.sampleRate, config.sampleRate)
        XCTAssertEqual(decoded.strategy, config.strategy)
    }

    func testCodableWithDifferentStrategies() throws {
        for strategy in [SamplingStrategy.random, .periodic, .adaptive] {
            let config = SamplingConfig(enabled: true, sampleRate: 0.5, strategy: strategy)

            let encoded = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(SamplingConfig.self, from: encoded)

            XCTAssertEqual(decoded.strategy, strategy)
        }
    }

    // MARK: - Equatable Tests

    func testEquatable() {
        let config1 = SamplingConfig(enabled: true, sampleRate: 0.5, strategy: .random)
        let config2 = SamplingConfig(enabled: true, sampleRate: 0.5, strategy: .random)
        let config3 = SamplingConfig(enabled: false, sampleRate: 0.5, strategy: .random)

        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)
    }

    // MARK: - Edge Cases

    func testExtremeValues() {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: Double.infinity,
            strategy: .random
        )

        let normalized = config.normalized()

        // Should clamp to 1.0
        XCTAssertEqual(normalized.sampleRate, 1.0)
    }

    func testNaNValue() {
        let config = SamplingConfig(
            enabled: true,
            sampleRate: Double.nan,
            strategy: .random
        )

        let normalized = config.normalized()

        // Should handle NaN gracefully
        XCTAssertTrue(normalized.sampleRate.isNaN || normalized.sampleRate >= 0.0)
    }
}
