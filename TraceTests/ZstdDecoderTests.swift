//
//  ZstdDecoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import Trace
@testable import TraceCompression

final class ZstdDecoderTests: XCTestCase {
    // MARK: - Basic Tests

    func testZstdDecoder_EmptyData_ReturnsEmpty() throws {
        let emptyData = Data()
        let result = try ZstdDecoder.decompress(emptyData)
        XCTAssertTrue(result.isEmpty)
    }

    func testZstdDecoder_InvalidData_ThrowsError() {
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])

        do {
            _ = try ZstdDecoder.decompress(invalidData)
            XCTFail("Expected error to be thrown")
        } catch let error as CompressionError {
            if case .invalidFormat = error {
                // Expected error
            } else {
                XCTFail("Expected invalidFormat error")
            }
        } catch {
            XCTFail("Expected CompressionError, got \(error)")
        }
    }

    func testZstdDecoder_TruncatedData_ThrowsError() throws {
        try requireZstdSupport()
        let original = String(repeating: "truncated stream", count: 200).data(using: .utf8)!
        let compressed = try compressZstd(original)
        let truncated = compressed.dropLast(max(1, compressed.count / 10))

        XCTAssertThrowsError(try ZstdDecoder.decompress(Data(truncated))) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testZstdDecoder_CorruptedData_ThrowsError() throws {
        try requireZstdSupport()
        let original = String(repeating: "corrupted stream", count: 200).data(using: .utf8)!
        var compressed = try compressZstd(original)
        compressed[compressed.startIndex + 8] ^= 0xFF

        XCTAssertThrowsError(try ZstdDecoder.decompress(compressed)) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testZstdDecoder_SimpleString_Decompresses() throws {
        try requireZstdSupport()
        let original = "Hello, World!"
        let originalData = original.data(using: .utf8)!

        let compressed = try compressZstd(originalData)

        let decompressed = try ZstdDecoder.decompress(compressed)
        let result = String(data: decompressed, encoding: .utf8)

        XCTAssertEqual(result, original)
    }

    func testZstdDecoder_LargeString_Decompresses() throws {
        try requireZstdSupport()
        let original = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 1000)
        let originalData = original.data(using: .utf8)!

        let compressed = try compressZstd(originalData)

        let decompressed = try ZstdDecoder.decompress(compressed)
        let result = String(data: decompressed, encoding: .utf8)

        XCTAssertEqual(result, original)
        XCTAssertLessThan(compressed.count, originalData.count)
    }

    func testZstdDecoder_BinaryData_Decompresses() throws {
        try requireZstdSupport()
        let original = Data((0..<1000).map { UInt8($0 % 256) })

        let compressed = try compressZstd(original)

        let decompressed = try ZstdDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, original)
    }

    func testZstdDecoder_RepeatingPattern_CompressesWell() throws {
        try requireZstdSupport()
        let original = Data(repeating: 0x42, count: 10000)

        let compressed = try compressZstd(original)

        let decompressed = try ZstdDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, original)
        // Repeating data should compress very well
        XCTAssertLessThan(compressed.count, original.count / 10)
    }

    // MARK: - Magic Number Detection

    func testZstdDecoder_CanDecode_ValidMagicNumber_ReturnsTrue() throws {
        try requireZstdSupport()
        // Create zstd-compressed data
        let original = "test".data(using: .utf8)!
        let compressed = try compressZstd(original)

        XCTAssertTrue(ZstdDecoder.canDecode(compressed))
    }

    func testZstdDecoder_CanDecode_InvalidMagicNumber_ReturnsFalse() {
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertFalse(ZstdDecoder.canDecode(invalidData))
    }

    func testZstdDecoder_CanDecode_TooShort_ReturnsFalse() {
        let shortData = Data([0x28, 0xB5])
        XCTAssertFalse(ZstdDecoder.canDecode(shortData))
    }

    func testZstdDecoder_CanDecode_EmptyData_ReturnsFalse() {
        let emptyData = Data()
        XCTAssertFalse(ZstdDecoder.canDecode(emptyData))
    }

    // MARK: - Compression Ratio Tests

    func testZstdDecoder_CompressionRatio_RepeatingData() throws {
        try requireZstdSupport()
        let original = Data(repeating: 0xAA, count: 1000)
        let compressed = try compressZstd(original)

        let ratio = ZstdDecoder.compressionRatio(compressed: compressed, decompressed: original)

        // Repeating data should have excellent compression
        XCTAssertLessThan(ratio, 0.1) // Less than 10% of original size
    }

    func testZstdDecoder_CompressionRatio_TextData() throws {
        try requireZstdSupport()
        let original = "The quick brown fox jumps over the lazy dog. ".data(using: .utf8)!
        let compressed = try compressZstd(original)

        let ratio = ZstdDecoder.compressionRatio(compressed: compressed, decompressed: original)

        // Text should compress reasonably
        XCTAssertLessThan(ratio, 1.0)
    }

    func testZstdDecoder_CompressionRatio_EmptyDecompressed_ReturnsOne() {
        let compressed = Data([1, 2, 3])
        let decompressed = Data()

        let ratio = ZstdDecoder.compressionRatio(compressed: compressed, decompressed: decompressed)

        XCTAssertEqual(ratio, 1.0)
    }

    // MARK: - Edge Cases

    func testZstdDecoder_SingleByte_Decompresses() throws {
        try requireZstdSupport()
        let original = Data([0x42])

        let compressed = try compressZstd(original)

        let decompressed = try ZstdDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, original)
    }

    func testZstdDecoder_AllZeros_Decompresses() throws {
        try requireZstdSupport()
        let original = Data(repeating: 0, count: 1000)

        let compressed = try compressZstd(original)

        let decompressed = try ZstdDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, original)
    }

    func testZstdDecoder_AllOnes_Decompresses() throws {
        try requireZstdSupport()
        let original = Data(repeating: 0xFF, count: 1000)

        let compressed = try compressZstd(original)

        let decompressed = try ZstdDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, original)
    }

    func testZstdDecoder_RandomData_Decompresses() throws {
        try requireZstdSupport()
        var original = Data(count: 1000)
        for i in 0..<1000 {
            original[i] = UInt8.random(in: 0...255)
        }

        let compressed = try compressZstd(original)

        let decompressed = try ZstdDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, original)
    }

    // MARK: - Real-World Data

    func testZstdDecoder_JSONData_Decompresses() throws {
        try requireZstdSupport()
        let json = """
        {
            "name": "John Doe",
            "age": 30,
            "email": "john@example.com",
            "address": {
                "street": "123 Main St",
                "city": "Anytown",
                "state": "CA",
                "zip": "12345"
            },
            "hobbies": ["reading", "gaming", "hiking"]
        }
        """
        let original = json.data(using: .utf8)!

        let compressed = try compressZstd(original)

        let decompressed = try ZstdDecoder.decompress(compressed)
        let result = String(data: decompressed, encoding: .utf8)

        XCTAssertEqual(result, json)
    }

    func testZstdDecoder_HTMLData_Decompresses() throws {
        try requireZstdSupport()
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Test Page</title>
        </head>
        <body>
            <h1>Hello, World!</h1>
            <p>This is a test page.</p>
        </body>
        </html>
        """
        let original = html.data(using: .utf8)!

        let compressed = try compressZstd(original)

        let decompressed = try ZstdDecoder.decompress(compressed)
        let result = String(data: decompressed, encoding: .utf8)

        XCTAssertEqual(result, html)
    }

    // MARK: - Performance Tests

    func testZstdDecoder_Performance_SmallData() throws {
        try requireZstdSupport()
        let original = "Hello, World!".data(using: .utf8)!
        let compressed = try compressZstd(original)

        measure {
            for _ in 0..<1000 {
                _ = try? ZstdDecoder.decompress(compressed)
            }
        }
    }

    func testZstdDecoder_Performance_LargeData() throws {
        try requireZstdSupport()
        let original = Data(repeating: 0x42, count: 100000)
        let compressed = try compressZstd(original)

        measure {
            for _ in 0..<100 {
                _ = try? ZstdDecoder.decompress(compressed)
            }
        }
    }

    // MARK: - Integration Tests

    func testZstdDecoder_MultipleDecompressions_ProduceSameResult() throws {
        try requireZstdSupport()
        let original = "Test data for consistency".data(using: .utf8)!
        let compressed = try compressZstd(original)

        let result1 = try ZstdDecoder.decompress(compressed)
        let result2 = try ZstdDecoder.decompress(compressed)
        let result3 = try ZstdDecoder.decompress(compressed)

        XCTAssertEqual(result1, result2)
        XCTAssertEqual(result2, result3)
        XCTAssertEqual(result1, original)
    }
}
