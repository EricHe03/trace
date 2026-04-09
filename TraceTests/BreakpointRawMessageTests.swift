//
//  BreakpointRawMessageTests.swift
//  TraceTests
//
//  Created by Justin on 2026/03/21.
//

import XCTest
@testable import TraceCore
@testable import TraceFeatures

final class BreakpointRawMessageTests: XCTestCase {
    func testParseRequestRawMessageResolvesHostHeaderAndCustomMethod() throws {
        let pausedRequest = PausedRequest(
            id: "req-1",
            url: "https://api.example.com/v1/users",
            method: .get,
            headers: [TraceHTTPHeader(key: "Host", value: "api.example.com")],
            body: nil,
            breakpointType: .request
        )

        let rawMessage = """
        PURGE /v2/cache?trace=1234 HTTP/1.1\r
        Host: edge.example.com\r
        X-Test: 1\r
        \r
        payload
        """

        let modifications = try BreakpointRawMessage.parse(rawMessage, for: pausedRequest)
        XCTAssertEqual(modifications.url, "https://edge.example.com/v2/cache?trace=1234")
        XCTAssertEqual(modifications.methodToken, "PURGE")
        XCTAssertEqual(modifications.headers, [
            TraceHTTPHeader(key: "Host", value: "edge.example.com"),
            TraceHTTPHeader(key: "X-Test", value: "1")
        ])
        XCTAssertEqual(modifications.body, Data("payload".utf8))
    }

    func testParseResponseRawMessageReturnsStatusHeadersAndBody() throws {
        let pausedRequest = PausedRequest(
            id: "resp-1",
            url: "https://api.example.com/v1/users",
            method: .get,
            headers: [],
            body: nil,
            breakpointType: .response,
            statusCode: 200,
            statusMessage: "OK"
        )

        let rawMessage = """
        HTTP/1.1 503 Service Unavailable\r
        Content-Type: application/json\r
        Retry-After: 60\r
        \r
        {"error":"down"}
        """

        let modifications = try BreakpointRawMessage.parse(rawMessage, for: pausedRequest)
        XCTAssertEqual(modifications.statusCode, 503)
        XCTAssertEqual(modifications.statusMessage, "Service Unavailable")
        XCTAssertEqual(modifications.headers, [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Retry-After", value: "60")
        ])
        XCTAssertEqual(modifications.body, Data("{\"error\":\"down\"}".utf8))
    }
}
