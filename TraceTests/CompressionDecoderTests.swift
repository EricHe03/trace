//
//  CompressionDecoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
import Compression
import zlib
@testable import Trace
@testable import TraceCompression

final class CompressionDecoder_BrotliDecoderTests: XCTestCase {
    // MARK: - Decompress Tests

    func testDecompress_WithEmptyData_ReturnsEmptyData() throws {
        // Given
        let emptyData = Data()

        // When
        let result = try BrotliDecoder.decompress(emptyData)

        // Then
        XCTAssertTrue(result.isEmpty)
    }

    func testDecompress_WithValidBrotliData_ReturnsDecompressedData() throws {
        // Given - Create Brotli-compressed data
        let originalString = "Hello, World! This is a test string for Brotli compression."
        let originalData = originalString.data(using: .utf8)!
        let compressedData = try compressBrotli(originalData)

        // When
        let decompressedData = try BrotliDecoder.decompress(compressedData)

        // Then
        let decompressedString = String(data: decompressedData, encoding: .utf8)
        XCTAssertEqual(decompressedString, originalString)
    }

    func testDecompress_WithLargeData_HandlesCorrectly() throws {
        // Given - Create large test data (>64KB to test chunking)
        let largeString = String(repeating: "Lorem ipsum dolor sit amet. ", count: 3000)
        let originalData = largeString.data(using: .utf8)!
        let compressedData = try compressBrotli(originalData)

        // When
        let decompressedData = try BrotliDecoder.decompress(compressedData)

        // Then
        let decompressedString = String(data: decompressedData, encoding: .utf8)
        XCTAssertEqual(decompressedString, largeString)
        XCTAssertGreaterThan(decompressedData.count, 64 * 1024) // Verify it's larger than chunk size
    }

    func testDecompress_WithInvalidData_ThrowsError() {
        // Given - Random invalid data
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        // When/Then
        do {
            _ = try BrotliDecoder.decompress(invalidData)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is DecompressionError)
        }
    }

    // MARK: - Can Decode Tests

    func testCanDecode_WithEmptyData_ReturnsFalse() {
        // Given
        let emptyData = Data()

        // When
        let canDecode = BrotliDecoder.canDecode(emptyData)

        // Then
        XCTAssertFalse(canDecode)
    }

    func testCanDecode_WithValidBrotliData_ReturnsTrue() throws {
        // Given
        let originalData = "Test string".data(using: .utf8)!
        let compressedData = try compressBrotli(originalData)

        // When
        let canDecode = BrotliDecoder.canDecode(compressedData)

        // Then
        XCTAssertTrue(canDecode)
    }

    func testCanDecode_WithInvalidWindowSize_ReturnsFalse() {
        // Given - Data with invalid window bits (> 14)
        let invalidData = Data([0xFF]) // Window bits would be 15

        // When
        let canDecode = BrotliDecoder.canDecode(invalidData)

        // Then
        XCTAssertFalse(canDecode)
    }

    // MARK: - Helper Methods

    private func compressBrotli(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = sourcePtr.baseAddress else {
                throw DecompressionError.invalidData
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
                throw DecompressionError.initializationFailed
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

// MARK: - DeflateDecoder Tests

final class CompressionDecoder_DeflateDecoderTests: XCTestCase {
    // MARK: - Decompress Tests

    func testDecompress_WithEmptyData_ReturnsEmptyData() throws {
        // Given
        let emptyData = Data()

        // When
        let result = try DeflateDecoder.decompress(emptyData)

        // Then
        XCTAssertTrue(result.isEmpty)
    }

    func testDecompress_WithZlibWrappedData_ReturnsDecompressedData() throws {
        // Given - Create zlib-wrapped deflate data
        let originalString = "Hello, World! This is a test string for zlib compression."
        let originalData = originalString.data(using: .utf8)!
        let compressedData = try compressZlib(originalData)

        // When
        let decompressedData = try DeflateDecoder.decompress(compressedData)

        // Then
        let decompressedString = String(data: decompressedData, encoding: .utf8)
        XCTAssertEqual(decompressedString, originalString)
    }

    func testDecompress_WithRawDeflateData_ReturnsDecompressedData() throws {
        // Given - Create raw deflate data (no zlib wrapper)
        let originalString = "Raw DEFLATE test string."
        let originalData = originalString.data(using: .utf8)!
        let compressedData = try compressRawDeflate(originalData)

        // When
        let decompressedData = try DeflateDecoder.decompress(compressedData)

        // Then
        let decompressedString = String(data: decompressedData, encoding: .utf8)
        XCTAssertEqual(decompressedString, originalString)
    }

    func testDecompress_WithLargeData_HandlesCorrectly() throws {
        // Given - Create large test data (>64KB to test chunking)
        let largeString = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 2000)
        let originalData = largeString.data(using: .utf8)!
        let compressedData = try compressZlib(originalData)

        // When
        let decompressedData = try DeflateDecoder.decompress(compressedData)

        // Then
        let decompressedString = String(data: decompressedData, encoding: .utf8)
        XCTAssertEqual(decompressedString, largeString)
        XCTAssertGreaterThan(decompressedData.count, 64 * 1024)
    }

    func testDecompress_WithInvalidData_ThrowsError() {
        // Given - Random invalid data
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        // When/Then
        do {
            _ = try DeflateDecoder.decompress(invalidData)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is DecompressionError)
        }
    }

    // MARK: - Helper Methods

    private func compressZlib(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = sourcePtr.bindMemory(to: UInt8.self).baseAddress else {
                throw DecompressionError.invalidData
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
                MAX_WBITS, // zlib wrapper
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else {
                throw DecompressionError.initializationFailed
            }
            defer { deflateEnd(&stream) }

            try outBuffer.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else {
                    throw DecompressionError.invalidData
                }
                stream.next_out = baseAddress
                stream.avail_out = uInt(bufferSize)

                let status = deflate(&stream, Z_FINISH)
                let produced = bufferSize - Int(stream.avail_out)
                output.append(baseAddress, count: produced)

                guard status == Z_STREAM_END else {
                    throw DecompressionError.processingFailed
                }
            }

            return output
        }
    }

    private func compressRawDeflate(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = sourcePtr.bindMemory(to: UInt8.self).baseAddress else {
                throw DecompressionError.invalidData
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
                -MAX_WBITS, // Raw deflate (no wrapper)
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else {
                throw DecompressionError.initializationFailed
            }
            defer { deflateEnd(&stream) }

            try outBuffer.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else {
                    throw DecompressionError.invalidData
                }
                stream.next_out = baseAddress
                stream.avail_out = uInt(bufferSize)

                let status = deflate(&stream, Z_FINISH)
                let produced = bufferSize - Int(stream.avail_out)
                output.append(baseAddress, count: produced)

                guard status == Z_STREAM_END else {
                    throw DecompressionError.processingFailed
                }
            }

            return output
        }
    }
}

// MARK: - CompressionErrors Tests

final class CompressionDecoder_CompressionErrorsTests: XCTestCase {
    func testDecompressionError_InvalidData_HasCorrectDescription() {
        // Given
        let error = DecompressionError.invalidData

        // When
        let description = error.errorDescription

        // Then
        XCTAssertEqual(description, "Invalid or corrupted compressed data")
    }

    func testDecompressionError_InitializationFailed_HasCorrectDescription() {
        // Given
        let error = DecompressionError.initializationFailed

        // When
        let description = error.errorDescription

        // Then
        XCTAssertEqual(description, "Failed to initialize decompression stream")
    }

    func testDecompressionError_ProcessingFailed_HasCorrectDescription() {
        // Given
        let error = DecompressionError.processingFailed

        // When
        let description = error.errorDescription

        // Then
        XCTAssertEqual(description, "Decompression processing failed")
    }

    func testDecompressionError_UnknownError_HasCorrectDescription() {
        // Given
        let error = DecompressionError.unknownError

        // When
        let description = error.errorDescription

        // Then
        XCTAssertEqual(description, "Unknown decompression error occurred")
    }
}
