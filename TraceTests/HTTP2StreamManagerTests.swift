//
//  HTTP2StreamManagerTests.swift
//  TraceTests
//
//  Updated for NIO HTTP/2 pipeline primitives used by NIOMITM.
//

import XCTest
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2
@testable import TraceCore

final class HTTP2StreamManagerTests: XCTestCase {
    func testHTTP2FramePayloadToHTTP1ServerCodecCanBeAddedToPipeline() throws {
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }

        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
        )
    }

    func testHTTP2StreamInfoPriorityStoresValues() {
        let priority = HTTP2StreamInfo.StreamPriority(exclusive: true, dependsOn: 1, weight: 32)

        XCTAssertTrue(priority.exclusive)
        XCTAssertEqual(priority.dependsOn, 1)
        XCTAssertEqual(priority.weight, 32)
    }

    func testHTTP2StreamInfoDecodingInitializesIdentifier() throws {
        let json = """
        {
          "streamId": 9,
          "headers": [{"key":":path","value":"/"}],
          "dataFrames": [],
          "state": "open",
          "priority": null,
          "windowSize": 65535,
          "totalDataSize": 0,
          "startTime": "2026-01-01T00:00:00Z",
          "endTime": null
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HTTP2StreamInfo.self, from: json)

        XCTAssertEqual(decoded.streamId, 9)
        XCTAssertEqual(decoded.state, .open)
        XCTAssertNotEqual(decoded.id, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }
}
