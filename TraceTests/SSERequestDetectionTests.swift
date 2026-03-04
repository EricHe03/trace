//
//  SSERequestDetectionTests.swift
//  TraceTests
//
//  Created by Justin on 2026/03/04.
//

import XCTest
import NIOHTTP1
@testable import TraceProxy

final class SSERequestDetectionTests: XCTestCase {
    func testIsSSERequest_AcceptExactMatch_ReturnsTrue() {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "text/event-stream")
        XCTAssertTrue(NIOMITMHTTPConnectHandler.isSSERequest(headers: headers))
    }

    func testIsSSERequest_AcceptWithParameters_ReturnsTrue() {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "text/event-stream;q=1.0, */*;q=0.8")
        XCTAssertTrue(NIOMITMHTTPConnectHandler.isSSERequest(headers: headers))
    }

    func testIsSSERequest_AcceptWithCharsetParameter_ReturnsTrue() {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "text/event-stream; charset=utf-8")
        XCTAssertTrue(NIOMITMHTTPConnectHandler.isSSERequest(headers: headers))
    }

    func testIsSSERequest_NonSSEAccept_ReturnsFalse() {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        XCTAssertFalse(NIOMITMHTTPConnectHandler.isSSERequest(headers: headers))
    }

    func testIsSSERequest_MultipleAcceptHeaders_ReturnsTrueWhenAnyIsSSE() {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "text/html,*/*;q=0.8")
        headers.add(name: "Accept", value: "text/event-stream")
        XCTAssertTrue(NIOMITMHTTPConnectHandler.isSSERequest(headers: headers))
    }
}

