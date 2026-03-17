//
//  DeflateDecoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCompression
import XCTest
import zlib

final class DeflateDecoderTests: XCTestCase {
    // MARK: - Round-Trip Tests (Zlib Wrapped)

    func testDeflateZlibRoundTrip() throws {
        let testStrings = [
            "Short",
            "Medium length string for testing",
            String(repeating: "Long string with repeated content. ", count: 100)
        ]

        for testString in testStrings {
            let input = try XCTUnwrap(testString.data(using: .utf8))

            let compressed = try compressZlib(input)
            XCTAssertNotNil(compressed, "Failed to compress: \(testString.prefix(20))")
            XCTAssertGreaterThan(compressed.count, 0)

            let decompressed = try DeflateDecoder.decompress(compressed)
            XCTAssertEqual(decompressed, input, "Round-trip failed for: \(testString.prefix(20))")
        }
    }

    // MARK: - Round-Trip Tests (Raw Deflate)

    func testDeflateRawRoundTrip() throws {
        let testStrings = [
            "Short",
            "Medium length string for testing",
            String(repeating: "Long string with repeated content. ", count: 100)
        ]

        for testString in testStrings {
            let input = try XCTUnwrap(testString.data(using: .utf8))

            let compressed = try compressRawDeflate(input)
            XCTAssertNotNil(compressed, "Failed to compress: \(testString.prefix(20))")
            XCTAssertGreaterThan(compressed.count, 0)

            let decompressed = try DeflateDecoder.decompress(compressed)
            XCTAssertEqual(decompressed, input, "Round-trip failed for: \(testString.prefix(20))")
        }
    }

    func testDeflateDecompressZlibWrappedData() throws {
        let input = "Hello, World! This is a test string for zlib compression.".data(using: .utf8)!
        let compressed = try compressZlib(input)

        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, input)
    }

    func testDeflateDecompressRawDeflateData() throws {
        let input = "Raw DEFLATE test string.".data(using: .utf8)!
        let compressed = try compressRawDeflate(input)

        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, input)
    }

    // MARK: - Various Data Sizes (Zlib)

    func testDeflateZlibSmallData() throws {
        let small = "Hi".data(using: .utf8)!

        let compressed = try compressZlib(small)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, small)
    }

    func testDeflateZlibMediumData() throws {
        let medium = try XCTUnwrap(String(repeating: "Medium test data. ", count: 50).data(using: .utf8))

        let compressed = try compressZlib(medium)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, medium)
    }

    func testDeflateZlibLargeData() throws {
        let largeString = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 2000)
        let large = try XCTUnwrap(largeString.data(using: .utf8))

        let compressed = try compressZlib(large)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, large)
        XCTAssertGreaterThan(decompressed.count, 64 * 1024)
    }

    func testDeflateZlibVeryLargeData() throws {
        let veryLarge = Data(repeating: 0x42, count: 100_000)

        let compressed = try compressZlib(veryLarge)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, veryLarge)
        XCTAssertLessThan(compressed.count, veryLarge.count)
    }

    // MARK: - Various Data Sizes (Raw Deflate)

    func testDeflateRawSmallData() throws {
        let small = "Hi".data(using: .utf8)!

        let compressed = try compressRawDeflate(small)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, small)
    }

    func testDeflateRawMediumData() throws {
        let medium = try XCTUnwrap(String(repeating: "Medium test data. ", count: 50).data(using: .utf8))

        let compressed = try compressRawDeflate(medium)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, medium)
    }

    func testDeflateRawLargeData() throws {
        let large = Data(repeating: 0x42, count: 100_000)

        let compressed = try compressRawDeflate(large)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, large)
    }

    // MARK: - Empty Data Tests

    func testDeflateDecompressEmptyData() throws {
        let empty = Data()

        let result = try DeflateDecoder.decompress(empty)

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Invalid Data Tests

    func testDeflateDecompressInvalidData() {
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        XCTAssertThrowsError(try DeflateDecoder.decompress(invalidData)) { error in
            XCTAssertTrue(error is CompressionError)
        }
    }

    func testDeflateDecompressGarbageData() {
        let garbage = Data((0 ..< 100).map { _ in UInt8.random(in: 0 ... 255) })

        XCTAssertThrowsError(try DeflateDecoder.decompress(garbage))
    }

    func testDeflateDecompressCorruptedZlibData() throws {
        let original = "Test data".data(using: .utf8)!
        var compressed = try compressZlib(original)

        if compressed.count > 10 {
            compressed[5] = compressed[5] ^ 0xFF
        }

        XCTAssertThrowsError(try DeflateDecoder.decompress(compressed))
    }

    func testDeflateDecompressCorruptedRawData() throws {
        let original = "Test data".data(using: .utf8)!
        var compressed = try compressRawDeflate(original)

        if compressed.count > 10 {
            compressed[5] = compressed[5] ^ 0xFF
        }

        do {
            let decompressed = try DeflateDecoder.decompress(compressed)
            XCTAssertNotEqual(decompressed, original)
        } catch {
            // Raw DEFLATE has no checksum; corruption may be detected or may produce garbage output.
        }
    }

    // MARK: - Binary Data Tests

    func testDeflateBinaryDataZlib() throws {
        var binaryData = Data()
        for i in 0 ..< 1000 {
            binaryData.append(UInt8(i % 256))
        }

        let compressed = try compressZlib(binaryData)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, binaryData)
    }

    func testDeflateBinaryDataRaw() throws {
        var binaryData = Data()
        for i in 0 ..< 1000 {
            binaryData.append(UInt8(i % 256))
        }

        let compressed = try compressRawDeflate(binaryData)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, binaryData)
    }

    // MARK: - Compression Ratio Tests

    func testDeflateCompressionRatioRepetitiveData() throws {
        let repetitiveData = Data(repeating: 0x41, count: 10000)

        let compressed = try compressZlib(repetitiveData)

        XCTAssertNotNil(compressed)
        XCTAssertLessThan(compressed.count, repetitiveData.count / 10)
    }

    func testDeflateCompressionRatioRandomData() throws {
        var randomData = Data()
        for _ in 0 ..< 1000 {
            randomData.append(UInt8.random(in: 0 ... 255))
        }

        let compressed = try compressZlib(randomData)

        XCTAssertGreaterThan(compressed.count, 0)
    }

    // MARK: - Unicode and Special Characters Tests

    func testDeflateUnicodeString() throws {
        let unicode = "Hello 世界 🌍 مرحبا".data(using: .utf8)!

        let compressed = try compressZlib(unicode)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, unicode)

        let reconstructed = String(data: decompressed, encoding: .utf8)
        XCTAssertEqual(reconstructed, "Hello 世界 🌍 مرحبا")
    }

    // MARK: - JSON Data Tests

    func testDeflateJSONCompression() throws {
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

        let compressed = try compressZlib(json)
        let decompressed = try DeflateDecoder.decompress(compressed)

        XCTAssertEqual(decompressed, json)
    }

    // MARK: - Zlib Header Tests

    func testDeflateZlibHeaderDetection() throws {
        let data = "Test".data(using: .utf8)!
        let zlibCompressed = try compressZlib(data)

        XCTAssertGreaterThanOrEqual(zlibCompressed.count, 2)

        let cmf = zlibCompressed[0]
        let cm = cmf & 0x0F
        XCTAssertEqual(cm, 8)

        let check = (UInt16(zlibCompressed[0]) << 8) | UInt16(zlibCompressed[1])
        XCTAssertEqual(check % 31, 0)
    }

    // MARK: - Helper Methods

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

    private func compressRawDeflate(_ data: Data) throws -> Data {
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
                -MAX_WBITS,
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
                    throw CompressionError.decompressionFailed("raw deflate compression failed for test fixture")
                }
            }

            return output
        }
    }
}
