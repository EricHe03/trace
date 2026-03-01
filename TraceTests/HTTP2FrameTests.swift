//
//  HTTP2FrameTests.swift
//  TraceTests
//
//  Updated for NIO-era HTTP/2 frame metadata models.
//

import XCTest
@testable import TraceCore

final class HTTP2FrameTests: XCTestCase {
    func testHTTP2DataFrameCodableRoundTrip() throws {
        let frame = HTTP2DataFrame(
            frameType: "DATA",
            flags: ["END_STREAM"],
            payloadSize: 128,
            timestamp: Date(),
            rawData: Data([0x01, 0x02, 0x03])
        )

        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(HTTP2DataFrame.self, from: encoded)

        XCTAssertEqual(decoded.frameType, "DATA")
        XCTAssertEqual(decoded.flags, ["END_STREAM"])
        XCTAssertEqual(decoded.payloadSize, 128)
        XCTAssertEqual(decoded.rawData, Data([0x01, 0x02, 0x03]))
    }

    func testHTTP2StreamInfoDurationWhenClosed() throws {
        let start = Date()
        let end = start.addingTimeInterval(0.75)

        let stream = HTTP2StreamInfo(
            streamId: 1,
            headers: [TraceHTTPHeader(key: ":method", value: "GET")],
            dataFrames: [
                HTTP2DataFrame(
                    frameType: "HEADERS",
                    flags: ["END_HEADERS"],
                    payloadSize: 32,
                    timestamp: start,
                    rawData: nil
                )
            ],
            state: .closed,
            priority: nil,
            windowSize: 65535,
            totalDataSize: 32,
            startTime: start,
            endTime: end
        )

        XCTAssertEqual(stream.streamId, 1)
        XCTAssertEqual(stream.state, .closed)
        XCTAssertEqual(try XCTUnwrap(stream.duration), 0.75, accuracy: 0.0001)
    }

    func testHTTP2StreamInfoHasNilDurationWhenActive() {
        let stream = HTTP2StreamInfo(
            streamId: 3,
            headers: [],
            dataFrames: [],
            state: .open,
            priority: nil,
            windowSize: 65535,
            totalDataSize: 0,
            startTime: Date(),
            endTime: nil
        )

        XCTAssertNil(stream.duration)
    }
}
