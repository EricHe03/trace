//
//  JSONXMLConverterTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class JSONXMLConverterTests: XCTestCase {

    // MARK: - JSON to XML Tests - Basic Objects

    func testJSONToXMLWithSimpleObject() {
        let json = """
        {
            "name": "John",
            "age": 30
        }
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<root>"))
        XCTAssertTrue(xmlString.contains("</root>"))
        XCTAssertTrue(xmlString.contains("<name>John</name>"))
        XCTAssertTrue(xmlString.contains("<age>30</age>"))
    }

    func testJSONToXMLWithNestedObject() {
        let json = """
        {
            "user": {
                "name": "John",
                "address": {
                    "city": "New York"
                }
            }
        }
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<user>"))
        XCTAssertTrue(xmlString.contains("<name>John</name>"))
        XCTAssertTrue(xmlString.contains("<address>"))
        XCTAssertTrue(xmlString.contains("<city>New York</city>"))
    }

    func testJSONToXMLWithEmptyObject() {
        let json = "{}".data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertEqual(xmlString, "<root></root>")
    }

    // MARK: - JSON to XML Tests - Arrays

    func testJSONToXMLWithArray() {
        let json = """
        [1, 2, 3]
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<item>1</item>"))
        XCTAssertTrue(xmlString.contains("<item>2</item>"))
        XCTAssertTrue(xmlString.contains("<item>3</item>"))
    }

    func testJSONToXMLWithObjectArray() {
        let json = """
        {
            "users": [
                {"name": "John"},
                {"name": "Jane"}
            ]
        }
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<users>"))
        XCTAssertTrue(xmlString.contains("<item>"))
        XCTAssertTrue(xmlString.contains("<name>John</name>"))
        XCTAssertTrue(xmlString.contains("<name>Jane</name>"))
    }

    func testJSONToXMLWithEmptyArray() {
        let json = """
        {"items": []}
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<items></items>"))
    }

    // MARK: - JSON to XML Tests - Data Types

    func testJSONToXMLWithString() {
        let json = """
        {"text": "Hello World"}
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<text>Hello World</text>"))
    }

    func testJSONToXMLWithNumber() {
        let json = """
        {"count": 42, "price": 19.99}
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<count>42</count>"))
        XCTAssertTrue(xmlString.contains("<price>19.99</price>"))
    }

    func testJSONToXMLWithBoolean() {
        let json = """
        {"active": true, "deleted": false}
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<active>1</active>"))
        XCTAssertTrue(xmlString.contains("<deleted>0</deleted>"))
    }

    func testJSONToXMLWithNull() {
        let json = """
        {"value": null}
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<value></value>"))
    }

    // MARK: - JSON to XML Tests - Special Characters

    func testJSONToXMLWithXMLSpecialCharacters() {
        let json = """
        {"text": "<tag> & \\"quote\\" & 'apostrophe' & > symbol"}
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("&lt;tag&gt;"))
        XCTAssertTrue(xmlString.contains("&amp;"))
        XCTAssertTrue(xmlString.contains("&quot;"))
        XCTAssertTrue(xmlString.contains("&apos;"))
    }

    func testJSONToXMLWithSpecialKeyCharacters() {
        let json = """
        {"key-with-dash": "value", "key.with.dot": "value", "key with space": "value"}
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        // Special characters in keys should be sanitized
        XCTAssertTrue(xmlString.contains("<key-with-dash>value</key-with-dash>"))
        XCTAssertTrue(xmlString.contains("<key_with_dot>value</key_with_dot>"))
        XCTAssertTrue(xmlString.contains("<key_with_space>value</key_with_space>"))
    }

    // MARK: - JSON to XML Tests - Error Cases

    func testJSONToXMLWithInvalidJSON() {
        let invalidJSON = "not valid json".data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: invalidJSON)
        XCTAssertNil(xmlData, "Invalid JSON should return nil")
    }

    func testJSONToXMLWithEmptyData() {
        let emptyData = Data()

        let xmlData = JSONXMLConverter.jsonToXML(data: emptyData)
        XCTAssertNil(xmlData, "Empty data should return nil")
    }

    // MARK: - XML to JSON Tests - Basic

    func testXMLToJSONWithSimpleElement() {
        let xml = """
        <root>
            <name>John</name>
            <age>30</age>
        </root>
        """.data(using: .utf8)!

        let jsonData = JSONXMLConverter.xmlToJSON(data: xml)
        XCTAssertNotNil(jsonData)

        let json = try? JSONSerialization.jsonObject(with: jsonData!, options: []) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertNotNil(json?["root"])
    }

    func testXMLToJSONWithNestedElements() {
        let xml = """
        <root>
            <user>
                <name>John</name>
            </user>
        </root>
        """.data(using: .utf8)!

        let jsonData = JSONXMLConverter.xmlToJSON(data: xml)
        XCTAssertNotNil(jsonData)

        let json = try? JSONSerialization.jsonObject(with: jsonData!, options: [])
        XCTAssertNotNil(json)
    }

    func testXMLToJSONWithAttributes() {
        let xml = """
        <root id="123" type="test">
            <item>value</item>
        </root>
        """.data(using: .utf8)!

        let jsonData = JSONXMLConverter.xmlToJSON(data: xml)
        XCTAssertNotNil(jsonData)

        let json = try? JSONSerialization.jsonObject(with: jsonData!, options: [])
        XCTAssertNotNil(json)
    }

    func testXMLToJSONWithTextContent() {
        let xml = """
        <root>
            <message>Hello World</message>
        </root>
        """.data(using: .utf8)!

        let jsonData = JSONXMLConverter.xmlToJSON(data: xml)
        XCTAssertNotNil(jsonData)

        let json = try? JSONSerialization.jsonObject(with: jsonData!, options: [])
        XCTAssertNotNil(json)
    }

    func testXMLToJSONWithRepeatingElements() {
        let xml = """
        <root>
            <item>1</item>
            <item>2</item>
            <item>3</item>
        </root>
        """.data(using: .utf8)!

        let jsonData = JSONXMLConverter.xmlToJSON(data: xml)
        XCTAssertNotNil(jsonData)

        let json = try? JSONSerialization.jsonObject(with: jsonData!, options: [])
        XCTAssertNotNil(json)
    }

    // MARK: - XML to JSON Tests - Error Cases

    func testXMLToJSONWithInvalidXML() {
        let invalidXML = "<root><unclosed>".data(using: .utf8)!

        let jsonData = JSONXMLConverter.xmlToJSON(data: invalidXML)
        XCTAssertNil(jsonData, "Invalid XML should return nil")
    }

    func testXMLToJSONWithEmptyData() {
        let emptyData = Data()

        let jsonData = JSONXMLConverter.xmlToJSON(data: emptyData)
        XCTAssertNil(jsonData, "Empty data should return nil")
    }

    // MARK: - JSONPath Set Tests

    func testJSONPathSetSimpleValue() {
        let json = """
        {"name": "John", "age": 30}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathSet(data: json, path: "$.name", rawValue: "Jane")
        XCTAssertNotNil(result)

        let updated = try? JSONSerialization.jsonObject(with: result!, options: []) as? [String: Any]
        XCTAssertEqual(updated?["name"] as? String, "Jane")
    }

    func testJSONPathSetNestedValue() {
        let json = """
        {"user": {"name": "John"}}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathSet(data: json, path: "$.user.name", rawValue: "Jane")
        XCTAssertNotNil(result)

        if let data = result,
           let updated = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let user = updated["user"] as? [String: Any] {
            XCTAssertEqual(user["name"] as? String, "Jane")
        } else {
            XCTFail("Failed to update nested value")
        }
    }

    func testJSONPathSetArrayElement() {
        let json = """
        {"items": [1, 2, 3]}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathSet(data: json, path: "$.items[1]", rawValue: "99")
        XCTAssertNotNil(result)

        if let data = result,
           let updated = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let items = updated["items"] as? [Int] {
            XCTAssertEqual(items[1], 99)
        } else {
            XCTFail("Failed to update array element")
        }
    }

    func testJSONPathSetWithNumber() {
        let json = """
        {"count": 0}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathSet(data: json, path: "$.count", rawValue: "42")
        XCTAssertNotNil(result)

        if let data = result,
           let updated = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            XCTAssertEqual(updated["count"] as? Int, 42)
        } else {
            XCTFail("Failed to set number value")
        }
    }

    func testJSONPathSetWithBoolean() {
        let json = """
        {"active": false}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathSet(data: json, path: "$.active", rawValue: "true")
        XCTAssertNotNil(result)

        if let data = result,
           let updated = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            XCTAssertEqual(updated["active"] as? Bool, true)
        } else {
            XCTFail("Failed to set boolean value")
        }
    }

    func testJSONPathSetWithNull() {
        let json = """
        {"value": "something"}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathSet(data: json, path: "$.value", rawValue: "null")
        XCTAssertNotNil(result)

        if let data = result,
           let updated = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            XCTAssertTrue(updated["value"] is NSNull)
        } else {
            XCTFail("Failed to set null value")
        }
    }

    func testJSONPathSetWithJSONObject() {
        let json = """
        {"data": null}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathSet(data: json, path: "$.data", rawValue: "{\"key\":\"value\"}")
        XCTAssertNotNil(result)

        if let resultData = result,
           let updated = try? JSONSerialization.jsonObject(with: resultData, options: []) as? [String: Any],
           let data = updated["data"] as? [String: Any] {
            XCTAssertEqual(data["key"] as? String, "value")
        } else {
            XCTFail("Failed to set JSON object value")
        }
    }

    func testJSONPathSetWithInvalidJSON() {
        let invalidJSON = "not json".data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathSet(data: invalidJSON, path: "$.name", rawValue: "value")
        XCTAssertNil(result, "Invalid JSON should return nil")
    }

    // MARK: - JSONPath Delete Tests

    func testJSONPathDeleteSimpleValue() {
        let json = """
        {"name": "John", "age": 30}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathDelete(data: json, path: "$.name")
        XCTAssertNotNil(result)

        if let data = result,
           let updated = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            XCTAssertNil(updated["name"])
            XCTAssertEqual(updated["age"] as? Int, 30)
        } else {
            XCTFail("Failed to delete value")
        }
    }

    func testJSONPathDeleteNestedValue() {
        let json = """
        {"user": {"name": "John", "age": 30}}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathDelete(data: json, path: "$.user.name")
        XCTAssertNotNil(result)

        if let data = result,
           let updated = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let user = updated["user"] as? [String: Any] {
            XCTAssertNil(user["name"])
            XCTAssertEqual(user["age"] as? Int, 30)
        } else {
            XCTFail("Failed to delete nested value")
        }
    }

    func testJSONPathDeleteArrayElement() {
        let json = """
        {"items": [1, 2, 3]}
        """.data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathDelete(data: json, path: "$.items[1]")
        XCTAssertNotNil(result)

        if let data = result,
           let updated = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let items = updated["items"] as? [Int] {
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0], 1)
            XCTAssertEqual(items[1], 3)
        } else {
            XCTFail("Failed to delete array element")
        }
    }

    func testJSONPathDeleteWithInvalidJSON() {
        let invalidJSON = "not json".data(using: .utf8)!

        let result = JSONXMLConverter.jsonPathDelete(data: invalidJSON, path: "$.name")
        XCTAssertNil(result, "Invalid JSON should return nil")
    }

    // MARK: - Integration Tests

    func testRoundTripJSONToXMLToJSON() {
        let originalJSON = """
        {"name": "John", "age": 30, "items": [1, 2, 3]}
        """.data(using: .utf8)!

        // Convert to XML
        let xmlData = JSONXMLConverter.jsonToXML(data: originalJSON)
        XCTAssertNotNil(xmlData)

        // Convert back to JSON
        let jsonData = JSONXMLConverter.xmlToJSON(data: xmlData!)
        XCTAssertNotNil(jsonData)
    }

    func testComplexJSONToXMLConversion() {
        let json = """
        {
            "user": {
                "name": "John Doe",
                "email": "john@example.com",
                "address": {
                    "street": "123 Main St",
                    "city": "New York",
                    "zip": 10001
                },
                "hobbies": ["reading", "gaming", "coding"],
                "active": true,
                "balance": 1234.56
            }
        }
        """.data(using: .utf8)!

        let xmlData = JSONXMLConverter.jsonToXML(data: json)
        XCTAssertNotNil(xmlData)

        let xmlString = String(data: xmlData!, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<user>"))
        XCTAssertTrue(xmlString.contains("<name>John Doe</name>"))
        XCTAssertTrue(xmlString.contains("<address>"))
        XCTAssertTrue(xmlString.contains("<hobbies>"))
    }

    func testMultipleJSONPathOperations() {
        var json = """
        {"a": 1, "b": 2, "c": 3}
        """.data(using: .utf8)!

        // Set a value
        json = JSONXMLConverter.jsonPathSet(data: json, path: "$.a", rawValue: "10")!

        // Delete a value
        json = JSONXMLConverter.jsonPathDelete(data: json, path: "$.b")!

        // Set another value
        json = JSONXMLConverter.jsonPathSet(data: json, path: "$.d", rawValue: "4")!

        let result = try? JSONSerialization.jsonObject(with: json, options: []) as? [String: Any]
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["a"] as? Int, 10)
        XCTAssertNil(result?["b"])
        XCTAssertEqual(result?["c"] as? Int, 3)
        XCTAssertEqual(result?["d"] as? Int, 4)
    }
}
