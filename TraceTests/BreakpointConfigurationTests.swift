//
//  BreakpointConfigurationTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class BreakpointConfigurationTests: XCTestCase {

    // MARK: - shouldBreakOnRequest Tests

    func testShouldBreakOnRequestDisabled() {
        let config = BreakpointConfiguration(
            enabled: false,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*"
        )

        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
    }

    func testShouldBreakOnRequestWrongType() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .response,
            matchType: .wildcard,
            matchPattern: "*"
        )

        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
    }

    func testShouldBreakOnRequestBothType() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .both,
            matchType: .exact,
            matchPattern: "https://api.example.com/test"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test", method: .get))
    }

    func testShouldBreakOnRequestMethodFilter() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*",
            methods: [.get, .post]
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .post))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com", method: .put))
    }

    func testShouldBreakOnRequestEmptyMethodFilter() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*",
            methods: []
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .post))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .delete))
    }

    // MARK: - shouldBreakOnResponse Tests

    func testShouldBreakOnResponseDisabled() {
        let config = BreakpointConfiguration(
            enabled: false,
            breakpointType: .response,
            matchType: .wildcard,
            matchPattern: "*"
        )

        XCTAssertFalse(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 200))
    }

    func testShouldBreakOnResponseWrongType() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*"
        )

        XCTAssertFalse(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 200))
    }

    func testShouldBreakOnResponseBothType() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .both,
            matchType: .exact,
            matchPattern: "https://api.example.com/test"
        )

        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com/test", statusCode: 200))
    }

    func testShouldBreakOnResponseStatusCodeFilter() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .response,
            matchType: .wildcard,
            matchPattern: "*",
            statusCodes: [200, 404, 500]
        )

        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 200))
        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 404))
        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 500))
        XCTAssertFalse(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 302))
    }

    func testShouldBreakOnResponseEmptyStatusCodeFilter() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .response,
            matchType: .wildcard,
            matchPattern: "*",
            statusCodes: []
        )

        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 200))
        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 404))
        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com", statusCode: 500))
    }

    // MARK: - URL Pattern Matching Tests

    func testMatchUrlNoPattern() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: nil
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://other.com", method: .get))
    }

    func testMatchUrlEmptyPattern() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: ""
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
    }

    // MARK: - Exact Match Tests

    func testExactMatch() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .exact,
            matchPattern: "https://api.example.com/test"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com/test/", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
    }

    // MARK: - Contains Match Tests

    func testContainsMatch() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .contains,
            matchPattern: "api.example.com"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "http://api.example.com:8080/path", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://other.com", method: .get))
    }

    // MARK: - Wildcard Match Tests

    func testWildcardMatchSimple() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*.example.com*"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://cdn.example.com", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://example.com/test", method: .get))
    }

    func testWildcardMatchCaseInsensitive() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*.EXAMPLE.COM*"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://API.EXAMPLE.COM/path", method: .get))
    }

    func testWildcardMatchSingleAsterisk() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://cdn.example.com", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "http://localhost:3000", method: .get))
    }

    func testWildcardMatchMultipleAsterisks() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "https://*/test/*"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test/123", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test/path/123", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com/other/123", method: .get))
    }

    func testWildcardMatchExactChars() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "https://api.example.com/test"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com/test/", method: .get))
    }

    // MARK: - Regex Match Tests

    func testRegexMatch() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .regex,
            matchPattern: "^https://api\\.example\\.com/.*"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/users/123", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://other.com", method: .get))
    }

    func testRegexMatchAlternation() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .regex,
            matchPattern: "^https://(api|cdn)\\.example\\.com.*"
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/test", method: .get))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://cdn.example.com/image.png", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://web.example.com", method: .get))
    }

    func testRegexMatchInvalidPattern() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .regex,
            matchPattern: "[invalid(regex"
        )

        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com", method: .get))
    }

    // MARK: - Complex Scenario Tests

    func testComplexScenarioRequestWithMethodAndPattern() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .request,
            matchType: .wildcard,
            matchPattern: "*.example.com/api/*",
            methods: [.post, .put, .patch]
        )

        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/api/users", method: .post))
        XCTAssertTrue(config.shouldBreakOnRequest(url: "https://api.example.com/api/data", method: .put))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://api.example.com/api/users", method: .get))
        XCTAssertFalse(config.shouldBreakOnRequest(url: "https://other.com/api/users", method: .post))
    }

    func testComplexScenarioResponseWithStatusCodesAndPattern() {
        let config = BreakpointConfiguration(
            enabled: true,
            breakpointType: .response,
            matchType: .contains,
            matchPattern: "/api/",
            statusCodes: [400, 401, 403, 404, 500, 502, 503]
        )

        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com/api/users", statusCode: 404))
        XCTAssertTrue(config.shouldBreakOnResponse(url: "https://api.example.com/api/data", statusCode: 500))
        XCTAssertFalse(config.shouldBreakOnResponse(url: "https://api.example.com/api/users", statusCode: 200))
        XCTAssertFalse(config.shouldBreakOnResponse(url: "https://cdn.example.com/image.png", statusCode: 404))
    }

    func testHeaderContainsConditionPasses() async {
        let manager = BreakpointManager.shared
        await manager.setEnabled(false)

        var config = BreakpointConfiguration(enabled: true, breakpointType: .request)
        config.conditions = [
            BreakpointCondition(type: .headerContains, parameter: "Authorization", value: "Bearer")
        ]
        await manager.updateConfiguration(config)

        let shouldBreak = await manager.shouldBreakOnRequest(
            url: "https://api.example.com",
            method: .get,
            headers: [TraceHTTPHeader(key: "Authorization", value: "Bearer token")],
            body: nil
        )

        XCTAssertTrue(shouldBreak)
    }

    func testQueryParamRegexConditionPasses() async {
        let manager = BreakpointManager.shared
        await manager.setEnabled(false)

        var config = BreakpointConfiguration(enabled: true, breakpointType: .request)
        config.conditions = [
            BreakpointCondition(type: .queryParamRegex, parameter: "trace", value: "^[0-9]{4}$")
        ]
        await manager.updateConfiguration(config)

        let shouldBreak = await manager.shouldBreakOnRequest(
            url: "https://api.example.com?trace=1234",
            method: .get,
            headers: [],
            body: nil
        )

        XCTAssertTrue(shouldBreak)
    }
}

// MARK: - PausedRequest Tests

final class PausedRequestTests: XCTestCase {

    func testPausedRequestInitialization() {
        let headers = [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        let body = "test body".data(using: .utf8)

        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: headers,
            body: body,
            breakpointType: .request
        )

        XCTAssertEqual(pausedRequest.id, "req-123")
        XCTAssertEqual(pausedRequest.url, "https://api.example.com")
        XCTAssertEqual(pausedRequest.method, .get)
        XCTAssertEqual(pausedRequest.headers, headers)
        XCTAssertEqual(pausedRequest.body, body)
        XCTAssertTrue(pausedRequest.isPaused)
        XCTAssertEqual(pausedRequest.state, .paused)
        XCTAssertEqual(pausedRequest.breakpointType, .request)
    }

    func testPausedRequestWithResponseData() {
        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .response,
            statusCode: 200,
            statusMessage: "OK"
        )

        XCTAssertEqual(pausedRequest.statusCode, 200)
        XCTAssertEqual(pausedRequest.statusMessage, "OK")
        XCTAssertEqual(pausedRequest.breakpointType, .response)
    }

    func testHasModificationsNoModifications() {
        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )

        XCTAssertFalse(pausedRequest.hasModifications)
    }

    func testHasModificationsWithUrlModification() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )
        pausedRequest.modifiedUrl = "https://api.example.com/modified"

        XCTAssertTrue(pausedRequest.hasModifications)
    }

    func testHasModificationsWithMethodModification() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )
        pausedRequest.modifiedMethod = .post

        XCTAssertTrue(pausedRequest.hasModifications)
    }

    func testHasModificationsWithHeaderModification() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )
        pausedRequest.modifiedHeaders = [TraceHTTPHeader(key: "X-Custom", value: "value")]

        XCTAssertTrue(pausedRequest.hasModifications)
    }

    func testHasModificationsWithBodyModification() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )
        pausedRequest.modifiedBody = "modified body".data(using: .utf8)

        XCTAssertTrue(pausedRequest.hasModifications)
    }

    func testHasModificationsWithStatusCodeModification() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .response,
            statusCode: 200
        )
        pausedRequest.modifiedStatusCode = 404

        XCTAssertTrue(pausedRequest.hasModifications)
    }

    func testHasModificationsWithStatusMessageModification() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .response,
            statusMessage: "OK"
        )
        pausedRequest.modifiedStatusMessage = "Modified"

        XCTAssertTrue(pausedRequest.hasModifications)
    }

    // MARK: - Effective Values Tests

    func testEffectiveUrlOriginal() {
        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )

        XCTAssertEqual(pausedRequest.effectiveUrl, "https://api.example.com")
    }

    func testEffectiveUrlModified() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )
        pausedRequest.modifiedUrl = "https://api.example.com/modified"

        XCTAssertEqual(pausedRequest.effectiveUrl, "https://api.example.com/modified")
    }

    func testEffectiveMethodOriginal() {
        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )

        XCTAssertEqual(pausedRequest.effectiveMethod, .get)
    }

    func testEffectiveMethodModified() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )
        pausedRequest.modifiedMethod = .post

        XCTAssertEqual(pausedRequest.effectiveMethod, .post)
    }

    func testEffectiveMethodTokenModified() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )
        pausedRequest.modifiedMethodToken = "PURGE"

        XCTAssertEqual(pausedRequest.effectiveMethodToken, "PURGE")
        XCTAssertEqual(pausedRequest.effectiveMethod, .get)
    }

    func testEffectiveHeadersOriginal() {
        let headers = [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: headers,
            breakpointType: .request
        )

        XCTAssertEqual(pausedRequest.effectiveHeaders, headers)
    }

    func testEffectiveHeadersModified() {
        let originalHeaders = [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        let modifiedHeaders = [TraceHTTPHeader(key: "X-Custom", value: "value")]

        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: originalHeaders,
            breakpointType: .request
        )
        pausedRequest.modifiedHeaders = modifiedHeaders

        XCTAssertEqual(pausedRequest.effectiveHeaders, modifiedHeaders)
    }

    func testEffectiveBodyOriginal() {
        let body = "test body".data(using: .utf8)
        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            body: body,
            breakpointType: .request
        )

        XCTAssertEqual(pausedRequest.effectiveBody, body)
    }

    func testEffectiveBodyModified() {
        let originalBody = "original".data(using: .utf8)
        let modifiedBody = "modified".data(using: .utf8)

        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            body: originalBody,
            breakpointType: .request
        )
        pausedRequest.modifiedBody = modifiedBody

        XCTAssertEqual(pausedRequest.effectiveBody, modifiedBody)
    }

    func testEffectiveStatusCodeOriginal() {
        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .response,
            statusCode: 200
        )

        XCTAssertEqual(pausedRequest.effectiveStatusCode, 200)
    }

    func testEffectiveStatusCodeModified() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .response,
            statusCode: 200
        )
        pausedRequest.modifiedStatusCode = 500

        XCTAssertEqual(pausedRequest.effectiveStatusCode, 500)
    }

    func testEffectiveStatusMessageOriginal() {
        let pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .response,
            statusMessage: "OK"
        )

        XCTAssertEqual(pausedRequest.effectiveStatusMessage, "OK")
    }

    func testEffectiveStatusMessageModified() {
        var pausedRequest = PausedRequest(
            id: "req-123",
            url: "https://api.example.com",
            method: .get,
            headers: [],
            breakpointType: .response,
            statusMessage: "OK"
        )
        pausedRequest.modifiedStatusMessage = "Server Error"

        XCTAssertEqual(pausedRequest.effectiveStatusMessage, "Server Error")
    }
}
