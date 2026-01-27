//
//  RequestMatcherTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class RequestMatcherTests: XCTestCase {

    // MARK: - Helper Methods

    private func makeRequest(
        url: String = "https://api.example.com/users",
        method: HTTPMethod = .get,
        statusCode: Int? = 200,
        requestHeaders: [TraceHTTPHeader] = [],
        responseHeaders: [TraceHTTPHeader] = [],
        requestBody: BodyStorage = .empty,
        responseBody: BodyStorage = .empty
    ) -> NetworkRequest {
        NetworkRequest(
            url: url,
            method: method,
            statusCode: statusCode,
            duration: 0.5,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody
        )
    }

    // MARK: - URL Matching Tests

    func testURLMatchingWithExactMatch() {
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .exact, pattern: "https://api.example.com/users")
        )
        let request = makeRequest(url: "https://api.example.com/users")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.details.count, 1)
        XCTAssertEqual(result.details[0].matcher, "url")
        XCTAssertTrue(result.details[0].passed)
    }

    func testURLMatchingWithExactMatchFails() {
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .exact, pattern: "https://api.example.com/users")
        )
        let request = makeRequest(url: "https://api.example.com/posts")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.details[0].passed)
    }

    func testURLMatchingWithWildcard() {
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .wildcard, pattern: "https://api.example.com/*")
        )
        let request = makeRequest(url: "https://api.example.com/users/123")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testURLMatchingWithContains() {
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "example.com")
        )
        let request = makeRequest(url: "https://api.example.com/users")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testURLMatchingWithRegex() {
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .regex, pattern: "https://api\\.example\\.com/users/\\d+")
        )
        let request = makeRequest(url: "https://api.example.com/users/123")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    // MARK: - Method Matching Tests

    func testMethodMatchingSingleMethod() {
        let criteria = MatchCriteria(methods: [.get])
        let request = makeRequest(method: .get)

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.details.contains(where: { $0.matcher == "method" && $0.passed }))
    }

    func testMethodMatchingMultipleMethods() {
        let criteria = MatchCriteria(methods: [.get, .post, .put])
        let getRequest = makeRequest(method: .get)
        let postRequest = makeRequest(method: .post)
        let deleteRequest = makeRequest(method: .delete)

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: getRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: postRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: deleteRequest, target: .request).passed)
    }

    func testMethodMatchingFailsForWrongMethod() {
        let criteria = MatchCriteria(methods: [.post])
        let request = makeRequest(method: .get)

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertFalse(result.passed)
    }

    // MARK: - Host Matching Tests

    func testHostMatchingWithExactMatch() {
        let criteria = MatchCriteria(
            hosts: [StringMatcher(matchType: .exact, pattern: "api.example.com")]
        )
        let request = makeRequest(url: "https://api.example.com/users")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.details.contains(where: { $0.matcher == "host" && $0.passed }))
    }

    func testHostMatchingWithWildcard() {
        let criteria = MatchCriteria(
            hosts: [StringMatcher(matchType: .wildcard, pattern: "*.example.com")]
        )
        let request = makeRequest(url: "https://api.example.com/users")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testHostMatchingWithMultipleHosts() {
        let criteria = MatchCriteria(
            hosts: [
                StringMatcher(matchType: .exact, pattern: "api.example.com"),
                StringMatcher(matchType: .exact, pattern: "cdn.example.com")
            ]
        )
        let apiRequest = makeRequest(url: "https://api.example.com/users")
        let cdnRequest = makeRequest(url: "https://cdn.example.com/image.jpg")
        let otherRequest = makeRequest(url: "https://other.example.com/data")

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: apiRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: cdnRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: otherRequest, target: .request).passed)
    }

    func testHostMatchingCaseInsensitive() {
        let criteria = MatchCriteria(
            hosts: [StringMatcher(matchType: .exact, pattern: "API.EXAMPLE.COM", caseSensitive: false)]
        )
        let request = makeRequest(url: "https://api.example.com/users")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    // MARK: - Scheme Matching Tests

    func testSchemeMatchingHTTPS() {
        let criteria = MatchCriteria(schemes: ["https"])
        let httpsRequest = makeRequest(url: "https://api.example.com/users")
        let httpRequest = makeRequest(url: "http://api.example.com/users")

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: httpsRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: httpRequest, target: .request).passed)
    }

    func testSchemeMatchingMultipleSchemes() {
        let criteria = MatchCriteria(schemes: ["http", "https"])
        let httpsRequest = makeRequest(url: "https://api.example.com/users")
        let httpRequest = makeRequest(url: "http://api.example.com/users")
        let wsRequest = makeRequest(url: "ws://api.example.com/socket")

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: httpsRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: httpRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: wsRequest, target: .request).passed)
    }

    // MARK: - Port Matching Tests

    func testPortMatchingExplicitPort() {
        let criteria = MatchCriteria(ports: [8080])
        let request = makeRequest(url: "https://api.example.com:8080/users")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testPortMatchingDefaultHTTPSPort() {
        let criteria = MatchCriteria(ports: [443])
        let request = makeRequest(url: "https://api.example.com/users")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testPortMatchingDefaultHTTPPort() {
        let criteria = MatchCriteria(ports: [80])
        let request = makeRequest(url: "http://api.example.com/users")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testPortMatchingMultiplePorts() {
        let criteria = MatchCriteria(ports: [80, 443, 8080])
        let httpsRequest = makeRequest(url: "https://api.example.com/users")
        let httpRequest = makeRequest(url: "http://api.example.com/users")
        let customRequest = makeRequest(url: "https://api.example.com:8080/users")
        let wrongPortRequest = makeRequest(url: "https://api.example.com:9000/users")

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: httpsRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: httpRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: customRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: wrongPortRequest, target: .request).passed)
    }

    // MARK: - Header Matching Tests

    func testHeaderMatchingExists() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(name: "Authorization", condition: .exists)]
        )
        let requestWithHeader = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Authorization", value: "Bearer token")]
        )
        let requestWithoutHeader = makeRequest(requestHeaders: [])

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: requestWithHeader, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: requestWithoutHeader, target: .request).passed)
    }

    func testHeaderMatchingNotExists() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(name: "Authorization", condition: .notExists)]
        )
        let requestWithHeader = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Authorization", value: "Bearer token")]
        )
        let requestWithoutHeader = makeRequest(requestHeaders: [])

        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: requestWithHeader, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: requestWithoutHeader, target: .request).passed)
    }

    func testHeaderMatchingEquals() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(
                name: "Content-Type",
                matcher: StringMatcher(matchType: .exact, pattern: "application/json"),
                condition: .equals
            )]
        )
        let matchingRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        )
        let nonMatchingRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/html")]
        )

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: matchingRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: nonMatchingRequest, target: .request).passed)
    }

    func testHeaderMatchingNotEquals() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(
                name: "Content-Type",
                matcher: StringMatcher(matchType: .exact, pattern: "application/json"),
                condition: .notEquals
            )]
        )
        let jsonRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        )
        let htmlRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/html")]
        )

        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: jsonRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: htmlRequest, target: .request).passed)
    }

    func testHeaderMatchingContains() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(
                name: "User-Agent",
                matcher: StringMatcher(matchType: .contains, pattern: "Safari"),
                condition: .contains
            )]
        )
        let safariRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "User-Agent", value: "Mozilla/5.0 Safari/537.36")]
        )
        let chromeRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "User-Agent", value: "Mozilla/5.0 Chrome/120.0")]
        )

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: safariRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: chromeRequest, target: .request).passed)
    }

    func testHeaderMatchingRegex() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(
                name: "Authorization",
                matcher: StringMatcher(matchType: .regex, pattern: "Bearer [A-Za-z0-9]+"),
                condition: .regex
            )]
        )
        let validRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Authorization", value: "Bearer abc123xyz")]
        )
        let invalidRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Authorization", value: "Basic abc")]
        )

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: validRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: invalidRequest, target: .request).passed)
    }

    func testHeaderMatchingCaseInsensitive() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(name: "authorization", condition: .exists)]
        )
        let request = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Authorization", value: "Bearer token")]
        )

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testHeaderMatchingMultipleHeaders() {
        let criteria = MatchCriteria(
            headers: [
                HeaderMatcher(name: "Authorization", condition: .exists),
                HeaderMatcher(
                    name: "Content-Type",
                    matcher: StringMatcher(matchType: .exact, pattern: "application/json"),
                    condition: .equals
                )
            ]
        )
        let validRequest = makeRequest(
            requestHeaders: [
                TraceHTTPHeader(key: "Authorization", value: "Bearer token"),
                TraceHTTPHeader(key: "Content-Type", value: "application/json")
            ]
        )
        let missingAuthRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        )

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: validRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: missingAuthRequest, target: .request).passed)
    }

    // MARK: - Query Parameter Matching Tests

    func testQueryParamMatchingExists() {
        let criteria = MatchCriteria(
            queryParams: [QueryParamMatcher(name: "userId", condition: .exists)]
        )
        let requestWithParam = makeRequest(url: "https://api.example.com/users?userId=123")
        let requestWithoutParam = makeRequest(url: "https://api.example.com/users")

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: requestWithParam, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: requestWithoutParam, target: .request).passed)
    }

    func testQueryParamMatchingNotExists() {
        let criteria = MatchCriteria(
            queryParams: [QueryParamMatcher(name: "userId", condition: .notExists)]
        )
        let requestWithParam = makeRequest(url: "https://api.example.com/users?userId=123")
        let requestWithoutParam = makeRequest(url: "https://api.example.com/users")

        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: requestWithParam, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: requestWithoutParam, target: .request).passed)
    }

    func testQueryParamMatchingEquals() {
        let criteria = MatchCriteria(
            queryParams: [QueryParamMatcher(
                name: "userId",
                matcher: StringMatcher(matchType: .exact, pattern: "123"),
                condition: .equals
            )]
        )
        let matchingRequest = makeRequest(url: "https://api.example.com/users?userId=123")
        let nonMatchingRequest = makeRequest(url: "https://api.example.com/users?userId=456")

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: matchingRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: nonMatchingRequest, target: .request).passed)
    }

    func testQueryParamMatchingMultipleParams() {
        let criteria = MatchCriteria(
            queryParams: [
                QueryParamMatcher(name: "page", condition: .exists),
                QueryParamMatcher(
                    name: "limit",
                    matcher: StringMatcher(matchType: .exact, pattern: "10"),
                    condition: .equals
                )
            ]
        )
        let validRequest = makeRequest(url: "https://api.example.com/users?page=1&limit=10")
        let missingPageRequest = makeRequest(url: "https://api.example.com/users?limit=10")
        let wrongLimitRequest = makeRequest(url: "https://api.example.com/users?page=1&limit=20")

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: validRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: missingPageRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: wrongLimitRequest, target: .request).passed)
    }

    // MARK: - Status Code Matching Tests

    func testStatusCodeMatchingSingleCode() {
        let criteria = MatchCriteria(statusCodes: [200])
        let successRequest = makeRequest(statusCode: 200)
        let errorRequest = makeRequest(statusCode: 404)

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: successRequest, target: .response).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: errorRequest, target: .response).passed)
    }

    func testStatusCodeMatchingMultipleCodes() {
        let criteria = MatchCriteria(statusCodes: [200, 201, 204])
        let successRequest = makeRequest(statusCode: 200)
        let createdRequest = makeRequest(statusCode: 201)
        let errorRequest = makeRequest(statusCode: 500)

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: successRequest, target: .response).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: createdRequest, target: .response).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: errorRequest, target: .response).passed)
    }

    func testStatusCodeMatchingWithNilStatusCode() {
        let criteria = MatchCriteria(statusCodes: [200])
        let request = makeRequest(statusCode: nil)

        let result = RequestMatcher.evaluate(criteria, request: request, target: .response)

        XCTAssertFalse(result.passed)
    }

    // MARK: - Content Type Matching Tests

    func testContentTypeMatching() {
        let criteria = MatchCriteria(
            contentTypes: [StringMatcher(matchType: .contains, pattern: "json")]
        )
        let jsonRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        )
        let htmlRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/html")]
        )

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: jsonRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: htmlRequest, target: .request).passed)
    }

    func testContentTypeMatchingMultipleTypes() {
        let criteria = MatchCriteria(
            contentTypes: [
                StringMatcher(matchType: .contains, pattern: "json"),
                StringMatcher(matchType: .contains, pattern: "xml")
            ]
        )
        let jsonRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        )
        let xmlRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/xml")]
        )
        let htmlRequest = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/html")]
        )

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: jsonRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: xmlRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: htmlRequest, target: .request).passed)
    }

    // MARK: - Body Matching Tests

    func testBodyMatchingContains() {
        let criteria = MatchCriteria(
            bodyMatchers: [BodyMatcher(matcherType: .contains, pattern: "username")]
        )
        let requestWithMatch = makeRequest(
            requestBody: BodyStorage.from(string: "{\"username\":\"john\",\"email\":\"john@example.com\"}")
        )
        let requestWithoutMatch = makeRequest(
            requestBody: BodyStorage.from(string: "{\"email\":\"john@example.com\"}")
        )

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: requestWithMatch, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: requestWithoutMatch, target: .request).passed)
    }

    func testBodyMatchingRegex() {
        let criteria = MatchCriteria(
            bodyMatchers: [BodyMatcher(matcherType: .regex, pattern: "\"id\":\\s*\\d+")]
        )
        let requestWithMatch = makeRequest(
            requestBody: BodyStorage.from(string: "{\"id\": 123, \"name\": \"Test\"}")
        )
        let requestWithoutMatch = makeRequest(
            requestBody: BodyStorage.from(string: "{\"name\": \"Test\"}")
        )

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: requestWithMatch, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: requestWithoutMatch, target: .request).passed)
    }

    func testBodyMatchingEmptyBody() {
        let criteria = MatchCriteria(
            bodyMatchers: [BodyMatcher(matcherType: .contains, pattern: "test")]
        )
        let request = makeRequest(requestBody: .empty)

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertFalse(result.passed)
    }

    // MARK: - Match Logic Tests

    func testMatchLogicAND() {
        let criteria = MatchCriteria(
            methods: [.get],
            hosts: [StringMatcher(matchType: .exact, pattern: "api.example.com")],
            logic: .and
        )
        let validRequest = makeRequest(url: "https://api.example.com/users", method: .get)
        let wrongMethodRequest = makeRequest(url: "https://api.example.com/users", method: .post)
        let wrongHostRequest = makeRequest(url: "https://other.example.com/users", method: .get)

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: validRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: wrongMethodRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: wrongHostRequest, target: .request).passed)
    }

    func testMatchLogicOR() {
        let criteria = MatchCriteria(
            methods: [.get],
            hosts: [StringMatcher(matchType: .exact, pattern: "api.example.com")],
            logic: .or
        )
        let bothMatchRequest = makeRequest(url: "https://api.example.com/users", method: .get)
        let methodMatchRequest = makeRequest(url: "https://other.example.com/users", method: .get)
        let hostMatchRequest = makeRequest(url: "https://api.example.com/users", method: .post)
        let neitherMatchRequest = makeRequest(url: "https://other.example.com/users", method: .post)

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: bothMatchRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: methodMatchRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: hostMatchRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: neitherMatchRequest, target: .request).passed)
    }

    func testEmptyCriteriaReturnsTrue() {
        let criteria = MatchCriteria()
        let request = makeRequest()

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.details.isEmpty)
    }

    // MARK: - Target Tests (Request vs Response)

    func testRequestTargetUsesRequestHeaders() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(name: "X-Request-ID", condition: .exists)]
        )
        let request = makeRequest(
            requestHeaders: [TraceHTTPHeader(key: "X-Request-ID", value: "123")],
            responseHeaders: []
        )

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testResponseTargetUsesResponseHeaders() {
        let criteria = MatchCriteria(
            headers: [HeaderMatcher(name: "X-Response-ID", condition: .exists)]
        )
        let request = makeRequest(
            requestHeaders: [],
            responseHeaders: [TraceHTTPHeader(key: "X-Response-ID", value: "456")]
        )

        let result = RequestMatcher.evaluate(criteria, request: request, target: .response)

        XCTAssertTrue(result.passed)
    }

    func testRequestTargetUsesRequestBody() {
        let criteria = MatchCriteria(
            bodyMatchers: [BodyMatcher(matcherType: .contains, pattern: "request")]
        )
        let request = makeRequest(
            requestBody: BodyStorage.from(string: "request body"),
            responseBody: BodyStorage.from(string: "response body")
        )

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testResponseTargetUsesResponseBody() {
        let criteria = MatchCriteria(
            bodyMatchers: [BodyMatcher(matcherType: .contains, pattern: "response")]
        )
        let request = makeRequest(
            requestBody: BodyStorage.from(string: "request body"),
            responseBody: BodyStorage.from(string: "response body")
        )

        let result = RequestMatcher.evaluate(criteria, request: request, target: .response)

        XCTAssertTrue(result.passed)
    }

    // MARK: - Complex Scenarios

    func testComplexCriteriaWithMultipleMatchers() {
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .wildcard, pattern: "https://api.example.com/*"),
            methods: [.post, .put],
            hosts: [StringMatcher(matchType: .exact, pattern: "api.example.com")],
            schemes: ["https"],
            headers: [
                HeaderMatcher(name: "Authorization", condition: .exists),
                HeaderMatcher(
                    name: "Content-Type",
                    matcher: StringMatcher(matchType: .contains, pattern: "json"),
                    condition: .contains
                )
            ],
            logic: .and
        )

        let validRequest = makeRequest(
            url: "https://api.example.com/users",
            method: .post,
            requestHeaders: [
                TraceHTTPHeader(key: "Authorization", value: "Bearer token"),
                TraceHTTPHeader(key: "Content-Type", value: "application/json")
            ]
        )

        let result = RequestMatcher.evaluate(criteria, request: validRequest, target: .request)

        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.details.count, 6) // url, method, host, scheme, 2 headers
        XCTAssertTrue(result.details.allSatisfy { $0.passed })
    }

    func testComplexCriteriaWithORLogic() {
        let criteria = MatchCriteria(
            methods: [.get],
            statusCodes: [404, 500],
            logic: .or
        )

        let getRequest = makeRequest(method: .get, statusCode: 200)
        let errorRequest = makeRequest(method: .post, statusCode: 404)
        let bothMatchRequest = makeRequest(method: .get, statusCode: 404)
        let neitherMatchRequest = makeRequest(method: .post, statusCode: 200)

        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: getRequest, target: .request).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: errorRequest, target: .response).passed)
        XCTAssertTrue(RequestMatcher.evaluate(criteria, request: bothMatchRequest, target: .request).passed)
        XCTAssertFalse(RequestMatcher.evaluate(criteria, request: neitherMatchRequest, target: .request).passed)
    }

    // MARK: - Edge Cases

    func testMatcherWithSpecialCharactersInURL() {
        let criteria = MatchCriteria(
            url: URLMatcher(matchType: .contains, pattern: "param=value&other=123")
        )
        let request = makeRequest(url: "https://api.example.com/endpoint?param=value&other=123")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testMatcherWithURLEncodedCharacters() {
        let criteria = MatchCriteria(
            queryParams: [QueryParamMatcher(
                name: "email",
                matcher: StringMatcher(matchType: .contains, pattern: "@"),
                condition: .contains
            )]
        )
        let request = makeRequest(url: "https://api.example.com/users?email=test@example.com")

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertTrue(result.passed)
    }

    func testMatcherEvaluationDetails() {
        let criteria = MatchCriteria(
            methods: [.get],
            hosts: [StringMatcher(matchType: .exact, pattern: "api.example.com")],
            statusCodes: [200]
        )
        let request = makeRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 200
        )

        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)

        XCTAssertEqual(result.details.count, 3)
        XCTAssertTrue(result.details.contains(where: { $0.matcher == "method" && $0.passed }))
        XCTAssertTrue(result.details.contains(where: { $0.matcher == "host" && $0.passed }))
        XCTAssertTrue(result.details.contains(where: { $0.matcher == "status" && $0.passed }))
    }
}
