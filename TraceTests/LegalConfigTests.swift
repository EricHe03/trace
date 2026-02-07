//
//  LegalConfigTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class LegalConfigTests: XCTestCase {

    // MARK: - Privacy Policy Tests

    func testPrivacyPolicyEffectiveDate() {
        let date = LegalConfig.privacyPolicyEffectiveDate

        XCTAssertFalse(date.isEmpty)
        XCTAssertEqual(date, "January 14, 2026")
    }

    func testPrivacyPolicyEffectiveDateFormat() {
        let date = LegalConfig.privacyPolicyEffectiveDate

        // Verify it contains expected components
        XCTAssertTrue(date.contains("2026"))
        XCTAssertTrue(date.contains("January"))
    }
}
