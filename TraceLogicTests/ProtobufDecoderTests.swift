//
//  ProtobufDecoderTests.swift
//  TraceTests
//
//  Created by Codex on 2026/04/11.
//

@testable import TraceCore
import XCTest

final class ProtobufDecoderTests: XCTestCase {
    func testDecodeReturnsPartialFieldsForTruncatedFixed64Field() {
        let data = Data([
            0x08, 0x96, 0x01, // field 1, varint(150)
            0x11, 0xAA, 0xBB, 0xCC // field 2, fixed64 but truncated
        ])

        let fields = ProtobufDecoder.decode(data)

        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.fieldNumber, 1)
        XCTAssertEqual(fields.first?.wireType, 0)
        guard case let .varint(value)? = fields.first?.value else {
            return XCTFail("Expected first field to decode as varint")
        }
        XCTAssertEqual(value, 150)
    }

    func testDecodeGRPCMessagesDecodesGRPCWebTextFrames() {
        let payload = Data([0x08, 0x96, 0x01]) // field 1, varint(150)
        let framed = makeGRPCFrame(flag: 0x00, payload: payload)
        let body = Data(framed.base64EncodedString().utf8)

        let messages = ProtobufDecoder.decodeGRPCMessages(
            from: body,
            contentType: "application/grpc-web-text+proto"
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.count, 1)
        XCTAssertEqual(messages.first?.first?.fieldNumber, 1)
        guard case let .varint(value)? = messages.first?.first?.value else {
            return XCTFail("Expected decoded gRPC-Web text payload to contain a varint field")
        }
        XCTAssertEqual(value, 150)
    }

    private func makeGRPCFrame(flag: UInt8, payload: Data) -> Data {
        var frame = Data([flag, 0, 0, 0, UInt8(payload.count)])
        frame.append(payload)
        return frame
    }
}
