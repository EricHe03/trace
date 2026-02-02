//
//  MatchCriteriaTests.swift
//  TraceTests
//
//  Created by Claude ​Code on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class MatchCriteriaTests: XCTestCase {

    // MARK: - MatchCriteria Tests

    func testMatchCriteriaInitialization() {
        let criteria = MatchCriteria()

        XCTAssertNil(criteria.url)
        XCTAssertTrue(criteria.methods.isEmpty)
        XCTAssertTrue(criteria.hosts.isEmpty)
        XCTAssertTrue(criteria.schemes.isEmpty)
        XCTAssertTrue(criteria.ports.isEmpty)
        XCTAssertTrue(criteria.headers.isEmpty)
        XCTAssertTrue(criteria.queryParams.isEmpty)
        XCTAssertTrue(criteria.statusCodes.isEmpty)
        XCTAssertTrue(criteria.contentTypes.isEmpty)
        XCTAssertTrue(criteria.bodyMatchers.isEmpty)
        XCTAssertEqual(criteria.logic, .and)
    }

    func testMatchCriteriaInitializationWithValues() {
        let urlMatcher = URLMatcher(matchType: .exact, pattern: "https://api.example.com")
        let methods: Set<HTTPMethod> = [.get, .post]
        let hosts = [StringMatcher(matchType: .contains, pattern: "example")]
        let schemes: Set<String> = ["https"]
        let ports: Set<Int> = [443]
        let headers = [HeaderMatcher(name: "Content-Type", matcher: StringMatcher(matchType: .exact, pattern: "application/json"))]
        let queryParams = [QueryParamMatcher(name: "id")]
        let statusCodes: Set<Int> = [200, 201]
        let contentTypes = [StringMatcher(matchType: .contains, pattern: "json")]
        let bodyMatchers = [BodyMatcher(matcherType: .regex, pattern: "test")]

        let criteria = MatchCriteria(
            url: urlMatcher,
            methods: methods,
            hosts: hosts,
            schemes: schemes,
            ports: ports,
            headers: headers,
            queryParams: queryParams,
            statusCodes: statusCodes,
            contentTypes: contentTypes,
            bodyMatchers: bodyMatchers,
            logic: .or
        )

        XCTAssertEqual(criteria.url?.pattern, "https://api.example.com")
        XCTAssertEqual(criteria.methods, methods)
        XCTAssertEqual(criteria.hosts.count, 1)
        XCTAssertEqual(criteria.schemes, schemes)
        XCTAssertEqual(criteria.ports, ports)
        XCTAssertEqual(criteria.headers.count, 1)
        XCTAssertEqual(criteria.queryParams.count, 1)
        XCTAssertEqual(criteria.statusCodes, statusCodes)
        XCTAssertEqual(criteria.contentTypes.count, 1)
        XCTAssertEqual(criteria.bodyMatchers.count, 1)
        XCTAssertEqual(criteria.logic, .or)
    }

    func testMatchCriteriaIsEmpty() {
        let emptyCriteria = MatchCriteria()
        XCTAssertTrue(emptyCriteria.isEmpty)

        let nonEmptyCriteria = MatchCriteria(
            url: URLMatcher(matchType: .exact, pattern: "test")
        )
        XCTAssertFalse(nonEmptyCriteria.isEmpty)

        let criteriaWithMethods = MatchCriteria(methods: [.get])
        XCTAssertFalse(criteriaWithMethods.isEmpty)
    }

    func testMatchCriteriaCodable() throws {
        let original = MatchCriteria(
            url: URLMatcher(matchType: .regex, pattern: ".*\\.example\\.com"),
            methods: [.get, .post],
            hosts: [StringMatcher(matchType: .wildcard, pattern: "*.example.com", caseSensitive: false)],
            schemes: ["https"],
            ports: [443, 8443],
            headers: [HeaderMatcher(name: "Authorization", condition: .exists)],
            queryParams: [QueryParamMatcher(name: "token", matcher: StringMatcher(matchType: .regex, pattern: "[a-z0-9]+"), condition: .equals)],
            statusCodes: [200, 201, 204],
            contentTypes: [StringMatcher(matchType: .contains, pattern: "json")],
            bodyMatchers: [BodyMatcher(matcherType: .jsonPath, pattern: "$.user.id")],
            logic: .or
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MatchCriteria.self, from: data)

        XCTAssertEqual(decoded.url?.matchType, original.url?.matchType)
        XCTAssertEqual(decoded.url?.pattern, original.url?.pattern)
        XCTAssertEqual(decoded.methods, original.methods)
        XCTAssertEqual(decoded.hosts.count, original.hosts.count)
        XCTAssertEqual(decoded.schemes, original.schemes)
        XCTAssertEqual(decoded.ports, original.ports)
        XCTAssertEqual(decoded.headers.count, original.headers.count)
        XCTAssertEqual(decoded.queryParams.count, original.queryParams.count)
        XCTAssertEqual(decoded.statusCodes, original.statusCodes)
        XCTAssertEqual(decoded.contentTypes.count, original.contentTypes.count)
        XCTAssertEqual(decoded.bodyMatchers.count, original.bodyMatchers.count)
        XCTAssertEqual(decoded.logic, original.logic)
    }

    // MARK: - URLMatcher Tests

    func testURLMatcherInitialization() {
        let matcher = URLMatcher(matchType: .exact, pattern: "https://example.com")
        XCTAssertEqual(matcher.matchType, .exact)
        XCTAssertEqual(matcher.pattern, "https://example.com")
    }

    func testURLMatcherMatches() {
        let exactMatcher = URLMatcher(matchType: .exact, pattern: "https://example.com")
        XCTAssertTrue(exactMatcher.matches("https://example.com"))
        XCTAssertTrue(exactMatcher.matches("HTTPS://EXAMPLE.COM"))
        XCTAssertFalse(exactMatcher.matches("https://example.com/path"))

        let wildcardMatcher = URLMatcher(matchType: .wildcard, pattern: "https://*.example.com")
        XCTAssertTrue(wildcardMatcher.matches("https://api.example.com"))
        XCTAssertTrue(wildcardMatcher.matches("https://www.example.com"))
        XCTAssertFalse(wildcardMatcher.matches("https://example.com"))
    }

    func testURLMatcherCodable() throws {
        let original = URLMatcher(matchType: .regex, pattern: "https://.*\\.example\\.com/.*")

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(URLMatcher.self, from: data)

        XCTAssertEqual(decoded.matchType, original.matchType)
        XCTAssertEqual(decoded.pattern, original.pattern)
    }

    // MARK: - StringMatcher Tests

    func testStringMatcherInitialization() {
        let matcher = StringMatcher(matchType: .contains, pattern: "test")
        XCTAssertEqual(matcher.matchType, .contains)
        XCTAssertEqual(matcher.pattern, "test")
        XCTAssertFalse(matcher.caseSensitive)

        let sensitiveMatcher = StringMatcher(matchType: .exact, pattern: "Test", caseSensitive: true)
        XCTAssertTrue(sensitiveMatcher.caseSensitive)
    }

    func testStringMatcherExactMatch() {
        let matcher = StringMatcher(matchType: .exact, pattern: "hello", caseSensitive: false)
        XCTAssertTrue(matcher.matches("hello"))
        XCTAssertTrue(matcher.matches("HELLO"))
        XCTAssertFalse(matcher.matches("hello world"))

        let sensitiveMatcher = StringMatcher(matchType: .exact, pattern: "Hello", caseSensitive: true)
        XCTAssertTrue(sensitiveMatcher.matches("Hello"))
        XCTAssertFalse(sensitiveMatcher.matches("hello"))
    }

    func testStringMatcherContains() {
        let matcher = StringMatcher(matchType: .contains, pattern: "test", caseSensitive: false)
        XCTAssertTrue(matcher.matches("this is a test"))
        XCTAssertTrue(matcher.matches("TEST"))
        XCTAssertTrue(matcher.matches("testing"))
        XCTAssertFalse(matcher.matches("no match"))
    }

    func testStringMatcherWildcard() {
        let matcher = StringMatcher(matchType: .wildcard, pattern: "*.example.com", caseSensitive: false)
        XCTAssertTrue(matcher.matches("api.example.com"))
        XCTAssertTrue(matcher.matches("www.example.com"))
        XCTAssertFalse(matcher.matches("example.com"))
        XCTAssertFalse(matcher.matches("api.example.org"))

        let multiWildcard = StringMatcher(matchType: .wildcard, pattern: "test*file*.txt", caseSensitive: false)
        XCTAssertTrue(multiWildcard.matches("test_file_1.txt"))
        XCTAssertTrue(multiWildcard.matches("testfile.txt"))
        XCTAssertFalse(multiWildcard.matches("test.txt"))
    }

    func testStringMatcherRegex() {
        let matcher = StringMatcher(matchType: .regex, pattern: "^[0-9]{3}$", caseSensitive: false)
        XCTAssertTrue(matcher.matches("123"))
        XCTAssertFalse(matcher.matches("12"))
        XCTAssertFalse(matcher.matches("1234"))
        XCTAssertFalse(matcher.matches("abc"))
    }

    func testStringMatcherCodable() throws {
        let original = StringMatcher(matchType: .regex, pattern: "[a-z]+", caseSensitive: true)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(StringMatcher.self, from: data)

        XCTAssertEqual(decoded.matchType, original.matchType)
        XCTAssertEqual(decoded.pattern, original.pattern)
        XCTAssertEqual(decoded.caseSensitive, original.caseSensitive)
    }

    // MARK: - HeaderMatcher Tests

    func testHeaderMatcherInitialization() {
        let matcher = HeaderMatcher(name: "Content-Type")
        XCTAssertEqual(matcher.name, "Content-Type")
        XCTAssertNil(matcher.matcher)
        XCTAssertEqual(matcher.condition, .exists)
    }

    func testHeaderMatcherWithMatcher() {
        let stringMatcher = StringMatcher(matchType: .contains, pattern: "json")
        let matcher = HeaderMatcher(name: "Content-Type", matcher: stringMatcher, condition: .equals)

        XCTAssertEqual(matcher.name, "Content-Type")
        XCTAssertNotNil(matcher.matcher)
        XCTAssertEqual(matcher.condition, .equals)
    }

    func testHeaderMatcherCodable() throws {
        let original = HeaderMatcher(
            name: "Authorization",
            matcher: StringMatcher(matchType: .regex, pattern: "Bearer.*"),
            condition: .regex
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HeaderMatcher.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.matcher?.pattern, original.matcher?.pattern)
        XCTAssertEqual(decoded.condition, original.condition)
    }

    // MARK: - QueryParamMatcher Tests

    func testQueryParamMatcherInitialization() {
        let matcher = QueryParamMatcher(name: "id")
        XCTAssertEqual(matcher.name, "id")
        XCTAssertNil(matcher.matcher)
        XCTAssertEqual(matcher.condition, .exists)
    }

    func testQueryParamMatcherWithMatcher() {
        let stringMatcher = StringMatcher(matchType: .regex, pattern: "[0-9]+")
        let matcher = QueryParamMatcher(name: "id", matcher: stringMatcher, condition: .equals)

        XCTAssertEqual(matcher.name, "id")
        XCTAssertNotNil(matcher.matcher)
        XCTAssertEqual(matcher.condition, .equals)
    }

    func testQueryParamMatcherCodable() throws {
        let original = QueryParamMatcher(
            name: "token",
            matcher: StringMatcher(matchType: .exact, pattern: "abc123"),
            condition: .equals
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(QueryParamMatcher.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.matcher?.pattern, original.matcher?.pattern)
        XCTAssertEqual(decoded.condition, original.condition)
    }

    // MARK: - BodyMatcher Tests

    func testBodyMatcherInitialization() {
        let matcher = BodyMatcher(matcherType: .regex, pattern: "test.*pattern")
        XCTAssertEqual(matcher.matcherType, .regex)
        XCTAssertEqual(matcher.pattern, "test.*pattern")
    }

    func testBodyMatcherAllTypes() {
        let regexMatcher = BodyMatcher(matcherType: .regex, pattern: "pattern")
        XCTAssertEqual(regexMatcher.matcherType, .regex)

        let jsonPathMatcher = BodyMatcher(matcherType: .jsonPath, pattern: "$.user.id")
        XCTAssertEqual(jsonPathMatcher.matcherType, .jsonPath)

        let xpathMatcher = BodyMatcher(matcherType: .xpath, pattern: "//user/id")
        XCTAssertEqual(xpathMatcher.matcherType, .xpath)

        let containsMatcher = BodyMatcher(matcherType: .contains, pattern: "substring")
        XCTAssertEqual(containsMatcher.matcherType, .contains)
    }

    func testBodyMatcherCodable() throws {
        let original = BodyMatcher(matcherType: .jsonPath, pattern: "$.data[*].id")

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BodyMatcher.self, from: data)

        XCTAssertEqual(decoded.matcherType, original.matcherType)
        XCTAssertEqual(decoded.pattern, original.pattern)
    }

    // MARK: - Enum Tests

    func testBodyMatcherTypeRawValues() {
        XCTAssertEqual(BodyMatcherType.regex.rawValue, "regex")
        XCTAssertEqual(BodyMatcherType.jsonPath.rawValue, "jsonPath")
        XCTAssertEqual(BodyMatcherType.xpath.rawValue, "xpath")
        XCTAssertEqual(BodyMatcherType.contains.rawValue, "contains")
    }

    func testMatchLogicRawValues() {
        XCTAssertEqual(MatchLogic.and.rawValue, "and")
        XCTAssertEqual(MatchLogic.or.rawValue, "or")
    }

    func testMatchConditionRawValues() {
        XCTAssertEqual(MatchCondition.exists.rawValue, "exists")
        XCTAssertEqual(MatchCondition.equals.rawValue, "equals")
        XCTAssertEqual(MatchCondition.contains.rawValue, "contains")
        XCTAssertEqual(MatchCondition.regex.rawValue, "regex")
        XCTAssertEqual(MatchCondition.notExists.rawValue, "notExists")
        XCTAssertEqual(MatchCondition.notEquals.rawValue, "notEquals")
    }

    func testMatchingStrategyRawValues() {
        XCTAssertEqual(MatchingStrategy.firstMatch.rawValue, "firstMatch")
        XCTAssertEqual(MatchingStrategy.allMatches.rawValue, "allMatches")
    }

    func testEnumCodable() throws {
        let bodyMatcherType: BodyMatcherType = .jsonPath
        let matchLogic: MatchLogic = .or
        let matchCondition: MatchCondition = .regex
        let matchingStrategy: MatchingStrategy = .firstMatch

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let bodyMatcherData = try encoder.encode(bodyMatcherType)
        let decodedBodyMatcher = try decoder.decode(BodyMatcherType.self, from: bodyMatcherData)
        XCTAssertEqual(decodedBodyMatcher, bodyMatcherType)

        let matchLogicData = try encoder.encode(matchLogic)
        let decodedMatchLogic = try decoder.decode(MatchLogic.self, from: matchLogicData)
        XCTAssertEqual(decodedMatchLogic, matchLogic)

        let matchConditionData = try encoder.encode(matchCondition)
        let decodedMatchCondition = try decoder.decode(MatchCondition.self, from: matchConditionData)
        XCTAssertEqual(decodedMatchCondition, matchCondition)

        let matchingStrategyData = try encoder.encode(matchingStrategy)
        let decodedMatchingStrategy = try decoder.decode(MatchingStrategy.self, from: matchingStrategyData)
        XCTAssertEqual(decodedMatchingStrategy, matchingStrategy)
    }

    // MARK: - Edge Cases

    func testMatchCriteriaWithEmptyCollections() throws {
        let criteria = MatchCriteria(
            methods: [],
            hosts: [],
            schemes: [],
            ports: [],
            headers: [],
            queryParams: [],
            statusCodes: [],
            contentTypes: [],
            bodyMatchers: []
        )

        XCTAssertTrue(criteria.isEmpty)

        let encoder = JSONEncoder()
        let data = try encoder.encode(criteria)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MatchCriteria.self, from: data)

        XCTAssertTrue(decoded.isEmpty)
    }

    func testStringMatcherWithEmptyPattern() {
        let matcher = StringMatcher(matchType: .exact, pattern: "")
        XCTAssertTrue(matcher.matches(""))
        XCTAssertFalse(matcher.matches("anything"))
    }

    func testStringMatcherWithSpecialCharacters() {
        let matcher = StringMatcher(matchType: .exact, pattern: "test@#$%^&*()")
        XCTAssertTrue(matcher.matches("test@#$%^&*()"))

        let wildcardMatcher = StringMatcher(matchType: .wildcard, pattern: "test*file")
        XCTAssertTrue(wildcardMatcher.matches("test@#$file"))
    }

    func testHeaderMatcherWithNilMatcher() throws {
        let matcher = HeaderMatcher(name: "X-Custom-Header", matcher: nil, condition: .exists)

        let encoder = JSONEncoder()
        let data = try encoder.encode(matcher)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HeaderMatcher.self, from: data)

        XCTAssertEqual(decoded.name, matcher.name)
        XCTAssertNil(decoded.matcher)
        XCTAssertEqual(decoded.condition, matcher.condition)
    }

    func testMatchCriteriaDefaultValues() {
        let criteria = MatchCriteria()

        XCTAssertEqual(criteria.logic, .and, "Default logic should be .and")
        XCTAssertTrue(criteria.methods.isEmpty, "Default methods should be empty")
        XCTAssertTrue(criteria.hosts.isEmpty, "Default hosts should be empty")
        XCTAssertTrue(criteria.schemes.isEmpty, "Default schemes should be empty")
        XCTAssertTrue(criteria.ports.isEmpty, "Default ports should be empty")
    }

    func testStringMatcherCaseSensitivityDefault() {
        let matcher = StringMatcher(matchType: .exact, pattern: "Test")
        XCTAssertFalse(matcher.caseSensitive, "Default should be case insensitive")
    }
}
