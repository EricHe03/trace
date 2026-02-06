//
//  StreamingDeflateDecoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
import zlib
@testable import TraceCompression

final class StreamingDeflateDecoderTests: XCTestCase {

    // MARK: - Round-Trip Tests

    func testStreamingDeflateRoundTrip() throws {
        let testStrings = [
            "Short",
            "Medium length string for testing",
            String(repeating: "Long string with repeated content. ", count: 100)
        ]

        for testString in testStrings {
            let input = testString.data(using: .utf8)!

            let compressed = try compressGzip(input)
            XCTAssertNotNil(compressed, "Failed to compress: \(testString.prefix(20))")

            let decoder = StreamingDeflateDecoder()
            try decoder.initialize()

            let chunk = try decoder.decompress(chunk: compressed)
            let final = try decoder.finalize()
            let decompressed = chunk + final

            XCTAssertEqual(decompressed, input, "Round-trip failed for: \(testString.prefix(20))")
        }
    }

    func testStreamingDeflateSingleChunk() throws {
        let original = "Hello, World!".data(using: .utf8)!
        let compressed = try compressGzip(original)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk1 = try decoder.decompress(chunk: compressed)
        let chunk2 = try decoder.finalize()

        let result = chunk1 + chunk2
        XCTAssertEqual(result, original)
    }

    func testStreamingDeflateMultipleChunks() throws {
        let original = String(repeating: "Test data ", count: 100).data(using: .utf8)!
        let compressed = try compressGzip(original)

        let decoder = StreamingDeflateDecoder()
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

    func testStreamingDeflateSmallData() throws {
        let small = "Hi".data(using: .utf8)!
        let compressed = try compressGzip(small)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, small)
    }

    func testStreamingDeflateMediumData() throws {
        let medium = String(repeating: "Medium test data. ", count: 50).data(using: .utf8)!
        let compressed = try compressGzip(medium)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, medium)
    }

    func testStreamingDeflateLargeData() throws {
        let large = String(repeating: "Lorem ipsum dolor sit amet. ", count: 3000).data(using: .utf8)!
        let compressed = try compressGzip(large)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, large)
        XCTAssertGreaterThan(result.count, 64 * 1024)
    }

    func testStreamingDeflateVeryLargeData() throws {
        let veryLarge = Data(repeating: 0x42, count: 100000)
        let compressed = try compressGzip(veryLarge)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, veryLarge)
    }

    // MARK: - Empty Data Tests

    func testStreamingDeflateEmptyChunk() throws {
        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let result = try decoder.decompress(chunk: Data())

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Invalid Data Tests

    func testStreamingDeflateInvalidData() throws {
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        XCTAssertThrowsError(try decoder.decompress(chunk: invalidData)) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testStreamingDeflateGarbageData() throws {
        let garbage = Data((0..<100).map { _ in UInt8.random(in: 0...255) })

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        XCTAssertThrowsError(try decoder.decompress(chunk: garbage))
    }

    // MARK: - State Tests

    func testStreamingDeflateNotInitialized() {
        let decoder = StreamingDeflateDecoder()
        let data = Data([1, 2, 3])

        XCTAssertThrowsError(try decoder.decompress(chunk: data)) { error in
            if case CompressionError.notInitialized = error {
                // Expected
            } else {
                XCTFail("Expected notInitialized error")
            }
        }
    }

    func testStreamingDeflateReset() throws {
        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)

        decoder.reset()

        XCTAssertFalse(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)
        XCTAssertEqual(decoder.totalBytesOut, 0)
    }

    func testStreamingDeflateTracksBytes() throws {
        let original = "Test".data(using: .utf8)!
        let compressed = try compressGzip(original)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        XCTAssertEqual(decoder.totalBytesIn, compressed.count)
        XCTAssertEqual(decoder.totalBytesOut, original.count)
    }

    func testStreamingDeflateMultipleInitialize() throws {
        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
    }

    // MARK: - Custom Configuration Tests

    func testStreamingDeflateCustomConfig() throws {
        let config = StreamingDecoderConfig(
            chunkSize: 1024,
            maxOutputSize: 100000
        )

        let decoder = StreamingDeflateDecoder(config: config)
        try decoder.initialize()

        let original = "Test data".data(using: .utf8)!
        let compressed = try compressGzip(original)

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, original)
    }

    func testStreamingDeflateMaxOutputSizeExceeded() throws {
        let config = StreamingDecoderConfig(
            chunkSize: 64 * 1024,
            maxOutputSize: 100
        )

        let decoder = StreamingDeflateDecoder(config: config)
        try decoder.initialize()

        let large = Data(repeating: 0x42, count: 10000)
        let compressed = try compressGzip(large)

        XCTAssertThrowsError(try decoder.decompress(chunk: compressed)) { error in
            if case CompressionError.bufferTooSmall = error {
                // Expected
            } else {
                XCTFail("Expected bufferTooSmall error")
            }
        }
    }

    // MARK: - Binary Data Tests

    func testStreamingDeflateBinaryData() throws {
        var binaryData = Data()
        for i in 0..<1000 {
            binaryData.append(UInt8(i % 256))
        }

        let compressed = try compressGzip(binaryData)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, binaryData)
    }

    // MARK: - Unicode Tests

    func testStreamingDeflateUnicodeString() throws {
        let unicode = "Hello 世界 🌍 مرحبا".data(using: .utf8)!
        let compressed = try compressGzip(unicode)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, unicode)

        let reconstructed = String(data: result, encoding: .utf8)
        XCTAssertEqual(reconstructed, "Hello 世界 🌍 مرحبا")
    }

    // MARK: - Format Tests

    func testStreamingDeflateAutoDetectGzip() throws {
        let original = "Test gzip".data(using: .utf8)!
        let compressed = try compressGzip(original)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, original)
    }

    func testStreamingDeflateAutoDetectZlib() throws {
        let original = "Test zlib".data(using: .utf8)!
        let compressed = try compressZlib(original)

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, original)
    }

    // MARK: - Helper Methods

    private func compressGzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        let bufferSize = data.count + 100
        var compressedData = Data(count: bufferSize)

        let result = data.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
            compressedData.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) in
                stream.avail_in = UInt32(data.count)
                stream.next_in = UnsafeMutablePointer<UInt8>(mutating: inputPointer.baseAddress?.assumingMemoryBound(to: UInt8.self))
                stream.avail_out = UInt32(bufferSize)
                stream.next_out = outputPointer.baseAddress?.assumingMemoryBound(to: UInt8.self)

                deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                defer { deflateEnd(&stream) }

                return deflate(&stream, Z_FINISH)
            }
        }

        guard result == Z_STREAM_END else {
            throw CompressionError.decompressionFailed("gzip compression failed for test fixture")
        }
        compressedData.count = bufferSize - Int(stream.avail_out)
        return compressedData
    }

    private func compressZlib(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = sourcePtr.bindMemory(to: UInt8.self).baseAddress else {
                throw CompressionError.invalidInput("Invalid input buffer")
            }

            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: baseAddress)
            stream.avail_in = uInt(data.count)

            var output = Data()
            let bufferSize = 64 * 1024
            var outBuffer = [UInt8](repeating: 0, count: bufferSize)

            let initStatus = deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                MAX_WBITS,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else {
                throw CompressionError.initializationFailed("deflateInit2 failed with code \(initStatus)")
            }
            defer { deflateEnd(&stream) }

            try outBuffer.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else {
                    throw CompressionError.invalidInput("Invalid output buffer")
                }
                stream.next_out = baseAddress
                stream.avail_out = uInt(bufferSize)

                let status = deflate(&stream, Z_FINISH)
                let produced = bufferSize - Int(stream.avail_out)
                output.append(baseAddress, count: produced)

                guard status == Z_STREAM_END else {
                    throw CompressionError.decompressionFailed("zlib compression failed for test fixture")
                }
            }

            return output
        }
    }
}
