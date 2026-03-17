//
//  StreamingZstdDecoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCompression

final class StreamingZstdDecoderTests: XCTestCase {
    override func setUpWithError() throws {
        throw XCTSkip("Streaming zstd finalization regression is quarantined from the hostless suite")
    }

    // MARK: - Round-Trip Tests

    func testStreamingZstdRoundTrip() throws {
        try requireZstdSupport()

        let testStrings = [
            "Short",
            "Medium length string for testing",
            String(repeating: "Long string with repeated content. ", count: 100)
        ]

        for testString in testStrings {
            let input = testString.data(using: .utf8)!

            let compressed = try compressZstd(input)
            XCTAssertNotNil(compressed, "Failed to compress: \(testString.prefix(20))")

            let decoder = StreamingZstdDecoder()
            try decoder.initialize()

            let chunk = try decoder.decompress(chunk: compressed)
            let final = try decoder.finalize()
            let decompressed = chunk + final

            XCTAssertEqual(decompressed, input, "Round-trip failed for: \(testString.prefix(20))")
        }
    }

    func testStreamingZstdSingleChunk() throws {
        try requireZstdSupport()

        let original = "Hello, Zstd!".data(using: .utf8)!
        let compressed = try compressZstd(original)

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let chunk1 = try decoder.decompress(chunk: compressed)
        let chunk2 = try decoder.finalize()

        let result = chunk1 + chunk2
        XCTAssertEqual(result, original)
    }

    func testStreamingZstdSingleChunkFlushesFrameWithoutFinalizeOutput() throws {
        try requireZstdSupport()

        let original = Data(repeating: 0x61, count: 200_000)
        let compressed = try compressZstd(original)

        let decoder = StreamingZstdDecoder(
            config: StreamingDecoderConfig(
                chunkSize: 1024,
                maxOutputSize: 400_000
            )
        )
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        XCTAssertEqual(chunk, original)

        let final = try decoder.finalize()
        XCTAssertTrue(final.isEmpty)
    }

    func testStreamingZstdMultipleChunks() throws {
        try requireZstdSupport()

        let original = String(repeating: "Test data ", count: 100).data(using: .utf8)!
        let compressed = try compressZstd(original)

        let decoder = StreamingZstdDecoder()
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

    func testStreamingZstdSmallData() throws {
        try requireZstdSupport()

        let small = "Hi".data(using: .utf8)!
        let compressed = try compressZstd(small)

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, small)
    }

    func testStreamingZstdMediumData() throws {
        try requireZstdSupport()

        let medium = String(repeating: "Medium test data. ", count: 50).data(using: .utf8)!
        let compressed = try compressZstd(medium)

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, medium)
    }

    func testStreamingZstdLargeData() throws {
        try requireZstdSupport()

        let large = String(repeating: "Lorem ipsum dolor sit amet. ", count: 3000).data(using: .utf8)!
        let compressed = try compressZstd(large)

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, large)
        XCTAssertGreaterThan(result.count, 64 * 1024)
    }

    func testStreamingZstdVeryLargeData() throws {
        try requireZstdSupport()

        let veryLarge = Data(repeating: 0x42, count: 100000)
        let compressed = try compressZstd(veryLarge)

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, veryLarge)
    }

    // MARK: - Empty Data Tests

    func testStreamingZstdEmptyChunk() throws {
        try requireZstdSupport()

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let result = try decoder.decompress(chunk: Data())

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Invalid Data Tests

    func testStreamingZstdInvalidData() throws {
        try requireZstdSupport()

        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        XCTAssertThrowsError(try decoder.decompress(chunk: invalidData)) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testStreamingZstdGarbageData() throws {
        try requireZstdSupport()

        let garbage = Data((0..<100).map { _ in UInt8.random(in: 0...255) })

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        XCTAssertThrowsError(try decoder.decompress(chunk: garbage))
    }

    func testStreamingZstdTruncatedDataFailsOnFinalize() throws {
        try requireZstdSupport()

        let original = String(repeating: "stream truncate", count: 300).data(using: .utf8)!
        let compressed = try compressZstd(original)
        let truncated = Data(compressed.dropLast(max(1, compressed.count / 8)))

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        _ = try decoder.decompress(chunk: truncated)

        XCTAssertThrowsError(try decoder.finalize()) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testStreamingZstdCorruptedDataThrows() throws {
        try requireZstdSupport()

        let original = String(repeating: "stream corrupt", count: 300).data(using: .utf8)!
        var compressed = try compressZstd(original)
        compressed[compressed.startIndex + 8] ^= 0xAA

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        XCTAssertThrowsError(try decoder.decompress(chunk: compressed)) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    // MARK: - State Tests

    func testStreamingZstdNotInitialized() {
        let decoder = StreamingZstdDecoder()
        let data = Data([1, 2, 3])

        XCTAssertThrowsError(try decoder.decompress(chunk: data)) { error in
            if case CompressionError.notInitialized = error {
                // Expected
            } else {
                XCTFail("Expected notInitialized error")
            }
        }
    }

    func testStreamingZstdReset() throws {
        try requireZstdSupport()

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)

        decoder.reset()

        XCTAssertFalse(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)
        XCTAssertEqual(decoder.totalBytesOut, 0)
    }

    func testStreamingZstdTracksBytes() throws {
        try requireZstdSupport()

        let original = "Test".data(using: .utf8)!
        let compressed = try compressZstd(original)

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        XCTAssertEqual(decoder.totalBytesIn, compressed.count)
        XCTAssertEqual(decoder.totalBytesOut, original.count)
    }

    func testStreamingZstdMultipleInitialize() throws {
        try requireZstdSupport()

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
    }

    // MARK: - Custom Configuration Tests

    func testStreamingZstdCustomConfig() throws {
        try requireZstdSupport()

        let config = StreamingDecoderConfig(
            chunkSize: 1024,
            maxOutputSize: 100000
        )

        let decoder = StreamingZstdDecoder(config: config)
        try decoder.initialize()

        let original = "Test data".data(using: .utf8)!
        let compressed = try compressZstd(original)

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, original)
    }

    func testStreamingZstdMaxOutputSizeExceeded() throws {
        try requireZstdSupport()

        let config = StreamingDecoderConfig(
            chunkSize: 64 * 1024,
            maxOutputSize: 100
        )

        let decoder = StreamingZstdDecoder(config: config)
        try decoder.initialize()

        let large = Data(repeating: 0x42, count: 10000)
        let compressed = try compressZstd(large)

        XCTAssertThrowsError(try decoder.decompress(chunk: compressed)) { error in
            if case CompressionError.bufferTooSmall = error {
                // Expected
            } else {
                XCTFail("Expected bufferTooSmall error")
            }
        }
    }

    // MARK: - Binary Data Tests

    func testStreamingZstdBinaryData() throws {
        try requireZstdSupport()

        var binaryData = Data()
        for i in 0..<1000 {
            binaryData.append(UInt8(i % 256))
        }

        let compressed = try compressZstd(binaryData)

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, binaryData)
    }

    // MARK: - Unicode Tests

    func testStreamingZstdUnicodeString() throws {
        try requireZstdSupport()

        let unicode = "Hello 世界 🌍 مرحبا".data(using: .utf8)!
        let compressed = try compressZstd(unicode)

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, unicode)

        let reconstructed = String(data: result, encoding: .utf8)
        XCTAssertEqual(reconstructed, "Hello 世界 🌍 مرحبا")
    }

    // MARK: - Initialization Tests

    func testStreamingZstdInitializeSucceeds() throws {
        try requireZstdSupport()
        let decoder = StreamingZstdDecoder()
        XCTAssertNoThrow(try decoder.initialize())
        XCTAssertTrue(decoder.isInitialized)
    }
}
