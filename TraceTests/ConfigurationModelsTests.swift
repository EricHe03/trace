//
//  ConfigurationModelsTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class ConfigurationModelsTests: XCTestCase {

    // MARK: - MatchType Tests

    func testMatchTypeDisplayNames() {
        XCTAssertEqual(MatchType.wildcard.displayName, "Wildcard")
        XCTAssertEqual(MatchType.regex.displayName, "Regex")
        XCTAssertEqual(MatchType.exact.displayName, "Exact Match")
        XCTAssertEqual(MatchType.contains.displayName, "Contains")
    }

    func testMatchTypeCodable() throws {
        for matchType in MatchType.allCases {
            let encoded = try JSONEncoder().encode(matchType)
            let decoded = try JSONDecoder().decode(MatchType.self, from: encoded)
            XCTAssertEqual(decoded, matchType)
        }
    }

    // MARK: - RuleType Tests

    func testRuleTypeDisplayNames() {
        XCTAssertEqual(RuleType.redirect.displayName, "Redirect")
        XCTAssertEqual(RuleType.modifyRequest.displayName, "Modify Request")
        XCTAssertEqual(RuleType.modifyResponse.displayName, "Modify Response")
        XCTAssertEqual(RuleType.block.displayName, "Block Request")
        XCTAssertEqual(RuleType.map.displayName, "Map Local")
    }

    func testRuleTypeDescriptions() {
        XCTAssertFalse(RuleType.redirect.description.isEmpty)
        XCTAssertFalse(RuleType.block.description.isEmpty)
    }

    // MARK: - RewriteRule Tests

    func testRewriteRuleInit() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "*.ads.com"
        )

        XCTAssertEqual(rule.name, "Test Rule")
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.ruleType, .block)
        XCTAssertEqual(rule.matchType, .wildcard)
        XCTAssertEqual(rule.matchPattern, "*.ads.com")
    }

    func testRewriteRuleMatches() {
        let rule = RewriteRule(
            name: "Test Rule",
            enabled: true,
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "*.example.com"
        )

        XCTAssertTrue(rule.matches("https://api.example.com/test"))
        XCTAssertTrue(rule.matches("https://www.example.com"))
        XCTAssertFalse(rule.matches("https://other.com"))
    }

    func testRewriteRuleMatchesExact() {
        let rule = RewriteRule(
            name: "Exact Rule",
            enabled: true,
            ruleType: .block,
            matchType: .exact,
            matchPattern: "https://api.example.com/v1/users"
        )

        XCTAssertTrue(rule.matches("https://api.example.com/v1/users"))
        XCTAssertFalse(rule.matches("https://api.example.com/v1/users/123"))
    }

    func testRewriteRuleMatchesContains() {
        let rule = RewriteRule(
            name: "Contains Rule",
            enabled: true,
            ruleType: .block,
            matchType: .contains,
            matchPattern: "example"
        )

        XCTAssertTrue(rule.matches("https://example.com"))
        XCTAssertTrue(rule.matches("https://api.example.com"))
        XCTAssertFalse(rule.matches("https://other.com"))
    }

    func testRewriteRuleMatchesRegex() {
        let rule = RewriteRule(
            name: "Regex Rule",
            enabled: true,
            ruleType: .block,
            matchType: .regex,
            matchPattern: "https://.*\\.example\\.com/.*"
        )

        XCTAssertTrue(rule.matches("https://api.example.com/test"))
        XCTAssertTrue(rule.matches("https://www.example.com/page"))
        XCTAssertFalse(rule.matches("https://example.com"))
    }

    func testRewriteRuleDisabled() {
        let rule = RewriteRule(
            name: "Disabled Rule",
            enabled: false,
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: "*"
        )

        XCTAssertFalse(rule.matches("https://example.com"))
    }

    func testRewriteRuleCodable() throws {
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .redirect,
            actions: [
                RewriteAction.redirectTo(url: "https://new.example.com")
            ]
        )

        let encoded = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(RewriteRule.self, from: encoded)

        XCTAssertEqual(decoded.name, rule.name)
        XCTAssertEqual(decoded.ruleType, rule.ruleType)
    }

    // MARK: - RewriteAction Tests

    func testRewriteActionSetHeader() {
        let action = RewriteAction.setHeader(key: "X-Custom", value: "test")

        XCTAssertEqual(action.actionType, .setHeader)
        XCTAssertEqual(action.headerKey, "X-Custom")
        XCTAssertEqual(action.headerValue, "test")
    }

    func testRewriteActionRemoveHeader() {
        let action = RewriteAction.removeHeader(key: "Authorization")

        XCTAssertEqual(action.actionType, .removeHeader)
        XCTAssertEqual(action.headerKey, "Authorization")
    }

    func testRewriteActionReplaceBody() {
        let action = RewriteAction.replaceBody(pattern: "old", replacement: "new")

        XCTAssertEqual(action.actionType, .replaceBody)
        XCTAssertEqual(action.bodyPattern, "old")
        XCTAssertEqual(action.bodyReplacement, "new")
    }

    func testRewriteActionSetBody() {
        let action = RewriteAction.setBody(content: "{\"key\": \"value\"}")

        XCTAssertEqual(action.actionType, .setBody)
        XCTAssertEqual(action.bodyContent, "{\"key\": \"value\"}")
    }

    func testRewriteActionSetStatusCode() {
        let action = RewriteAction.setStatusCode(404)

        XCTAssertEqual(action.actionType, .setStatusCode)
        XCTAssertEqual(action.statusCode, 404)
    }

    func testRewriteActionAddDelay() {
        let action = RewriteAction.addDelay(milliseconds: 500)

        XCTAssertEqual(action.actionType, .addDelay)
        XCTAssertEqual(action.delayMilliseconds, 500)
    }

    func testRewriteActionRedirectTo() {
        let action = RewriteAction.redirectTo(url: "https://new.example.com")

        XCTAssertEqual(action.actionType, .redirectTo)
        XCTAssertEqual(action.redirectUrl, "https://new.example.com")
    }

    // MARK: - HostEntry Tests

    func testHostEntryInit() {
        let entry = HostEntry(
            name: "Local API",
            hostname: "api.example.com",
            targetIP: "192.168.1.100",
            targetPort: 8080
        )

        XCTAssertEqual(entry.name, "Local API")
        XCTAssertEqual(entry.hostname, "api.example.com")
        XCTAssertEqual(entry.targetIP, "192.168.1.100")
        XCTAssertEqual(entry.targetPort, 8080)
    }

    func testHostEntryMatches() {
        let entry = HostEntry(
            name: "Test",
            hostname: "api.example.com",
            targetIP: "192.168.1.100"
        )

        XCTAssertTrue(entry.matches("https://api.example.com/test"))
        XCTAssertTrue(entry.matches("api.example.com"))
        XCTAssertFalse(entry.matches("https://other.com"))
    }

    func testHostEntryWildcardMatch() {
        let entry = HostEntry(
            name: "Wildcard",
            hostname: "*.example.com",
            targetIP: "192.168.1.100"
        )

        XCTAssertTrue(entry.matches("https://api.example.com"))
        XCTAssertTrue(entry.matches("https://www.example.com"))
        XCTAssertFalse(entry.matches("https://example.com"))
    }

    func testHostEntryValidation() {
        let validEntry = HostEntry(
            name: "Valid",
            hostname: "example.com",
            targetIP: "192.168.1.1",
            targetPort: 8080
        )

        XCTAssertTrue(validEntry.isValid)
        XCTAssertEqual(validEntry.validationErrors.count, 0)
    }

    func testHostEntryInvalidHostname() {
        let entry = HostEntry(
            name: "Invalid",
            hostname: "invalid!@#hostname",
            targetIP: "192.168.1.1"
        )

        XCTAssertFalse(entry.isValidHostname)
        XCTAssertFalse(entry.isValid)
    }

    func testHostEntryInvalidIP() {
        let entry = HostEntry(
            name: "Invalid",
            hostname: "example.com",
            targetIP: "999.999.999.999"
        )

        XCTAssertFalse(entry.isValidTargetIP)
    }

    // MARK: - RequestMap Tests

    func testRequestMapInit() {
        let mockResponse = MockResponse(statusCode: 200, statusMessage: "OK")
        let map = RequestMap(
            name: "Test Map",
            matchType: .exact,
            matchPattern: "https://api.example.com/test",
            mockResponse: mockResponse
        )

        XCTAssertEqual(map.name, "Test Map")
        XCTAssertEqual(map.matchType, .exact)
        XCTAssertEqual(map.mockResponse.statusCode, 200)
    }

    func testRequestMapMatches() {
        let mockResponse = MockResponse()
        let map = RequestMap(
            name: "Test Map",
            matchType: .wildcard,
            matchPattern: "*.example.com/*",
            mockResponse: mockResponse
        )

        XCTAssertTrue(map.matches("https://api.example.com/test"))
        XCTAssertFalse(map.matches("https://other.com/test"))
    }

    func testRequestMapFromRequest() {
        var request = NetworkRequest.sample
        request.url = "https://api.example.com/test"

        let map = RequestMap.fromRequest(request, name: "Test Mock")

        XCTAssertEqual(map.name, "Test Mock")
        XCTAssertEqual(map.matchType, .exact)
        XCTAssertEqual(map.matchPattern, request.url)
    }

    // MARK: - MockResponse Tests

    func testMockResponseInit() {
        let response = MockResponse(
            statusCode: 404,
            statusMessage: "Not Found",
            headers: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            bodySource: .inline,
            bodyContent: Data("{\"error\": \"Not found\"}".utf8),
            delay: 100
        )

        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(response.statusMessage, "Not Found")
        XCTAssertEqual(response.delay, 100)
    }

    func testMockResponseGetBodyInline() throws {
        let bodyData = Data("{\"key\": \"value\"}".utf8)
        let response = MockResponse(
            bodySource: .inline,
            bodyContent: bodyData
        )

        let body = try response.getBody()
        XCTAssertEqual(body, bodyData)
    }

    func testMockResponseGetBodyEmpty() throws {
        let response = MockResponse(
            bodySource: .inline,
            bodyContent: nil
        )

        let body = try response.getBody()
        XCTAssertEqual(body, Data())
    }

    // MARK: - Script Tests

    func testScriptInit() {
        let script = Script(
            name: "Test Script",
            scriptType: .request,
            matchType: .wildcard,
            matchPattern: "*.example.com",
            code: "console.log('test');"
        )

        XCTAssertEqual(script.name, "Test Script")
        XCTAssertEqual(script.scriptType, .request)
        XCTAssertEqual(script.code, "console.log('test');")
    }

    func testScriptMatches() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchPattern: "example.com"
        )

        XCTAssertTrue(script.matches("https://api.example.com/test"))
        XCTAssertFalse(script.matches("https://other.com"))
    }

    func testScriptMatchesWithoutPattern() {
        let script = Script(
            name: "Global Script",
            scriptType: .both,
            matchPattern: nil
        )

        XCTAssertTrue(script.matches("https://any.com"))
    }

    // MARK: - Breakpoint Tests

    func testBreakpointInit() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .both,
            matchType: .wildcard,
            matchPattern: "*.example.com"
        )
        let breakpoint = Breakpoint(
            name: "Test Breakpoint",
            configuration: config
        )

        XCTAssertEqual(breakpoint.name, "Test Breakpoint")
        XCTAssertTrue(breakpoint.configuration.enabled)
    }

    func testBreakpointShouldBreakOnRequest() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*.example.com",
            methods: [.get, .post]
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com", method: .delete))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://other.com", method: .get))
    }

    func testBreakpointShouldBreakOnResponse() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .response,
            matchType: .wildcard,
            matchPattern: "*.example.com",
            statusCodes: [200, 404]
        )

        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 200))
        XCTAssertFalse(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 500))
    }

    // MARK: - PausedRequest Tests

    func testPausedRequestInit() {
        let request = PausedRequest(
            id: "test-id",
            url: "https://api.example.com",
            method: .get,
            headers: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            breakpointType: .request
        )

        XCTAssertEqual(request.id, "test-id")
        XCTAssertEqual(request.url, "https://api.example.com")
        XCTAssertEqual(request.method, .get)
        XCTAssertTrue(request.isPaused)
    }

    func testPausedRequestModifications() {
        var request = PausedRequest(
            id: "test-id",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )

        XCTAssertFalse(request.hasModifications)

        request.modifiedUrl = "https://api-v2.example.com"
        XCTAssertTrue(request.hasModifications)
        XCTAssertEqual(request.effectiveUrl, "https://api-v2.example.com")
    }

    // MARK: - Favorite Tests

    func testFavoriteInit() {
        let favorite = Favorite(
            requestId: UUID(),
            name: "Test Favorite",
            notes: "Important request"
        )

        XCTAssertEqual(favorite.name, "Test Favorite")
        XCTAssertEqual(favorite.notes, "Important request")
    }

    func testFavoriteCodable() throws {
        let favorite = Favorite(
            requestId: UUID(),
            name: "Test",
            notes: "Notes"
        )

        let encoded = try JSONEncoder().encode(favorite)
        let decoded = try JSONDecoder().decode(Favorite.self, from: encoded)

        XCTAssertEqual(decoded.name, favorite.name)
        XCTAssertEqual(decoded.notes, favorite.notes)
    }

    // MARK: - Edge Cases

    func testRewriteRuleWithInvalidRegex() {
        let rule = RewriteRule(
            name: "Invalid Regex",
            enabled: true,
            ruleType: .block,
            matchType: .regex,
            matchPattern: "[invalid(regex"
        )

        // Should handle invalid regex gracefully
        XCTAssertFalse(rule.matches("https://example.com"))
    }

    func testEmptyMatchPattern() {
        let rule = RewriteRule(
            name: "Empty Pattern",
            enabled: true,
            ruleType: .block,
            matchType: .wildcard,
            matchPattern: ""
        )

        // Empty pattern should not match
        XCTAssertFalse(rule.matches("https://example.com"))
    }
}
