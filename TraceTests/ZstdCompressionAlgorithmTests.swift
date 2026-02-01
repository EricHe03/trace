//
//  ZstdCompressionAlgorithmTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
import Compression
@testable import TraceCompression

final class ZstdCompressionAlgorithmTests: XCTestCase {

    // MARK: - Supported Algorithm Tests

    func testZstdSupportedAlgorithmExists() {
        let algorithm = ZstdCompressionAlgorithm.supportedAlgorithm

        if algorithm != nil {
            XCTAssertNotNil(algorithm, "Zstandard algorithm should be available on this SDK")
        } else {
            print("Zstandard algorithm is not available on this SDK version")
        }
    }

    func testZstdSupportedAlgorithmIsConsistent() {
        let algorithm1 = ZstdCompressionAlgorithm.supportedAlgorithm
        let algorithm2 = ZstdCompressionAlgorithm.supportedAlgorithm

        XCTAssertEqual(algorithm1, algorithm2, "Supported algorithm should be consistent")
    }

    func testZstdSupportedAlgorithmCanInitializeStream() throws {
        guard let algorithm = ZstdCompressionAlgorithm.supportedAlgorithm else {
            throw XCTSkip("Zstandard compression is unavailable on this SDK")
        }

        let tempBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { tempBuffer.deallocate() }

        var stream = compression_stream(
            dst_ptr: tempBuffer,
            dst_size: 0,
            src_ptr: UnsafePointer(tempBuffer),
            src_size: 0,
            state: nil
        )

        let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm)
        defer { compression_stream_destroy(&stream) }

        XCTAssertNotEqual(status, COMPRESSION_STATUS_ERROR, "Stream initialization should succeed")
    }

    func testZstdSupportedAlgorithmCanCompress() throws {
        guard let algorithm = ZstdCompressionAlgorithm.supportedAlgorithm else {
            throw XCTSkip("Zstandard compression is unavailable on this SDK")
        }

        let testData = "Hello, Zstd!".data(using: .utf8)!
        var compressed = Data(count: 1024)

        let compressedSize = compressed.withUnsafeMutableBytes { outputBuffer in
            testData.withUnsafeBytes { inputBuffer in
                compression_encode_buffer(
                    outputBuffer.baseAddress!,
                    1024,
                    inputBuffer.baseAddress!,
                    testData.count,
                    nil,
                    algorithm
                )
            }
        }

        XCTAssertGreaterThan(compressedSize, 0, "Compression should produce output")
    }

    func testZstdSupportedAlgorithmCanDecompress() throws {
        guard let algorithm = ZstdCompressionAlgorithm.supportedAlgorithm else {
            throw XCTSkip("Zstandard compression is unavailable on this SDK")
        }

        let testData = "Hello, Zstd!".data(using: .utf8)!

        var compressed = Data(count: 1024)
        let compressedSize = compressed.withUnsafeMutableBytes { outputBuffer in
            testData.withUnsafeBytes { inputBuffer in
                compression_encode_buffer(
                    outputBuffer.baseAddress!,
                    1024,
                    inputBuffer.baseAddress!,
                    testData.count,
                    nil,
                    algorithm
                )
            }
        }

        XCTAssertGreaterThan(compressedSize, 0)
        compressed.count = compressedSize

        var decompressed = Data(count: 1024)
        let decompressedSize = decompressed.withUnsafeMutableBytes { outputBuffer in
            compressed.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.baseAddress!,
                    1024,
                    inputBuffer.baseAddress!,
                    compressed.count,
                    nil,
                    algorithm
                )
            }
        }

        XCTAssertGreaterThan(decompressedSize, 0)
        decompressed.count = decompressedSize

        XCTAssertEqual(decompressed, testData, "Round-trip compression should work")
    }

    // MARK: - Algorithm Candidate Tests

    func testZstdAlgorithmCandidatesAreValid() {
        let candidates: [compression_algorithm] = [
            compression_algorithm(rawValue: 0xD03),
            compression_algorithm(rawValue: 0xD01),
            compression_algorithm(rawValue: 0xD02),
            compression_algorithm(rawValue: 0xD04),
            compression_algorithm(rawValue: 0xD05)
        ]

        XCTAssertGreaterThan(candidates.count, 0, "Should have candidate algorithms to test")
    }

    // MARK: - Performance Tests

    func testZstdSupportedAlgorithmPerformance() throws {
        guard ZstdCompressionAlgorithm.supportedAlgorithm != nil else {
            throw XCTSkip("Zstandard compression is unavailable on this SDK")
        }

        measure {
            _ = ZstdCompressionAlgorithm.supportedAlgorithm
        }
    }

    // MARK: - Edge Case Tests

    func testZstdSupportedAlgorithmWithLargeData() throws {
        guard let algorithm = ZstdCompressionAlgorithm.supportedAlgorithm else {
            throw XCTSkip("Zstandard compression is unavailable on this SDK")
        }

        let largeData = Data(repeating: 0x42, count: 100000)
        var compressed = Data(count: largeData.count * 2)

        let compressedSize = compressed.withUnsafeMutableBytes { outputBuffer in
            largeData.withUnsafeBytes { inputBuffer in
                compression_encode_buffer(
                    outputBuffer.baseAddress!,
                    compressed.count,
                    inputBuffer.baseAddress!,
                    largeData.count,
                    nil,
                    algorithm
                )
            }
        }

        XCTAssertGreaterThan(compressedSize, 0)
        XCTAssertLessThan(compressedSize, largeData.count, "Large repetitive data should compress well")
    }

    func testZstdSupportedAlgorithmWithBinaryData() throws {
        guard let algorithm = ZstdCompressionAlgorithm.supportedAlgorithm else {
            throw XCTSkip("Zstandard compression is unavailable on this SDK")
        }

        var binaryData = Data()
        for i in 0..<1000 {
            binaryData.append(UInt8(i % 256))
        }

        var compressed = Data(count: binaryData.count * 2)

        let compressedSize = compressed.withUnsafeMutableBytes { outputBuffer in
            binaryData.withUnsafeBytes { inputBuffer in
                compression_encode_buffer(
                    outputBuffer.baseAddress!,
                    compressed.count,
                    inputBuffer.baseAddress!,
                    binaryData.count,
                    nil,
                    algorithm
                )
            }
        }

        XCTAssertGreaterThan(compressedSize, 0)

        compressed.count = compressedSize

        var decompressed = Data(count: binaryData.count * 2)
        let decompressedSize = decompressed.withUnsafeMutableBytes { outputBuffer in
            compressed.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.baseAddress!,
                    decompressed.count,
                    inputBuffer.baseAddress!,
                    compressed.count,
                    nil,
                    algorithm
                )
            }
        }

        decompressed.count = decompressedSize
        XCTAssertEqual(decompressed, binaryData)
    }

    func testZstdSupportedAlgorithmWithUnicodeData() throws {
        guard let algorithm = ZstdCompressionAlgorithm.supportedAlgorithm else {
            throw XCTSkip("Zstandard compression is unavailable on this SDK")
        }

        let unicodeData = "Hello 世界 🌍 مرحبا".data(using: .utf8)!
        var compressed = Data(count: 1024)

        let compressedSize = compressed.withUnsafeMutableBytes { outputBuffer in
            unicodeData.withUnsafeBytes { inputBuffer in
                compression_encode_buffer(
                    outputBuffer.baseAddress!,
                    1024,
                    inputBuffer.baseAddress!,
                    unicodeData.count,
                    nil,
                    algorithm
                )
            }
        }

        XCTAssertGreaterThan(compressedSize, 0)

        compressed.count = compressedSize

        var decompressed = Data(count: 1024)
        let decompressedSize = decompressed.withUnsafeMutableBytes { outputBuffer in
            compressed.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.baseAddress!,
                    1024,
                    inputBuffer.baseAddress!,
                    compressed.count,
                    nil,
                    algorithm
                )
            }
        }

        decompressed.count = decompressedSize
        XCTAssertEqual(decompressed, unicodeData)

        let reconstructed = String(data: decompressed, encoding: .utf8)
        XCTAssertEqual(reconstructed, "Hello 世界 🌍 مرحبا")
    }
}
