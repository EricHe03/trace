//
//  CompressionHelperTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

final class CompressionHelperTests: XCTestCase {
    // MARK: - Deflate Compression Tests

    func testDeflateCompress() throws {
        let input = "Hello, World!".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: "deflate")

        XCTAssertNotNil(compressed)
        XCTAssertGreaterThan(try XCTUnwrap(compressed?.count), 0)
        XCTAssertNotEqual(compressed, input)
    }

    func testDeflateDecompress() throws {
        let input = "Hello, World! This is a test string for compression.".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: "deflate")
        XCTAssertNotNil(compressed)

        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "deflate")
        XCTAssertNotNil(decompressed)
        XCTAssertEqual(decompressed, input)
    }

    func testDeflateRoundTrip() throws {
        let testStrings = [
            "Short",
            "Medium length string for testing",
            String(repeating: "Long string with repeated content. ", count: 100)
        ]

        for testString in testStrings {
            let input = try XCTUnwrap(testString.data(using: .utf8))

            let compressed = CompressionHelper.compress(data: input, algorithm: "deflate")
            XCTAssertNotNil(compressed, "Failed to compress: \(testString.prefix(20))")

            let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "deflate")
            XCTAssertNotNil(decompressed, "Failed to decompress: \(testString.prefix(20))")
            XCTAssertEqual(decompressed, input, "Round-trip failed for: \(testString.prefix(20))")
        }
    }

    // MARK: - Zlib Tests

    func testZlibCompress() throws {
        let input = "Test data for zlib compression".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: "zlib")

        XCTAssertNotNil(compressed)
        XCTAssertGreaterThan(try XCTUnwrap(compressed?.count), 0)
    }

    func testZlibDecompress() throws {
        let input = "Test data for zlib decompression".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: "zlib")
        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "zlib")

        XCTAssertEqual(decompressed, input)
    }

    // MARK: - Gzip Tests

    func testGzipCompress() throws {
        let input = "Hello, World!".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: "gzip")

        XCTAssertNotNil(compressed)
        XCTAssertGreaterThan(try XCTUnwrap(compressed?.count), 10) // Should have gzip header/footer

        // Verify gzip magic bytes
        XCTAssertEqual(compressed?[0], 0x1F)
        XCTAssertEqual(compressed?[1], 0x8B)
    }

    func testGzipDecompress() throws {
        let input = "Hello, World! Testing gzip compression.".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: "gzip")
        XCTAssertNotNil(compressed)

        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "gzip")
        XCTAssertNotNil(decompressed)
        XCTAssertEqual(decompressed, input)
    }

    func testGzipRoundTrip() throws {
        let input = "This is a test string for gzip round-trip compression.".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: "gzip")
        XCTAssertNotNil(compressed)

        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "gzip")
        XCTAssertNotNil(decompressed)
        XCTAssertEqual(decompressed, input)
    }

    // MARK: - Empty Data Tests

    func testCompressEmptyData() {
        let empty = Data()

        let compressed = CompressionHelper.compress(data: empty, algorithm: "deflate")

        XCTAssertNotNil(compressed)
        XCTAssertEqual(compressed, empty)
    }

    func testDecompressEmptyData() {
        let empty = Data()

        let decompressed = CompressionHelper.decompress(data: empty, algorithm: "deflate")

        XCTAssertNotNil(decompressed)
        XCTAssertEqual(decompressed, empty)
    }

    // MARK: - Large Data Tests

    func testCompressLargeData() throws {
        let largeData = Data(repeating: 0x42, count: 100_000)

        let compressed = CompressionHelper.compress(data: largeData, algorithm: "deflate")

        XCTAssertNotNil(compressed)
        XCTAssertLessThan(try XCTUnwrap(compressed?.count), largeData.count) // Should compress well
    }

    func testLargeDataRoundTrip() throws {
        let largeData = Data(repeating: 0x42, count: 50000)

        let compressed = CompressionHelper.compress(data: largeData, algorithm: "deflate")
        XCTAssertNotNil(compressed)

        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "deflate")
        XCTAssertEqual(decompressed, largeData)
    }

    // MARK: - Binary Data Tests

    func testBinaryDataCompression() throws {
        var binaryData = Data()
        for i in 0 ..< 1000 {
            binaryData.append(UInt8(i % 256))
        }

        let compressed = CompressionHelper.compress(data: binaryData, algorithm: "deflate")
        XCTAssertNotNil(compressed)

        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "deflate")
        XCTAssertEqual(decompressed, binaryData)
    }

    // MARK: - Algorithm Name Tests

    func testCaseInsensitiveAlgorithmNames() {
        let input = "Test".data(using: .utf8)!

        let deflate1 = CompressionHelper.compress(data: input, algorithm: "DEFLATE")
        let deflate2 = CompressionHelper.compress(data: input, algorithm: "deflate")
        let deflate3 = CompressionHelper.compress(data: input, algorithm: "Deflate")

        XCTAssertNotNil(deflate1)
        XCTAssertNotNil(deflate2)
        XCTAssertNotNil(deflate3)
    }

    func testDefaultAlgorithm() throws {
        let input = "Test".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: nil)

        XCTAssertNotNil(compressed)

        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: nil)
        XCTAssertEqual(decompressed, input)
    }

    // MARK: - Unsupported Algorithm Tests

    func testUnsupportedAlgorithm() {
        let input = "Test".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: input, algorithm: "unsupported")

        XCTAssertNil(compressed)
    }

    // MARK: - Brotli Tests

    // MARK: - Invalid Data Tests

    func testDecompressInvalidData() {
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        let decompressed = CompressionHelper.decompress(data: invalidData, algorithm: "deflate")

        // Should handle gracefully (return nil or empty)
        XCTAssertTrue(decompressed == nil || decompressed!.isEmpty)
    }

    func testDecompressGarbageData() {
        let garbage = Data((0 ..< 100).map { _ in UInt8.random(in: 0 ... 255) })

        let decompressed = CompressionHelper.decompress(data: garbage, algorithm: "deflate")

        // Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Compression Ratio Tests

    func testCompressionRatioForRepetitiveData() throws {
        let repetitiveData = Data(repeating: 0x41, count: 10000)

        let compressed = CompressionHelper.compress(data: repetitiveData, algorithm: "deflate")

        XCTAssertNotNil(compressed)
        XCTAssertLessThan(try XCTUnwrap(compressed?.count), repetitiveData.count / 10) // Should compress very well
    }

    func testCompressionRatioForRandomData() throws {
        var randomData = Data()
        for _ in 0 ..< 1000 {
            randomData.append(UInt8.random(in: 0 ... 255))
        }

        let compressed = CompressionHelper.compress(data: randomData, algorithm: "deflate")

        XCTAssertNotNil(compressed)
        // Random data doesn't compress well, might even be larger
        XCTAssertGreaterThan(try XCTUnwrap(compressed?.count), 0)
    }

    // MARK: - Unicode and Special Characters Tests

    func testUnicodeStringCompression() throws {
        let unicode = "Hello 世界 🌍 مرحبا".data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: unicode, algorithm: "deflate")
        XCTAssertNotNil(compressed)

        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "deflate")
        XCTAssertEqual(decompressed, unicode)

        let reconstructed = try String(data: XCTUnwrap(decompressed), encoding: .utf8)
        XCTAssertEqual(reconstructed, "Hello 世界 🌍 مرحبا")
    }

    // MARK: - JSON Data Tests

    func testJSONCompression() throws {
        let json = """
        {
            "name": "Test",
            "value": 123,
            "array": [1, 2, 3, 4, 5],
            "nested": {
                "key": "value"
            }
        }
        """.data(using: .utf8)!

        let compressed = CompressionHelper.compress(data: json, algorithm: "gzip")
        XCTAssertNotNil(compressed)

        let decompressed = try CompressionHelper.decompress(data: XCTUnwrap(compressed), algorithm: "gzip")
        XCTAssertEqual(decompressed, json)
    }
}
