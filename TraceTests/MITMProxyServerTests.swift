//
//  MITMProxyServerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/13.
//

import Foundation
import XCTest
@testable import TraceNetworking
@testable import TraceVPN

final class MITMProxyServerTests: XCTestCase {

    // MARK: - Chunked Transfer Encoding Tests

    func testIsChunkedBodyComplete_SimpleChunk() {
        let chunkedBody = makeChunkedBody(["Hello"])
        let data = makeChunkedRequest(body: chunkedBody)

        XCTAssertNotNil(HTTPParser.parseRequest(from: data))
    }

    func testIsChunkedBodyComplete_MultipleChunks() {
        let chunkedBody = makeChunkedBody(["Hello", " World"])
        let data = makeChunkedRequest(body: chunkedBody)

        XCTAssertNotNil(HTTPParser.parseRequest(from: data))
    }

    func testIsChunkedBodyComplete_Incomplete() {
        var chunkedBody = Data()
        chunkedBody.append("5\r\nHello\r\n".data(using: .ascii)!)

        let data = makeChunkedRequest(body: chunkedBody)

        XCTAssertNil(HTTPParser.parseRequest(from: data))
    }

    func testDecodeChunkedBody_Simple() {
        let chunkedBody = makeChunkedBody(["Hello"])
        let expected = "Hello".data(using: .ascii)!

        XCTAssertEqual(HTTPParser.decodeChunkedBody(chunkedBody), expected)
    }

    func testDecodeChunkedBody_MultipleChunks() {
        let chunkedBody = makeChunkedBody(["Hello", " World"])
        let expected = "Hello World".data(using: .ascii)!

        XCTAssertEqual(HTTPParser.decodeChunkedBody(chunkedBody), expected)
    }

    func testDecodeChunkedBody_WithChunkExtensions() {
        var chunkedBody = Data()
        chunkedBody.append("5;ext=test\r\n".data(using: .ascii)!)
        chunkedBody.append("Hello".data(using: .ascii)!)
        chunkedBody.append("\r\n".data(using: .ascii)!)
        chunkedBody.append("0\r\n\r\n".data(using: .ascii)!)

        let expected = "Hello".data(using: .ascii)!

        XCTAssertEqual(HTTPParser.decodeChunkedBody(chunkedBody), expected)
    }

    func testDecodeChunkedBody_BinaryData() {
        let binaryData = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        var chunkedBody = Data()
        chunkedBody.append("5\r\n".data(using: .ascii)!)
        chunkedBody.append(binaryData)
        chunkedBody.append("\r\n".data(using: .ascii)!)
        chunkedBody.append("0\r\n\r\n".data(using: .ascii)!)

        XCTAssertEqual(HTTPParser.decodeChunkedBody(chunkedBody), binaryData)
    }

    func testDecodeChunkedBody_WithTrailers() {
        var chunkedBody = Data()
        chunkedBody.append("5\r\n".data(using: .ascii)!)
        chunkedBody.append("Hello".data(using: .ascii)!)
        chunkedBody.append("\r\n".data(using: .ascii)!)
        chunkedBody.append("0\r\n".data(using: .ascii)!)
        chunkedBody.append("Expires: Wed, 21 Oct 2015 07:28:00 GMT\r\n".data(using: .ascii)!)
        chunkedBody.append("\r\n".data(using: .ascii)!)

        let expected = "Hello".data(using: .ascii)!

        XCTAssertEqual(HTTPParser.decodeChunkedBody(chunkedBody), expected)
    }

    func testDecodeChunkedBody_EmptyChunks() {
        let chunkedBody = "0\r\n\r\n".data(using: .ascii)!

        XCTAssertEqual(HTTPParser.decodeChunkedBody(chunkedBody), Data())
    }

    func testChunkedBodyEndIndex_IgnoresEmbeddedMarker() {
        let payload = "hello0\r\n\r\nworld"
        let chunkedBody = makeChunkedBody([payload])
        let endIndex = HTTPParser.chunkedBodyEndIndex(chunkedBody)
        XCTAssertEqual(endIndex, chunkedBody.count)
    }

    func testChunkedBodyEndIndex_StopsBeforeExtraData() {
        let chunkedBody = makeChunkedBody(["Hello"])
        let combined = chunkedBody + "EXTRA".data(using: .ascii)!
        let endIndex = HTTPParser.chunkedBodyEndIndex(combined)
        XCTAssertEqual(endIndex, chunkedBody.count)
    }

    func testDecodeChunkedBody_InvalidFormat() {
        let chunkedBody = "XYZ\r\n".data(using: .ascii)!

        XCTAssertNil(HTTPParser.decodeChunkedBody(chunkedBody))
    }

    func testDecodeChunkedBody_LargeChunkSize() {
        let largeData = Data(repeating: 0x41, count: 255)
        var chunkedBody = Data()
        chunkedBody.append("FF\r\n".data(using: .ascii)!)
        chunkedBody.append(largeData)
        chunkedBody.append("\r\n".data(using: .ascii)!)
        chunkedBody.append("0\r\n\r\n".data(using: .ascii)!)

        XCTAssertEqual(HTTPParser.decodeChunkedBody(chunkedBody), largeData)
    }

    // MARK: - Request Header Parsing Tests

    func testParseRequestHeaders_ContentLength() {
        let body = Data(repeating: 0x7A, count: 42)
        let headersString = """
        POST /api/test HTTP/1.1\r
        Host: example.com\r
        Content-Type: application/json\r
        Content-Length: 42\r
        \r
        """
        let data = Data(headersString.utf8) + body

        let request = HTTPParser.parseRequest(from: data)
        XCTAssertEqual(request?.body.count, 42)
        XCTAssertEqual(request?.headers["content-length"]?.first, "42")
    }

    func testParseRequestHeaders_ChunkedTransferEncoding() {
        let chunkedBody = makeChunkedBody(["Hello"])
        let headersString = """
        POST /api/test HTTP/1.1\r
        Host: example.com\r
        Transfer-Encoding: chunked\r
        \r
        """
        let data = Data(headersString.utf8) + chunkedBody

        let request = HTTPParser.parseRequest(from: data)
        XCTAssertEqual(request?.body, "Hello".data(using: .ascii)!)
    }

    func testParseRequestHeaders_BothContentLengthAndChunked() {
        let chunkedBody = makeChunkedBody(["Hello"])
        let headersString = """
        POST /api/test HTTP/1.1\r
        Host: example.com\r
        Content-Length: 42\r
        Transfer-Encoding: chunked\r
        \r
        """
        let data = Data(headersString.utf8) + chunkedBody

        let request = HTTPParser.parseRequest(from: data)
        XCTAssertEqual(request?.body, "Hello".data(using: .ascii)!)
        XCTAssertEqual(request?.headers["transfer-encoding"]?.first, "chunked")
    }

    func testParseRequestHeaders_NoContentLengthOrChunked() {
        let headersString = """
        GET /api/test HTTP/1.1\r
        Host: example.com\r
        \r
        """
        let data = Data(headersString.utf8)

        let request = HTTPParser.parseRequest(from: data)
        XCTAssertEqual(request?.body, Data())
    }

    func testParseRequestHeaders_CaseInsensitive() {
        let headersString = """
        POST /api/test HTTP/1.1\r
        host: example.com\r
        content-length: 3\r
        transfer-encoding: chunked\r
        \r
        """
        let data = Data(headersString.utf8) + makeChunkedBody(["abc"])

        let request = HTTPParser.parseRequest(from: data)
        XCTAssertEqual(request?.body, "abc".data(using: .ascii)!)
        XCTAssertEqual(request?.headers["host"]?.first, "example.com")
    }

    // MARK: - Helpers

    private func makeChunkedBody(_ chunks: [String]) -> Data {
        var data = Data()
        for chunk in chunks {
            let size = String(format: "%X", chunk.utf8.count)
            data.append("\(size)\r\n".data(using: .ascii)!)
            data.append(chunk.data(using: .ascii)!)
            data.append("\r\n".data(using: .ascii)!)
        }
        data.append("0\r\n\r\n".data(using: .ascii)!)
        return data
    }

    private func makeChunkedRequest(body: Data) -> Data {
        let headers = """
        POST /api/test HTTP/1.1\r
        Host: example.com\r
        Transfer-Encoding: chunked\r
        \r
        """
        return Data(headers.utf8) + body
    }
}
