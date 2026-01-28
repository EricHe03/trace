//
//  ParallelMatcherTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class ParallelMatcherTests: XCTestCase {

    var matcher: ParallelMatcher!

    override func setUp() async throws {
        try await super.setUp()
        matcher = ParallelMatcher()
    }

    override func tearDown() async throws {
        matcher = nil
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func makeRequest(
        url: String = "https://api.example.com/users",
        method: HTTPMethod = .get
    ) -> NetworkRequest {
        NetworkRequest(
            url: url,
            method: method,
            duration: 0.5
        )
    }

    private func makeRule(
        name: String,
        priority: Int = 0,
        matchPattern: String = "*",
        matchCriteria: MatchCriteria? = nil
    ) -> RewriteRule {
        RewriteRule(
            name: name,
            ruleType: .redirect,
            matchPattern: matchPattern,
            matchCriteria: matchCriteria,
            priority: priority
        )
    }

    // MARK: - Basic Matching Tests

    func testMatchRulesWithNoRules() async {
        let request = makeRequest()
        let rules: [RewriteRule] = []

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertTrue(matched.isEmpty)
    }

    func testMatchRulesWithSingleMatchingRule() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let rule = makeRule(name: "Rule 1", matchPattern: "*example.com*")

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].name, "Rule 1")
    }

    func testMatchRulesWithSingleNonMatchingRule() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let rule = makeRule(name: "Rule 1", matchPattern: "*other.com*")

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertTrue(matched.isEmpty)
    }

    func testMatchRulesWithMultipleMatchingRules() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let rules = [
            makeRule(name: "Rule 1", matchPattern: "*example.com*"),
            makeRule(name: "Rule 2", matchPattern: "*api.example.com*"),
            makeRule(name: "Rule 3", matchPattern: "*/users*")
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 3)
        XCTAssertTrue(matched.contains(where: { $0.name == "Rule 1" }))
        XCTAssertTrue(matched.contains(where: { $0.name == "Rule 2" }))
        XCTAssertTrue(matched.contains(where: { $0.name == "Rule 3" }))
    }

    func testMatchRulesWithMixedMatchingAndNonMatching() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let rules = [
            makeRule(name: "Rule 1", matchPattern: "*example.com*"),
            makeRule(name: "Rule 2", matchPattern: "*other.com*"),
            makeRule(name: "Rule 3", matchPattern: "*/users*"),
            makeRule(name: "Rule 4", matchPattern: "*google.com*")
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 2)
        XCTAssertTrue(matched.contains(where: { $0.name == "Rule 1" }))
        XCTAssertTrue(matched.contains(where: { $0.name == "Rule 3" }))
        XCTAssertFalse(matched.contains(where: { $0.name == "Rule 2" }))
        XCTAssertFalse(matched.contains(where: { $0.name == "Rule 4" }))
    }

    // MARK: - Priority Sorting Tests

    func testMatchRulesSortedByPriority() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let rules = [
            makeRule(name: "Low Priority", priority: 100, matchPattern: "*"),
            makeRule(name: "High Priority", priority: 1, matchPattern: "*"),
            makeRule(name: "Medium Priority", priority: 50, matchPattern: "*")
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 3)
        XCTAssertEqual(matched[0].name, "High Priority")
        XCTAssertEqual(matched[1].name, "Medium Priority")
        XCTAssertEqual(matched[2].name, "Low Priority")
    }

    func testMatchRulesWithSamePriority() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let rules = [
            makeRule(name: "Rule A", priority: 10, matchPattern: "*"),
            makeRule(name: "Rule B", priority: 10, matchPattern: "*"),
            makeRule(name: "Rule C", priority: 10, matchPattern: "*")
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 3)
        // All have same priority, order should be stable
    }

    func testMatchRulesWithNegativePriority() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let rules = [
            makeRule(name: "Negative", priority: -10, matchPattern: "*"),
            makeRule(name: "Zero", priority: 0, matchPattern: "*"),
            makeRule(name: "Positive", priority: 10, matchPattern: "*")
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 3)
        XCTAssertEqual(matched[0].name, "Negative")
        XCTAssertEqual(matched[1].name, "Zero")
        XCTAssertEqual(matched[2].name, "Positive")
    }

    // MARK: - MatchCriteria Tests

    func testMatchRulesWithMatchCriteriaMethod() async {
        let request = makeRequest(url: "https://api.example.com/users", method: .post)
        let criteria = MatchCriteria(methods: [.post])
        let rule = makeRule(name: "POST Rule", matchCriteria: criteria)

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].name, "POST Rule")
    }

    func testMatchRulesWithMatchCriteriaMethodMismatch() async {
        let request = makeRequest(url: "https://api.example.com/users", method: .get)
        let criteria = MatchCriteria(methods: [.post])
        let rule = makeRule(name: "POST Rule", matchCriteria: criteria)

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertTrue(matched.isEmpty)
    }

    func testMatchRulesWithMatchCriteriaURL() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example.com")
        )
        let rule = makeRule(name: "URL Rule", matchCriteria: criteria)

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    func testMatchRulesWithMatchCriteriaHost() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let criteria = MatchCriteria(
            hosts: [StringMatcher(matchType: .exact, pattern: "api.example.com")]
        )
        let rule = makeRule(name: "Host Rule", matchCriteria: criteria)

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    func testMatchRulesWithComplexCriteria() async {
        let request = makeRequest(url: "https://api.example.com/users", method: .post)
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example.com"),
            methods: [.post, .put],
            hosts: [StringMatcher(matchType: .exact, pattern: "api.example.com")],
            logic: .and
        )
        let rule = makeRule(name: "Complex Rule", matchCriteria: criteria)

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    func testMatchRulesWithEmptyMatchCriteria() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let criteria = MatchCriteria() // Empty criteria
        let rule = makeRule(name: "Empty Criteria", matchPattern: "*example.com*", matchCriteria: criteria)

        let matched = await matcher.matchRules([rule], against: request)

        // Falls back to pattern matching when criteria is empty
        XCTAssertEqual(matched.count, 1)
    }

    // MARK: - Wildcard Pattern Tests

    func testMatchRulesWithWildcardPattern() async {
        let request = makeRequest(url: "https://api.example.com/users/123")
        let rule = makeRule(name: "Wildcard", matchPattern: "https://api.example.com/users/*")

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    func testMatchRulesWithWildcardAllPattern() async {
        let request = makeRequest(url: "https://api.example.com/users")
        let rule = makeRule(name: "Match All", matchPattern: "*")

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    // MARK: - Performance and Concurrency Tests

    func testMatchRulesWithManyRules() async {
        let request = makeRequest(url: "https://api.example.com/users")
        var rules: [RewriteRule] = []

        // Create 100 rules, half matching, half not
        for i in 0..<100 {
            let pattern = (i % 2 == 0) ? "*example.com*" : "*other.com*"
            rules.append(makeRule(name: "Rule \(i)", priority: i, matchPattern: pattern))
        }

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 50)
        // Should be sorted by priority
        for i in 0..<matched.count - 1 {
            XCTAssertLessThanOrEqual(matched[i].priority, matched[i + 1].priority)
        }
    }

    func testMatchRulesPerformance() async {
        let request = makeRequest(url: "https://api.example.com/users")
        var rules: [RewriteRule] = []

        for i in 0..<1000 {
            rules.append(makeRule(name: "Rule \(i)", priority: i, matchPattern: "*example.com*"))
        }

        measure {
            Task {
                let matched = await self.matcher.matchRules(rules, against: request)
                XCTAssertEqual(matched.count, 1000)
            }
        }
    }

    func testMatchRulesConcurrentCalls() async {
        let request1 = makeRequest(url: "https://api.example.com/users")
        let request2 = makeRequest(url: "https://cdn.example.com/image.jpg")
        let request3 = makeRequest(url: "https://other.com/data")

        let rules = [
            makeRule(name: "API Rule", matchPattern: "*api.example.com*"),
            makeRule(name: "CDN Rule", matchPattern: "*cdn.example.com*"),
            makeRule(name: "Example Rule", matchPattern: "*example.com*")
        ]

        // Run multiple matches concurrently
        async let matched1 = matcher.matchRules(rules, against: request1)
        async let matched2 = matcher.matchRules(rules, against: request2)
        async let matched3 = matcher.matchRules(rules, against: request3)

        let results = await [matched1, matched2, matched3]

        // Request 1 should match API Rule and Example Rule
        XCTAssertEqual(results[0].count, 2)
        // Request 2 should match CDN Rule and Example Rule
        XCTAssertEqual(results[1].count, 2)
        // Request 3 should match nothing
        XCTAssertEqual(results[2].count, 0)
    }

    func testMatchRulesMultipleCallsInSequence() async {
        let rules = [
            makeRule(name: "Rule 1", matchPattern: "*example.com*"),
            makeRule(name: "Rule 2", matchPattern: "*api*")
        ]

        for i in 0..<10 {
            let request = makeRequest(url: "https://api.example.com/endpoint\(i)")
            let matched = await matcher.matchRules(rules, against: request)

            XCTAssertEqual(matched.count, 2)
        }
    }

    // MARK: - Edge Cases

    func testMatchRulesWithEmptyURL() async {
        let request = makeRequest(url: "")
        let rule = makeRule(name: "Rule 1", matchPattern: "*")

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    func testMatchRulesWithVeryLongURL() async {
        let longURL = "https://api.example.com/" + String(repeating: "a", count: 10000)
        let request = makeRequest(url: longURL)
        let rule = makeRule(name: "Rule 1", matchPattern: "*example.com*")

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    func testMatchRulesWithSpecialCharactersInURL() async {
        let request = makeRequest(url: "https://api.example.com/users?name=John&email=john@example.com")
        let rule = makeRule(name: "Rule 1", matchPattern: "*example.com*")

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    func testMatchRulesWithUnicodeInURL() async {
        let request = makeRequest(url: "https://api.example.com/用户/数据")
        let rule = makeRule(name: "Rule 1", matchPattern: "*example.com*")

        let matched = await matcher.matchRules([rule], against: request)

        XCTAssertEqual(matched.count, 1)
    }

    // MARK: - Real-world Scenarios

    func testMatchRulesAPIRoutingScenario() async {
        let request = makeRequest(url: "https://api.example.com/v1/users/123", method: .get)

        let rules = [
            makeRule(
                name: "Block Analytics",
                priority: 1,
                matchPattern: "*analytics*"
            ),
            makeRule(
                name: "API v1 Users",
                priority: 10,
                matchPattern: "*/v1/users/*"
            ),
            makeRule(
                name: "All API",
                priority: 100,
                matchPattern: "*api.example.com*"
            )
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 2)
        XCTAssertEqual(matched[0].name, "API v1 Users")
        XCTAssertEqual(matched[1].name, "All API")
    }

    func testMatchRulesCDNRedirectScenario() async {
        let request = makeRequest(url: "https://cdn.example.com/images/logo.png")

        let rules = [
            makeRule(
                name: "CDN Images",
                priority: 5,
                matchCriteria: MatchCriteria(
                    hosts: [StringMatcher(matchType: .exact, pattern: "cdn.example.com")]
                )
            ),
            makeRule(
                name: "All CDN",
                priority: 10,
                matchPattern: "*cdn*"
            ),
            makeRule(
                name: "Images",
                priority: 20,
                matchPattern: "*.png"
            )
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 3)
        XCTAssertEqual(matched[0].name, "CDN Images")
    }

    func testMatchRulesSecurityBlockingScenario() async {
        let request = makeRequest(url: "https://malicious.com/script.js")

        let rules = [
            makeRule(
                name: "Block Malicious",
                priority: 1,
                matchPattern: "*malicious.com*"
            ),
            makeRule(
                name: "Block Scripts",
                priority: 5,
                matchPattern: "*.js"
            ),
            makeRule(
                name: "Allow All",
                priority: 100,
                matchPattern: "*"
            )
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 3)
        // Highest priority (lowest number) should be first
        XCTAssertEqual(matched[0].name, "Block Malicious")
    }

    // MARK: - Different Rule Types

    func testMatchRulesWithDifferentRuleTypes() async {
        let request = makeRequest(url: "https://api.example.com/users")

        let rules = [
            RewriteRule(name: "Redirect", ruleType: .redirect, matchPattern: "*example.com*"),
            RewriteRule(name: "Block", ruleType: .block, matchPattern: "*example.com*"),
            RewriteRule(name: "Modify", ruleType: .modifyRequest, matchPattern: "*example.com*")
        ]

        let matched = await matcher.matchRules(rules, against: request)

        XCTAssertEqual(matched.count, 3)
        // All types should be matched if pattern matches
    }

    // MARK: - Actor Isolation Tests

    func testMatcherIsActorIsolated() async {
        // This test ensures the matcher is properly actor-isolated
        let matcher1 = ParallelMatcher()
        let matcher2 = ParallelMatcher()

        let request = makeRequest()
        let rules = [makeRule(name: "Rule 1", matchPattern: "*")]

        // Both should work independently
        async let result1 = matcher1.matchRules(rules, against: request)
        async let result2 = matcher2.matchRules(rules, against: request)

        let results = await [result1, result2]

        XCTAssertEqual(results[0].count, 1)
        XCTAssertEqual(results[1].count, 1)
    }

    func testMatcherStateIsolation() async {
        let request = makeRequest()
        let rules1 = [makeRule(name: "Rule 1", matchPattern: "*")]
        let rules2 = [makeRule(name: "Rule 2", matchPattern: "*")]

        // Call with different rules
        let matched1 = await matcher.matchRules(rules1, against: request)
        let matched2 = await matcher.matchRules(rules2, against: request)

        // Results should be independent
        XCTAssertEqual(matched1[0].name, "Rule 1")
        XCTAssertEqual(matched2[0].name, "Rule 2")
    }
}
