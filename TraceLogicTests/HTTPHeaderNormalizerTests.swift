//
//  HTTPHeaderNormalizerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

final class HTTPHeaderNormalizerTests: XCTestCase {
    // MARK: - Basic Flattening Tests

    func testFlattenEmptyHeaders() {
        let headers: [AnyHashable: Any] = [:]
        let result = HTTPHeaderNormalizer.flatten(headers)
        XCTAssertTrue(result.isEmpty, "Flattening empty headers should return empty array")
    }

    func testFlattenSingleHeader() {
        let headers: [AnyHashable: Any] = ["Content-Type": "application/json"]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1, "Should have one header")
        XCTAssertEqual(result[0].key, "Content-Type")
        XCTAssertEqual(result[0].value, "application/json")
    }

    func testFlattenMultipleHeaders() {
        let headers: [AnyHashable: Any] = [
            "Content-Type": "application/json",
            "Authorization": "Bearer token123",
            "User-Agent": "TestClient/1.0"
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 3, "Should have three headers")

        let keys = result.map(\.key)
        XCTAssertTrue(keys.contains("Content-Type"))
        XCTAssertTrue(keys.contains("Authorization"))
        XCTAssertTrue(keys.contains("User-Agent"))
    }

    // MARK: - Array Value Tests

    func testFlattenHeaderWithArrayValue() {
        let headers: [AnyHashable: Any] = [
            "Set-Cookie": ["session=abc123", "user=john"]
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 2, "Should have two headers for array value")
        XCTAssertTrue(result.allSatisfy { $0.key == "Set-Cookie" })

        let values = result.map(\.value)
        XCTAssertTrue(values.contains("session=abc123"))
        XCTAssertTrue(values.contains("user=john"))
    }

    func testFlattenHeaderWithEmptyArray() {
        let headers: [AnyHashable: Any] = [
            "Empty-Header": [String]()
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 0, "Empty array should produce no headers")
    }

    func testFlattenHeaderWithSingleItemArray() {
        let headers: [AnyHashable: Any] = [
            "X-Custom": ["value1"]
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1, "Single item array should produce one header")
        XCTAssertEqual(result[0].key, "X-Custom")
        XCTAssertEqual(result[0].value, "value1")
    }

    func testFlattenHeaderWithMultipleArrayItems() {
        let headers: [AnyHashable: Any] = [
            "Accept": ["text/html", "application/json", "application/xml"]
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 3, "Should have three headers for three array items")
        XCTAssertTrue(result.allSatisfy { $0.key == "Accept" })

        let values = result.map(\.value)
        XCTAssertTrue(values.contains("text/html"))
        XCTAssertTrue(values.contains("application/json"))
        XCTAssertTrue(values.contains("application/xml"))
    }

    // MARK: - NSArray Tests

    func testFlattenHeaderWithNSArray() {
        let nsArray = NSArray(array: ["value1", "value2"])
        let headers: [AnyHashable: Any] = [
            "X-Custom": nsArray
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 2, "NSArray should be flattened")
        XCTAssertTrue(result.allSatisfy { $0.key == "X-Custom" })

        let values = result.map(\.value)
        XCTAssertTrue(values.contains("value1"))
        XCTAssertTrue(values.contains("value2"))
    }

    func testFlattenHeaderWithEmptyNSArray() {
        let nsArray = NSArray()
        let headers: [AnyHashable: Any] = [
            "Empty-Header": nsArray
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 0, "Empty NSArray should produce no headers")
    }

    // MARK: - Mixed Value Types

    func testFlattenHeadersWithMixedTypes() {
        let headers: [AnyHashable: Any] = [
            "Content-Type": "application/json",
            "Set-Cookie": ["cookie1=value1", "cookie2=value2"],
            "Content-Length": 1234
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 4, "Should have four headers total")

        // Check Content-Type
        let contentTypeHeaders = result.filter { $0.key == "Content-Type" }
        XCTAssertEqual(contentTypeHeaders.count, 1)
        XCTAssertEqual(contentTypeHeaders[0].value, "application/json")

        // Check Set-Cookie
        let cookieHeaders = result.filter { $0.key == "Set-Cookie" }
        XCTAssertEqual(cookieHeaders.count, 2)

        // Check Content-Length
        let lengthHeaders = result.filter { $0.key == "Content-Length" }
        XCTAssertEqual(lengthHeaders.count, 1)
        XCTAssertEqual(lengthHeaders[0].value, "1234")
    }

    // MARK: - String Conversion Tests

    func testFlattenHeaderWithIntegerValue() {
        let headers: [AnyHashable: Any] = [
            "Content-Length": 12345
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].key, "Content-Length")
        XCTAssertEqual(result[0].value, "12345")
    }

    func testFlattenHeaderWithBooleanValue() {
        let headers: [AnyHashable: Any] = [
            "X-Enabled": true,
            "X-Disabled": false
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 2)

        let enabledHeader = result.first { $0.key == "X-Enabled" }
        XCTAssertNotNil(enabledHeader)
        XCTAssertEqual(enabledHeader?.value, "true")

        let disabledHeader = result.first { $0.key == "X-Disabled" }
        XCTAssertNotNil(disabledHeader)
        XCTAssertEqual(disabledHeader?.value, "false")
    }

    func testFlattenHeaderWithFloatValue() {
        let headers: [AnyHashable: Any] = [
            "X-Score": 3.14159
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].key, "X-Score")
        XCTAssertTrue(result[0].value.contains("3.14159"))
    }

    // MARK: - Key Type Tests

    func testFlattenHeaderWithStringKey() {
        let headers: [AnyHashable: Any] = [
            "String-Key": "value"
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].key, "String-Key")
    }

    func testFlattenHeaderWithIntegerKey() {
        let headers: [AnyHashable: Any] = [
            123: "value"
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].key, "123")
    }

    // MARK: - Special Character Tests

    func testFlattenHeaderWithSpecialCharactersInValue() {
        let headers: [AnyHashable: Any] = [
            "X-Special": "value with spaces and (parentheses) and \"quotes\""
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].value, "value with spaces and (parentheses) and \"quotes\"")
    }

    func testFlattenHeaderWithEmptyValue() {
        let headers: [AnyHashable: Any] = [
            "Empty-Header": ""
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].key, "Empty-Header")
        XCTAssertEqual(result[0].value, "")
    }

    func testFlattenHeaderWithWhitespaceValue() {
        let headers: [AnyHashable: Any] = [
            "Whitespace-Header": "   "
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].value, "   ")
    }

    // MARK: - Array with Different Types

    func testFlattenHeaderWithMixedArrayTypes() {
        let headers: [AnyHashable: Any] = [
            "X-Mixed": ["string", 123, true, 3.14] as [Any]
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 4, "Should have four headers for four array items")
        XCTAssertTrue(result.allSatisfy { $0.key == "X-Mixed" })

        let values = result.map(\.value)
        XCTAssertTrue(values.contains("string"))
        XCTAssertTrue(values.contains("123"))
        XCTAssertTrue(values.contains("true"))
        XCTAssertTrue(values.contains { $0.contains("3.14") })
    }

    // MARK: - Real World HTTP Headers

    func testFlattenRealWorldHTTPHeaders() {
        let headers: [AnyHashable: Any] = [
            "Host": "example.com",
            "User-Agent": "Mozilla/5.0",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.5",
            "Accept-Encoding": "gzip, deflate, br",
            "Connection": "keep-alive",
            "Upgrade-Insecure-Requests": "1"
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 7, "Should have seven headers")

        // Verify all expected headers are present
        let keys = Set(result.map(\.key))
        XCTAssertTrue(keys.contains("Host"))
        XCTAssertTrue(keys.contains("User-Agent"))
        XCTAssertTrue(keys.contains("Accept"))
        XCTAssertTrue(keys.contains("Accept-Language"))
        XCTAssertTrue(keys.contains("Accept-Encoding"))
        XCTAssertTrue(keys.contains("Connection"))
        XCTAssertTrue(keys.contains("Upgrade-Insecure-Requests"))
    }

    func testFlattenMultipleCookieHeaders() {
        let headers: [AnyHashable: Any] = [
            "Cookie": ["session=abc123; path=/", "user=john; domain=.example.com", "preferences=dark_mode; max-age=3600"]
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 3, "Should have three cookie headers")
        XCTAssertTrue(result.allSatisfy { $0.key == "Cookie" })
    }

    func testFlattenResponseHeaders() {
        let headers: [AnyHashable: Any] = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": 1234,
            "Server": "nginx/1.18.0",
            "Date": "Mon, 01 Feb 2026 12:00:00 GMT",
            "Set-Cookie": ["session=xyz789; HttpOnly; Secure", "tracking=enabled; SameSite=Strict"],
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "X-Frame-Options": "DENY"
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 8, "Should have eight headers total (2 Set-Cookie)")

        let setCookieHeaders = result.filter { $0.key == "Set-Cookie" }
        XCTAssertEqual(setCookieHeaders.count, 2, "Should have two Set-Cookie headers")
    }

    // MARK: - Case Sensitivity Tests

    func testFlattenHeadersPreservesCase() {
        let headers: [AnyHashable: Any] = [
            "Content-Type": "application/json",
            "content-type": "text/plain",
            "CONTENT-TYPE": "text/html"
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        // Should have three separate headers (case-sensitive keys)
        XCTAssertEqual(result.count, 3, "Should preserve case-sensitive keys")

        let keys = result.map(\.key)
        XCTAssertTrue(keys.contains("Content-Type"))
        XCTAssertTrue(keys.contains("content-type"))
        XCTAssertTrue(keys.contains("CONTENT-TYPE"))
    }

    // MARK: - Nested Array Tests

    func testFlattenHeaderWithNestedArray() {
        // Note: Nested arrays are flattened at first level only
        let nestedArray = [["nested1", "nested2"], ["nested3"]] as [Any]
        let headers: [AnyHashable: Any] = [
            "X-Nested": nestedArray
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        // Each nested array becomes a string representation
        XCTAssertEqual(result.count, 2, "Should have two headers for nested array")
        XCTAssertTrue(result.allSatisfy { $0.key == "X-Nested" })
    }

    // MARK: - Performance Tests

    func testFlattenLargeNumberOfHeaders() {
        var headers: [AnyHashable: Any] = [:]
        for i in 0 ..< 1000 {
            headers["Header-\(i)"] = "Value-\(i)"
        }

        let result = HTTPHeaderNormalizer.flatten(headers)
        XCTAssertEqual(result.count, 1000, "Should handle 1000 headers")
    }

    func testFlattenHeaderWithLargeArray() {
        var arrayValues: [String] = []
        for i in 0 ..< 100 {
            arrayValues.append("value-\(i)")
        }

        let headers: [AnyHashable: Any] = [
            "X-Large-Array": arrayValues
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 100, "Should handle large arrays")
        XCTAssertTrue(result.allSatisfy { $0.key == "X-Large-Array" })
    }

    // MARK: - Edge Cases

    func testFlattenHeaderWithNullValue() {
        let headers: [AnyHashable: Any] = [
            "X-Null": NSNull()
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].key, "X-Null")
        // NSNull converts to some string representation
        XCTAssertFalse(result[0].value.isEmpty)
    }

    func testFlattenHeaderWithUnicodeKey() {
        let headers: [AnyHashable: Any] = [
            "X-Unicode-🔥": "value"
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].key.contains("🔥"))
    }

    func testFlattenHeaderWithUnicodeValue() {
        let headers: [AnyHashable: Any] = [
            "X-Unicode": "Hello 世界 🌍"
        ]
        let result = HTTPHeaderNormalizer.flatten(headers)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].value, "Hello 世界 🌍")
    }
}
