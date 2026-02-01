//
//  StreamingDecoderProtocolTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
import Compression
import zlib
@testable import TraceCompression

final class StreamingDecoderProtocolTests: XCTestCase {

    // MARK: - Protocol Conformance Tests

    func testStreamingBrotliDecoderConformsToProtocol() {
        let decoder: any StreamingDecoderProtocol = StreamingBrotliDecoder()

        XCTAssertFalse(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)
        XCTAssertEqual(decoder.totalBytesOut, 0)
    }

    func testStreamingDeflateDecoderConformsToProtocol() {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()

        XCTAssertFalse(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)
        XCTAssertEqual(decoder.totalBytesOut, 0)
    }

    func testStreamingZstdDecoderConformsToProtocol() {
        let decoder: any StreamingDecoderProtocol = StreamingZstdDecoder()

        XCTAssertFalse(decoder.isInitialized)
        XCTAssertEqual(decoder.totalBytesIn, 0)
        XCTAssertEqual(decoder.totalBytesOut, 0)
    }

    // MARK: - Protocol Method Tests

    func testProtocolInitializeMethod() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()

        XCTAssertFalse(decoder.isInitialized)

        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)
    }

    func testProtocolDecompressMethod() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()
        try decoder.initialize()

        let testData = "Hello, World!".data(using: .utf8)!
        let compressed = try compressGzip(testData)

        let result = try decoder.decompress(chunk: compressed)

        XCTAssertNotNil(result)
    }

    func testProtocolFinalizeMethod() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()
        try decoder.initialize()

        let result = try decoder.finalize()

        XCTAssertNotNil(result)
    }

    func testProtocolResetMethod() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()
        try decoder.initialize()

        decoder.reset()

        XCTAssertFalse(decoder.isInitialized)
    }

    // MARK: - Protocol Properties Tests

    func testProtocolIsInitializedProperty() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()

        XCTAssertFalse(decoder.isInitialized)

        try decoder.initialize()

        XCTAssertTrue(decoder.isInitialized)

        decoder.reset()

        XCTAssertFalse(decoder.isInitialized)
    }

    func testProtocolTotalBytesInProperty() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()
        try decoder.initialize()

        XCTAssertEqual(decoder.totalBytesIn, 0)

        let testData = "Test".data(using: .utf8)!
        let compressed = try compressGzip(testData)

        _ = try decoder.decompress(chunk: compressed)

        XCTAssertEqual(decoder.totalBytesIn, compressed.count)
    }

    func testProtocolTotalBytesOutProperty() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()
        try decoder.initialize()

        XCTAssertEqual(decoder.totalBytesOut, 0)

        let testData = "Test".data(using: .utf8)!
        let compressed = try compressGzip(testData)

        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        XCTAssertEqual(decoder.totalBytesOut, testData.count)
    }

    // MARK: - StreamingDecoderConfig Tests

    func testStreamingDecoderConfigDefaultValues() {
        let config = StreamingDecoderConfig.default

        XCTAssertEqual(config.chunkSize, 64 * 1024)
        XCTAssertEqual(config.maxOutputSize, 10 * 1024 * 1024)
        XCTAssertTrue(config.validateChecksums)
    }

    func testStreamingDecoderConfigCustomValues() {
        let config = StreamingDecoderConfig(
            chunkSize: 1024,
            maxOutputSize: 100000,
            validateChecksums: false
        )

        XCTAssertEqual(config.chunkSize, 1024)
        XCTAssertEqual(config.maxOutputSize, 100000)
        XCTAssertFalse(config.validateChecksums)
    }

    func testStreamingDecoderConfigIsSendable() {
        let config = StreamingDecoderConfig(
            chunkSize: 2048,
            maxOutputSize: 200000,
            validateChecksums: true
        )

        Task {
            let taskConfig = config
            XCTAssertEqual(taskConfig.chunkSize, 2048)
        }
    }

    // MARK: - Multiple Decoder Types Tests

    func testMultipleDecoderTypesCanBeUsedInterchangeably() throws {
        let decoders: [any StreamingDecoderProtocol] = [
            StreamingDeflateDecoder(),
            StreamingBrotliDecoder()
        ]

        for decoder in decoders {
            XCTAssertFalse(decoder.isInitialized)

            try decoder.initialize()

            XCTAssertTrue(decoder.isInitialized)

            decoder.reset()

            XCTAssertFalse(decoder.isInitialized)
        }
    }

    func testDecoderArrayCanBeStored() {
        var decoders: [any StreamingDecoderProtocol] = []

        decoders.append(StreamingDeflateDecoder())
        decoders.append(StreamingBrotliDecoder())
        decoders.append(StreamingZstdDecoder())

        XCTAssertEqual(decoders.count, 3)

        for decoder in decoders {
            XCTAssertFalse(decoder.isInitialized)
        }
    }

    // MARK: - Protocol Usage Pattern Tests

    func testProtocolTypicalUsagePattern() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()

        try decoder.initialize()
        XCTAssertTrue(decoder.isInitialized)

        let testData = "Test data for streaming".data(using: .utf8)!
        let compressed = try compressGzip(testData)

        let chunk1 = try decoder.decompress(chunk: compressed)
        let chunk2 = try decoder.finalize()

        let result = chunk1 + chunk2
        XCTAssertEqual(result, testData)

        XCTAssertGreaterThan(decoder.totalBytesIn, 0)
        XCTAssertGreaterThan(decoder.totalBytesOut, 0)
    }

    func testProtocolResetAndReusePattern() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()

        let testData = "Test data".data(using: .utf8)!
        let compressed = try compressGzip(testData)

        try decoder.initialize()
        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        let firstBytesIn = decoder.totalBytesIn

        decoder.reset()
        XCTAssertEqual(decoder.totalBytesIn, 0)
        XCTAssertEqual(decoder.totalBytesOut, 0)

        try decoder.initialize()
        _ = try decoder.decompress(chunk: compressed)
        _ = try decoder.finalize()

        XCTAssertEqual(decoder.totalBytesIn, firstBytesIn)
    }

    // MARK: - Config Application Tests

    func testProtocolWithCustomConfig() throws {
        let config = StreamingDecoderConfig(
            chunkSize: 1024,
            maxOutputSize: 100000,
            validateChecksums: false
        )

        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder(config: config)
        try decoder.initialize()

        let testData = "Test".data(using: .utf8)!
        let compressed = try compressGzip(testData)

        let result1 = try decoder.decompress(chunk: compressed)
        let result2 = try decoder.finalize()

        XCTAssertEqual(result1 + result2, testData)
    }

    func testProtocolEnforcesMaxOutputSize() throws {
        let config = StreamingDecoderConfig(
            chunkSize: 64 * 1024,
            maxOutputSize: 100,
            validateChecksums: true
        )

        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder(config: config)
        try decoder.initialize()

        let largeData = Data(repeating: 0x42, count: 10000)
        let compressed = try compressGzip(largeData)

        XCTAssertThrowsError(try decoder.decompress(chunk: compressed)) { error in
            if case CompressionError.bufferTooSmall = error {
                // Expected
            } else {
                XCTFail("Expected bufferTooSmall error")
            }
        }
    }

    // MARK: - Error Handling Tests

    func testProtocolThrowsWhenNotInitialized() {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()

        XCTAssertThrowsError(try decoder.decompress(chunk: Data([1, 2, 3]))) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testProtocolThrowsOnInvalidData() throws {
        let decoder: any StreamingDecoderProtocol = StreamingDeflateDecoder()
        try decoder.initialize()

        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        XCTAssertThrowsError(try decoder.decompress(chunk: invalidData)) { error in
            XCTAssertTrue(error is CompressionError)
        }
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
            throw DecompressionError.processingFailed
        }
        compressedData.count = bufferSize - Int(stream.avail_out)
        return compressedData
    }
}
