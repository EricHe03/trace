//
//  StreamingBrotliDecoderTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
import Compression
@testable import TraceCompression

final class StreamingBrotliDecoderTests: XCTestCase {

    // MARK: - Round-Trip Tests

    func testStreamingBrotliRoundTrip() throws {
        let testStrings = [
            "Short",
            "Medium length string for testing",
            String(repeating: "Long string with repeated content. ", count: 100)
        ]

        for testString in testStrings {
            let input = testString.data(using: .utf8)!

            let compressed = try compressBrotli(input)
            XCTAssertNotNil(compressed, "Failed to compress: \(testString.prefix(20))")

            let decoder = StreamingBrotliDecoder()
            try decoder.initialize()

            let chunk = try decoder.decompress(chunk: compressed)
            let final = try decoder.finalize()
            let decompressed = chunk + final

            XCTAssertEqual(decompressed, input, "Round-trip failed for: \(testString.prefix(20))")
        }
    }

    func testStreamingBrotliSingleChunk() throws {
        let original = "Hello, World!".data(using: .utf8)!
        let compressed = try compressBrotli(original)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let chunk1 = try decoder.decompress(chunk: compressed)
        let chunk2 = try decoder.finalize()

        let result = chunk1 + chunk2
        XCTAssertEqual(result, original)
    }

    func testStreamingBrotliMultipleChunks() throws {
        let original = String(repeating: "Test data ", count: 100).data(using: .utf8)!
        let compressed = try compressBrotli(original)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        var output = Data()

        let chunkSize = 100
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + chunkSize, compressed.count)
            let chunk = compressed[offset..<end]
            let decompressed = try decoder.decompress(chunk: chunk)
            output.append(decompressed)
            offset = end
        }

        let final = try decoder.finalize()
        output.append(final)

        XCTAssertEqual(output, original)
    }

    // MARK: - Various Data Sizes

    func testStreamingBrotliSmallData() throws {
        let small = "Hi".data(using: .utf8)!
        let compressed = try compressBrotli(small)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, small)
    }

    func testStreamingBrotliMediumData() throws {
        let medium = String(repeating: "Medium test data. ", count: 50).data(using: .utf8)!
        let compressed = try compressBrotli(medium)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, medium)
    }

    func testStreamingBrotliLargeData() throws {
        let large = String(repeating: "Lorem ipsum dolor sit amet. ", count: 3000).data(using: .utf8)!
        let compressed = try compressBrotli(large)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, large)
        XCTAssertGreaterThan(result.count, 64 * 1024)
    }

    func testStreamingBrotliVeryLargeData() throws {
        let veryLarge = Data(repeating: 0x42, count: 100000)
        let compressed = try compressBrotli(veryLarge)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, veryLarge)
    }

    // MARK: - Empty Data Tests

    func testStreamingBrotliEmptyChunk() throws {
        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let result = try decoder.decompress(chunk: Data())

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Invalid Data Tests

    func testStreamingBrotliInvalidData() throws {
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        XCTAssertThrowsError(try decoder.decompress(chunk: invalidData)) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testStreamingBrotliGarbageData() throws {
        let garbage = Data((0..<100).map { _ in UInt8.random(in: 0...255) })

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        XCTAssertThrowsError(try decoder.decompress(chunk: garbage))
    }

    // MARK: - State Tests

    func testStreamingBrotliNotInitialized() {
        let decoder = StreamingBrotliDecoder()
        let data = Data([1, 2, 3])

        XCTAssertThrowsError(try decoder.decompress(chunk: data)) { error in
            if case CompressionError.notInitialized = error {
                // Expected
            } else {
                XCTFail("Expected notInitialized error")
            }
        }
    }

    func testStreamingBrotliReset() throws {
        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)

        decoder.reset()

        XCTAssertFalse(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)
        XCTAssertEqual(decoder.totalBytesOut, 0)
    }

    func testStreamingBrotliTracksBytes() throws {
        let original = "Test".data(using: .utf8)!
        let compressed = try compressBrotli(original)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        XCTAssertEqual(decoder.totalBytesIn, compressed.count)
        XCTAssertEqual(decoder.totalBytesOut, original.count)
    }

    func testStreamingBrotliMultipleInitialize() throws {
        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
    }

    // MARK: - Custom Configuration Tests

    func testStreamingBrotliCustomConfig() throws {
        let config = StreamingDecoderConfig(
            chunkSize: 1024,
            maxOutputSize: 100000
        )

        let decoder = StreamingBrotliDecoder(config: config)
        try decoder.initialize()

        let original = "Test data".data(using: .utf8)!
        let compressed = try compressBrotli(original)

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, original)
    }

    func testStreamingBrotliMaxOutputSizeExceeded() throws {
        let config = StreamingDecoderConfig(
            chunkSize: 64 * 1024,
            maxOutputSize: 100
        )

        let decoder = StreamingBrotliDecoder(config: config)
        try decoder.initialize()

        let large = Data(repeating: 0x42, count: 10000)
        let compressed = try compressBrotli(large)

        XCTAssertThrowsError(try decoder.decompress(chunk: compressed)) { error in
            if case CompressionError.bufferTooSmall = error {
                // Expected
            } else {
                XCTFail("Expected bufferTooSmall error")
            }
        }
    }

    // MARK: - Binary Data Tests

    func testStreamingBrotliBinaryData() throws {
        var binaryData = Data()
        for i in 0..<1000 {
            binaryData.append(UInt8(i % 256))
        }

        let compressed = try compressBrotli(binaryData)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, binaryData)
    }

    // MARK: - Unicode Tests

    func testStreamingBrotliUnicodeString() throws {
        let unicode = "Hello 世界 🌍 مرحبا".data(using: .utf8)!
        let compressed = try compressBrotli(unicode)

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, unicode)

        let reconstructed = String(data: result, encoding: .utf8)
        XCTAssertEqual(reconstructed, "Hello 世界 🌍 مرحبا")
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
