//
//  JSONPathEvaluatorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class JSONPathEvaluatorTests: XCTestCase {

    var evaluator: JSONPathEvaluator!

    override func setUp() {
        super.setUp()
        evaluator = JSONPathEvaluator()
    }

    override func tearDown() {
        evaluator = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func makeJSON(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func makeJSONArray(_ array: [Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: array)
    }

    // MARK: - Get Tests - Basic Paths

    func testGetSimplePath() {
        let json = #"{"user":{"id":123,"name":"Alice"}}"#.data(using: .utf8)!
        let value = evaluator.get(json: json, path: "$.user.name") as? String
        XCTAssertEqual(value, "Alice")
    }

    func testGetSimpleKey() {
        let json = makeJSON(["name": "John", "age": 30])

        let name = evaluator.get(json: json, path: "name") as? String
        let age = evaluator.get(json: json, path: "age") as? Int

        XCTAssertEqual(name, "John")
        XCTAssertEqual(age, 30)
    }

    func testGetNestedObject() {
        let json = makeJSON(["user": ["name": "John", "email": "john@example.com"]])

        let name = evaluator.get(json: json, path: "user.name") as? String
        let email = evaluator.get(json: json, path: "user.email") as? String

        XCTAssertEqual(name, "John")
        XCTAssertEqual(email, "john@example.com")
    }

    func testGetArrayElement() {
        let json = makeJSONArray(["apple", "banana", "cherry"])

        let first = evaluator.get(json: json, path: "[0]") as? String
        let second = evaluator.get(json: json, path: "[1]") as? String

        XCTAssertEqual(first, "apple")
        XCTAssertEqual(second, "banana")
    }

    func testGetNestedArrayElement() {
        let json = makeJSON(["users": [["name": "Alice"], ["name": "Bob"]]])

        let name = evaluator.get(json: json, path: "users[1].name") as? String

        XCTAssertEqual(name, "Bob")
    }

    func testGetNonExistentKey() {
        let json = makeJSON(["name": "John"])

        let result = evaluator.get(json: json, path: "age")

        XCTAssertNil(result)
    }

    // MARK: - Set Tests

    func testSetSimpleKey() throws {
        let json = makeJSON(["name": "John"])

        let updated = try evaluator.set(json: json, path: "name", value: "Jane")
        let result = evaluator.get(json: updated, path: "name") as? String

        XCTAssertEqual(result, "Jane")
    }

    func testSetNewKey() throws {
        let json = makeJSON(["name": "John"])

        let updated = try evaluator.set(json: json, path: "age", value: 30)
        let result = evaluator.get(json: updated, path: "age") as? Int

        XCTAssertEqual(result, 30)
    }

    func testSetNestedKey() throws {
        let json = makeJSON(["user": ["name": "John"]])

        let updated = try evaluator.set(json: json, path: "user.name", value: "Jane")
        let result = evaluator.get(json: updated, path: "user.name") as? String

        XCTAssertEqual(result, "Jane")
    }

    func testSetArrayElement() throws {
        let json = makeJSONArray(["apple", "banana", "cherry"])

        let updated = try evaluator.set(json: json, path: "[1]", value: "blueberry")
        let result = evaluator.get(json: updated, path: "[1]") as? String

        XCTAssertEqual(result, "blueberry")
    }

    // MARK: - Delete Tests

    func testDeleteSimpleKey() throws {
        let json = makeJSON(["name": "John", "age": 30])

        let updated = try evaluator.delete(json: json, path: "age")
        let result = evaluator.get(json: updated, path: "age")

        XCTAssertNil(result)
        XCTAssertNotNil(evaluator.get(json: updated, path: "name"))
    }

    func testDeleteArrayElement() throws {
        let json = makeJSONArray(["apple", "banana", "cherry"])

        let updated = try evaluator.delete(json: json, path: "[1]")
        let result = evaluator.get(json: updated, path: "[1]") as? String

        XCTAssertEqual(result, "cherry")
    }

    // MARK: - Bracket Notation Tests

    func testBracketNotationWithQuotes() {
        let json = makeJSON(["user-name": "John"])

        let result = evaluator.get(json: json, path: "['user-name']") as? String

        XCTAssertEqual(result, "John")
    }

    // MARK: - Real-world Scenarios

    func testAPIResponseNavigation() {
        let json = makeJSON([
            "status": "success",
            "data": [
                "users": [
                    ["id": 1, "name": "Alice", "email": "alice@example.com"],
                    ["id": 2, "name": "Bob", "email": "bob@example.com"]
                ],
                "total": 2
            ]
        ])

        let status = evaluator.get(json: json, path: "status") as? String
        let total = evaluator.get(json: json, path: "data.total") as? Int
        let firstUserName = evaluator.get(json: json, path: "data.users[0].name") as? String

        XCTAssertEqual(status, "success")
        XCTAssertEqual(total, 2)
        XCTAssertEqual(firstUserName, "Alice")
    }

    func testConfigurationUpdate() throws {
        let json = makeJSON([
            "app": [
                "version": "1.0.0",
                "settings": [
                    "theme": "light",
                    "notifications": true
                ]
            ]
        ])

        var updated = try evaluator.set(json: json, path: "app.version", value: "1.1.0")
        updated = try evaluator.set(json: updated, path: "app.settings.theme", value: "dark")

        let version = evaluator.get(json: updated, path: "app.version") as? String
        let theme = evaluator.get(json: updated, path: "app.settings.theme") as? String

        XCTAssertEqual(version, "1.1.0")
        XCTAssertEqual(theme, "dark")
    }
}
