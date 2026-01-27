//
//  TemplateEngineTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class TemplateEngineTests: XCTestCase {

    var engine: TemplateEngine!
    var context: TemplateContext!

    override func setUp() {
        super.setUp()
        engine = TemplateEngine()

        let request = NetworkRequest(
            url: "https://api.example.com/users/123",
            method: .post,
            duration: 0.5,
            requestHeaders: [
                TraceHTTPHeader(key: "Authorization", value: "Bearer abc123"),
                TraceHTTPHeader(key: "Content-Type", value: "application/json"),
                TraceHTTPHeader(key: "X-Custom-Header", value: "custom-value")
            ]
        )
        context = TemplateContext(request: request)
    }

    override func tearDown() {
        engine = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Basic Token Tests

    func testRenderWithNoTokens() {
        let template = "Hello, World!"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Hello, World!")
    }

    func testRenderWithSingleToken() {
        let template = "URL: {{ requestUrl }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "URL: https://api.example.com/users/123")
    }

    func testRenderWithMultipleTokens() {
        let template = "{{ requestMethod }} {{ requestUrl }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "POST https://api.example.com/users/123")
    }

    func testRenderWithTokensInMiddle() {
        let template = "Request: {{ requestMethod }} to {{ requestUrl }} completed"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Request: POST to https://api.example.com/users/123 completed")
    }

    // MARK: - Request Token Tests

    func testRequestUrlToken() {
        let template = "{{ requestUrl }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "https://api.example.com/users/123")
    }

    func testRequestMethodToken() {
        let template = "{{ requestMethod }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "POST")
    }

    func testRequestMethodTokenWithDifferentMethod() {
        let getRequest = NetworkRequest(url: "https://api.example.com", method: .get, duration: 0.1)
        let getContext = TemplateContext(request: getRequest)
        let template = "{{ requestMethod }}"
        let result = engine.render(template, context: getContext)

        XCTAssertEqual(result, "GET")
    }

    // MARK: - Request Header Token Tests

    func testRequestHeaderToken() {
        let template = "{{ requestHeader.Authorization }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Bearer abc123")
    }

    func testRequestHeaderTokenCaseInsensitive() {
        let template = "{{ requestHeader.authorization }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Bearer abc123")
    }

    func testRequestHeaderTokenMixedCase() {
        let template = "{{ requestHeader.AUTHORIZATION }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Bearer abc123")
    }

    func testRequestHeaderTokenNonExistent() {
        let template = "{{ requestHeader.NonExistent }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "")
    }

    func testRequestHeaderTokenCustomHeader() {
        let template = "{{ requestHeader.X-Custom-Header }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "custom-value")
    }

    func testMultipleRequestHeaderTokens() {
        let template = "Auth: {{ requestHeader.Authorization }}, Type: {{ requestHeader.Content-Type }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Auth: Bearer abc123, Type: application/json")
    }

    // MARK: - Dynamic Token Tests

    func testTimestampToken() {
        let template = "{{ timestamp }}"
        let result = engine.render(template, context: context)

        // Should be a valid integer timestamp
        XCTAssertNotNil(Int(result))
        XCTAssertGreaterThan(Int(result) ?? 0, 1_600_000_000) // After Sept 2020
    }

    func testIsoDateToken() {
        let template = "{{ isoDate }}"
        let result = engine.render(template, context: context)

        // Should be a valid ISO8601 date
        let formatter = ISO8601DateFormatter()
        XCTAssertNotNil(formatter.date(from: result))
    }

    func testRandomIntToken() {
        let template = "{{ randomInt }}"
        let result1 = engine.render(template, context: context)
        let result2 = engine.render(template, context: context)

        // Should be valid integers
        XCTAssertNotNil(Int(result1))
        XCTAssertNotNil(Int(result2))

        // Should be in valid range
        let value1 = Int(result1) ?? -1
        let value2 = Int(result2) ?? -1
        XCTAssertGreaterThanOrEqual(value1, 0)
        XCTAssertLessThanOrEqual(value1, 999_999)
        XCTAssertGreaterThanOrEqual(value2, 0)
        XCTAssertLessThanOrEqual(value2, 999_999)

        // Results should be different (probabilistically)
        // Note: There's a tiny chance they could be equal, but very unlikely
    }

    func testRandomUUIDToken() {
        let template = "{{ randomUUID }}"
        let result1 = engine.render(template, context: context)
        let result2 = engine.render(template, context: context)

        // Should be valid UUIDs
        XCTAssertNotNil(UUID(uuidString: result1))
        XCTAssertNotNil(UUID(uuidString: result2))

        // Should be different
        XCTAssertNotEqual(result1, result2)
    }

    // MARK: - Environment Variable Tests

    func testEnvToken() {
        // Set a test environment variable
        setenv("TEST_VAR", "test_value", 1)

        let template = "{{ env.TEST_VAR }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "test_value")

        // Clean up
        unsetenv("TEST_VAR")
    }

    func testEnvTokenNonExistent() {
        let template = "{{ env.NON_EXISTENT_VAR }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "")
    }

    func testEnvTokenMultiple() {
        setenv("VAR1", "value1", 1)
        setenv("VAR2", "value2", 1)

        let template = "{{ env.VAR1 }} - {{ env.VAR2 }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "value1 - value2")

        unsetenv("VAR1")
        unsetenv("VAR2")
    }

    // MARK: - Unknown Token Tests

    func testUnknownToken() {
        let template = "{{ unknownToken }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "")
    }

    func testUnknownTokenWithText() {
        let template = "Hello {{ unknownToken }} World"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Hello  World")
    }

    // MARK: - Whitespace Handling Tests

    func testTokenWithExtraWhitespace() {
        let template = "{{  requestUrl  }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "https://api.example.com/users/123")
    }

    func testTokenWithTabs() {
        let template = "{{\trequestUrl\t}}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "https://api.example.com/users/123")
    }

    func testTokenWithNewlines() {
        let template = "{{\nrequestUrl\n}}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "https://api.example.com/users/123")
    }

    func testTokenWithMixedWhitespace() {
        let template = "{{ \t requestUrl \n }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "https://api.example.com/users/123")
    }

    // MARK: - Complex Template Tests

    func testComplexJsonTemplate() {
        let template = """
        {
          "method": "{{ requestMethod }}",
          "url": "{{ requestUrl }}",
          "timestamp": {{ timestamp }},
          "uuid": "{{ randomUUID }}",
          "auth": "{{ requestHeader.Authorization }}"
        }
        """
        let result = engine.render(template, context: context)

        // Check that all tokens were replaced
        XCTAssertFalse(result.contains("{{"))
        XCTAssertFalse(result.contains("}}"))

        // Check that specific values are present
        XCTAssertTrue(result.contains("\"method\": \"POST\""))
        XCTAssertTrue(result.contains("\"url\": \"https://api.example.com/users/123\""))
        XCTAssertTrue(result.contains("\"auth\": \"Bearer abc123\""))
    }

    func testComplexUrlTemplate() {
        let template = "https://api.example.com/v1/users?timestamp={{ timestamp }}&uuid={{ randomUUID }}&method={{ requestMethod }}"
        let result = engine.render(template, context: context)

        XCTAssertTrue(result.hasPrefix("https://api.example.com/v1/users?timestamp="))
        XCTAssertTrue(result.contains("&uuid="))
        XCTAssertTrue(result.contains("&method=POST"))
    }

    func testMultilineTemplate() {
        let template = """
        Request Details:
        Method: {{ requestMethod }}
        URL: {{ requestUrl }}
        Authorization: {{ requestHeader.Authorization }}
        Content-Type: {{ requestHeader.Content-Type }}
        Timestamp: {{ timestamp }}
        """
        let result = engine.render(template, context: context)

        XCTAssertTrue(result.contains("Method: POST"))
        XCTAssertTrue(result.contains("URL: https://api.example.com/users/123"))
        XCTAssertTrue(result.contains("Authorization: Bearer abc123"))
        XCTAssertTrue(result.contains("Content-Type: application/json"))
        XCTAssertTrue(result.contains("Timestamp: "))
    }

    // MARK: - Edge Cases

    func testEmptyTemplate() {
        let template = ""
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "")
    }

    func testTemplateWithOnlyBraces() {
        let template = "{{ }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "")
    }

    func testTemplateWithIncompleteBraces() {
        let template = "{{ requestUrl"
        let result = engine.render(template, context: context)

        // Should return original if not valid token format
        XCTAssertEqual(result, "{{ requestUrl")
    }

    func testTemplateWithSingleBrace() {
        let template = "{ requestUrl }"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "{ requestUrl }")
    }

    func testTemplateWithNestedBraces() {
        let template = "{{ requestUrl {{ nested }} }}"
        let result = engine.render(template, context: context)

        // The regex should handle this gracefully
        XCTAssertFalse(result.isEmpty)
    }

    func testTemplateWithConsecutiveTokens() {
        let template = "{{ requestMethod }}{{ requestUrl }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "POSThttps://api.example.com/users/123")
    }

    func testTemplateWithEscapedCharacters() {
        let template = "Method: {{ requestMethod }}, URL: \"{{ requestUrl }}\""
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Method: POST, URL: \"https://api.example.com/users/123\"")
    }

    func testTemplateLikeTextWithoutTokens() {
        let template = "This is not a token: { requestUrl }"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "This is not a token: { requestUrl }")
    }

    func testMultipleSameTokens() {
        let template = "{{ requestMethod }} request to {{ requestUrl }} using {{ requestMethod }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "POST request to https://api.example.com/users/123 using POST")
    }

    // MARK: - Real-world Use Cases

    func testCurlCommandTemplate() {
        let template = """
        curl -X {{ requestMethod }} \\
          -H "Authorization: {{ requestHeader.Authorization }}" \\
          -H "Content-Type: {{ requestHeader.Content-Type }}" \\
          "{{ requestUrl }}"
        """
        let result = engine.render(template, context: context)

        XCTAssertTrue(result.contains("curl -X POST"))
        XCTAssertTrue(result.contains("-H \"Authorization: Bearer abc123\""))
        XCTAssertTrue(result.contains("-H \"Content-Type: application/json\""))
        XCTAssertTrue(result.contains("\"https://api.example.com/users/123\""))
    }

    func testApiKeyRotationTemplate() {
        setenv("API_KEY", "secret_key_12345", 1)

        let template = "Authorization: Bearer {{ env.API_KEY }}"
        let result = engine.render(template, context: context)

        XCTAssertEqual(result, "Authorization: Bearer secret_key_12345")

        unsetenv("API_KEY")
    }

    func testDynamicQueryParamsTemplate() {
        let template = "{{ requestUrl }}?timestamp={{ timestamp }}&nonce={{ randomInt }}"
        let result = engine.render(template, context: context)

        XCTAssertTrue(result.hasPrefix("https://api.example.com/users/123?timestamp="))
        XCTAssertTrue(result.contains("&nonce="))
    }

    func testRequestIdGenerationTemplate() {
        let template = "X-Request-ID: {{ randomUUID }}"
        let result1 = engine.render(template, context: context)
        let result2 = engine.render(template, context: context)

        XCTAssertTrue(result1.hasPrefix("X-Request-ID: "))
        XCTAssertTrue(result2.hasPrefix("X-Request-ID: "))
        XCTAssertNotEqual(result1, result2)
    }

    // MARK: - Performance Tests

    func testRenderPerformanceWithManyTokens() {
        let template = String(repeating: "{{ requestMethod }} ", count: 100)

        measure {
            _ = engine.render(template, context: context)
        }
    }

    func testRenderPerformanceWithLargeTemplate() {
        let template = String(repeating: "Some text {{ requestUrl }} more text ", count: 1000)

        measure {
            _ = engine.render(template, context: context)
        }
    }

    // MARK: - Thread Safety Tests

    func testConcurrentRenderingDifferentEngines() {
        let expectation = XCTestExpectation(description: "Concurrent rendering")
        expectation.expectedFulfillmentCount = 10

        for _ in 0..<10 {
            DispatchQueue.global().async {
                let engine = TemplateEngine()
                let template = "{{ requestMethod }} {{ requestUrl }}"
                let result = engine.render(template, context: self.context)

                XCTAssertTrue(result.contains("POST"))
                XCTAssertTrue(result.contains("https://api.example.com/users/123"))
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }
}
