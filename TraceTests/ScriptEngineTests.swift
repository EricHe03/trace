//
//  ScriptEngineTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class ScriptEngineTests: XCTestCase {

    var engine: ScriptEngine!

    override func setUp() {
        super.setUp()
        engine = ScriptEngine()
        XCTAssertNotNil(engine, "Failed to initialize ScriptEngine")
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Request Script Tests

    func testModifyRequestURL() throws {
        let script = """
        request.url = 'https://modified.com/api';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        XCTAssertEqual(modified.url, "https://modified.com/api")
        XCTAssertEqual(modified.method, original.method)
    }

    func testModifyRequestMethod() throws {
        let script = """
        request.method = 'POST';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        XCTAssertEqual(modified.method, .post)
        XCTAssertEqual(modified.url, original.url)
    }

    func testModifyRequestHeaders() throws {
        let script = """
        request.headers['Authorization'] = 'Bearer token123';
        request.headers['Content-Type'] = 'application/json';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let authHeader = modified.requestHeaders.first { $0.key == "Authorization" }
        XCTAssertNotNil(authHeader)
        XCTAssertEqual(authHeader?.value, "Bearer token123")

        let contentTypeHeader = modified.requestHeaders.first { $0.key == "Content-Type" }
        XCTAssertNotNil(contentTypeHeader)
        XCTAssertEqual(contentTypeHeader?.value, "application/json")
    }

    func testModifyRequestBody() throws {
        let script = """
        request.body = '{"modified": true}';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5,
            requestBody: BodyStorage.from(string: "{\"original\": true}")
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let bodyString = modified.requestBody.getString()
        XCTAssertEqual(bodyString, "{\"modified\": true}")
    }

    func testModifyRequestMultipleProperties() throws {
        let script = """
        request.url = 'https://api.example.com/v2/users';
        request.method = 'PUT';
        request.headers['X-Custom'] = 'value';
        request.body = '{"updated": true}';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        XCTAssertEqual(modified.url, "https://api.example.com/v2/users")
        XCTAssertEqual(modified.method, .put)
        XCTAssertNotNil(modified.requestHeaders.first { $0.key == "X-Custom" })
        XCTAssertEqual(modified.requestBody.getString(), "{\"updated\": true}")
    }

    // MARK: - Response Script Tests

    func testModifyResponseStatusCode() throws {
        let script = """
        response.statusCode = 404;
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeResponseScript(script, request: original)

        XCTAssertEqual(modified.statusCode, 404)
    }

    func testModifyResponseHeaders() throws {
        let script = """
        response.headers['X-Modified'] = 'true';
        response.headers['Cache-Control'] = 'no-cache';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeResponseScript(script, request: original)

        let modifiedHeader = modified.responseHeaders.first { $0.key == "X-Modified" }
        XCTAssertNotNil(modifiedHeader)
        XCTAssertEqual(modifiedHeader?.value, "true")

        let cacheHeader = modified.responseHeaders.first { $0.key == "Cache-Control" }
        XCTAssertNotNil(cacheHeader)
        XCTAssertEqual(cacheHeader?.value, "no-cache")
    }

    func testModifyResponseBody() throws {
        let script = """
        response.body = '{"mocked": true}';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            responseBody: BodyStorage.from(string: "{\"original\": true}")
        )

        let modified = try engine.executeResponseScript(script, request: original)

        let bodyString = modified.responseBody.getString()
        XCTAssertEqual(bodyString, "{\"mocked\": true}")
    }

    func testModifyResponseMultipleProperties() throws {
        let script = """
        response.statusCode = 201;
        response.headers['Content-Type'] = 'application/json';
        response.body = '{"created": true}';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeResponseScript(script, request: original)

        XCTAssertEqual(modified.statusCode, 201)
        XCTAssertNotNil(modified.responseHeaders.first { $0.key == "Content-Type" })
        XCTAssertEqual(modified.responseBody.getString(), "{\"created\": true}")
    }

    // MARK: - Helper Functions Tests

    func testBase64Encode() throws {
        let script = """
        request.body = encodeBase64('Hello, World!');
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let bodyString = modified.requestBody.getString()
        XCTAssertEqual(bodyString, "SGVsbG8sIFdvcmxkIQ==")
    }

    func testBase64Decode() throws {
        let script = """
        request.body = decodeBase64('SGVsbG8sIFdvcmxkIQ==');
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let bodyString = modified.requestBody.getString()
        XCTAssertEqual(bodyString, "Hello, World!")
    }

    func testJSONParse() throws {
        let script = """
        var parsed = parseJSON('{"key":"value"}');
        request.body = stringifyJSON(parsed);
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let bodyString = modified.requestBody.getString()
        XCTAssertTrue(bodyString?.contains("key") ?? false)
        XCTAssertTrue(bodyString?.contains("value") ?? false)
    }

    func testJSONParseInvalidReturnsNull() throws {
        let script = """
        var parsed = parseJSON('invalid json');
        if (parsed === null) {
            request.body = 'null';
        }
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        XCTAssertEqual(modified.requestBody.getString(), "null")
    }

    // MARK: - Complex Script Tests

    func testComplexRequestModification() throws {
        let script = """
        // Parse existing body
        var body = parseJSON(request.body);

        // Modify data
        body.timestamp = new Date().toISOString();
        body.modified = true;

        // Update request
        request.body = stringifyJSON(body);
        request.headers['X-Modified'] = 'true';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5,
            requestBody: BodyStorage.from(string: "{\"data\":\"test\"}")
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let bodyString = modified.requestBody.getString()
        XCTAssertNotNil(bodyString)
        XCTAssertTrue(bodyString?.contains("modified") ?? false)
        XCTAssertTrue(bodyString?.contains("timestamp") ?? false)

        let header = modified.requestHeaders.first { $0.key == "X-Modified" }
        XCTAssertEqual(header?.value, "true")
    }

    func testConditionalModification() throws {
        let script = """
        if (request.method === 'POST') {
            request.headers['Content-Type'] = 'application/json';
        }
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let header = modified.requestHeaders.first { $0.key == "Content-Type" }
        XCTAssertNotNil(header)
    }

    func testResponseBodyTransformation() throws {
        let script = """
        var data = parseJSON(response.body);
        data.enhanced = true;
        data.server = 'mock';
        response.body = stringifyJSON(data);
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            responseBody: BodyStorage.from(string: "{\"result\":\"success\"}")
        )

        let modified = try engine.executeResponseScript(script, request: original)

        let bodyString = modified.responseBody.getString()
        XCTAssertTrue(bodyString?.contains("enhanced") ?? false)
        XCTAssertTrue(bodyString?.contains("server") ?? false)
        XCTAssertTrue(bodyString?.contains("mock") ?? false)
    }

    // MARK: - Script Validation Tests

    func testValidateValidScript() {
        let script = """
        request.url = 'https://example.com';
        request.headers['X-Custom'] = 'value';
        """

        let result = engine.validateScript(script)

        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.errorMessage)
    }

    func testValidateInvalidScript() {
        let script = """
        this is not valid javascript syntax !!!
        """

        let result = engine.validateScript(script)

        XCTAssertFalse(result.isValid)
        XCTAssertNotNil(result.errorMessage)
    }

    func testValidateSyntaxError() {
        let script = """
        request.url = 'https://example.com'
        if (true { // Missing closing parenthesis
            request.method = 'POST';
        }
        """

        let result = engine.validateScript(script)

        XCTAssertFalse(result.isValid)
    }

    func testValidateEmptyScript() {
        let result = engine.validateScript("")

        XCTAssertTrue(result.isValid)
    }

    // MARK: - Error Handling Tests

    func testScriptWithRuntimeError() {
        let script = """
        throw new Error('Intentional error');
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        do {
            _ = try engine.executeRequestScript(script, request: original)
            XCTFail("Expected error to be thrown")
        } catch let scriptError as ScriptError {
            if case .executionFailed(let message) = scriptError {
                XCTAssertTrue(message.contains("error") || message.contains("Error"))
            } else {
                XCTFail("Expected executionFailed error")
            }
        } catch {
            XCTFail("Expected ScriptError, got \(error)")
        }
    }

    func testScriptWithUndefinedVariable() {
        let script = """
        request.url = undefinedVariable;
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        // JavaScriptCore throws ReferenceError for undefined variables
        do {
            _ = try engine.executeRequestScript(script, request: original)
            XCTFail("Expected error to be thrown")
        } catch let scriptError as ScriptError {
            if case .executionFailed(let message) = scriptError {
                XCTAssertTrue(message.contains("ReferenceError") || message.contains("undefined"))
            } else {
                XCTFail("Expected executionFailed error")
            }
        } catch {
            XCTFail("Expected ScriptError, got \(error)")
        }
    }

    // MARK: - Edge Cases Tests

    func testEmptyScript() throws {
        let script = ""

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        // Request should be unchanged
        XCTAssertEqual(modified.url, original.url)
        XCTAssertEqual(modified.method, original.method)
    }

    func testScriptWithComments() throws {
        let script = """
        // This is a comment
        request.url = 'https://example.com';
        /* Multi-line
           comment */
        request.method = 'POST';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        XCTAssertEqual(modified.url, "https://example.com")
        XCTAssertEqual(modified.method, .post)
    }

    func testScriptWithUnicodeCharacters() throws {
        let script = """
        request.body = 'Hello 世界';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let bodyString = modified.requestBody.getString()
        XCTAssertEqual(bodyString, "Hello 世界")
    }

    func testScriptPreservesOriginalProperties() throws {
        let script = """
        // Only modify URL
        request.url = 'https://modified.com';
        """

        let timestamp = Date()
        let original = NetworkRequest(
            id: UUID(),
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            timestamp: timestamp,
            duration: 1.5,
            requestHeaders: [TraceHTTPHeader(key: "Authorization", value: "Bearer token")]
        )

        let modified = try engine.executeRequestScript(script, request: original)

        XCTAssertEqual(modified.id, original.id)
        XCTAssertEqual(modified.timestamp, original.timestamp)
        XCTAssertEqual(modified.duration, original.duration)
        XCTAssertEqual(modified.statusCode, original.statusCode)
    }

    // MARK: - Multiple Script Execution Tests

    func testMultipleScriptExecutions() throws {
        let script1 = "request.url = 'https://step1.com';"
        let script2 = "request.url = 'https://step2.com';"

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let step1 = try engine.executeRequestScript(script1, request: original)
        XCTAssertEqual(step1.url, "https://step1.com")

        let step2 = try engine.executeRequestScript(script2, request: step1)
        XCTAssertEqual(step2.url, "https://step2.com")
    }

    func testScriptIsolation() throws {
        let script1 = """
        var myVariable = 'test';
        request.url = 'https://example.com';
        """

        let script2 = """
        // myVariable should not exist here
        request.url = typeof myVariable === 'undefined' ? 'https://isolated.com' : 'https://notIsolated.com';
        """

        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        _ = try engine.executeRequestScript(script1, request: original)

        // Variables from previous script should persist in same engine instance
        let result = try engine.executeRequestScript(script2, request: original)

        // In JavaScriptCore, variables persist across evaluations in the same context
        // So myVariable will be defined
        XCTAssertEqual(result.url, "https://notIsolated.com")
    }

    // MARK: - Real World Example Tests

    func testAddAuthenticationToken() throws {
        let script = """
        request.headers['Authorization'] = 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9';
        """

        let original = NetworkRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeRequestScript(script, request: original)

        let authHeader = modified.requestHeaders.first { $0.key == "Authorization" }
        XCTAssertNotNil(authHeader)
        XCTAssertTrue(authHeader?.value.hasPrefix("Bearer ") ?? false)
    }

    func testModifyAPIResponse() throws {
        let script = """
        var data = parseJSON(response.body);
        data.items = data.items.map(function(item) {
            item.enhanced = true;
            return item;
        });
        response.body = stringifyJSON(data);
        """

        let original = NetworkRequest(
            url: "https://api.example.com/items",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            responseBody: BodyStorage.from(string: "{\"items\":[{\"id\":1},{\"id\":2}]}")
        )

        let modified = try engine.executeResponseScript(script, request: original)

        let bodyString = modified.responseBody.getString()
        XCTAssertTrue(bodyString?.contains("enhanced") ?? false)
    }

    func testCORSHeaderInjection() throws {
        let script = """
        response.headers['Access-Control-Allow-Origin'] = '*';
        response.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE';
        """

        let original = NetworkRequest(
            url: "https://api.example.com/data",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let modified = try engine.executeResponseScript(script, request: original)

        let originHeader = modified.responseHeaders.first { $0.key == "Access-Control-Allow-Origin" }
        XCTAssertEqual(originHeader?.value, "*")

        let methodsHeader = modified.responseHeaders.first { $0.key == "Access-Control-Allow-Methods" }
        XCTAssertNotNil(methodsHeader)
    }
}
