//
//  HTTPParserTests.swift
//  TraceTests
//
//  Updated for NIO HTTP codec migration.
//

import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

final class HTTPParserTests: XCTestCase {
    func testHTTPRequestDecoderParsesSimpleGet() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)))
        defer { XCTAssertNoThrow(try channel.finish()) }

        var input = channel.allocator.buffer(capacity: 0)
        input.writeString("GET /api/users HTTP/1.1\r\nHost: example.com\r\nAccept: application/json\r\n\r\n")

        XCTAssertNoThrow(try channel.writeInbound(input))

        guard case let .head(head)? = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            return XCTFail("Expected request head")
        }
        XCTAssertEqual(head.method, .GET)
        XCTAssertEqual(head.uri, "/api/users")
        XCTAssertEqual(head.headers.first(name: "host"), "example.com")
        XCTAssertEqual(head.headers.first(name: "accept"), "application/json")

        guard case .end? = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            return XCTFail("Expected request end")
        }
        XCTAssertNil(try channel.readInbound(as: HTTPServerRequestPart.self))
    }

    func testHTTPRequestDecoderParsesChunkedBody() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)))
        defer { XCTAssertNoThrow(try channel.finish()) }

        var input = channel.allocator.buffer(capacity: 0)
        input.writeString(
            "POST /upload HTTP/1.1\r\n" +
                "Host: example.com\r\n" +
                "Transfer-Encoding: chunked\r\n\r\n" +
                "5\r\nHello\r\n" +
                "6\r\n World\r\n" +
                "0\r\n\r\n"
        )

        XCTAssertNoThrow(try channel.writeInbound(input))

        guard case .head? = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            return XCTFail("Expected request head")
        }

        var body = ByteBuffer()
        while let part = try channel.readInbound(as: HTTPServerRequestPart.self) {
            switch part {
            case let .body(buffer):
                var mutable = buffer
                body.writeBuffer(&mutable)
            case .end:
                let bytes = body.readableBytesView
                XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "Hello World")
                return
            case .head:
                XCTFail("Unexpected additional head")
            }
        }

        XCTFail("Expected end part")
    }

    func testHTTPResponseDecoderParsesStatusHeadersAndBody() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)))
        defer { XCTAssertNoThrow(try channel.finish()) }

        let requestHead = HTTPClientRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/"))
        XCTAssertNoThrow(try channel.writeOutbound(requestHead))

        var input = channel.allocator.buffer(capacity: 0)
        input.writeString(
            "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: 13\r\n\r\n" +
                "{\"ok\":\"yes\"}\n"
        )

        XCTAssertNoThrow(try channel.writeInbound(input))

        guard case let .head(head)? = try channel.readInbound(as: HTTPClientResponsePart.self) else {
            return XCTFail("Expected response head")
        }
        XCTAssertEqual(head.status, .ok)
        XCTAssertEqual(head.headers.first(name: "content-type"), "application/json")

        guard case let .body(buffer)? = try channel.readInbound(as: HTTPClientResponsePart.self) else {
            return XCTFail("Expected response body")
        }
        XCTAssertEqual(buffer.readableBytes, 13)

        guard case .end? = try channel.readInbound(as: HTTPClientResponsePart.self) else {
            return XCTFail("Expected response end")
        }
        XCTAssertNil(try channel.readInbound(as: HTTPClientResponsePart.self))
    }

    func testHTTPRequestDecoderBuffersIncompleteHead() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)))
        defer { XCTAssertNoThrow(try channel.finish()) }

        var partial = channel.allocator.buffer(capacity: 0)
        partial.writeString("GET /partial HTTP/1.1\r\nHost: example.com\r\n")
        XCTAssertNoThrow(try channel.writeInbound(partial))

        XCTAssertNil(try channel.readInbound(as: HTTPServerRequestPart.self))

        var tail = channel.allocator.buffer(capacity: 0)
        tail.writeString("\r\n")
        XCTAssertNoThrow(try channel.writeInbound(tail))

        guard case .head? = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            return XCTFail("Expected completed request head")
        }
        guard case .end? = try channel.readInbound(as: HTTPServerRequestPart.self) else {
            return XCTFail("Expected completed request end")
        }
    }
}
