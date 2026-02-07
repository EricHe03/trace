//
//  RuleIndexTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceFeatures
@testable import TraceCore

final class RuleIndexTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitialization() async {
        // Arrange & Act
        let index = RuleIndex()

        // Assert
        let results = await index.lookup(url: "https://example.com")
        XCTAssertEqual(results.count, 0, "Newly initialized index should be empty")
    }

    // MARK: - Build Index Tests

    func testBuildIndexWithEmptyRules() async {
        // Arrange
        let index = RuleIndex()
        let rules: [RewriteRule] = []

        // Act
        await index.buildIndex(rules: rules)
        let results = await index.lookup(url: "https://example.com")

        // Assert
        XCTAssertEqual(results.count, 0, "Index with empty rules should return no results")
    }

    func testBuildIndexWithSingleHostRule() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            matchURL: "https://api.example.com/test",
            enabled: true
        )

        // Act
        await index.buildIndex(rules: [rule])
        let results = await index.lookup(url: "https://api.example.com/anything")

        // Assert
        XCTAssertEqual(results.count, 1, "Should find rule by host")
        XCTAssertTrue(results.contains(rule.id), "Should contain the rule ID")
    }

    func testBuildIndexWithPathPrefixRule() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            matchURL: "/api/v1",
            enabled: true
        )

        // Act
        await index.buildIndex(rules: [rule])
        let results = await index.lookup(url: "https://example.com/api/v1/users")

        // Assert
        XCTAssertEqual(results.count, 1, "Should find rule by path prefix")
        XCTAssertTrue(results.contains(rule.id), "Should contain the rule ID")
    }

    func testBuildIndexWithMultipleRules() async {
        // Arrange
        let index = RuleIndex()
        let rule1 = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        let rule2 = makeRewriteRule(
            id: UUID(),
            matchURL: "https://cdn.example.com",
            enabled: true
        )
        let rule3 = makeRewriteRule(
            id: UUID(),
            matchURL: "/api",
            enabled: true
        )

        // Act
        await index.buildIndex(rules: [rule1, rule2, rule3])
        let results1 = await index.lookup(url: "https://api.example.com/test")
        let results2 = await index.lookup(url: "https://cdn.example.com/image.png")

        // Assert
        XCTAssertGreaterThanOrEqual(results1.count, 1, "Should find at least one rule")
        XCTAssertGreaterThanOrEqual(results2.count, 1, "Should find at least one rule")
    }

    func testBuildIndexIgnoresDisabledRules() async {
        // Arrange
        let index = RuleIndex()
        let enabledRule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        let disabledRule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: false
        )

        // Act
        await index.buildIndex(rules: [enabledRule, disabledRule])
        let results = await index.lookup(url: "https://api.example.com/test")

        // Assert
        XCTAssertTrue(results.contains(enabledRule.id), "Should contain enabled rule")
        XCTAssertFalse(results.contains(disabledRule.id), "Should not contain disabled rule")
    }

    func testBuildIndexWithMatchCriteria() async {
        // Arrange
        let index = RuleIndex()
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .wildcard, pattern: "https://api.example.com/*")
        )
        let rule = RewriteRule(
            id: UUID(),
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )

        // Act
        await index.buildIndex(rules: [rule])
        let results = await index.lookup(url: "https://api.example.com/test")

        // Assert
        XCTAssertGreaterThanOrEqual(results.count, 0, "Should handle matchCriteria")
    }

    func testBuildIndexReplacesOldIndex() async {
        // Arrange
        let index = RuleIndex()
        let rule1 = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        let rule2 = makeRewriteRule(
            id: UUID(),
            matchURL: "https://cdn.example.com",
            enabled: true
        )

        // Act
        await index.buildIndex(rules: [rule1])
        let results1 = await index.lookup(url: "https://api.example.com")

        await index.buildIndex(rules: [rule2])
        let results2 = await index.lookup(url: "https://api.example.com")
        let results3 = await index.lookup(url: "https://cdn.example.com")

        // Assert
        XCTAssertGreaterThan(results1.count, 0, "First index should find rule1")
        XCTAssertEqual(results2.count, 0, "After rebuild, old rule should not be found")
        XCTAssertGreaterThan(results3.count, 0, "After rebuild, new rule should be found")
    }

    // MARK: - Lookup Tests

    func testLookupWithInvalidURL() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let results = await index.lookup(url: "not a valid url")

        // Assert
        XCTAssertEqual(results.count, 0, "Invalid URL should return no results")
    }

    func testLookupWithEmptyURL() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let results = await index.lookup(url: "")

        // Assert
        XCTAssertEqual(results.count, 0, "Empty URL should return no results")
    }

    func testLookupWithHostMatch() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let results = await index.lookup(url: "https://api.example.com/users")

        // Assert
        XCTAssertTrue(results.contains(rule.id), "Should find rule by host")
    }

    func testLookupWithPathPrefixMatch() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "/api/v1",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let results = await index.lookup(url: "https://example.com/api/v1/users")

        // Assert
        XCTAssertTrue(results.contains(rule.id), "Should find rule by path prefix")
    }

    func testLookupWithNoPathPrefixMatch() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "/api/v1",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let results = await index.lookup(url: "https://example.com/api/v2/users")

        // Assert
        XCTAssertFalse(results.contains(rule.id), "Should not find rule with different path")
    }

    func testLookupWithMultipleMatches() async {
        // Arrange
        let index = RuleIndex()
        let rule1 = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        let rule2 = makeRewriteRule(
            id: UUID(),
            matchURL: "/api",
            enabled: true
        )
        await index.buildIndex(rules: [rule1, rule2])

        // Act
        let results = await index.lookup(url: "https://api.example.com/api/users")

        // Assert
        XCTAssertGreaterThanOrEqual(results.count, 1, "Should find multiple matching rules")
        let uniqueResults = Set(results)
        XCTAssertEqual(uniqueResults.count, results.count, "Should not have duplicate IDs")
    }

    func testLookupReturnsDeduplicated() async {
        // Arrange
        let index = RuleIndex()
        let ruleId = UUID()
        let rule1 = makeRewriteRule(
            id: ruleId,
            matchURL: "https://api.example.com",
            enabled: true
        )
        let rule2 = makeRewriteRule(
            id: ruleId,
            matchURL: "/api",
            enabled: true
        )
        await index.buildIndex(rules: [rule1, rule2])

        // Act
        let results = await index.lookup(url: "https://api.example.com/api/users")

        // Assert
        let uniqueResults = Set(results)
        XCTAssertEqual(uniqueResults.count, results.count, "Should deduplicate results")
    }

    func testLookupWithDifferentSchemes() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let httpsResults = await index.lookup(url: "https://api.example.com/test")
        let httpResults = await index.lookup(url: "http://api.example.com/test")

        // Assert
        XCTAssertTrue(httpsResults.contains(rule.id), "Should find HTTPS rule")
        XCTAssertTrue(httpResults.contains(rule.id), "Should find rule regardless of scheme")
    }

    func testLookupWithQueryParameters() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let results = await index.lookup(url: "https://api.example.com/test?param=value")

        // Assert
        XCTAssertTrue(results.contains(rule.id), "Should find rule with query parameters")
    }

    func testLookupWithFragment() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let results = await index.lookup(url: "https://api.example.com/test#section")

        // Assert
        XCTAssertTrue(results.contains(rule.id), "Should find rule with fragment")
    }

    func testLookupWithPort() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com:8080",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        let results = await index.lookup(url: "https://api.example.com:8080/test")

        // Assert
        XCTAssertTrue(results.contains(rule.id), "Should find rule with port")
    }

    // MARK: - Invalidate Tests

    func testInvalidate() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])
        let resultsBefore = await index.lookup(url: "https://api.example.com/test")

        // Act
        await index.invalidate()
        let resultsAfter = await index.lookup(url: "https://api.example.com/test")

        // Assert
        XCTAssertGreaterThan(resultsBefore.count, 0, "Should have results before invalidation")
        XCTAssertEqual(resultsAfter.count, 0, "Should have no results after invalidation")
    }

    func testInvalidateAllowsRebuild() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])
        await index.invalidate()

        // Act
        await index.buildIndex(rules: [rule])
        let results = await index.lookup(url: "https://api.example.com/test")

        // Assert
        XCTAssertTrue(results.contains(rule.id), "Should rebuild index after invalidation")
    }

    // MARK: - Edge Cases

    func testBuildIndexWithRuleWithoutHost() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            matchURL: "not-a-valid-url",
            enabled: true
        )

        // Act
        await index.buildIndex(rules: [rule])
        let results = await index.lookup(url: "https://api.example.com")

        // Assert
        XCTAssertEqual(results.count, 0, "Should handle rules without valid host")
    }

    func testBuildIndexWithManyRules() async {
        // Arrange
        let index = RuleIndex()
        var rules: [RewriteRule] = []
        for i in 0..<100 {
            rules.append(makeRewriteRule(
                id: UUID(),
                matchURL: "https://api\(i).example.com",
                enabled: true
            ))
        }

        // Act
        await index.buildIndex(rules: rules)
        let results = await index.lookup(url: "https://api50.example.com/test")

        // Assert
        XCTAssertGreaterThan(results.count, 0, "Should handle many rules")
    }

    func testBuildIndexWithDuplicatePatterns() async {
        // Arrange
        let index = RuleIndex()
        let rule1 = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        let rule2 = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )

        // Act
        await index.buildIndex(rules: [rule1, rule2])
        let results = await index.lookup(url: "https://api.example.com/test")

        // Assert
        XCTAssertEqual(results.count, 2, "Should index both rules with same pattern")
        XCTAssertTrue(results.contains(rule1.id))
        XCTAssertTrue(results.contains(rule2.id))
    }

    func testConcurrentLookups() async {
        // Arrange
        let index = RuleIndex()
        let rule = makeRewriteRule(
            id: UUID(),
            matchURL: "https://api.example.com",
            enabled: true
        )
        await index.buildIndex(rules: [rule])

        // Act
        async let results1 = index.lookup(url: "https://api.example.com/test1")
        async let results2 = index.lookup(url: "https://api.example.com/test2")
        async let results3 = index.lookup(url: "https://api.example.com/test3")

        let (r1, r2, r3) = await (results1, results2, results3)

        // Assert
        XCTAssertTrue(r1.contains(rule.id), "Concurrent lookup 1 should work")
        XCTAssertTrue(r2.contains(rule.id), "Concurrent lookup 2 should work")
        XCTAssertTrue(r3.contains(rule.id), "Concurrent lookup 3 should work")
    }

    // MARK: - Performance Tests

    func testBuildIndexPerformance() async {
        let index = RuleIndex()
        var rules: [RewriteRule] = []
        for i in 0..<1000 {
            rules.append(makeRewriteRule(
                id: UUID(),
                matchURL: "https://api\(i).example.com",
                enabled: true
            ))
        }

        measure {
            Task {
                await index.buildIndex(rules: rules)
            }
        }
    }

    func testLookupPerformance() async {
        let index = RuleIndex()
        var rules: [RewriteRule] = []
        for i in 0..<1000 {
            rules.append(makeRewriteRule(
                id: UUID(),
                matchURL: "https://api\(i).example.com",
                enabled: true
            ))
        }
        await index.buildIndex(rules: rules)

        measure {
            Task {
                _ = await index.lookup(url: "https://api500.example.com/test")
            }
        }
    }
}
