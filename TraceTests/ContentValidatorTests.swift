//
//  ContentValidatorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class ContentValidatorTests: XCTestCase {

    var validator: ContentValidator!

    override func setUp() {
        super.setUp()
        validator = ContentValidator()
    }

    override func tearDown() {
        validator = nil
        super.tearDown()
    }

    // MARK: - JSON Validation Tests

    func testValidateJSONWithValidObject() {
        let json = """
        {
          "name": "John Doe",
          "age": 30,
          "email": "john@example.com"
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(result.canAutoFix)
    }

    func testValidateJSONWithValidArray() {
        let json = """
        [
          {"id": 1, "name": "Alice"},
          {"id": 2, "name": "Bob"},
          {"id": 3, "name": "Charlie"}
        ]
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONWithEmptyObject() {
        let json = "{}".data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONWithEmptyArray() {
        let json = "[]".data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONWithNestedStructures() {
        let json = """
        {
          "user": {
            "name": "John",
            "address": {
              "city": "New York",
              "zip": "10001"
            }
          },
          "tags": ["developer", "engineer"]
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONWithNull() {
        let json = """
        {
          "name": "John",
          "middleName": null,
          "age": 30
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONWithNumbers() {
        let json = """
        {
          "integer": 42,
          "float": 3.14,
          "negative": -10,
          "scientific": 1.5e10
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONWithBooleans() {
        let json = """
        {
          "isActive": true,
          "isDeleted": false
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONWithEscapedCharacters() {
        let json = """
        {
          "message": "Hello \\"World\\"",
          "path": "C:\\\\Users\\\\John",
          "newline": "Line1\\nLine2"
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONWithUnicodeCharacters() {
        let json = """
        {
          "greeting": "Hello 世界",
          "emoji": "🚀🎉",
          "unicode": "\\u0048\\u0065\\u006C\\u006C\\u006F"
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    // MARK: - Invalid JSON Tests

    func testValidateJSONWithInvalidSyntax() {
        let json = """
        {
          "name": "John",
          "age": 30,
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(result.canAutoFix)
    }

    func testValidateJSONWithMissingBrace() {
        let json = """
        {
          "name": "John",
          "age": 30
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateJSONWithMissingQuotes() {
        let json = """
        {
          name: "John"
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateJSONWithSingleQuotes() {
        let json = """
        {
          'name': 'John'
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateJSONWithTrailingComma() {
        let json = """
        {
          "name": "John",
          "age": 30,
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateJSONWithInvalidValue() {
        let json = """
        {
          "name": "John",
          "age": undefined
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateJSONWithEmptyData() {
        let json = Data()

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateJSONWithPlainText() {
        let json = "This is just plain text".data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateJSONWithMalformedUnicode() {
        let json = """
        {
          "text": "\\uXXXX"
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    // MARK: - XML Validation Tests

    func testValidateXMLWithValidDocument() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <root>
          <user>
            <name>John Doe</name>
            <age>30</age>
            <email>john@example.com</email>
          </user>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(result.canAutoFix)
    }

    func testValidateXMLWithoutDeclaration() {
        let xml = """
        <root>
          <item>Value</item>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLWithAttributes() {
        let xml = """
        <root version="1.0">
          <user id="123" active="true">
            <name>John</name>
          </user>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLWithSelfClosingTags() {
        let xml = """
        <root>
          <item id="1" />
          <item id="2" />
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLWithCDATA() {
        let xml = """
        <root>
          <data><![CDATA[Some <special> & characters]]></data>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLWithComments() {
        let xml = """
        <root>
          <!-- This is a comment -->
          <item>Value</item>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLWithNamespaces() {
        let xml = """
        <root xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <xsi:item>Value</xsi:item>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLWithEscapedCharacters() {
        let xml = """
        <root>
          <text>&lt;html&gt;&amp;&quot;&apos;</text>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLWithNestedElements() {
        let xml = """
        <root>
          <level1>
            <level2>
              <level3>
                <level4>Deep Value</level4>
              </level3>
            </level2>
          </level1>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLWithEmptyElements() {
        let xml = """
        <root>
          <empty></empty>
          <selfClosed />
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    // MARK: - Invalid XML Tests

    func testValidateXMLWithMissingClosingTag() {
        let xml = """
        <root>
          <item>Value
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(result.canAutoFix)
    }

    func testValidateXMLWithMismatchedTags() {
        let xml = """
        <root>
          <item>Value</items>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateXMLWithInvalidCharacters() {
        let xml = """
        <root>
          <item>Value & Stuff</item>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateXMLWithInvalidTagName() {
        let xml = """
        <root>
          <123item>Value</123item>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateXMLWithNoRootElement() {
        let xml = """
        <item>Value1</item>
        <item>Value2</item>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateXMLWithEmptyData() {
        let xml = Data()

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateXMLWithPlainText() {
        let xml = "This is just plain text".data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateXMLWithMalformedCDATA() {
        let xml = """
        <root>
          <data><![CDATA[Unclosed CDATA</data>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateXMLWithInvalidAttributes() {
        let xml = """
        <root>
          <item id="123" id="456">Duplicate attributes</item>
        </root>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    // MARK: - Real-world Examples

    func testValidateJSONAPIResponse() {
        let json = """
        {
          "status": "success",
          "data": {
            "users": [
              {"id": 1, "name": "Alice", "active": true},
              {"id": 2, "name": "Bob", "active": false}
            ],
            "total": 2,
            "page": 1,
            "perPage": 10
          },
          "meta": {
            "timestamp": 1640000000,
            "version": "1.0"
          }
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateJSONErrorResponse() {
        let json = """
        {
          "status": "error",
          "error": {
            "code": 404,
            "message": "Resource not found",
            "details": {
              "resource": "user",
              "id": 12345
            }
          }
        }
        """.data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLSOAPResponse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Body>
            <GetUserResponse xmlns="http://example.com/user">
              <User>
                <Id>123</Id>
                <Name>John Doe</Name>
                <Email>john@example.com</Email>
              </User>
            </GetUserResponse>
          </soap:Body>
        </soap:Envelope>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateXMLRSSFeed() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Example Feed</title>
            <link>https://example.com</link>
            <description>Example RSS Feed</description>
            <item>
              <title>Article 1</title>
              <link>https://example.com/article1</link>
              <pubDate>Mon, 27 Jan 2026 12:00:00 GMT</pubDate>
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    // MARK: - Performance Tests

    func testValidateJSONPerformanceWithLargeDocument() {
        var largeArray = "["
        for i in 0..<1000 {
            if i > 0 { largeArray += "," }
            largeArray += "{\"id\":\(i),\"name\":\"User\(i)\",\"active\":true}"
        }
        largeArray += "]"

        let json = largeArray.data(using: .utf8)!

        measure {
            let result = validator.validateJSON(json)
            XCTAssertTrue(result.isValid)
        }
    }

    func testValidateXMLPerformanceWithLargeDocument() {
        var largeXML = "<root>"
        for i in 0..<1000 {
            largeXML += "<item id=\"\(i)\"><name>User\(i)</name><active>true</active></item>"
        }
        largeXML += "</root>"

        let xml = largeXML.data(using: .utf8)!

        measure {
            let result = validator.validateXML(xml)
            XCTAssertTrue(result.isValid)
        }
    }

    // MARK: - Edge Cases

    func testValidateJSONWithWhitespaceOnly() {
        let json = "   \n\t   ".data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateXMLWithWhitespaceOnly() {
        let xml = "   \n\t   ".data(using: .utf8)!

        let result = validator.validateXML(xml)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testValidateJSONWithBOM() {
        // Byte Order Mark + valid JSON
        var data = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        data.append("{}".data(using: .utf8)!)

        let result = validator.validateJSON(data)

        XCTAssertTrue(result.isValid)
    }

    func testValidateJSONPrimitiveString() {
        let json = "\"just a string\"".data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
    }

    func testValidateJSONPrimitiveNumber() {
        let json = "42".data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
    }

    func testValidateJSONPrimitiveBoolean() {
        let jsonTrue = "true".data(using: .utf8)!
        let jsonFalse = "false".data(using: .utf8)!

        XCTAssertTrue(validator.validateJSON(jsonTrue).isValid)
        XCTAssertTrue(validator.validateJSON(jsonFalse).isValid)
    }

    func testValidateJSONPrimitiveNull() {
        let json = "null".data(using: .utf8)!

        let result = validator.validateJSON(json)

        XCTAssertTrue(result.isValid)
    }
}
