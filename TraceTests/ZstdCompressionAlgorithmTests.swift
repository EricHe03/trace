//
//  ZstdCompressionAlgorithmTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
import libzstd
@testable import TraceCompression

final class ZstdCompressionAlgorithmTests: XCTestCase {
    func testZstdSupportFlagIsEnabled() {
        XCTAssertTrue(ZstdDecoder.isSupported)
    }

    func testZstdCompressBoundIsGreaterThanInputSize() {
        let size = 1024
        let bound = Int(ZSTD_compressBound(size))
        XCTAssertGreaterThan(bound, size)
    }

    func testZstdRoundTripWithLibraryCompression() throws {
        try requireZstdSupport()

        let original = String(repeating: "zstd round trip ", count: 200).data(using: .utf8)!
        let compressed = try compressZstd(original)
        let decompressed = try ZstdDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, original)
    }

    func testZstdCanDecodeRecognizesLibraryOutput() throws {
        try requireZstdSupport()

        let original = "magic number".data(using: .utf8)!
        let compressed = try compressZstd(original)

        XCTAssertTrue(ZstdDecoder.canDecode(compressed))
    }

    func testZstdCorruptedLibraryOutputIsError() throws {
        try requireZstdSupport()

        let original = String(repeating: "zstd corruption ", count: 200).data(using: .utf8)!
        var compressed = try compressZstd(original)
        compressed[compressed.startIndex + 8] ^= 0xAA

        XCTAssertThrowsError(try ZstdDecoder.decompress(compressed))
    }
}
