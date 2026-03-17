//
//  HTTP3BridgeTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/18.
//

import Foundation
@testable import TraceQUIC
import XCTest

final class HTTP3BridgeTests: XCTestCase {
    func testRequestHeadParsesPseudoHeaders() throws {
        let event = HTTP3StreamEvent(
            streamID: 1,
            headers: [
                HTTP3HeaderField(name: ":method", value: "POST"),
                HTTP3HeaderField(name: ":scheme", value: "https"),
                HTTP3HeaderField(name: ":authority", value: "example.com"),
                HTTP3HeaderField(name: ":path", value: "/api?x=1"),
                HTTP3HeaderField(name: "content-type", value: "application/json")
            ],
            body: Data("{\"ok\":true}".utf8)
        )

        let head = try HTTP3Bridge.requestHead(from: event)
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.url.absoluteString, "https://example.com/api?x=1")
        XCTAssertEqual(head.headers, [HTTP3HeaderField(name: "content-type", value: "application/json")])
    }

    func testResponseHeadParsesStatusAndStripsPseudoHeaders() throws {
        let head = try HTTP3Bridge.responseHead(
            from: [
                HTTP3HeaderField(name: ":status", value: "204"),
                HTTP3HeaderField(name: "cache-control", value: "no-store")
            ]
        )

        XCTAssertEqual(head.statusCode, 204)
        XCTAssertEqual(head.headers, [HTTP3HeaderField(name: "cache-control", value: "no-store")])
    }

    func testRequestHeadUsesHostFallbackWhenAuthorityMissing() throws {
        let event = HTTP3StreamEvent(
            streamID: 2,
            headers: [
                HTTP3HeaderField(name: ":method", value: "GET"),
                HTTP3HeaderField(name: ":path", value: "/"),
                HTTP3HeaderField(name: "host", value: "fallback.example")
            ],
            body: Data()
        )

        let head = try HTTP3Bridge.requestHead(from: event)
        XCTAssertEqual(head.url.absoluteString, "https://fallback.example/")
    }
}
