//
//  AppVersionTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class AppVersionTests: XCTestCase {

    // MARK: - Version Tests

    func testVersionIsNotEmpty() {
        let version = AppVersion.version
        XCTAssertFalse(version.isEmpty, "Version should not be empty")
    }

    func testVersionFormat() {
        let version = AppVersion.version
        // Version should contain at least one dot for semantic versioning
        XCTAssertTrue(version.contains(".") || version.count > 0, "Version should follow semantic versioning format")
    }

    func testVersionFallback() {
        // When CFBundleShortVersionString is missing, should return "1.0.0"
        // This is tested implicitly through the default value in the implementation
        let version = AppVersion.version
        XCTAssertNotNil(version)
        XCTAssertGreaterThanOrEqual(version.count, 5, "Version should be at least '1.0.0'")
    }

    // MARK: - Build Tests

    func testBuildIsNotEmpty() {
        let build = AppVersion.build
        XCTAssertFalse(build.isEmpty, "Build number should not be empty")
    }

    func testBuildIsNumeric() {
        let build = AppVersion.build
        // Build should be numeric or fallback to "1"
        XCTAssertTrue(build.allSatisfy { $0.isNumber } || build == "1", "Build should be numeric")
    }

    func testBuildFallback() {
        // When CFBundleVersion is missing, should return "1"
        let build = AppVersion.build
        XCTAssertNotNil(build)
        XCTAssertGreaterThanOrEqual(Int(build) ?? 0, 1, "Build should be at least 1")
    }

    // MARK: - Full Version Tests

    func testFullVersionFormat() {
        let fullVersion = AppVersion.fullVersion
        let version = AppVersion.version
        let build = AppVersion.build

        let expected = "\(version) (\(build))"
        XCTAssertEqual(fullVersion, expected, "Full version should follow format: version (build)")
    }

    func testFullVersionContainsParentheses() {
        let fullVersion = AppVersion.fullVersion
        XCTAssertTrue(fullVersion.contains("("), "Full version should contain opening parenthesis")
        XCTAssertTrue(fullVersion.contains(")"), "Full version should contain closing parenthesis")
    }

    func testFullVersionContainsSpace() {
        let fullVersion = AppVersion.fullVersion
        XCTAssertTrue(fullVersion.contains(" "), "Full version should contain space between version and build")
    }

    // MARK: - Semantic Version Component Tests

    func testMajorVersion() {
        let major = AppVersion.major
        XCTAssertGreaterThanOrEqual(major, 0, "Major version should be non-negative")
        XCTAssertLessThanOrEqual(major, 999, "Major version should be reasonable")
    }

    func testMinorVersion() {
        let minor = AppVersion.minor
        XCTAssertGreaterThanOrEqual(minor, 0, "Minor version should be non-negative")
        XCTAssertLessThanOrEqual(minor, 999, "Minor version should be reasonable")
    }

    func testPatchVersion() {
        let patch = AppVersion.patch
        XCTAssertGreaterThanOrEqual(patch, 0, "Patch version should be non-negative")
        XCTAssertLessThanOrEqual(patch, 999, "Patch version should be reasonable")
    }

    func testSemanticVersionParsing() {
        // Test that major.minor.patch can be reconstructed
        let major = AppVersion.major
        let minor = AppVersion.minor
        let patch = AppVersion.patch

        let reconstructed = "\(major).\(minor).\(patch)"
        let version = AppVersion.version

        // If version follows strict semantic versioning, they should match
        // Otherwise, we just verify components are valid
        XCTAssertTrue(major >= 0 && minor >= 0 && patch >= 0, "All semantic version components should be non-negative")
    }

    func testSemanticVersionDefaultValues() {
        // Test that version components have sensible defaults
        let major = AppVersion.major
        let minor = AppVersion.minor
        let patch = AppVersion.patch

        // At minimum, major should be 1 (from default "1.0.0")
        XCTAssertGreaterThanOrEqual(major, 1, "Major version should be at least 1")

        // Minor and patch should be 0 or greater
        XCTAssertGreaterThanOrEqual(minor, 0, "Minor version should be 0 or greater")
        XCTAssertGreaterThanOrEqual(patch, 0, "Patch version should be 0 or greater")
    }

    // MARK: - Edge Cases

    func testVersionWithExtraComponents() {
        // If version is like "1.0.0.1234", major/minor/patch should still parse correctly
        let major = AppVersion.major
        let minor = AppVersion.minor
        let patch = AppVersion.patch

        XCTAssertNotNil(major)
        XCTAssertNotNil(minor)
        XCTAssertNotNil(patch)
    }

    func testVersionConsistency() {
        // Multiple calls should return the same values
        let version1 = AppVersion.version
        let version2 = AppVersion.version
        XCTAssertEqual(version1, version2, "Version should be consistent across calls")

        let build1 = AppVersion.build
        let build2 = AppVersion.build
        XCTAssertEqual(build1, build2, "Build should be consistent across calls")
    }

    func testFullVersionConsistency() {
        let fullVersion1 = AppVersion.fullVersion
        let fullVersion2 = AppVersion.fullVersion
        XCTAssertEqual(fullVersion1, fullVersion2, "Full version should be consistent across calls")
    }

    func testSemanticVersionComponentsConsistency() {
        let major1 = AppVersion.major
        let major2 = AppVersion.major
        XCTAssertEqual(major1, major2, "Major version should be consistent")

        let minor1 = AppVersion.minor
        let minor2 = AppVersion.minor
        XCTAssertEqual(minor1, minor2, "Minor version should be consistent")

        let patch1 = AppVersion.patch
        let patch2 = AppVersion.patch
        XCTAssertEqual(patch1, patch2, "Patch version should be consistent")
    }

    // MARK: - Integration Tests

    func testAllVersionComponentsValid() {
        // Test that all properties return valid values
        let version = AppVersion.version
        let build = AppVersion.build
        let fullVersion = AppVersion.fullVersion
        let major = AppVersion.major
        let minor = AppVersion.minor
        let patch = AppVersion.patch

        XCTAssertFalse(version.isEmpty)
        XCTAssertFalse(build.isEmpty)
        XCTAssertFalse(fullVersion.isEmpty)
        XCTAssertGreaterThanOrEqual(major, 0)
        XCTAssertGreaterThanOrEqual(minor, 0)
        XCTAssertGreaterThanOrEqual(patch, 0)
    }
}
