//
//  BrotliDecoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import Compression
@testable import TraceCompression
import XCTest

final class BrotliDecoderTests: XCTestCase {
    // MARK: - Round-Trip Tests

    func testBrotliRoundTrip() throws {
        let testStrings = [
            "Short",
            "Medium length string for testing",
            String(repeating: "Long string with repeated content. ", count: 100)
        ]

        for testString in testStrings {
            let input = try XCTUnwrap(testString.data(using: .utf8))

            let compressed = try compressBrotli(input)
            XCTAssertNotNil(compressed, "Failed to compress: \(testString.prefix(20))")
            XCTAssertGreaterThan(compressed.count, 0)

            let decompressed = try BrotliDecoder.decompress(compressed)
            XCTAssertEqual(decompressed, input, "Round-trip failed for: \(testString.prefix(20))")
        }
    }

    func testBrotliDecompressValidData() throws {
        let input = "Hello, World! This is a test string for Brotli compression.".data(using: .utf8)!
        let compressed = try compressBrotli(input)

        let decompressed = try BrotliDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, input)
    }

    // MARK: - Various Data Sizes

    func testBrotliSmallData() throws {
        let small = "Hi".data(using: .utf8)!

        let compressed = try compressBrotli(small)
        let decompressed = try BrotliDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, small)
    }

    func testBrotliMediumData() throws {
        let medium = try XCTUnwrap(String(repeating: "Medium test data. ", count: 50).data(using: .utf8))

        let compressed = try compressBrotli(medium)
        let decompressed = try BrotliDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, medium)
    }

    func testBrotliLargeData() throws {
        let largeString = String(repeating: "Lorem ipsum dolor sit amet. ", count: 3000)
        let large = try XCTUnwrap(largeString.data(using: .utf8))

        let compressed = try compressBrotli(large)
        let decompressed = try BrotliDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, large)
        XCTAssertGreaterThan(decompressed.count, 64 * 1024)
    }

    func testBrotliVeryLargeData() throws {
        let veryLarge = Data(repeating: 0x42, count: 100_000)

        let compressed = try compressBrotli(veryLarge)
        let decompressed = try BrotliDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, veryLarge)
        XCTAssertLessThan(compressed.count, veryLarge.count)
    }

    // MARK: - Empty Data Tests

    func testBrotliDecompressEmptyData() throws {
        let empty = Data()

        let result = try BrotliDecoder.decompress(empty)

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Invalid Data Tests

    func testBrotliDecompressInvalidData() {
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        XCTAssertThrowsError(try BrotliDecoder.decompress(invalidData)) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testBrotliDecompressGarbageData() {
        let garbage = Data((0 ..< 100).map { _ in UInt8.random(in: 0 ... 255) })

        XCTAssertThrowsError(try BrotliDecoder.decompress(garbage))
    }

    func testBrotliDecompressCorruptedData() throws {
        let original = "Test data".data(using: .utf8)!
        var compressed = try compressBrotli(original)

        if compressed.count > 10 {
            compressed[5] = compressed[5] ^ 0xFF
        }

        do {
            let decompressed = try BrotliDecoder.decompress(compressed)
            XCTAssertNotEqual(decompressed, original)
        } catch {
            // Brotli should reject corrupt input when possible; accept throwing as well.
        }
    }

    // MARK: - Binary Data Tests

    func testBrotliBinaryData() throws {
        var binaryData = Data()
        for i in 0 ..< 1000 {
            binaryData.append(UInt8(i % 256))
        }

        let compressed = try compressBrotli(binaryData)
        let decompressed = try BrotliDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, binaryData)
    }

    // MARK: - Compression Ratio Tests

    func testBrotliCompressionRatioRepetitiveData() throws {
        let repetitiveData = Data(repeating: 0x41, count: 10000)

        let compressed = try compressBrotli(repetitiveData)

        XCTAssertNotNil(compressed)
        XCTAssertLessThan(compressed.count, repetitiveData.count / 10)
    }

    func testBrotliCompressionRatioRandomData() throws {
        var randomData = Data()
        for _ in 0 ..< 1000 {
            randomData.append(UInt8.random(in: 0 ... 255))
        }

        let compressed = try compressBrotli(randomData)

        XCTAssertGreaterThan(compressed.count, 0)
    }

    // MARK: - Unicode and Special Characters Tests

    func testBrotliUnicodeString() throws {
        let unicode = "Hello 世界 🌍 مرحبا".data(using: .utf8)!

        let compressed = try compressBrotli(unicode)
        let decompressed = try BrotliDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, unicode)

        let reconstructed = String(data: decompressed, encoding: .utf8)
        XCTAssertEqual(reconstructed, "Hello 世界 🌍 مرحبا")
    }

    // MARK: - JSON Data Tests

    func testBrotliJSONCompression() throws {
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

        let compressed = try compressBrotli(json)
        let decompressed = try BrotliDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, json)
    }

    // MARK: - Can Decode Tests

    func testCanDecodeEmptyData() {
        let emptyData = Data()

        let canDecode = BrotliDecoder.canDecode(emptyData)

        XCTAssertFalse(canDecode)
    }

    func testCanDecodeValidBrotliData() throws {
        let originalData = "Test string".data(using: .utf8)!
        let compressedData = try compressBrotli(originalData)

        let canDecode = BrotliDecoder.canDecode(compressedData)

        XCTAssertTrue(canDecode)
    }

    func testCanDecodeInvalidWindowSize() {
        let invalidData = Data([0xFF])

        let canDecode = BrotliDecoder.canDecode(invalidData)

        XCTAssertFalse(canDecode)
    }

    func testCanDecodeRandomData() {
        let randomData = Data([0x12, 0x34, 0x56, 0x78])

        let canDecode = BrotliDecoder.canDecode(randomData)

        XCTAssertFalse(canDecode)
    }

    // MARK: - Helper Methods

    private func compressBrotli(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = sourcePtr.baseAddress else {
                throw CompressionError.invalidInput("Invalid input buffer")
            }

            let bufferSize = 64 * 1024
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { destinationBuffer.deallocate() }

            var stream = compression_stream(
                dst_ptr: destinationBuffer,
                dst_size: bufferSize,
                src_ptr: baseAddress.assumingMemoryBound(to: UInt8.self),
                src_size: data.count,
                state: nil
            )

            let status = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_BROTLI)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw CompressionError.initializationFailed("Failed to initialize Brotli compression stream")
            }
            defer { compression_stream_destroy(&stream) }

            var output = Data()
            var processStatus = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

            while processStatus == COMPRESSION_STATUS_OK {
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(destinationBuffer, count: produced)
                }
                stream.dst_ptr = destinationBuffer
                stream.dst_size = bufferSize
                processStatus = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            }

            if processStatus == COMPRESSION_STATUS_END {
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(destinationBuffer, count: produced)
                }
            }

            return output
        }
    }
}
