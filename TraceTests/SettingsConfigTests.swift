//
//  SettingsConfigTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/24.
//

import XCTest
@testable import TraceCore

final class SettingsConfigTests: XCTestCase {
    func testSamplingConfigNormalization() {
        let config = SamplingConfig(enabled: true, sampleRate: 2.5, strategy: .random)
        let normalized = config.normalized()
        XCTAssertEqual(normalized.sampleRate, 1.0)
    }

    func testBodyStorageConfigNormalization() {
        let config = BodyStorageConfig(inlineThreshold: -1, truncationThreshold: 100, previewSize: 500)
        let normalized = config.normalized()
        XCTAssertEqual(normalized.inlineThreshold, 1)
        XCTAssertEqual(normalized.truncationThreshold, 100)
        XCTAssertEqual(normalized.previewSize, 100)
    }

    func testDomainPatternValidation() {
        XCTAssertTrue(Validation.isValidDomainPattern("example.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("*.example.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("exa mple.com"))
        XCTAssertFalse(Validation.isValidDomainPattern(""))
    }

    func testIPAddressValidation() {
        XCTAssertTrue(Validation.isValidIPAddress("8.8.8.8"))
        XCTAssertTrue(Validation.isValidIPAddress("2001:4860:4860::8888"))
        XCTAssertFalse(Validation.isValidIPAddress("999.1.1.1"))
        XCTAssertFalse(Validation.isValidIPAddress("not-an-ip"))
    }
}
