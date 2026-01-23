//
//  JSONPathEvaluatorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/21.
//

import XCTest
@testable import TraceCore

final class JSONPathEvaluatorTests: XCTestCase {
    func testGetSimplePath() {
        let json = #"{"user":{"id":123,"name":"Alice"}}"#.data(using: .utf8)!
        let evaluator = JSONPathEvaluator()
        let value = evaluator.get(json: json, path: "$.user.name") as? String
        XCTAssertEqual(value, "Alice")
    }
}
