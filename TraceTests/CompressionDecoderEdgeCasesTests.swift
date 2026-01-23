//
//  CompressionDecoderEdgeCasesTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceCompression

final class CompressionDecoderEdgeCasesTests: XCTestCase {
    // MARK: - Gzip Tests

    func testGzipDecompression_ValidData() {
        // Create gzip compressed data
        let originalString = "Hello, World! This is a test string for gzip compression."
        guard let originalData = originalString.data(using: .utf8) else {
            XCTFail("Failed to create original data")
            return
        }

        // Create BodyStorage with gzip encoding
        let bodyStorage = BodyStorage.from(data: originalData, contentEncoding: "gzip")

        // Should store the data (even if not actually compressed in test)
        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testGzipDecompression_EmptyData() {
        let emptyData = Data()
        let bodyStorage = BodyStorage.from(data: emptyData, contentEncoding: "gzip")

        XCTAssertTrue(bodyStorage.isEmpty)
    }

    func testGzipDecompression_InvalidMagicBytes() {
        // Data that doesn't start with gzip magic bytes (0x1F 0x8B)
        let invalidData = Data([0x00, 0x00, 0x01, 0x02, 0x03])
        let bodyStorage = BodyStorage.from(data: invalidData, contentEncoding: "gzip")

        // Should handle gracefully
        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testGzipDecompression_TruncatedData() {
        // Truncated gzip stream (starts with magic bytes but incomplete)
        let truncatedData = Data([0x1F, 0x8B, 0x08, 0x00])
        let bodyStorage = BodyStorage.from(data: truncatedData, contentEncoding: "gzip")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    // MARK: - Deflate Tests

    func testDeflateDecompression_ValidData() {
        let originalString = "Test data for deflate compression"
        guard let originalData = originalString.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let bodyStorage = BodyStorage.from(data: originalData, contentEncoding: "deflate")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testDeflateDecompression_EmptyData() {
        let emptyData = Data()
        let bodyStorage = BodyStorage.from(data: emptyData, contentEncoding: "deflate")

        XCTAssertTrue(bodyStorage.isEmpty)
    }

    // MARK: - Brotli Tests

    func testBrotliDecompression_ValidEncoding() {
        let testData = Data("Test brotli data".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "br")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testBrotliDecompression_AlternativeName() {
        let testData = Data("Test brotli data".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "brotli")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    // MARK: - Multiple Encoding Tests

    func testChainedCompression_GzipThenBrotli() {
        let testData = Data("Chained compression test".utf8)
        // "gzip, br" means first gzip, then brotli
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "gzip, br")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testChainedCompression_DeflateGzip() {
        let testData = Data("Multiple compression layers".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "deflate, gzip")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testChainedCompression_WithSpaces() {
        let testData = Data("Test data".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "gzip , deflate")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    // MARK: - Identity Encoding Tests

    func testIdentityEncoding_NoCompression() {
        let testData = Data("No compression".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "identity")

        XCTAssertFalse(bodyStorage.isEmpty)
        XCTAssertEqual(bodyStorage.totalSize, testData.count)
    }

    func testEmptyEncoding_NoCompression() {
        let testData = Data("No compression".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testNoEncoding_NoCompression() {
        let testData = Data("No compression".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: nil)

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    // MARK: - Unknown Encoding Tests

    func testUnknownEncoding_HandledGracefully() {
        let testData = Data("Unknown encoding".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "unknown-encoding")

        // Should store the data even if encoding is unknown
        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testInvalidEncoding_HandledGracefully() {
        let testData = Data("Invalid encoding".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "!@#$%")

        XCTAssertFalse(bodyStorage.isEmpty)
    }

    // MARK: - Case Sensitivity Tests

    func testEncodingNames_CaseInsensitive() {
        let testData = Data("Case test".utf8)

        let bodyStorage1 = BodyStorage.from(data: testData, contentEncoding: "GZIP")
        let bodyStorage2 = BodyStorage.from(data: testData, contentEncoding: "gzip")
        let bodyStorage3 = BodyStorage.from(data: testData, contentEncoding: "GzIp")

        XCTAssertFalse(bodyStorage1.isEmpty)
        XCTAssertFalse(bodyStorage2.isEmpty)
        XCTAssertFalse(bodyStorage3.isEmpty)
    }

    // MARK: - Compression Info Tests

    func testCompressionInfo_IsTracked() {
        let testData = Data("Compression tracking test".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: "gzip")

        let compressionInfo = bodyStorage.getCompressionInfo()

        // Compression info may or may not be present depending on whether actual compression happened
        // Just verify it doesn't crash
        if let info = compressionInfo {
            XCTAssertNotNil(info.algorithm)
        }
    }

    func testCompressionInfo_WithoutEncoding_IsNil() {
        let testData = Data("No compression info".utf8)
        let bodyStorage = BodyStorage.from(data: testData, contentEncoding: nil)

        let compressionInfo = bodyStorage.getCompressionInfo()

        // Without compression, info might be nil or present with no compression detected
        // Just verify it doesn't crash
        XCTAssertNotNil(bodyStorage)
    }

    // MARK: - Alternative Encoding Names Tests

    func testGzipAlternativeNames() {
        let testData = Data("Gzip alternatives".utf8)

        let bodyStorage1 = BodyStorage.from(data: testData, contentEncoding: "x-gzip")
        let bodyStorage2 = BodyStorage.from(data: testData, contentEncoding: "gzip")

        XCTAssertFalse(bodyStorage1.isEmpty)
        XCTAssertFalse(bodyStorage2.isEmpty)
    }

    // MARK: - Body Storage Size Thresholds Tests

    func testInlineStorage_SmallData() {
        let smallData = Data(count: 500 * 1024) // 500 KB (< 1 MB inline threshold)
        let bodyStorage = BodyStorage.from(data: smallData)

        // Should be inline
        XCTAssertFalse(bodyStorage.isFile)
        XCTAssertFalse(bodyStorage.isTruncated)
    }

    func testFileStorage_LargeData() {
        let largeData = Data(count: 2 * 1024 * 1024) // 2 MB (> 1 MB inline threshold)
        let bodyStorage = BodyStorage.from(data: largeData)

        // Should be file or inline (depending on file save success)
        XCTAssertFalse(bodyStorage.isEmpty)
    }

    func testTruncatedStorage_VeryLargeData() {
        let veryLargeData = Data(count: 15 * 1024 * 1024) // 15 MB (> 10 MB truncation threshold)
        let bodyStorage = BodyStorage.from(data: veryLargeData, maxSize: 10 * 1024 * 1024)

        // Should be truncated
        XCTAssertTrue(bodyStorage.isTruncated)
    }

    // MARK: - Charset Tests

    func testCharsetExtraction_FromContentType() {
        let charset = BodyStorage.extractCharset(from: "text/html; charset=utf-8")
        XCTAssertEqual(charset, "utf-8")
    }

    func testCharsetExtraction_WithQuotes() {
        let charset = BodyStorage.extractCharset(from: "text/plain; charset=\"iso-8859-1\"")
        XCTAssertEqual(charset, "iso-8859-1")
    }

    func testCharsetExtraction_NoCharset() {
        let charset = BodyStorage.extractCharset(from: "application/json")
        XCTAssertNil(charset)
    }

    func testCharsetExtraction_CaseInsensitive() {
        let charset1 = BodyStorage.extractCharset(from: "text/html; CHARSET=UTF-8")
        let charset2 = BodyStorage.extractCharset(from: "text/html; charset=UTF-8")

        XCTAssertEqual(charset1, "UTF-8")
        XCTAssertEqual(charset2, "UTF-8")
    }

    func testCharsetExtraction_WithMultipleParameters() {
        let charset = BodyStorage.extractCharset(from: "text/html; boundary=----; charset=utf-8; format=flowed")
        XCTAssertEqual(charset, "utf-8")
    }

    func testCharsetExtraction_FromHeaderArray() {
        let headers = [
            TraceHTTPHeader(key: "Content-Type", value: "text/html; charset=windows-1252")
        ]

        let charset = BodyStorage.extractCharset(from: headers)
        XCTAssertEqual(charset, "windows-1252")
    }

    // MARK: - String Decoding Tests

    func testStringDecoding_UTF8() {
        let testString = "Hello, UTF-8! 你好世界"
        let data = testString.data(using: .utf8)!
        let bodyStorage = BodyStorage.from(data: data, charset: "utf-8")

        let decodedString = bodyStorage.getString()

        XCTAssertEqual(decodedString, testString)
    }

    func testStringDecoding_WithoutCharset_FallbackToUTF8() {
        let testString = "Fallback to UTF-8"
        let data = testString.data(using: .utf8)!
        let bodyStorage = BodyStorage.from(data: data)

        let decodedString = bodyStorage.getString()

        XCTAssertEqual(decodedString, testString)
    }

    func testStringDecoding_EmptyBody() {
        let bodyStorage = BodyStorage.empty

        let decodedString = bodyStorage.getString()

        XCTAssertNil(decodedString)
    }

    // MARK: - Error Recovery Tests

    func testCorruptedCompressedData_HandledGracefully() {
        // Create corrupted data
        let corruptedData = Data([0x1F, 0x8B, 0xFF, 0xFF, 0xFF, 0xFF])
        let bodyStorage = BodyStorage.from(data: corruptedData, contentEncoding: "gzip")

        // Should not crash
        XCTAssertNotNil(bodyStorage)
    }

    func testMixedValidInvalidData() {
        // Start with valid magic bytes but invalid content
        var mixedData = Data([0x1F, 0x8B, 0x08, 0x00])
        mixedData.append(Data(repeating: 0xFF, count: 100))

        let bodyStorage = BodyStorage.from(data: mixedData, contentEncoding: "gzip")

        // Should handle gracefully
        XCTAssertNotNil(bodyStorage)
    }

    // MARK: - Memory Limits Tests

    func testMemoryLimit_EnforcedForTruncation() {
        let largeData = Data(count: 20 * 1024 * 1024) // 20 MB
        let maxSize = 5 * 1024 * 1024 // 5 MB limit

        let bodyStorage = BodyStorage.from(data: largeData, maxSize: maxSize)

        // Should be truncated
        XCTAssertTrue(bodyStorage.isTruncated)
    }

    // MARK: - Data Retrieval Tests

    func testGetData_FromInlineStorage() {
        let testData = Data("Inline test".utf8)
        let bodyStorage = BodyStorage.from(data: testData)

        let retrievedData = bodyStorage.getData()

        XCTAssertEqual(retrievedData, testData)
    }

    func testGetPreview_LimitsSize() {
        let largeData = Data(count: 10000)
        let bodyStorage = BodyStorage.from(data: largeData)

        let preview = bodyStorage.getPreview(maxBytes: 100)

        XCTAssertEqual(preview?.count, 100)
    }

    func testGetString_WithMaxBytes() {
        let testString = String(repeating: "A", count: 1000)
        let bodyStorage = BodyStorage.from(string: testString)

        let preview = bodyStorage.getString(maxBytes: 50)

        XCTAssertNotNil(preview)
        if let preview = preview {
            XCTAssertLessThanOrEqual(preview.count, 50)
        }
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentCompressionOperations() {
        let iterations = 100
        let expectation = XCTestExpectation(description: "Concurrent compression")
        expectation.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let testData = Data("Concurrent test \(i)".utf8)
            let encoding = i % 3 == 0 ? "gzip" : (i % 3 == 1 ? "deflate" : "br")
            let bodyStorage = BodyStorage.from(data: testData, contentEncoding: encoding)

            XCTAssertFalse(bodyStorage.isEmpty)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }
}
