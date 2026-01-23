//
//  MatchCriteriaTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/21.
//

import XCTest
@testable import TraceCore

final class MatchCriteriaTests: XCTestCase {
    func testURLMatcherExact() {
        let criteria = MatchCriteria(url: URLMatcher(matchType: .exact, pattern: "https://example.com"))
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            duration: 0,
            requestHeaders: [],
            responseHeaders: [],
            requestBody: .empty,
            responseBody: .empty
        )
        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)
        XCTAssertTrue(result.passed)
    }

    func testHeaderMatcherExists() {
        let criteria = MatchCriteria(headers: [HeaderMatcher(name: "X-Test", condition: .exists)])
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            duration: 0,
            requestHeaders: [TraceHTTPHeader(key: "X-Test", value: "1")],
            responseHeaders: [],
            requestBody: .empty,
            responseBody: .empty
        )
        let result = RequestMatcher.evaluate(criteria, request: request, target: .request)
        XCTAssertTrue(result.passed)
    }
}
