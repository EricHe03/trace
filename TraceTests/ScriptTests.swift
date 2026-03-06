//
//  ScriptTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class ScriptTests: XCTestCase {

    // MARK: - Initialization Tests

    func testScriptInitialization() {
        let script = Script(
            name: "Test Script",
            scriptType: .request,
            code: "console.log('test');"
        )

        XCTAssertNotNil(script.id)
        XCTAssertEqual(script.name, "Test Script")
        XCTAssertTrue(script.enabled)
        XCTAssertEqual(script.scriptType, .request)
        XCTAssertEqual(script.matchType, .wildcard)
        XCTAssertNil(script.matchPattern)
        XCTAssertEqual(script.code, "console.log('test');")
        XCTAssertEqual(script.executionCount, 0)
    }

    func testScriptInitializationWithAllParameters() {
        let id = UUID()
        let createdAt = Date()
        let modifiedAt = Date()

        let script = Script(
            id: id,
            name: "Custom Script",
            enabled: false,
            scriptType: .response,
            matchType: .regex,
            matchPattern: ".*\\.example\\.com",
            code: "// code",
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            executionCount: 5
        )

        XCTAssertEqual(script.id, id)
        XCTAssertEqual(script.name, "Custom Script")
        XCTAssertFalse(script.enabled)
        XCTAssertEqual(script.scriptType, .response)
        XCTAssertEqual(script.matchType, .regex)
        XCTAssertEqual(script.matchPattern, ".*\\.example\\.com")
        XCTAssertEqual(script.code, "// code")
        XCTAssertEqual(script.createdAt, createdAt)
        XCTAssertEqual(script.modifiedAt, modifiedAt)
        XCTAssertEqual(script.executionCount, 5)
    }

    // MARK: - ScriptType Tests

    func testScriptTypeDisplayName() {
        XCTAssertEqual(ScriptType.request.displayName, "Request")
        XCTAssertEqual(ScriptType.response.displayName, "Response")
        XCTAssertEqual(ScriptType.stream.displayName, "Stream")
        XCTAssertEqual(ScriptType.both.displayName, "Both")
    }

    func testScriptTypeDescription() {
        XCTAssertEqual(ScriptType.request.description, "Runs on outgoing requests")
        XCTAssertEqual(ScriptType.response.description, "Runs on incoming responses")
        XCTAssertEqual(ScriptType.stream.description, "Runs on stream events (SSE/WebSocket)")
        XCTAssertEqual(ScriptType.both.description, "Runs on both requests and responses")
    }

    func testScriptTypeCaseIterable() {
        let allTypes = ScriptType.allCases
        XCTAssertEqual(allTypes.count, 4)
        XCTAssertTrue(allTypes.contains(.request))
        XCTAssertTrue(allTypes.contains(.response))
        XCTAssertTrue(allTypes.contains(.stream))
        XCTAssertTrue(allTypes.contains(.both))
    }

    // MARK: - URL Matching Tests - Wildcard

    func testMatchesWildcardSimplePattern() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .wildcard,
            matchPattern: "*example.com*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/users"))
        XCTAssertTrue(script.matches("https://example.com"))
        XCTAssertTrue(script.matches("http://subdomain.example.com/path"))
        XCTAssertFalse(script.matches("https://different.com"))
    }

    func testMatchesWildcardPrefixPattern() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .wildcard,
            matchPattern: "https://*.example.com/*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/users"))
        XCTAssertTrue(script.matches("https://subdomain.example.com/path"))
        XCTAssertFalse(script.matches("http://api.example.com/users")) // http not https
        XCTAssertFalse(script.matches("https://example.org/users"))
    }

    func testMatchesWildcardSuffixPattern() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .wildcard,
            matchPattern: "*/api/*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://example.com/api/users"))
        XCTAssertTrue(script.matches("https://test.com/api/data"))
        XCTAssertFalse(script.matches("https://example.com/web/users"))
    }

    func testMatchesWildcardMultipleWildcards() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .wildcard,
            matchPattern: "https://*example*/api/*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/api/users"))
        XCTAssertTrue(script.matches("https://examples.org/api/data"))
        XCTAssertFalse(script.matches("https://test.com/api/users"))
    }

    // MARK: - URL Matching Tests - Exact

    func testMatchesExactMatch() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .exact,
            matchPattern: "https://api.example.com/users",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/users"))
        XCTAssertFalse(script.matches("https://api.example.com/users/123"))
        XCTAssertFalse(script.matches("https://api.example.com"))
        XCTAssertFalse(script.matches("http://api.example.com/users")) // http vs https
    }

    func testMatchesExactCaseSensitive() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .exact,
            matchPattern: "https://API.example.com/users",
            code: ""
        )

        XCTAssertTrue(script.matches("https://API.example.com/users"))
        XCTAssertFalse(script.matches("https://api.example.com/users"))
    }

    // MARK: - URL Matching Tests - Contains

    func testMatchesContainsSubstring() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .contains,
            matchPattern: "example.com",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/users"))
        XCTAssertTrue(script.matches("https://example.com"))
        XCTAssertTrue(script.matches("http://subdomain.example.com/path"))
        XCTAssertFalse(script.matches("https://different.org"))
    }

    func testMatchesContainsPath() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .contains,
            matchPattern: "/api/v1/",
            code: ""
        )

        XCTAssertTrue(script.matches("https://example.com/api/v1/users"))
        XCTAssertTrue(script.matches("https://test.com/api/v1/data"))
        XCTAssertFalse(script.matches("https://example.com/api/v2/users"))
        XCTAssertFalse(script.matches("https://example.com/web/users"))
    }

    func testMatchesContainsCaseSensitive() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .contains,
            matchPattern: "/API/",
            code: ""
        )

        XCTAssertTrue(script.matches("https://example.com/API/users"))
        XCTAssertFalse(script.matches("https://example.com/api/users"))
    }

    // MARK: - URL Matching Tests - Regex

    func testMatchesRegexSimplePattern() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .regex,
            matchPattern: "https://.*\\.example\\.com/.*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/users"))
        XCTAssertTrue(script.matches("https://subdomain.example.com/path"))
        XCTAssertFalse(script.matches("http://api.example.com/users")) // http not https
        XCTAssertFalse(script.matches("https://example.org/users"))
    }

    func testMatchesRegexComplexPattern() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .regex,
            matchPattern: "https://api\\.example\\.com/(users|posts)/\\d+",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/users/123"))
        XCTAssertTrue(script.matches("https://api.example.com/posts/456"))
        XCTAssertFalse(script.matches("https://api.example.com/comments/789"))
        XCTAssertFalse(script.matches("https://api.example.com/users/abc"))
    }

    func testMatchesRegexInvalidPattern() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .regex,
            matchPattern: "[invalid regex ((",
            code: ""
        )

        // Invalid regex should not match anything
        XCTAssertFalse(script.matches("https://example.com"))
    }

    func testMatchesRegexAnchors() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .regex,
            matchPattern: "^https://example\\.com$",
            code: ""
        )

        XCTAssertTrue(script.matches("https://example.com"))
        XCTAssertFalse(script.matches("https://example.com/users"))
        XCTAssertFalse(script.matches("http://example.com"))
    }

    // MARK: - URL Matching Tests - No Pattern (Match All)

    func testMatchesNoPattern() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchPattern: nil,
            code: ""
        )

        XCTAssertTrue(script.matches("https://example.com"))
        XCTAssertTrue(script.matches("https://any-domain.com/path"))
        XCTAssertTrue(script.matches("http://localhost:8080"))
    }

    func testMatchesEmptyPattern() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchPattern: "",
            code: ""
        )

        XCTAssertTrue(script.matches("https://example.com"))
        XCTAssertTrue(script.matches("https://any-domain.com/path"))
    }

    // MARK: - URL Matching Tests - Disabled Scripts

    func testDisabledScriptDoesNotMatch() {
        let script = Script(
            name: "Test",
            enabled: false,
            scriptType: .request,
            matchPattern: "*example.com*",
            code: ""
        )

        XCTAssertFalse(script.matches("https://api.example.com/users"))
        XCTAssertFalse(script.matches("https://example.com"))
    }

    func testDisabledScriptWithNoPattern() {
        let script = Script(
            name: "Test",
            enabled: false,
            scriptType: .request,
            matchPattern: nil,
            code: ""
        )

        // Even with no pattern (match all), disabled scripts don't match
        XCTAssertFalse(script.matches("https://example.com"))
    }

    // MARK: - Edge Cases

    func testMatchesEmptyURL() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .contains,
            matchPattern: "example",
            code: ""
        )

        XCTAssertFalse(script.matches(""))
    }

    func testMatchesSpecialCharactersInURL() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .contains,
            matchPattern: "?query=test",
            code: ""
        )

        XCTAssertTrue(script.matches("https://example.com/path?query=test&param=value"))
        XCTAssertFalse(script.matches("https://example.com/path"))
    }

    func testMatchesWildcardWithSpecialRegexCharacters() {
        // Test that special regex characters in wildcard patterns are properly escaped
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .wildcard,
            matchPattern: "https://example.com/api?key=*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://example.com/api?key=value"))
        XCTAssertTrue(script.matches("https://example.com/api?key=123"))
    }

    func testMatchesUnicodeURL() {
        let script = Script(
            name: "Test",
            scriptType: .request,
            matchType: .contains,
            matchPattern: "münchen",
            code: ""
        )

        XCTAssertTrue(script.matches("https://münchen.de/path"))
        XCTAssertFalse(script.matches("https://example.com/path"))
    }

    // MARK: - Codable Tests

    func testScriptCodable() throws {
        let script = Script(
            name: "Test Script",
            enabled: true,
            scriptType: .both,
            matchType: .regex,
            matchPattern: ".*example.*",
            code: "console.log('test');",
            executionCount: 10
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(script)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Script.self, from: data)

        XCTAssertEqual(script.id, decoded.id)
        XCTAssertEqual(script.name, decoded.name)
        XCTAssertEqual(script.enabled, decoded.enabled)
        XCTAssertEqual(script.scriptType, decoded.scriptType)
        XCTAssertEqual(script.matchType, decoded.matchType)
        XCTAssertEqual(script.matchPattern, decoded.matchPattern)
        XCTAssertEqual(script.code, decoded.code)
        XCTAssertEqual(script.executionCount, decoded.executionCount)
    }

    // MARK: - Equatable Tests

    func testScriptEquatable() {
        let id = UUID()
        let script1 = Script(id: id, name: "Test 1", scriptType: .request, code: "")
        let script2 = Script(id: id, name: "Test 2", scriptType: .response, code: "")
        let script3 = Script(id: UUID(), name: "Test 1", scriptType: .request, code: "")

        XCTAssertEqual(script1, script2) // Same ID
        XCTAssertNotEqual(script1, script3) // Different ID
    }

    // MARK: - Template Tests

    func testScriptTemplates() {
        let templates = Script.templates

        XCTAssertFalse(templates.isEmpty)
        XCTAssertTrue(templates.count >= 5)

        // Verify all templates have required properties
        for template in templates {
            XCTAssertFalse(template.name.isEmpty)
            XCTAssertFalse(template.code.isEmpty)
        }
    }

    func testAddCustomHeaderTemplate() {
        let template = Script.templates.first { $0.name == "Add Custom Header" }

        XCTAssertNotNil(template)
        XCTAssertEqual(template?.scriptType, .request)
        XCTAssertTrue(template?.code.contains("request.headers") ?? false)
    }

    func testModifyJSONResponseTemplate() {
        let template = Script.templates.first { $0.name == "Modify JSON Response" }

        XCTAssertNotNil(template)
        XCTAssertEqual(template?.scriptType, .response)
        XCTAssertTrue(template?.code.contains("parseJSON") ?? false)
        XCTAssertTrue(template?.code.contains("response.body") ?? false)
    }

    func testLogRequestDetailsTemplate() {
        let template = Script.templates.first { $0.name == "Log Request Details" }

        XCTAssertNotNil(template)
        XCTAssertEqual(template?.scriptType, .request)
        XCTAssertTrue(template?.code.contains("console.log") ?? false)
    }

    func testAddCORSHeadersTemplate() {
        let template = Script.templates.first { $0.name == "Add CORS Headers" }

        XCTAssertNotNil(template)
        XCTAssertEqual(template?.scriptType, .response)
        XCTAssertTrue(template?.code.contains("Access-Control-Allow-Origin") ?? false)
    }

    func testInjectDataTemplate() {
        let template = Script.templates.first { $0.name == "Inject Data into Response" }

        XCTAssertNotNil(template)
        XCTAssertEqual(template?.scriptType, .response)
        XCTAssertTrue(template?.code.contains("injectedField") ?? false)
    }

    // MARK: - Real World Scenario Tests

    func testAPIVersioningPattern() {
        let script = Script(
            name: "API Version",
            scriptType: .request,
            matchType: .regex,
            matchPattern: "https://api\\.example\\.com/v\\d+/.*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/v1/users"))
        XCTAssertTrue(script.matches("https://api.example.com/v2/posts"))
        XCTAssertTrue(script.matches("https://api.example.com/v10/data"))
        XCTAssertFalse(script.matches("https://api.example.com/users"))
        XCTAssertFalse(script.matches("https://web.example.com/v1/users"))
    }

    func testEnvironmentSpecificPattern() {
        let script = Script(
            name: "Production Only",
            scriptType: .request,
            matchType: .wildcard,
            matchPattern: "https://api.example.com/*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/users"))
        XCTAssertTrue(script.matches("https://api.example.com/v1/data"))
        XCTAssertFalse(script.matches("https://staging.api.example.com/users"))
        XCTAssertFalse(script.matches("https://dev.api.example.com/users"))
    }

    func testMultiDomainPattern() {
        let script = Script(
            name: "Multiple Domains",
            scriptType: .request,
            matchType: .regex,
            matchPattern: "https://(api|web|cdn)\\.example\\.com/.*",
            code: ""
        )

        XCTAssertTrue(script.matches("https://api.example.com/users"))
        XCTAssertTrue(script.matches("https://web.example.com/home"))
        XCTAssertTrue(script.matches("https://cdn.example.com/assets/image.png"))
        XCTAssertFalse(script.matches("https://admin.example.com/dashboard"))
    }
}
