//
//  RequestMapTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class RequestMapTests: XCTestCase {

    // MARK: - URL Matching Tests

    func testMatchesDisabled() {
        let map = RequestMap(
            name: "Test Map",
            enabled: false,
            matchType: .wildcard,
            matchPattern: "*",
            mockResponse: MockResponse()
        )

        XCTAssertFalse(map.matches("https://api.example.com"))
    }

    func testMatchesExact() {
        let map = RequestMap(
            name: "Test Map",
            enabled: true,
            matchType: .exact,
            matchPattern: "https://api.example.com/test",
            mockResponse: MockResponse()
        )

        XCTAssertTrue(map.matches("https://api.example.com/test"))
        XCTAssertFalse(map.matches("https://api.example.com/test/"))
        XCTAssertFalse(map.matches("https://api.example.com"))
    }

    func testMatchesContains() {
        let map = RequestMap(
            name: "Test Map",
            enabled: true,
            matchType: .contains,
            matchPattern: "api.example.com",
            mockResponse: MockResponse()
        )

        XCTAssertTrue(map.matches("https://api.example.com/test"))
        XCTAssertTrue(map.matches("https://api.example.com"))
        XCTAssertTrue(map.matches("http://api.example.com:8080/path"))
        XCTAssertFalse(map.matches("https://other.com"))
    }

    func testMatchesWildcard() {
        let map = RequestMap(
            name: "Test Map",
            enabled: true,
            matchType: .wildcard,
            matchPattern: "*.example.com/api/*",
            mockResponse: MockResponse()
        )

        XCTAssertTrue(map.matches("https://api.example.com/api/users"))
        XCTAssertTrue(map.matches("https://cdn.example.com/api/data"))
        XCTAssertFalse(map.matches("https://example.com/api/users"))
        XCTAssertFalse(map.matches("https://api.example.com/other"))
    }

    func testMatchesWildcardCaseInsensitive() {
        let map = RequestMap(
            name: "Test Map",
            enabled: true,
            matchType: .wildcard,
            matchPattern: "*.EXAMPLE.COM*",
            mockResponse: MockResponse()
        )

        XCTAssertTrue(map.matches("https://api.example.com/test"))
        XCTAssertTrue(map.matches("https://API.EXAMPLE.COM/test"))
    }

    func testMatchesWildcardMatchAll() {
        let map = RequestMap(
            name: "Test Map",
            enabled: true,
            matchType: .wildcard,
            matchPattern: "*",
            mockResponse: MockResponse()
        )

        XCTAssertTrue(map.matches("https://api.example.com"))
        XCTAssertTrue(map.matches("https://other.com"))
        XCTAssertTrue(map.matches("http://localhost:3000"))
    }

    func testMatchesRegex() {
        let map = RequestMap(
            name: "Test Map",
            enabled: true,
            matchType: .regex,
            matchPattern: "^https://api\\.example\\.com/.*",
            mockResponse: MockResponse()
        )

        XCTAssertTrue(map.matches("https://api.example.com/test"))
        XCTAssertTrue(map.matches("https://api.example.com/users/123"))
        XCTAssertFalse(map.matches("https://other.com"))
    }

    func testMatchesRegexAlternation() {
        let map = RequestMap(
            name: "Test Map",
            enabled: true,
            matchType: .regex,
            matchPattern: "^https://(api|cdn)\\.example\\.com.*",
            mockResponse: MockResponse()
        )

        XCTAssertTrue(map.matches("https://api.example.com/test"))
        XCTAssertTrue(map.matches("https://cdn.example.com/image.png"))
        XCTAssertFalse(map.matches("https://web.example.com"))
    }

    func testMatchesRegexInvalidPattern() {
        let map = RequestMap(
            name: "Test Map",
            enabled: true,
            matchType: .regex,
            matchPattern: "[invalid(regex",
            mockResponse: MockResponse()
        )

        XCTAssertFalse(map.matches("https://api.example.com"))
    }

    // MARK: - RequestMap Creation Tests

    func testFromRequestWithDefaultName() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/test",
            method: .get,
            statusCode: 200,
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            responseBody: makeBodyStorage(string: "{\"test\": true}")
        )

        let map = RequestMap.fromRequest(request)

        XCTAssertEqual(map.name, "Mock for https://api.example.com/test")
        XCTAssertTrue(map.enabled)
        XCTAssertEqual(map.matchType, .exact)
        XCTAssertEqual(map.matchPattern, "https://api.example.com/test")
        XCTAssertEqual(map.mockResponse.statusCode, 200)
    }

    func testFromRequestWithCustomName() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/test",
            method: .get,
            statusCode: 200
        )

        let map = RequestMap.fromRequest(request, name: "Custom Mock Name")

        XCTAssertEqual(map.name, "Custom Mock Name")
        XCTAssertEqual(map.matchPattern, "https://api.example.com/test")
    }

    func testHitCountInitializesToZero() {
        let map = RequestMap(
            name: "Test Map",
            matchType: .wildcard,
            matchPattern: "*",
            mockResponse: MockResponse()
        )

        XCTAssertEqual(map.hitCount, 0)
    }

    // MARK: - Equatable Tests

    func testRequestMapEquality() {
        let id = UUID()
        let map1 = RequestMap(
            id: id,
            name: "Test Map",
            matchType: .wildcard,
            matchPattern: "*",
            mockResponse: MockResponse()
        )
        let map2 = RequestMap(
            id: id,
            name: "Different Name",
            matchType: .exact,
            matchPattern: "https://other.com",
            mockResponse: MockResponse()
        )

        XCTAssertEqual(map1, map2) // Same ID means equal
    }

    func testRequestMapInequality() {
        let map1 = RequestMap(
            name: "Test Map",
            matchType: .wildcard,
            matchPattern: "*",
            mockResponse: MockResponse()
        )
        let map2 = RequestMap(
            name: "Test Map",
            matchType: .wildcard,
            matchPattern: "*",
            mockResponse: MockResponse()
        )

        XCTAssertNotEqual(map1, map2) // Different IDs
    }
}

// MARK: - MockResponse Tests

final class MockResponseTests: XCTestCase {

    func testGetBodyInline() throws {
        let testData = "test body".data(using: .utf8)!
        let response = MockResponse(
            bodySource: .inline,
            bodyContent: testData
        )

        let body = try response.getBody()
        XCTAssertEqual(body, testData)
    }

    func testGetBodyInlineEmpty() throws {
        let response = MockResponse(
            bodySource: .inline,
            bodyContent: nil
        )

        let body = try response.getBody()
        XCTAssertEqual(body, Data())
    }

    func testGetBodyFileThrowsWhenPathMissing() {
        let response = MockResponse(
            bodySource: .file,
            bodyFilePath: nil
        )

        do {
            _ = try response.getBody()
            XCTFail("Expected error to be thrown")
        } catch let mapError as RequestMapError {
            switch mapError {
            case .missingFilePath:
                break // Expected error
            default:
                XCTFail("Expected missingFilePath error")
            }
        } catch {
            XCTFail("Expected RequestMapError, got \(error)")
        }
    }

    func testGetBodyFileThrowsWhenFileNotFound() {
        let response = MockResponse(
            bodySource: .file,
            bodyFilePath: "/nonexistent/path/to/file.json"
        )

        do {
            _ = try response.getBody()
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected error
        }
    }

    func testGetBodyFileWithValidFile() throws {
        // Create a temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-\(UUID().uuidString).txt")
        let testContent = "test file content".data(using: .utf8)!
        try testContent.write(to: tempFile)

        // Test reading from file
        let response = MockResponse(
            bodySource: .file,
            bodyFilePath: tempFile.path
        )

        let body = try response.getBody()
        XCTAssertEqual(body, testContent)

        // Cleanup
        try? FileManager.default.removeItem(at: tempFile)
    }

    func testGetBodyScriptThrowsNotSupported() {
        let response = MockResponse(
            bodySource: .script,
            scriptContent: "return { data: 'test' }"
        )

        do {
            _ = try response.getBody()
            XCTFail("Expected error to be thrown")
        } catch let mapError as RequestMapError {
            switch mapError {
            case .scriptExecutionNotSupported:
                break // Expected error
            default:
                XCTFail("Expected scriptExecutionNotSupported error")
            }
        } catch {
            XCTFail("Expected RequestMapError, got \(error)")
        }
    }

    func testFromRequest() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/test",
            method: .get,
            statusCode: 404,
            statusMessage: "Not Found",
            responseHeaders: [
                TraceHTTPHeader(key: "Content-Type", value: "application/json"),
                TraceHTTPHeader(key: "X-Custom", value: "header-value")
            ],
            responseBody: makeBodyStorage(string: "{\"error\": \"not found\"}")
        )

        let mockResponse = MockResponse.from(request: request)

        XCTAssertEqual(mockResponse.statusCode, 404)
        XCTAssertEqual(mockResponse.statusMessage, "not found") // System localized
        XCTAssertEqual(mockResponse.headers.count, 2)
        XCTAssertEqual(mockResponse.bodySource, .inline)
        XCTAssertNotNil(mockResponse.bodyContent)
        XCTAssertEqual(mockResponse.delay, 0)
    }

    func testFromRequestWithEmptyBody() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/test",
            method: .get,
            statusCode: 200,
            responseBody: .empty
        )

        let mockResponse = MockResponse.from(request: request)

        XCTAssertEqual(mockResponse.statusCode, 200)
        XCTAssertEqual(mockResponse.bodySource, .inline)
        // Body content should be nil or empty data
    }

    func testFromRequestWithNoStatusCode() {
        let request = makeNetworkRequest(
            url: "https://api.example.com/test",
            method: .get,
            statusCode: nil,
            responseBody: .empty
        )

        let mockResponse = MockResponse.from(request: request)

        XCTAssertEqual(mockResponse.statusCode, 200) // Defaults to 200
    }

    func testMockResponseInitialization() {
        let response = MockResponse(
            statusCode: 201,
            statusMessage: "Created",
            headers: [TraceHTTPHeader(key: "Location", value: "/resource/123")],
            bodySource: .inline,
            bodyContent: "Created".data(using: .utf8),
            delay: 100
        )

        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.statusMessage, "Created")
        XCTAssertEqual(response.headers.count, 1)
        XCTAssertEqual(response.bodySource, .inline)
        XCTAssertNotNil(response.bodyContent)
        XCTAssertEqual(response.delay, 100)
    }

    func testMockResponseDefaultInitialization() {
        let response = MockResponse()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.statusMessage, "OK")
        XCTAssertEqual(response.headers.count, 0)
        XCTAssertEqual(response.bodySource, .inline)
        XCTAssertNil(response.bodyContent)
        XCTAssertEqual(response.delay, 0)
    }

    // MARK: - Equatable Tests

    func testMockResponseEquality() {
        let headers = [TraceHTTPHeader(key: "Content-Type", value: "application/json")]
        let bodyData = "test".data(using: .utf8)

        let response1 = MockResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: headers,
            bodySource: .inline,
            bodyContent: bodyData,
            delay: 100
        )

        let response2 = MockResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: headers,
            bodySource: .inline,
            bodyContent: bodyData,
            delay: 100
        )

        XCTAssertEqual(response1, response2)
    }

    func testMockResponseInequalityStatusCode() {
        let response1 = MockResponse(statusCode: 200)
        let response2 = MockResponse(statusCode: 404)

        XCTAssertNotEqual(response1, response2)
    }

    func testMockResponseInequalityBodySource() {
        let response1 = MockResponse(bodySource: .inline)
        let response2 = MockResponse(bodySource: .file)

        XCTAssertNotEqual(response1, response2)
    }

    func testMockResponseInequalityDelay() {
        let response1 = MockResponse(delay: 0)
        let response2 = MockResponse(delay: 100)

        XCTAssertNotEqual(response1, response2)
    }
}

// MARK: - RequestMapError Tests

final class RequestMapErrorTests: XCTestCase {

    func testMissingFilePathError() {
        let error = RequestMapError.missingFilePath
        XCTAssertEqual(error.errorDescription, "File path is required when body source is 'file'")
    }

    func testFileNotFoundError() {
        let error = RequestMapError.fileNotFound("/path/to/file")
        XCTAssertEqual(error.errorDescription, "File not found at path: /path/to/file")
    }

    func testScriptExecutionNotSupportedError() {
        let error = RequestMapError.scriptExecutionNotSupported
        XCTAssertEqual(error.errorDescription, "Script execution not yet supported")
    }

    func testInvalidBodyDataError() {
        let error = RequestMapError.invalidBodyData
        XCTAssertEqual(error.errorDescription, "Invalid body data")
    }
}
