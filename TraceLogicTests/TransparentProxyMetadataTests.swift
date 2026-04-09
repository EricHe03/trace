//
//  TransparentProxyMetadataTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/20.
//

import NIOCore
@testable import TraceCore
import XCTest

final class TransparentProxyMetadataTests: XCTestCase {
    func testEncodeDecodeRoundTrip_DomainHost() {
        guard let bytes = TransparentProxyMetadata.encodeUpstreamHint(
            host: "example.com",
            port: 443,
            addressTypeRaw: 0x03
        ) else {
            XCTFail("Expected encoded metadata bytes")
            return
        }

        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)

        let result = TransparentProxyMetadata.decodeUpstreamHintPrefix(from: buffer)
        guard case let .value(hint, consumedBytes) = result else {
            XCTFail("Expected decode value, got \(result)")
            return
        }

        XCTAssertEqual(consumedBytes, bytes.count)
        XCTAssertEqual(hint.host, "example.com")
        XCTAssertEqual(hint.port, 443)
        XCTAssertEqual(hint.addressTypeRaw, 0x03)
    }

    func testDecodePrefix_ReturnsNeedMoreForPartialMagic() {
        var buffer = ByteBufferAllocator().buffer(capacity: 5)
        buffer.writeBytes(Array("TRACE".utf8))

        let result = TransparentProxyMetadata.decodeUpstreamHintPrefix(from: buffer)
        XCTAssertEqual(result, .needMore)
    }

    func testDecodePrefix_ReturnsAbsentForTLSClientHelloPrefix() {
        var buffer = ByteBufferAllocator().buffer(capacity: 6)
        buffer.writeBytes([0x16, 0x03, 0x01, 0x00, 0x10, 0x01])

        let result = TransparentProxyMetadata.decodeUpstreamHintPrefix(from: buffer)
        XCTAssertEqual(result, .absent)
    }

    func testDecodePrefix_ReturnsInvalidForUnsupportedVersion() {
        guard var bytes = TransparentProxyMetadata.encodeUpstreamHint(
            host: "example.com",
            port: 443,
            addressTypeRaw: 0x03
        ) else {
            XCTFail("Expected encoded metadata bytes")
            return
        }
        bytes[8] = 0x02 // unsupported version

        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)

        let result = TransparentProxyMetadata.decodeUpstreamHintPrefix(from: buffer)
        guard case let .invalid(reason) = result else {
            XCTFail("Expected invalid decode result, got \(result)")
            return
        }
        XCTAssertEqual(reason, "unsupported_version_2")
    }

    func testEncodeDecodeRoundTripV2_WithFlowIDAndPolicyMode() {
        guard let bytes = TransparentProxyMetadata.encodeUpstreamHintV2(
            host: "api.example.com",
            port: 443,
            addressTypeRaw: 0x03,
            flowID: 42,
            policyModeRaw: 1
        ) else {
            XCTFail("Expected encoded metadata bytes")
            return
        }

        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)

        let result = TransparentProxyMetadata.decodeUpstreamHintPrefix(from: buffer)
        guard case let .value(hint, consumedBytes) = result else {
            XCTFail("Expected decode value, got \(result)")
            return
        }

        XCTAssertEqual(consumedBytes, bytes.count)
        XCTAssertEqual(hint.version, .v2)
        XCTAssertEqual(hint.host, "api.example.com")
        XCTAssertEqual(hint.port, 443)
        XCTAssertEqual(hint.addressTypeRaw, 0x03)
        XCTAssertEqual(hint.flowID, 42)
        XCTAssertEqual(hint.policyModeRaw, 1)
    }

    func testDecodeV1HintHasNoFlowID() {
        guard let bytes = TransparentProxyMetadata.encodeUpstreamHint(
            host: "example.com",
            port: 443,
            addressTypeRaw: 0x03
        ) else {
            XCTFail("Expected encoded metadata bytes")
            return
        }

        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)

        let result = TransparentProxyMetadata.decodeUpstreamHintPrefix(from: buffer)
        guard case let .value(hint, _) = result else {
            XCTFail("Expected decode value, got \(result)")
            return
        }

        XCTAssertEqual(hint.version, .v1)
        XCTAssertNil(hint.flowID)
        XCTAssertNil(hint.policyModeRaw)
    }
}
