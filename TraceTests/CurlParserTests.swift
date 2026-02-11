//
//  CurlParserTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class CurlParserTests: XCTestCase {

    // MARK: - Basic Parsing Tests

    func testParseSimpleGET() throws {
        let curl = "curl https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://example.com")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.requestHeaders.count, 0)
        XCTAssertTrue(request.requestBody.isEmpty)
    }

    func testParseWithoutCurlPrefix() throws {
        let curl = "https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://example.com")
        XCTAssertEqual(request.method, .get)
    }

    func testParseWithHTTP() throws {
        let curl = "curl http://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "http://example.com")
    }

    func testParseWithoutSchemeDefaultsToHTTP() throws {
        let curl = "curl example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "http://example.com")
        XCTAssertEqual(request.method, .get)
    }

    // MARK: - HTTP Method Tests

    func testParsePOSTMethod() throws {
        let curl = "curl -X POST https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .post)
    }

    func testParsePUTMethod() throws {
        let curl = "curl --request PUT https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .put)
    }

    func testParseDELETEMethod() throws {
        let curl = "curl -X DELETE https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .delete)
    }

    func testParseHEADMethod() throws {
        let curl = "curl -I https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .head)
    }

    func testParseHeadWithFlag() throws {
        let curl = "curl --head https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .head)
    }

    // MARK: - Header Tests

    func testParseSingleHeader() throws {
        let curl = "curl -H 'Content-Type: application/json' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 1)
        XCTAssertEqual(request.requestHeaders[0].key, "Content-Type")
        XCTAssertEqual(request.requestHeaders[0].value, "application/json")
    }

    func testParseMultipleHeaders() throws {
        let curl = "curl -H 'Content-Type: application/json' -H 'Authorization: Bearer token' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 2)
        XCTAssertEqual(request.requestHeaders[0].key, "Content-Type")
        XCTAssertEqual(request.requestHeaders[0].value, "application/json")
        XCTAssertEqual(request.requestHeaders[1].key, "Authorization")
        XCTAssertEqual(request.requestHeaders[1].value, "Bearer token")
    }

    func testParseHeaderWithLongFlag() throws {
        let curl = "curl --header 'Accept: */*' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 1)
        XCTAssertEqual(request.requestHeaders[0].key, "Accept")
        XCTAssertEqual(request.requestHeaders[0].value, "*/*")
    }

    // MARK: - Data/Body Tests

    func testParseDataImplicitPOST() throws {
        let curl = "curl -d 'key=value' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .post) // Implicit POST
        let bodyData = request.requestBody.getData()
        XCTAssertNotNil(bodyData)
        XCTAssertEqual(String(data: bodyData!, encoding: .utf8), "key=value")
    }

    func testParseDataRaw() throws {
        let curl = "curl --data-raw '{\"name\":\"test\"}' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .post)
        let bodyData = request.requestBody.getData()
        XCTAssertNotNil(bodyData)
        XCTAssertEqual(String(data: bodyData!, encoding: .utf8), "{\"name\":\"test\"}")
    }

    func testParseDataBinary() throws {
        let curl = "curl --data-binary 'raw data' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .post)
        let bodyData = request.requestBody.getData()
        XCTAssertNotNil(bodyData)
        XCTAssertEqual(String(data: bodyData!, encoding: .utf8), "raw data")
    }

    func testParseDataWithExplicitPOST() throws {
        let curl = "curl -X POST -d 'data' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .post)
    }

    func testParseGetMovesDataToQuery() throws {
        let curl = "curl -G -d 'a=1' -d 'b=2' https://example.com/path"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url, "https://example.com/path?a=1&b=2")
        XCTAssertTrue(request.requestBody.isEmpty)
    }

    func testParseDataUrlencodeNameFile() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "hello world".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let curl = "curl --data-urlencode message@\(tempURL.path) https://example.com"
        let request = try CurlParser.parse(curl)

        let bodyData = request.requestBody.getData()
        XCTAssertNotNil(bodyData)
        XCTAssertEqual(String(data: bodyData!, encoding: .utf8), "message=hello%20world")
    }

    func testParseFormSetsMultipartBody() throws {
        let curl = "curl -F 'field=value' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .post)
        let contentType = request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? ""
        XCTAssertTrue(contentType.contains("multipart/form-data"))
        let body = request.requestBody.getString() ?? ""
        XCTAssertTrue(body.contains("field"))
        XCTAssertTrue(body.contains("value"))
    }

    func testParseUploadFileSetsBody() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "payload".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let curl = "curl -T \(tempURL.path) https://example.com/upload"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.method, .put)
        let bodyData = request.requestBody.getData()
        XCTAssertNotNil(bodyData)
        XCTAssertEqual(String(data: bodyData!, encoding: .utf8), "payload")
    }

    // MARK: - Authentication Tests

    func testParseBasicAuth() throws {
        let curl = "curl -u username:password https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 1)
        XCTAssertEqual(request.requestHeaders[0].key, "Authorization")
        XCTAssertTrue(request.requestHeaders[0].value.hasPrefix("Basic "))

        // Verify the base64 encoding
        let credentials = "username:password"
        let expectedAuth = credentials.data(using: .utf8)!.base64EncodedString()
        XCTAssertEqual(request.requestHeaders[0].value, "Basic \(expectedAuth)")
    }

    func testParseUserWithLongFlag() throws {
        let curl = "curl --user admin:secret https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 1)
        XCTAssertEqual(request.requestHeaders[0].key, "Authorization")
    }

    // MARK: - User Agent Tests

    func testParseUserAgent() throws {
        let curl = "curl -A 'MyApp/1.0' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 1)
        XCTAssertEqual(request.requestHeaders[0].key, "User-Agent")
        XCTAssertEqual(request.requestHeaders[0].value, "MyApp/1.0")
    }

    func testParseUserAgentLongFlag() throws {
        let curl = "curl --user-agent 'CustomAgent/2.0' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders[0].value, "CustomAgent/2.0")
    }

    // MARK: - Referer Tests

    func testParseReferer() throws {
        let curl = "curl -e 'https://google.com' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 1)
        XCTAssertEqual(request.requestHeaders[0].key, "Referer")
        XCTAssertEqual(request.requestHeaders[0].value, "https://google.com")
    }

    func testParseRefererLongFlag() throws {
        let curl = "curl --referer 'https://previous.com' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders[0].key, "Referer")
    }

    // MARK: - Cookie Tests

    func testParseCookie() throws {
        let curl = "curl -b 'session=abc123' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 1)
        XCTAssertEqual(request.requestHeaders[0].key, "Cookie")
        XCTAssertEqual(request.requestHeaders[0].value, "session=abc123")
    }

    func testParseCookieLongFlag() throws {
        let curl = "curl --cookie 'user=john; session=xyz' https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders[0].value, "user=john; session=xyz")
    }

    // MARK: - Compressed Response Tests

    func testParseCompressed() throws {
        let curl = "curl --compressed https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.requestHeaders.count, 1)
        XCTAssertEqual(request.requestHeaders[0].key, "Accept-Encoding")
        XCTAssertEqual(request.requestHeaders[0].value, "gzip, deflate, br")
    }

    // MARK: - Quote and Escape Tests

    func testParseQuotedURL() throws {
        let curl = "curl 'https://example.com/path'"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://example.com/path")
    }

    func testParseDoubleQuotedURL() throws {
        let curl = "curl \"https://example.com/path\""
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://example.com/path")
    }

    func testParseEscapedQuotes() throws {
        let curl = "curl -d '{\\\"key\\\":\\\"value\\\"}' https://example.com"
        let request = try CurlParser.parse(curl)

        let bodyData = request.requestBody.getData()
        XCTAssertNotNil(bodyData)
        XCTAssertEqual(String(data: bodyData!, encoding: .utf8), "{\"key\":\"value\"}")
    }

    // MARK: - Complex Command Tests

    func testParseComplexCommand() throws {
        let curl = """
        curl -X POST https://api.example.com/users \
          -H 'Content-Type: application/json' \
          -H 'Authorization: Bearer token123' \
          -d '{"name":"John","email":"john@example.com"}'
        """
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://api.example.com/users")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.requestHeaders.count, 2)

        let bodyData = request.requestBody.getData()
        XCTAssertNotNil(bodyData)
        let bodyString = String(data: bodyData!, encoding: .utf8)
        XCTAssertTrue(bodyString?.contains("John") ?? false)
    }

    func testParseMultilineCommandWithLineContinuationAfterQuotedValues() throws {
        let curl = """
        curl -X POST -H 'Content-Type: application/json' \
             -d '{"hello":"world"}' \
             https://httpbin.org/post
        """

        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://httpbin.org/post")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.requestHeaders.first(where: { $0.key == "Content-Type" })?.value, "application/json")

        let bodyData = request.requestBody.getData()
        XCTAssertNotNil(bodyData)
        XCTAssertEqual(String(data: bodyData!, encoding: .utf8), "{\"hello\":\"world\"}")
    }

    func testParseRealWorldExample() throws {
        let curl = """
        curl 'https://api.github.com/repos/owner/repo/issues' \
          -H 'Accept: application/vnd.github.v3+json' \
          -H 'Authorization: token ghp_abc123' \
          -d '{"title":"Bug report","body":"Description"}'
        """
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://api.github.com/repos/owner/repo/issues")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.requestHeaders.count, 2)
    }

    // MARK: - Ignored Options Tests

    func testParseIgnoredOptions() throws {
        let curl = "curl -v -s --silent https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://example.com")
    }

    func testParseOutputOption() throws {
        let curl = "curl -o output.txt https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://example.com")
    }

    func testParseIncludeOption() throws {
        let curl = "curl -i https://example.com"
        let request = try CurlParser.parse(curl)

        XCTAssertEqual(request.url, "https://example.com")
    }

    // MARK: - Error Handling Tests

    func testParseEmptyCommand() {
        do {
            _ = try CurlParser.parse("")
            XCTFail("Expected error to be thrown")
        } catch let parseError as CurlParser.ParseError {
            XCTAssertEqual(parseError, .missingURL)
        } catch {
            XCTFail("Expected ParseError, got \(error)")
        }
    }

    func testParseCurlOnly() {
        do {
            _ = try CurlParser.parse("curl")
            XCTFail("Expected error to be thrown")
        } catch let parseError as CurlParser.ParseError {
            XCTAssertEqual(parseError, .missingURL)
        } catch {
            XCTFail("Expected ParseError, got \(error)")
        }
    }

    func testParseWhitespaceOnly() {
        do {
            _ = try CurlParser.parse("   ")
            XCTFail("Expected error to be thrown")
        } catch let parseError as CurlParser.ParseError {
            XCTAssertEqual(parseError, .missingURL)
        } catch {
            XCTFail("Expected ParseError, got \(error)")
        }
    }

    // MARK: - Export to cURL Tests

    func testToCurlSimpleGET() {
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5
        )

        let curl = CurlParser.toCurl(request)

        XCTAssertTrue(curl.contains("curl"))
        XCTAssertTrue(curl.contains("'https://example.com'"))
        XCTAssertTrue(curl.contains("-X GET"))
    }

    func testToCurlPOSTWithData() {
        let bodyData = "{\"key\":\"value\"}".data(using: .utf8)!
        let request = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5,
            requestBody: BodyStorage.from(data: bodyData)
        )

        let curl = CurlParser.toCurl(request)

        XCTAssertTrue(curl.contains("-X POST"))
        XCTAssertTrue(curl.contains("--data-raw"))
        XCTAssertTrue(curl.contains("key"))
    }

    func testToCurlWithHeaders() {
        let headers = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Authorization", value: "Bearer token")
        ]
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            requestHeaders: headers
        )

        let curl = CurlParser.toCurl(request)

        XCTAssertTrue(curl.contains("-H 'Content-Type: application/json'"))
        XCTAssertTrue(curl.contains("-H 'Authorization: Bearer token'"))
    }

    func testToCurlEscapesQuotes() {
        let headers = [
            TraceHTTPHeader(key: "X-Custom", value: "value with 'quotes'")
        ]
        let request = NetworkRequest(
            url: "https://example.com",
            method: .get,
            statusCode: 200,
            duration: 0.5,
            requestHeaders: headers
        )

        let curl = CurlParser.toCurl(request)

        XCTAssertTrue(curl.contains("\\'"))
    }

    // MARK: - Multiple Commands Tests

    func testParseAllMultipleUrls() throws {
        let requests = try CurlParser.parseAll("curl https://example.com/1 https://example.com/2")

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, "https://example.com/1")
        XCTAssertEqual(requests[1].url, "https://example.com/2")
    }

    func testParseGlobbingExpandsRanges() throws {
        let requests = try CurlParser.parseAll("curl https://example.com/file[1-2].txt")

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url, "https://example.com/file1.txt")
        XCTAssertEqual(requests[1].url, "https://example.com/file2.txt")
    }

    func testParseGloboffDisablesExpansion() throws {
        let requests = try CurlParser.parseAll("curl -g https://example.com/file[1-2].txt")

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, "https://example.com/file[1-2].txt")
    }

    func testParseMultipleCommands() {
        let commands = """
        curl https://example.com/1
        curl https://example.com/2
        curl https://example.com/3
        """

        let results = CurlParser.parseMultiple(commands)

        XCTAssertEqual(results.count, 3)
        XCTAssertNotNil(results[0].request)
        XCTAssertNil(results[0].error)
        XCTAssertEqual(results[0].request?.url, "https://example.com/1")
        XCTAssertEqual(results[1].request?.url, "https://example.com/2")
        XCTAssertEqual(results[2].request?.url, "https://example.com/3")
    }

    func testParseMultipleWithErrors() {
        let commands = """
        curl https://example.com/1
        invalid command
        curl https://example.com/3
        """

        let results = CurlParser.parseMultiple(commands)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].request?.url, "https://example.com/1")
        XCTAssertNotNil(results[1].error)
        XCTAssertEqual(results[2].request?.url, "https://example.com/3")
    }

    func testParseMultipleSkipsComments() {
        let commands = """
        # This is a comment
        curl https://example.com/1
        # Another comment
        curl https://example.com/2
        """

        let results = CurlParser.parseMultiple(commands)

        XCTAssertEqual(results.count, 2)
    }

    func testParseMultipleSkipsEmptyLines() {
        let commands = """
        curl https://example.com/1

        curl https://example.com/2

        """

        let results = CurlParser.parseMultiple(commands)

        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Round-Trip Tests

    func testRoundTripSimple() throws {
        let original = NetworkRequest(
            url: "https://example.com/api",
            method: .post,
            statusCode: 200,
            duration: 0.5,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            requestBody: BodyStorage.from(data: "{\"test\":true}".data(using: .utf8)!)
        )

        let curl = CurlParser.toCurl(original)
        let parsed = try CurlParser.parse(curl)

        XCTAssertEqual(parsed.url, original.url)
        XCTAssertEqual(parsed.method, original.method)
        XCTAssertEqual(parsed.requestHeaders.count, original.requestHeaders.count)
    }
}
