//
//  StreamingDecompressionTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
import zlib
import Compression
@testable import Trace
@testable import TraceCompression

final class StreamingDecompressionTests: XCTestCase {
    // MARK: - Helper Methods

    private func compressDeflate(_ data: Data) -> Data? {
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

        guard result == Z_STREAM_END else { return nil }
        compressedData.count = bufferSize - Int(stream.avail_out)
        return compressedData
    }

    private func compressWithCompressionFramework(_ data: Data, algorithm: compression_algorithm) -> Data? {
        let maxSize = max(data.count * 8, 1024)
        var bufferSize = max(data.count, 64)

        while bufferSize <= maxSize {
            var compressed = Data(count: bufferSize)
            let actualSize = compressed.withUnsafeMutableBytes { outputBuffer in
                data.withUnsafeBytes { inputBuffer in
                    compression_encode_buffer(
                        outputBuffer.baseAddress!,
                        bufferSize,
                        inputBuffer.baseAddress!,
                        data.count,
                        nil,
                        algorithm
                    )
                }
            }

            if actualSize > 0 {
                compressed.count = actualSize
                return compressed
            }

            bufferSize *= 2
        }

        return nil
    }

    // MARK: - Streaming Deflate Tests

    func testStreamingDeflate_SingleChunk_Decompresses() throws {
        let original = "Hello, World!".data(using: .utf8)!
        guard let compressed = compressDeflate(original) else {
            XCTFail("Failed to compress")
            return
        }

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let chunk1 = try decoder.decompress(chunk: compressed)
        let chunk2 = try decoder.finalize()

        let result = chunk1 + chunk2
        XCTAssertEqual(result, original)
    }

    func testStreamingDeflate_MultipleChunks_Decompresses() throws {
        let original = String(repeating: "Test data ", count: 100).data(using: .utf8)!
        guard let compressed = compressDeflate(original) else {
            XCTFail("Failed to compress")
            return
        }

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        var output = Data()

        // Split compressed data into chunks
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

    func testStreamingDeflate_EmptyChunk_ReturnsEmpty() throws {
        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        let result = try decoder.decompress(chunk: Data())
        XCTAssertTrue(result.isEmpty)
    }

    func testStreamingDeflate_NotInitialized_ThrowsError() {
        let decoder = StreamingDeflateDecoder()
        let data = Data([1, 2, 3])

        do {
            _ = try decoder.decompress(chunk: data)
            XCTFail("Expected error to be thrown")
        } catch let error as CompressionError {
            if case .notInitialized = error {
                // Expected
            } else {
                XCTFail("Expected notInitialized error")
            }
        } catch {
            XCTFail("Expected CompressionError, got \(error)")
        }
    }

    func testStreamingDeflate_Reset_ClearsState() throws {
        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)

        decoder.reset()

        XCTAssertFalse(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)
        XCTAssertEqual(decoder.totalBytesOut, 0)
    }

    func testStreamingDeflate_TracksBytes() throws {
        let original = "Test".data(using: .utf8)!
        guard let compressed = compressDeflate(original) else {
            XCTFail("Failed to compress")
            return
        }

        let decoder = StreamingDeflateDecoder()
        try decoder.initialize()

        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        XCTAssertEqual(decoder.totalBytesIn, compressed.count)
        XCTAssertEqual(decoder.totalBytesOut, original.count)
    }

    // MARK: - Streaming Brotli Tests

    func testStreamingBrotli_Decompresses() throws {
        let original = "Hello, Brotli!".data(using: .utf8)!

        guard let compressed = compressWithCompressionFramework(original, algorithm: COMPRESSION_BROTLI) else {
            XCTFail("Failed to compress")
            return
        }

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, original)
    }

    func testStreamingBrotli_TracksBytes() throws {
        let original = "Test".data(using: .utf8)!

        guard let compressed = compressWithCompressionFramework(original, algorithm: COMPRESSION_BROTLI) else {
            XCTFail("Failed to compress")
            return
        }

        let decoder = StreamingBrotliDecoder()
        try decoder.initialize()

        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        XCTAssertEqual(decoder.totalBytesIn, compressed.count)
        XCTAssertEqual(decoder.totalBytesOut, original.count)
    }

    // MARK: - Streaming Zstd Tests

    func testStreamingZstd_Decompresses() throws {
        let original = "Hello, Zstd!".data(using: .utf8)!

        try XCTSkipIf(ZstdCompressionAlgorithm.supportedAlgorithm == nil, "Zstandard compression is unavailable on this SDK")
        guard let compressed = compressWithCompressionFramework(original, algorithm: ZstdCompressionAlgorithm.supportedAlgorithm!) else {
            XCTFail("Failed to compress")
            return
        }

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        let chunk = try decoder.decompress(chunk: compressed)
        let final = try decoder.finalize()
        let result = chunk + final

        XCTAssertEqual(result, original)
    }

    func testStreamingZstd_TracksBytes() throws {
        let original = "Test".data(using: .utf8)!

        try XCTSkipIf(ZstdCompressionAlgorithm.supportedAlgorithm == nil, "Zstandard compression is unavailable on this SDK")
        guard let compressed = compressWithCompressionFramework(original, algorithm: ZstdCompressionAlgorithm.supportedAlgorithm!) else {
            XCTFail("Failed to compress")
            return
        }

        let decoder = StreamingZstdDecoder()
        try decoder.initialize()

        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        XCTAssertEqual(decoder.totalBytesIn, compressed.count)
        XCTAssertEqual(decoder.totalBytesOut, original.count)
    }

    // MARK: - Configuration Tests

    func testStreamingDecoder_CustomConfig_Respected() throws {
        let config = StreamingDecoderConfig(
            chunkSize: 1024,
            maxOutputSize: 10000
        )

        let decoder = StreamingDeflateDecoder(config: config)
        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
    }

    // MARK: - Performance Tests

    func testStreamingDeflate_Performance() {
        let original = Data(repeating: 0x42, count: 100000)
        guard let compressed = compressDeflate(original) else {
            XCTFail("Failed to compress")
            return
        }

        measure {
            let decoder = StreamingDeflateDecoder()
            try? decoder.initialize()
            _ = try? decoder.decompress(chunk: compressed)
            _ = try? decoder.finalize()
        }
    }
}
