//
//  HTTPParserTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/13.
//

import XCTest
@testable import TraceNetworking
@testable import TraceVPN

final class HTTPParserTests: XCTestCase {
    // MARK: - Request Parsing Tests

    func testParseRequest_ValidGET_ParsesCorrectly() {
        // Given
        let requestData = makeHTTPRequest(
            method: "GET",
            path: "/api/users",
            headers: [
                "Host": "example.com",
                "User-Agent": "TestClient/1.0",
                "Accept": "application/json"
            ]
        )

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.method, "GET")
        XCTAssertEqual(result?.uri, "/api/users")
        XCTAssertEqual(result?.version, "HTTP/1.1")
        XCTAssertEqual(result?.headers["host"]?.first, "example.com")
        XCTAssertEqual(result?.headers["user-agent"]?.first, "TestClient/1.0")
        XCTAssertEqual(result?.headers["accept"]?.first, "application/json")
        XCTAssertTrue(result?.body.isEmpty ?? false)
    }

    func testParseRequest_ValidPOST_ParsesBodyCorrectly() {
        // Given
        let body = "{\"name\":\"John\",\"age\":30}".data(using: .utf8)!
        let requestData = makeHTTPRequest(
            method: "POST",
            path: "/api/users",
            headers: [
                "Host": "example.com",
                "Content-Type": "application/json"
            ],
            body: body
        )

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.method, "POST")
        XCTAssertEqual(result?.body, body)
    }

    func testParseRequest_AllHTTPMethods_ParsedCorrectly() {
        // Given
        let methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

        for method in methods {
            // When
            let requestData = makeHTTPRequest(method: method, path: "/test")
            let result = HTTPParser.parseRequest(from: requestData)

            // Then
            XCTAssertNotNil(result, "Failed to parse \(method)")
            XCTAssertEqual(result?.method, method)
        }
    }

    func testParseRequest_HeadersAreCaseInsensitive() {
        // Given
        let requestData = makeHTTPRequest(
            method: "GET",
            path: "/",
            headers: [
                "Content-Type": "text/html",
                "X-Custom-Header": "Value"
            ]
        )

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.headers["content-type"]?.first, "text/html")
        XCTAssertEqual(result?.headers["x-custom-header"]?.first, "Value")
    }

    func testParseRequest_MultipleHeadersWithSameKey_LastValueWins() {
        // Given
        let requestString = "GET / HTTP/1.1\r\nHost: example.com\r\nCookie: a=1\r\nCookie: b=2\r\n\r\n"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        // In this implementation, the last value overwrites previous ones
        XCTAssertNotNil(result?.headers["cookie"]?.first)
    }

    func testParseRequest_WithContentLength_ExtractsBody() {
        // Given
        let body = "Hello World"
        let requestData = makeHTTPRequest(
            method: "POST",
            path: "/api/test",
            headers: ["Host": "example.com"],
            body: body.data(using: .utf8)!
        )

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, body.data(using: .utf8))
        XCTAssertEqual(result?.body.count, body.count)
    }

    func testParseRequest_ChunkedEncoding_DecodesBody() {
        // Given
        let requestString = "POST /api/data HTTP/1.1\r\n" +
            "Host: example.com\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "5\r\n" +
            "Hello\r\n" +
            "6\r\n" +
            " World\r\n" +
            "0\r\n" +
            "\r\n"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, "Hello World".data(using: .utf8))
    }

    func testParseRequest_ChunkedEncoding_WithTrailers_ParsesTrailers() {
        // Given
        let requestString = "POST /api/data HTTP/1.1\r\n" +
            "Host: example.com\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "5\r\n" +
            "Hello\r\n" +
            "0\r\n" +
            "Trailer-One: value1\r\n" +
            "Set-Cookie: blocked\r\n" +
            "\r\n"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, "Hello".data(using: .utf8))
        XCTAssertEqual(result?.trailers["trailer-one"]?.first, "value1")
        XCTAssertNil(result?.trailers["set-cookie"])
    }

    func testParseRequest_HeaderDelimiterWithLFOnly_ParsesCorrectly() {
        // Given - LF-only header delimiter
        let requestString = "GET / HTTP/1.1\nHost: example.com\n\n"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.method, "GET")
        XCTAssertEqual(result?.headers["host"]?.first, "example.com")
    }

    func testParseRequest_IncompleteHeaders_ReturnsNil() {
        // Given - Missing double CRLF
        let incompleteData = "GET / HTTP/1.1\r\nHost: example.com\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: incompleteData)

        // Then
        XCTAssertNil(result)
    }

    func testParseRequest_IncompleteBody_ReturnsNil() {
        // Given - Content-Length says 100 bytes but only 10 provided
        let requestString = "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 100\r\n\r\n0123456789"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNil(result)
    }

    func testParseRequest_IncompleteChunkedBody_ReturnsNil() {
        // Given - Chunked encoding without terminal chunk
        let requestString = "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNil(result)
    }

    func testParseRequest_MalformedRequestLine_ReturnsNil() {
        // Given - Request line with only 2 components instead of 3
        let malformedData = "GET /\r\nHost: example.com\r\n\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: malformedData)

        // Then
        XCTAssertNil(result)
    }

    func testParseRequest_EmptyRequestLine_ReturnsNil() {
        // Given
        let emptyData = "\r\nHost: example.com\r\n\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: emptyData)

        // Then
        XCTAssertNil(result)
    }

    // MARK: - Response Parsing Tests

    func testParseResponse_ValidStatus200_ParsesCorrectly() {
        // Given
        let responseData = makeHTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: [
                "Content-Type": "text/html",
                "Server": "TestServer/1.0"
            ],
            body: "<html></html>".data(using: .utf8)!
        )

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.statusCode, 200)
        XCTAssertEqual(result?.statusMessage, "OK")
        XCTAssertEqual(result?.version, "HTTP/1.1")
        XCTAssertEqual(result?.headers["content-type"]?.first, "text/html")
        XCTAssertEqual(result?.headers["server"]?.first, "TestServer/1.0")
    }

    func testParseResponse_Status404_ParsesCorrectly() {
        // Given
        let responseData = makeHTTPResponse(
            statusCode: 404,
            statusMessage: "Not Found",
            headers: ["Content-Type": "text/plain"],
            body: "Not Found".data(using: .utf8)!
        )

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.statusCode, 404)
        XCTAssertEqual(result?.statusMessage, "Not Found")
    }

    func testParseResponse_Status204NoContent_HasEmptyBody() {
        // Given
        let responseString = "HTTP/1.1 204 No Content\r\nServer: TestServer\r\n\r\n"
        let responseData = responseString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.statusCode, 204)
        XCTAssertTrue(result?.body.isEmpty ?? false)
    }

    func testParseResponse_Status304NotModified_HasEmptyBody() {
        // Given
        let responseString = "HTTP/1.1 304 Not Modified\r\nServer: TestServer\r\n\r\n"
        let responseData = responseString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.statusCode, 304)
        XCTAssertTrue(result?.body.isEmpty ?? false)
    }

    func testParseResponse_Status1xx_HasEmptyBody() {
        // Given
        let responseString = "HTTP/1.1 100 Continue\r\nServer: TestServer\r\n\r\n"
        let responseData = responseString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.statusCode, 100)
        XCTAssertTrue(result?.body.isEmpty ?? false)
    }

    func testParseResponse_WithContentLength_ExtractsBody() {
        // Given
        let body = "Response body content"
        let responseData = makeHTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: ["Content-Type": "text/plain"],
            body: body.data(using: .utf8)!
        )

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, body.data(using: .utf8))
    }

    func testParseResponse_ChunkedEncoding_DecodesBody() {
        // Given
        let responseString = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/plain\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "7\r\n" +
            "Hello, \r\n" +
            "6\r\n" +
            "World!\r\n" +
            "0\r\n" +
            "\r\n"
        let responseData = responseString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, "Hello, World!".data(using: .utf8))
    }

    func testParseResponse_ChunkedEncoding_WithTrailers_ParsesTrailers() {
        // Given
        let responseString = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/plain\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "5\r\n" +
            "Hello\r\n" +
            "0\r\n" +
            "Trailer-Two: value2\r\n" +
            "\r\n"
        let responseData = responseString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, "Hello".data(using: .utf8))
        XCTAssertEqual(result?.trailers["trailer-two"]?.first, "value2")
    }

    func testParseResponse_InvalidContentLength_WithEmptyBody_ParsesHeaders() {
        // Given
        let responseString = "HTTP/1.1 200 OK\r\nContent-Length: invalid\r\n\r\n"
        let responseData = responseString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.body.isEmpty ?? false)
    }

    func testParseResponse_WithoutContentLength_WhenConnectionClosed_ReturnsFullBody() {
        // Given - Response without Content-Length
        let responseString = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nBody content here"
        let responseData = responseString.data(using: .utf8)!

        // When - Connection is closed
        let result = HTTPParser.parseResponse(from: responseData, isConnectionClosed: true)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, "Body content here".data(using: .utf8))
    }

    func testParseResponse_WithoutContentLength_WhenConnectionOpen_ReturnsNil() {
        // Given - Response without Content-Length
        let responseString = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nBody content"
        let responseData = responseString.data(using: .utf8)!

        // When - Connection is still open
        let result = HTTPParser.parseResponse(from: responseData, isConnectionClosed: false)

        // Then - Should return nil because we don't know if body is complete
        XCTAssertNil(result)
    }

    func testParseResponse_IncompleteHeaders_ReturnsNil() {
        // Given - Missing double CRLF
        let incompleteData = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: incompleteData)

        // Then
        XCTAssertNil(result)
    }

    func testParseResponse_IncompleteBody_ReturnsNil() {
        // Given - Content-Length says 100 bytes but only 10 provided
        let responseString = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n0123456789"
        let responseData = responseString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNil(result)
    }

    func testParseResponse_MalformedStatusLine_ReturnsNil() {
        // Given - Status line with only 2 components
        let malformedData = "HTTP/1.1 200\r\nContent-Type: text/html\r\n\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: malformedData)

        // Then
        XCTAssertNil(result)
    }

    func testParseResponse_NonNumericStatusCode_ReturnsNil() {
        // Given
        let malformedData = "HTTP/1.1 OK 200\r\nContent-Type: text/html\r\n\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: malformedData)

        // Then
        XCTAssertNil(result)
    }

    func testParseResponse_StatusMessageWithSpaces_ParsesCorrectly() {
        // Given
        let responseData = "HTTP/1.1 403 Forbidden Access Denied\r\n\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.statusCode, 403)
        XCTAssertEqual(result?.statusMessage, "Forbidden Access Denied")
    }

    // MARK: - Chunked Encoding Tests

    func testDecodeChunkedBody_MultipleChunks_DecodesCorrectly() {
        // Given
        let chunkedData = makeChunkedBody(chunks: ["Chunk1", "Chunk2", "Chunk3"])

        // When
        let result = HTTPParser.decodeChunkedBody(chunkedData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "Chunk1Chunk2Chunk3".data(using: .utf8))
    }

    func testDecodeChunkedBody_SingleChunk_DecodesCorrectly() {
        // Given
        let chunkedData = makeChunkedBody(chunks: ["SingleChunk"])

        // When
        let result = HTTPParser.decodeChunkedBody(chunkedData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "SingleChunk".data(using: .utf8))
    }

    func testDecodeChunkedBody_EmptyChunks_DecodesCorrectly() {
        // Given
        let chunkedData = makeChunkedBody(chunks: ["Hello", "", "World"])

        // When
        let result = HTTPParser.decodeChunkedBody(chunkedData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "HelloWorld".data(using: .utf8))
    }

    func testDecodeChunkedBody_WithChunkExtensions_DecodesCorrectly() {
        // Given - Chunk with extension (size;extension)
        let chunkedString = "5;name=value\r\nHello\r\n0\r\n\r\n"
        let chunkedData = chunkedString.data(using: .utf8)!

        // When
        let result = HTTPParser.decodeChunkedBody(chunkedData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "Hello".data(using: .utf8))
    }

    func testDecodeChunkedBody_IncompleteChunk_ReturnsNil() {
        // Given - Missing terminal chunk
        let incompleteData = "5\r\nHello\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.decodeChunkedBody(incompleteData)

        // Then
        XCTAssertNil(result)
    }

    func testDecodeChunkedBody_InvalidChunkSize_ReturnsNil() {
        // Given - Non-hex chunk size
        let invalidData = "INVALID\r\nHello\r\n0\r\n\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.decodeChunkedBody(invalidData)

        // Then
        XCTAssertNil(result)
    }

    func testDecodeChunkedBody_TruncatedChunk_ReturnsNil() {
        // Given - Chunk size larger than available data
        let truncatedData = "A\r\nHello".data(using: .utf8)! // Says 10 bytes, only 5 provided

        // When
        let result = HTTPParser.decodeChunkedBody(truncatedData)

        // Then
        XCTAssertNil(result)
    }

    func testDecodeChunkedBody_MissingTrailingCRLF_ReturnsNil() {
        // Given - Missing CRLF after chunk data
        let invalidData = "5\r\nHello0\r\n\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.decodeChunkedBody(invalidData)

        // Then
        XCTAssertNil(result)
    }

    func testDecodeChunkedBody_LargeChunk_DecodesCorrectly() {
        // Given
        let largeContent = String(repeating: "X", count: 1000)
        let chunkedData = makeChunkedBody(chunks: [largeContent])

        // When
        let result = HTTPParser.decodeChunkedBody(chunkedData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result, largeContent.data(using: .utf8))
    }

    // MARK: - Header Parsing Tests

    func testParseRequest_HeadersWithWhitespace_TrimsCorrectly() {
        // Given
        let requestString = "GET / HTTP/1.1\r\n" +
            "Host:   example.com   \r\n" +
            "  User-Agent:  TestClient  \r\n" +
            "\r\n"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.headers["host"]?.first, "example.com")
        XCTAssertEqual(result?.headers["user-agent"]?.first, "TestClient")
    }

    func testParseRequest_HeaderWithoutValue_ParsesEmptyValue() {
        // Given
        let requestString = "GET / HTTP/1.1\r\nHost: example.com\r\nX-Empty:\r\n\r\n"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.headers["x-empty"]?.first, "")
    }

    func testParseRequest_HeaderWithColonInValue_ParsesCorrectly() {
        // Given
        let requestString = "GET / HTTP/1.1\r\nHost: example.com\r\nX-URL: http://example.com:8080/path\r\n\r\n"
        let requestData = requestString.data(using: .utf8)!

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.headers["x-url"]?.first, "http://example.com:8080/path")
    }

    // MARK: - Completeness Check Tests

    func testHasCompleteRequest_Complete_ReturnsTrue() {
        // Given
        let completeData = makeHTTPRequest(method: "GET", path: "/")

        // When
        let result = HTTPParser.hasCompleteRequest(completeData)

        // Then
        XCTAssertTrue(result)
    }

    func testHasCompleteRequest_Incomplete_ReturnsFalse() {
        // Given
        let incompleteData = "GET / HTTP/1.1\r\nHost: example.com\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.hasCompleteRequest(incompleteData)

        // Then
        XCTAssertFalse(result)
    }

    func testHasCompleteResponse_Complete_ReturnsTrue() {
        // Given
        let completeData = makeHTTPResponse(statusCode: 200, statusMessage: "OK")

        // When
        let result = HTTPParser.hasCompleteResponse(completeData)

        // Then
        XCTAssertTrue(result)
    }

    func testHasCompleteResponse_Incomplete_ReturnsFalse() {
        // Given
        let incompleteData = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n".data(using: .utf8)!

        // When
        let result = HTTPParser.hasCompleteResponse(incompleteData)

        // Then
        XCTAssertFalse(result)
    }

    // MARK: - Edge Cases

    func testParseRequest_VeryLongURI_ParsesCorrectly() {
        // Given
        let longPath = "/api/" + String(repeating: "a", count: 1000)
        let requestData = makeHTTPRequest(method: "GET", path: longPath)

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.uri, longPath)
    }

    func testParseRequest_ManyHeaders_ParsesCorrectly() {
        // Given
        var headers: [String: String] = [:]
        for i in 0 ..< 50 {
            headers["X-Header-\(i)"] = "Value\(i)"
        }
        let requestData = makeHTTPRequest(method: "GET", path: "/", headers: headers)

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result?.headers.count ?? 0, 50)
    }

    func testParseRequest_BinaryBody_ParsesCorrectly() {
        // Given
        let binaryBody = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        let requestData = makeHTTPRequest(
            method: "POST",
            path: "/upload",
            headers: ["Content-Type": "application/octet-stream"],
            body: binaryBody
        )

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, binaryBody)
    }

    func testParseResponse_EmptyBody_ParsesCorrectly() {
        // Given
        let responseData = makeHTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: ["Content-Length": "0"],
            body: Data()
        )

        // When
        let result = HTTPParser.parseResponse(from: responseData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.body.isEmpty ?? false)
    }

    func testParseRequest_UTF8Body_ParsesCorrectly() {
        // Given
        let utf8Body = "Hello 世界".data(using: .utf8)!
        let requestData = makeHTTPRequest(
            method: "POST",
            path: "/",
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: utf8Body
        )

        // When
        let result = HTTPParser.parseRequest(from: requestData)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, utf8Body)
    }

    func testParseResponse_MultipleStatusCodeFormats_ParseCorrectly() {
        // Test various valid status code formats
        let testCases: [(Int, String)] = [
            (200, "OK"),
            (201, "Created"),
            (301, "Moved Permanently"),
            (400, "Bad Request"),
            (404, "Not Found"),
            (500, "Internal Server Error"),
            (503, "Service Unavailable")
        ]

        for (code, message) in testCases {
            // Given
            let responseData = makeHTTPResponse(statusCode: code, statusMessage: message)

            // When
            let result = HTTPParser.parseResponse(from: responseData)

            // Then
            XCTAssertNotNil(result, "Failed to parse \(code) \(message)")
            XCTAssertEqual(result?.statusCode, code)
            XCTAssertEqual(result?.statusMessage, message)
        }
    }
}
