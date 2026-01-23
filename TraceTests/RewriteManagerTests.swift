//
//  RewriteManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class RewriteManagerTests: XCTestCase {

    // MARK: - RewriteRule Matching Tests

    func testExactMatch() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .exact,
            matchPattern: "https://example.com/api"
        )

        XCTAssertTrue(rule.matches("https://example.com/api"))
        XCTAssertFalse(rule.matches("https://example.com/api/users"))
        XCTAssertFalse(rule.matches("https://other.com/api"))
    }

    func testContainsMatch() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "example.com"
        )

        XCTAssertTrue(rule.matches("https://example.com/api"))
        XCTAssertTrue(rule.matches("https://api.example.com/users"))
        XCTAssertTrue(rule.matches("http://example.com"))
        XCTAssertFalse(rule.matches("https://other.com/api"))
    }

    func testWildcardMatch() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .wildcard,
            matchPattern: "https://*.example.com/*"
        )

        XCTAssertTrue(rule.matches("https://api.example.com/users"))
        XCTAssertTrue(rule.matches("https://www.example.com/path"))
        XCTAssertTrue(rule.matches("https://subdomain.example.com/any/path"))
        XCTAssertFalse(rule.matches("https://example.com/api"))
        XCTAssertFalse(rule.matches("http://api.example.com/users"))
    }

    func testWildcardMatchSimple() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .wildcard,
            matchPattern: "*example.com*"
        )

        XCTAssertTrue(rule.matches("https://example.com/api"))
        XCTAssertTrue(rule.matches("https://api.example.com/users"))
        XCTAssertTrue(rule.matches("http://example.com"))
        XCTAssertFalse(rule.matches("https://other.com/api"))
    }

    func testRegexMatch() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .regex,
            matchPattern: "^https://api\\.example\\.com/v[0-9]+/.*$"
        )

        XCTAssertTrue(rule.matches("https://api.example.com/v1/users"))
        XCTAssertTrue(rule.matches("https://api.example.com/v2/posts"))
        XCTAssertTrue(rule.matches("https://api.example.com/v10/data"))
        XCTAssertFalse(rule.matches("https://api.example.com/users"))
        XCTAssertFalse(rule.matches("http://api.example.com/v1/users"))
    }

    func testRegexMatchInvalidPattern() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .regex,
            matchPattern: "[invalid regex("
        )

        // Invalid regex should not match anything
        XCTAssertFalse(rule.matches("https://example.com"))
    }

    func testDisabledRuleDoesNotMatch() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: false,
            ruleType: .modifyRequest,
            matchType: .exact,
            matchPattern: "https://example.com"
        )

        XCTAssertFalse(rule.matches("https://example.com"))
    }

    // MARK: - RewriteAction Tests

    func testSetHeaderAction() {
        let action = RewriteAction.setHeader(key: "Authorization", value: "Bearer token")

        XCTAssertEqual(action.actionType, .setHeader)
        XCTAssertEqual(action.headerKey, "Authorization")
        XCTAssertEqual(action.headerValue, "Bearer token")
    }

    func testRemoveHeaderAction() {
        let action = RewriteAction.removeHeader(key: "Cookie")

        XCTAssertEqual(action.actionType, .removeHeader)
        XCTAssertEqual(action.headerKey, "Cookie")
    }

    func testReplaceBodyAction() {
        let action = RewriteAction.replaceBody(pattern: "old", replacement: "new")

        XCTAssertEqual(action.actionType, .replaceBody)
        XCTAssertEqual(action.bodyPattern, "old")
        XCTAssertEqual(action.bodyReplacement, "new")
    }

    func testSetBodyAction() {
        let action = RewriteAction.setBody(content: "{\"mocked\": true}")

        XCTAssertEqual(action.actionType, .setBody)
        XCTAssertEqual(action.bodyContent, "{\"mocked\": true}")
    }

    func testSetStatusCodeAction() {
        let action = RewriteAction.setStatusCode(404)

        XCTAssertEqual(action.actionType, .setStatusCode)
        XCTAssertEqual(action.statusCode, 404)
    }

    func testAddDelayAction() {
        let action = RewriteAction.addDelay(milliseconds: 1000)

        XCTAssertEqual(action.actionType, .addDelay)
        XCTAssertEqual(action.delayMilliseconds, 1000)
    }

    func testRedirectToAction() {
        let action = RewriteAction.redirectTo(url: "https://redirect.com")

        XCTAssertEqual(action.actionType, .redirectTo)
        XCTAssertEqual(action.redirectUrl, "https://redirect.com")
    }

    // MARK: - Rule Type and Match Type Tests

    func testRuleTypeDisplayNames() {
        XCTAssertEqual(RuleType.redirect.displayName, "Redirect")
        XCTAssertEqual(RuleType.modifyRequest.displayName, "Modify Request")
        XCTAssertEqual(RuleType.modifyResponse.displayName, "Modify Response")
        XCTAssertEqual(RuleType.block.displayName, "Block Request")
        XCTAssertEqual(RuleType.map.displayName, "Map Local")
    }

    func testMatchTypeDisplayNames() {
        XCTAssertEqual(MatchType.wildcard.displayName, "Wildcard")
        XCTAssertEqual(MatchType.regex.displayName, "Regex")
        XCTAssertEqual(MatchType.exact.displayName, "Exact Match")
        XCTAssertEqual(MatchType.contains.displayName, "Contains")
    }

    // MARK: - Complex Matching Tests

    func testMultipleWildcards() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .wildcard,
            matchPattern: "https://*.example.com/api/*/users"
        )

        XCTAssertTrue(rule.matches("https://api.example.com/api/v1/users"))
        XCTAssertTrue(rule.matches("https://www.example.com/api/public/users"))
        XCTAssertFalse(rule.matches("https://api.example.com/api/users"))
        XCTAssertFalse(rule.matches("https://api.example.com/api/v1/posts"))
    }

    func testCaseSensitiveRegex() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .regex,
            matchPattern: "https://EXAMPLE\\.com/.*"
        )

        // Regex is case-sensitive by default in NSRegularExpression
        XCTAssertTrue(rule.matches("https://EXAMPLE.com/api"))
        XCTAssertFalse(rule.matches("https://example.com/api"))
    }

    func testWildcardCaseInsensitive() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .wildcard,
            matchPattern: "https://EXAMPLE.com/*"
        )

        // Wildcard matching is case-insensitive
        XCTAssertTrue(rule.matches("https://example.com/api"))
        XCTAssertTrue(rule.matches("https://EXAMPLE.com/api"))
        XCTAssertTrue(rule.matches("https://Example.com/api"))
    }

    // MARK: - Priority and Ordering Tests

    func testRulePriority() {
        let rule1 = RewriteRule(
            name: "High Priority",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "example.com",
            priority: 0
        )

        let rule2 = RewriteRule(
            name: "Low Priority",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "example.com",
            priority: 10
        )

        // Lower priority number means higher priority
        XCTAssertLessThan(rule1.priority, rule2.priority)
    }

    // MARK: - Serialization Tests

    func testRuleCodable() throws {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .wildcard,
            matchPattern: "https://*.example.com/*",
            actions: [
                .setHeader(key: "Authorization", value: "Bearer token"),
                .removeHeader(key: "Cookie")
            ],
            priority: 5
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(rule)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RewriteRule.self, from: data)

        XCTAssertEqual(decoded.name, rule.name)
        XCTAssertEqual(decoded.enabled, rule.enabled)
        XCTAssertEqual(decoded.ruleType, rule.ruleType)
        XCTAssertEqual(decoded.matchType, rule.matchType)
        XCTAssertEqual(decoded.matchPattern, rule.matchPattern)
        XCTAssertEqual(decoded.priority, rule.priority)
        XCTAssertEqual(decoded.actions.count, rule.actions.count)
    }

    func testActionCodable() throws {
        let action = RewriteAction.setHeader(key: "Content-Type", value: "application/json")

        let encoder = JSONEncoder()
        let data = try encoder.encode(action)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RewriteAction.self, from: data)

        XCTAssertEqual(decoded.actionType, action.actionType)
        XCTAssertEqual(decoded.headerKey, action.headerKey)
        XCTAssertEqual(decoded.headerValue, action.headerValue)
    }

    // MARK: - Edge Cases Tests

    func testEmptyPattern() {
        let rule = RewriteRule(
            name: "Empty Pattern",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .exact,
            matchPattern: ""
        )

        XCTAssertTrue(rule.matches(""))
        XCTAssertFalse(rule.matches("https://example.com"))
    }

    func testSpecialCharactersInPattern() {
        let rule = RewriteRule(
            name: "Special Chars",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "?query=test&param=value"
        )

        XCTAssertTrue(rule.matches("https://example.com/api?query=test&param=value"))
        XCTAssertFalse(rule.matches("https://example.com/api"))
    }

    func testUnicodeInPattern() {
        let rule = RewriteRule(
            name: "Unicode Pattern",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "世界"
        )

        XCTAssertTrue(rule.matches("https://example.com/世界"))
        XCTAssertFalse(rule.matches("https://example.com/world"))
    }

    // MARK: - Real World Example Tests

    func testBlockAdvertisementRule() {
        let rule = RewriteRule(
            name: "Block Ads",
            enabled: true,
            ruleType: .block,
            matchType: .contains,
            matchPattern: "ads.example.com"
        )

        XCTAssertTrue(rule.matches("https://ads.example.com/banner.js"))
        XCTAssertTrue(rule.matches("http://ads.example.com/tracking"))
        XCTAssertFalse(rule.matches("https://www.example.com/content"))
    }

    func testRedirectAPIVersion() {
        let rule = RewriteRule(
            name: "Redirect to v2",
            enabled: true,
            ruleType: .redirect,
            matchType: .wildcard,
            matchPattern: "https://api.example.com/v1/*",
            actions: [
                .redirectTo(url: "https://api.example.com/v2/*")
            ]
        )

        XCTAssertTrue(rule.matches("https://api.example.com/v1/users"))
        XCTAssertTrue(rule.matches("https://api.example.com/v1/posts"))
        XCTAssertFalse(rule.matches("https://api.example.com/v2/users"))
    }

    func testModifyAuthenticationHeader() {
        let rule = RewriteRule(
            name: "Add Auth",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "api.example.com",
            actions: [
                .setHeader(key: "Authorization", value: "Bearer secret-token")
            ]
        )

        XCTAssertTrue(rule.matches("https://api.example.com/users"))

        let action = rule.actions.first
        XCTAssertEqual(action?.actionType, .setHeader)
        XCTAssertEqual(action?.headerKey, "Authorization")
    }

    func testMockResponseRule() {
        let mockBody = """
        {
            "status": "success",
            "data": {
                "id": 1,
                "name": "Mock User"
            }
        }
        """

        let rule = RewriteRule(
            name: "Mock User API",
            enabled: true,
            ruleType: .modifyResponse,
            matchType: .exact,
            matchPattern: "https://api.example.com/user/me",
            actions: [
                .setStatusCode(200),
                .setHeader(key: "Content-Type", value: "application/json"),
                .setBody(content: mockBody)
            ]
        )

        XCTAssertTrue(rule.matches("https://api.example.com/user/me"))
        XCTAssertEqual(rule.actions.count, 3)
    }

    func testCORSHeaderInjection() {
        let rule = RewriteRule(
            name: "CORS Headers",
            enabled: true,
            ruleType: .modifyResponse,
            matchType: .wildcard,
            matchPattern: "*",
            actions: [
                .setHeader(key: "Access-Control-Allow-Origin", value: "*"),
                .setHeader(key: "Access-Control-Allow-Methods", value: "GET, POST, PUT, DELETE")
            ]
        )

        XCTAssertTrue(rule.matches("https://any-domain.com/api"))
        XCTAssertTrue(rule.matches("http://example.com"))
    }

    func testReplaceAPIKeyInBody() {
        let rule = RewriteRule(
            name: "Replace API Key",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "api.example.com",
            actions: [
                .replaceBody(pattern: "old-api-key", replacement: "new-api-key")
            ]
        )

        let action = rule.actions.first
        XCTAssertEqual(action?.actionType, .replaceBody)
        XCTAssertEqual(action?.bodyPattern, "old-api-key")
        XCTAssertEqual(action?.bodyReplacement, "new-api-key")
    }

    // MARK: - Rule Equality Tests

    func testRuleEquality() {
        let id = UUID()

        let rule1 = RewriteRule(
            id: id,
            name: "Rule 1",
            ruleType: .modifyRequest,
            matchPattern: "https://example.com"
        )

        let rule2 = RewriteRule(
            id: id,
            name: "Rule 2",
            ruleType: .modifyResponse,
            matchPattern: "https://other.com"
        )

        let rule3 = RewriteRule(
            id: UUID(),
            name: "Rule 3",
            ruleType: .modifyRequest,
            matchPattern: "https://example.com"
        )

        XCTAssertEqual(rule1, rule2) // Same ID
        XCTAssertNotEqual(rule1, rule3) // Different ID
    }

    func testActionEquality() {
        let id = UUID()

        let action1 = RewriteAction(id: id, actionType: .setHeader)
        let action2 = RewriteAction(id: id, actionType: .removeHeader)
        let action3 = RewriteAction(id: UUID(), actionType: .setHeader)

        XCTAssertEqual(action1, action2) // Same ID
        XCTAssertNotEqual(action1, action3) // Different ID
    }

    // MARK: - Multiple Actions Tests

    func testMultipleActionsOnSameRule() {
        let rule = RewriteRule(
            name: "Multiple Actions",
            enabled: true,
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "api.example.com",
            actions: [
                .setHeader(key: "Authorization", value: "Bearer token"),
                .setHeader(key: "Content-Type", value: "application/json"),
                .removeHeader(key: "Cookie"),
                .replaceBody(pattern: "old", replacement: "new")
            ]
        )

        XCTAssertEqual(rule.actions.count, 4)

        let setHeaderActions = rule.actions.filter { $0.actionType == .setHeader }
        XCTAssertEqual(setHeaderActions.count, 2)

        let removeHeaderActions = rule.actions.filter { $0.actionType == .removeHeader }
        XCTAssertEqual(removeHeaderActions.count, 1)

        let replaceBodyActions = rule.actions.filter { $0.actionType == .replaceBody }
        XCTAssertEqual(replaceBodyActions.count, 1)
    }

    // MARK: - Date Tests

    func testRuleTimestamps() {
        let createdAt = Date()
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            matchPattern: "https://example.com",
            createdAt: createdAt,
            modifiedAt: createdAt
        )

        XCTAssertEqual(rule.createdAt, createdAt)
        XCTAssertEqual(rule.modifiedAt, createdAt)
    }
}
