//
//  RuleInspectorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
@testable import TraceFeatures
import XCTest

final class RuleInspectorTests: XCTestCase {
    // MARK: - Initialization and Basic Tests

    func testEvaluateWithSimpleMatchPattern() {
        // Arrange
        let rule = makeRewriteRule(
            name: "Test Rule",
            matchURL: "*.example.com",
            enabled: true
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Rule should match the URL")
        XCTAssertEqual(evaluation.details.count, 1, "Should have one matcher evaluation")
        XCTAssertEqual(evaluation.details.first?.matcher, "url", "Matcher should be url")
        XCTAssertTrue(evaluation.details.first?.passed ?? false, "URL matcher should pass")
    }

    func testEvaluateWithNonMatchingPattern() {
        // Arrange
        let rule = makeRewriteRule(
            name: "Test Rule",
            matchURL: "*.example.com",
            enabled: true
        )
        let request = makeNetworkRequest(url: "https://api.other.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertFalse(evaluation.passed, "Rule should not match the URL")
        XCTAssertEqual(evaluation.details.count, 1, "Should have one matcher evaluation")
        XCTAssertFalse(evaluation.details.first?.passed ?? true, "URL matcher should fail")
    }

    func testEvaluateWithExactMatch() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .exact, pattern: "https://api.example.com/test")
        )
        let rule = RewriteRule(
            name: "Exact Match Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Exact match should pass")
        XCTAssertTrue(evaluation.details.first?.passed ?? false, "URL matcher should pass")
    }

    func testEvaluateWithWildcardMatch() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .wildcard, pattern: "https://api.*.com/*")
        )
        let rule = RewriteRule(
            name: "Wildcard Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Wildcard match should pass")
    }

    func testEvaluateWithContainsMatch() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example")
        )
        let rule = RewriteRule(
            name: "Contains Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Contains match should pass")
    }

    func testEvaluateWithRegexMatch() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .regex, pattern: "https://api\\.[a-z]+\\.com/.*")
        )
        let rule = RewriteRule(
            name: "Regex Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Regex match should pass")
    }

    // MARK: - Match Criteria Tests

    func testEvaluateWithEmptyMatchCriteria() {
        // Arrange
        let criteria = MatchCriteria()
        let rule = RewriteRule(
            name: "Empty Criteria Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Empty criteria should pass")
    }

    func testEvaluateWithMethodCriteria() {
        // Arrange
        let criteria = MatchCriteria(
            methods: [.get, .post]
        )
        let rule = RewriteRule(
            name: "Method Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let getRequest = makeNetworkRequest(url: "https://api.example.com/test", method: .get)
        let deleteRequest = makeNetworkRequest(url: "https://api.example.com/test", method: .delete)

        // Act
        let getEvaluation = RuleInspector.evaluate(rule: rule, request: getRequest, target: .request)
        let deleteEvaluation = RuleInspector.evaluate(rule: rule, request: deleteRequest, target: .request)

        // Assert
        XCTAssertTrue(getEvaluation.passed, "GET request should match")
        XCTAssertFalse(deleteEvaluation.passed, "DELETE request should not match")
    }

    func testEvaluateWithStatusCodeCriteria() {
        // Arrange
        let criteria = MatchCriteria(
            statusCodes: [200, 201, 204]
        )
        let rule = RewriteRule(
            name: "Status Code Rule",
            enabled: true,
            ruleType: .modifyResponse,
            matchCriteria: criteria
        )
        let successRequest = makeNetworkRequest(url: "https://api.example.com/test", statusCode: 200)
        let errorRequest = makeNetworkRequest(url: "https://api.example.com/test", statusCode: 404)

        // Act
        let successEvaluation = RuleInspector.evaluate(rule: rule, request: successRequest, target: .response)
        let errorEvaluation = RuleInspector.evaluate(rule: rule, request: errorRequest, target: .response)

        // Assert
        XCTAssertTrue(successEvaluation.passed, "200 status code should match")
        XCTAssertFalse(errorEvaluation.passed, "404 status code should not match")
    }

    func testEvaluateWithMultipleCriteriaAnd() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example"),
            methods: [.get],
            logic: .and
        )
        let rule = RewriteRule(
            name: "Multiple Criteria AND",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let matchingRequest = makeNetworkRequest(url: "https://api.example.com/test", method: .get)
        let nonMatchingRequest = makeNetworkRequest(url: "https://api.example.com/test", method: .post)

        // Act
        let matchingEvaluation = RuleInspector.evaluate(rule: rule, request: matchingRequest, target: .request)
        let nonMatchingEvaluation = RuleInspector.evaluate(rule: rule, request: nonMatchingRequest, target: .request)

        // Assert
        XCTAssertTrue(matchingEvaluation.passed, "Both criteria should match")
        XCTAssertFalse(nonMatchingEvaluation.passed, "Method should not match")
    }

    func testEvaluateWithMultipleCriteriaOr() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example"),
            methods: [.post],
            logic: .or
        )
        let rule = RewriteRule(
            name: "Multiple Criteria OR",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test", method: .get)

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "URL criteria should match (OR logic)")
    }

    // MARK: - Target Tests

    func testEvaluateWithRequestTarget() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example")
        )
        let rule = RewriteRule(
            name: "Request Target Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Request target should match")
    }

    func testEvaluateWithResponseTarget() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example"),
            statusCodes: [200]
        )
        let rule = RewriteRule(
            name: "Response Target Rule",
            enabled: true,
            ruleType: .modifyResponse,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test", statusCode: 200)

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .response)

        // Assert
        XCTAssertTrue(evaluation.passed, "Response target should match")
    }

    // MARK: - Evaluation Details Tests

    func testEvaluationDetailsContainsMatcher() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .exact, pattern: "https://api.example.com/test")
        )
        let rule = RewriteRule(
            name: "Details Test Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertFalse(evaluation.details.isEmpty, "Should have details")
        XCTAssertEqual(evaluation.details.first?.matcher, "url", "Should have url matcher")
    }

    func testEvaluationDetailsContainsMessage() {
        // Arrange
        let rule = makeRewriteRule(
            name: "Message Test Rule",
            matchURL: "*.example.com",
            enabled: true
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertNotNil(evaluation.details.first?.message, "Should have message")
        XCTAssertEqual(evaluation.details.first?.message, "*.example.com", "Message should be the pattern")
    }

    func testEvaluationDetailsWithMultipleMatchers() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example"),
            methods: [.get],
            statusCodes: [200]
        )
        let rule = RewriteRule(
            name: "Multiple Matchers Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test", method: .get, statusCode: 200)

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertGreaterThanOrEqual(evaluation.details.count, 2, "Should have multiple matcher details")
    }

    // MARK: - Edge Cases

    func testEvaluateWithDisabledRule() {
        // Arrange
        let rule = makeRewriteRule(
            name: "Disabled Rule",
            matchURL: "*.example.com",
            enabled: false
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertFalse(evaluation.passed, "Disabled rule should not match")
    }

    func testEvaluateWithEmptyURL() {
        // Arrange
        let rule = makeRewriteRule(
            name: "Test Rule",
            matchURL: "*.example.com",
            enabled: true
        )
        let request = makeNetworkRequest(url: "")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertFalse(evaluation.passed, "Empty URL should not match")
    }

    func testEvaluateWithInvalidRegex() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .regex, pattern: "[invalid(regex")
        )
        let rule = RewriteRule(
            name: "Invalid Regex Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertFalse(evaluation.passed, "Invalid regex should not match")
    }

    func testEvaluateWithNilStatusCode() {
        // Arrange
        let criteria = MatchCriteria(
            statusCodes: [200]
        )
        let rule = RewriteRule(
            name: "Status Code Rule",
            enabled: true,
            ruleType: .modifyResponse,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test", statusCode: nil)

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .response)

        // Assert
        XCTAssertFalse(evaluation.passed, "Nil status code should not match 200")
    }

    func testEvaluateWithCaseInsensitivePattern() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "EXAMPLE")
        )
        let rule = RewriteRule(
            name: "Case Insensitive Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Should match case-insensitively")
    }

    func testEvaluateWithSpecialCharacters() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "/test?param=value&other=123")
        )
        let rule = RewriteRule(
            name: "Special Chars Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test?param=value&other=123")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Should match with special characters")
    }

    func testEvaluateWithUnicodeURL() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "測試")
        )
        let rule = RewriteRule(
            name: "Unicode Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/測試")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Should match Unicode URLs")
    }

    // MARK: - Complex Scenarios

    func testEvaluateWithComplexWildcard() {
        // Arrange
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .wildcard, pattern: "https://*/api/*/users")
        )
        let rule = RewriteRule(
            name: "Complex Wildcard Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/api/v1/users")

        // Act
        let evaluation = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertTrue(evaluation.passed, "Complex wildcard should match")
    }

    func testEvaluateWithMultipleRequests() {
        // Arrange
        let rule = makeRewriteRule(
            name: "Test Rule",
            matchURL: "*.example.com",
            enabled: true
        )
        let request1 = makeNetworkRequest(url: "https://api.example.com/test1")
        let request2 = makeNetworkRequest(url: "https://api.example.com/test2")
        let request3 = makeNetworkRequest(url: "https://api.other.com/test3")

        // Act
        let eval1 = RuleInspector.evaluate(rule: rule, request: request1, target: .request)
        let eval2 = RuleInspector.evaluate(rule: rule, request: request2, target: .request)
        let eval3 = RuleInspector.evaluate(rule: rule, request: request3, target: .request)

        // Assert
        XCTAssertTrue(eval1.passed, "Request 1 should match")
        XCTAssertTrue(eval2.passed, "Request 2 should match")
        XCTAssertFalse(eval3.passed, "Request 3 should not match")
    }

    func testEvaluatePreservesRuleState() {
        // Arrange
        let rule = makeRewriteRule(
            name: "Test Rule",
            matchURL: "*.example.com",
            enabled: true
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        // Act
        let evaluation1 = RuleInspector.evaluate(rule: rule, request: request, target: .request)
        let evaluation2 = RuleInspector.evaluate(rule: rule, request: request, target: .request)

        // Assert
        XCTAssertEqual(evaluation1.passed, evaluation2.passed, "Multiple evaluations should be consistent")
    }

    // MARK: - Performance Tests

    func testEvaluatePerformance() {
        let rule = makeRewriteRule(
            name: "Performance Test Rule",
            matchURL: "*.example.com",
            enabled: true
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test")

        measure {
            _ = RuleInspector.evaluate(rule: rule, request: request, target: .request)
        }
    }

    func testEvaluateComplexCriteriaPerformance() {
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .regex, pattern: "https://api\\.[a-z]+\\.com/.*"),
            methods: [.get, .post, .put, .delete],
            statusCodes: [200, 201, 204, 400, 401, 403, 404, 500],
            logic: .and
        )
        let rule = RewriteRule(
            name: "Complex Criteria Rule",
            enabled: true,
            ruleType: .modifyRequest,
            matchCriteria: criteria
        )
        let request = makeNetworkRequest(url: "https://api.example.com/test", method: .get, statusCode: 200)

        measure {
            _ = RuleInspector.evaluate(rule: rule, request: request, target: .request)
        }
    }
}
