//
//  RuleMigrationTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class RuleMigrationTests: XCTestCase {

    // MARK: - Migration Tests

    func testMigrateV1ToV2WithExistingMatchCriteria() {
        let originalCriteria = MatchCriteria(
            url: URLMatcher(matchType: .wildcard, pattern: "*.example.com")
        )
        var rule = RewriteRule(
            name: "Test Rule",
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "*.example.com",
            matchCriteria: originalCriteria
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertNotNil(migrated.matchCriteria)
        XCTAssertEqual(migrated.matchCriteria?.url?.pattern, "*.example.com")
    }

    func testMigrateV1ToV2WithoutMatchCriteria() {
        var rule = RewriteRule(
            name: "Test Rule",
            ruleType: .block,
            matchType: .regex,
            matchPattern: "https://.*\\.example\\.com/.*",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertNotNil(migrated.matchCriteria)
        XCTAssertEqual(migrated.matchCriteria?.url?.matchType, .regex)
        XCTAssertEqual(migrated.matchCriteria?.url?.pattern, "https://.*\\.example\\.com/.*")
    }

    func testMigrateV1ToV2WithEmptyPattern() {
        var rule = RewriteRule(
            name: "Test Rule",
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        // Should not create match criteria for empty pattern
        XCTAssertNil(migrated.matchCriteria)
    }

    func testMigrateV1ToV2PreservesAllFields() {
        var rule = RewriteRule(
            id: UUID(),
            name: "Test Rule",
            enabled: true,
            ruleType: .redirect,
            matchType: .exact,
            matchPattern: "https://api.example.com",
            matchCriteria: nil,
            stopProcessing: true,
            matchingStrategy: .firstMatch,
            actions: [
                RewriteAction.redirectTo(url: "https://api-v2.example.com")
            ],
            priority: 10,
            tags: ["migration", "test"],
            hitCount: 5,
            lastHitAt: Date(),
            averageExecutionTimeMs: 1.5
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertEqual(migrated.id, rule.id)
        XCTAssertEqual(migrated.name, rule.name)
        XCTAssertEqual(migrated.enabled, rule.enabled)
        XCTAssertEqual(migrated.ruleType, rule.ruleType)
        XCTAssertEqual(migrated.stopProcessing, rule.stopProcessing)
        XCTAssertEqual(migrated.matchingStrategy, rule.matchingStrategy)
        XCTAssertEqual(migrated.priority, rule.priority)
        XCTAssertEqual(migrated.tags, rule.tags)
        XCTAssertEqual(migrated.hitCount, rule.hitCount)
        XCTAssertEqual(migrated.actions.count, rule.actions.count)
    }

    // MARK: - Different Match Types Tests

    func testMigrateWildcardMatchType() {
        var rule = RewriteRule(
            name: "Wildcard Rule",
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "*.example.*",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertEqual(migrated.matchCriteria?.url?.matchType, .wildcard)
        XCTAssertEqual(migrated.matchCriteria?.url?.pattern, "*.example.*")
    }

    func testMigrateRegexMatchType() {
        var rule = RewriteRule(
            name: "Regex Rule",
            ruleType: .block,
            matchType: .regex,
            matchPattern: "^https?://.*\\.example\\.com$",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertEqual(migrated.matchCriteria?.url?.matchType, .regex)
        XCTAssertEqual(migrated.matchCriteria?.url?.pattern, "^https?://.*\\.example\\.com$")
    }

    func testMigrateExactMatchType() {
        var rule = RewriteRule(
            name: "Exact Rule",
            ruleType: .block,
            matchType: .exact,
            matchPattern: "https://api.example.com/v1/users",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertEqual(migrated.matchCriteria?.url?.matchType, .exact)
        XCTAssertEqual(migrated.matchCriteria?.url?.pattern, "https://api.example.com/v1/users")
    }

    func testMigrateContainsMatchType() {
        var rule = RewriteRule(
            name: "Contains Rule",
            ruleType: .block,
            matchType: .contains,
            matchPattern: "example.com",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertEqual(migrated.matchCriteria?.url?.matchType, .contains)
        XCTAssertEqual(migrated.matchCriteria?.url?.pattern, "example.com")
    }

    // MARK: - Different Rule Types Tests

    func testMigrateBlockRule() {
        var rule = RewriteRule(
            name: "Block Rule",
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "*.ads.com",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertEqual(migrated.ruleType, .block)
        XCTAssertNotNil(migrated.matchCriteria)
    }

    func testMigrateRedirectRule() {
        var rule = RewriteRule(
            name: "Redirect Rule",
            ruleType: .redirect,
            matchType: .exact,
            matchPattern: "https://old.example.com",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertEqual(migrated.ruleType, .redirect)
        XCTAssertNotNil(migrated.matchCriteria)
    }

    func testMigrateModifyRequestRule() {
        var rule = RewriteRule(
            name: "Modify Rule",
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "api.example.com",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertEqual(migrated.ruleType, .modifyRequest)
        XCTAssertNotNil(migrated.matchCriteria)
    }

    // MARK: - Multiple Migrations Tests

    func testMultipleMigrations() {
        var rule1 = RewriteRule(
            name: "Rule 1",
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "*.example1.com",
            matchCriteria: nil
        )
        var rule2 = RewriteRule(
            name: "Rule 2",
            ruleType: .redirect,
            matchType: .regex,
            matchPattern: ".*example2.*",
            matchCriteria: nil
        )

        let migrated1 = RuleMigration.migrateV1ToV2(rule1)
        let migrated2 = RuleMigration.migrateV1ToV2(rule2)

        XCTAssertNotNil(migrated1.matchCriteria)
        XCTAssertNotNil(migrated2.matchCriteria)
        XCTAssertNotEqual(migrated1.matchCriteria?.url?.pattern, migrated2.matchCriteria?.url?.pattern)
    }

    // MARK: - Idempotency Tests

    func testMigrationIsIdempotent() {
        var rule = RewriteRule(
            name: "Test Rule",
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "*.example.com",
            matchCriteria: nil
        )

        let migrated1 = RuleMigration.migrateV1ToV2(rule)
        let migrated2 = RuleMigration.migrateV1ToV2(migrated1)

        XCTAssertEqual(migrated1.matchCriteria?.url?.pattern, migrated2.matchCriteria?.url?.pattern)
        XCTAssertEqual(migrated1.matchCriteria?.url?.matchType, migrated2.matchCriteria?.url?.matchType)
    }

    // MARK: - Edge Cases Tests

    func testMigrateRuleWithSpecialCharacters() {
        var rule = RewriteRule(
            name: "Special Chars Rule",
            ruleType: .block,
            matchType: .regex,
            matchPattern: "^https?://[a-z]+\\.example\\.com/api/v[0-9]+/.*$",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertNotNil(migrated.matchCriteria)
        XCTAssertEqual(migrated.matchCriteria?.url?.pattern, rule.matchPattern)
    }

    func testMigrateRuleWithUnicodePattern() {
        var rule = RewriteRule(
            name: "Unicode Rule",
            ruleType: .block,
            matchType: .contains,
            matchPattern: "例え.com",
            matchCriteria: nil
        )

        let migrated = RuleMigration.migrateV1ToV2(rule)

        XCTAssertNotNil(migrated.matchCriteria)
        XCTAssertEqual(migrated.matchCriteria?.url?.pattern, "例え.com")
    }
}
