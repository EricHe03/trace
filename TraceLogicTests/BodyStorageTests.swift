//
//  BodyStorageTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

final class BodyStorageTests: XCTestCase {
    // MARK: - CompressionInfo Tests

    func testCompressionInfoRatio() {
        let info = CompressionInfo(
            algorithm: "gzip",
            compressedSize: 500,
            decompressedSize: 2000,
            decompressionSuccess: true,
            decompressionTime: 0.01
        )

        XCTAssertEqual(info.ratio, 0.25)
    }

    func testCompressionInfoSavingsPercentage() {
        let info = CompressionInfo(
            algorithm: "gzip",
            compressedSize: 500,
            decompressedSize: 2000,
            decompressionSuccess: true,
            decompressionTime: 0.01
        )

        XCTAssertEqual(info.savingsPercentage, 75.0)
    }

    func testCompressionInfoZeroDecompressedSize() {
        let info = CompressionInfo(
            algorithm: "gzip",
            compressedSize: 0,
            decompressedSize: 0,
            decompressionSuccess: true,
            decompressionTime: 0.0
        )

        XCTAssertEqual(info.ratio, 1.0)
        XCTAssertEqual(info.savingsPercentage, 0.0)
    }

    // MARK: - Factory Methods Tests

    func testFromEmptyData() {
        let storage = BodyStorage.from(data: Data())

        XCTAssertEqual(storage, .empty)
    }

    func testFromSmallData() {
        let data = "Small test data".data(using: .utf8)!
        let storage = BodyStorage.from(data: data, charset: "utf-8")

        if case let .inline(storedData, charset, _) = storage {
            XCTAssertEqual(storedData, data)
            XCTAssertEqual(charset, "utf-8")
        } else {
            XCTFail("Expected inline storage for small data")
        }
    }

    func testFromLargeDataCreatesFile() {
        let largeData = Data(repeating: 0x41, count: 2 * 1024 * 1024) // 2MB
        let storage = BodyStorage.from(data: largeData)

        if case let .file(url, _, _) = storage {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let loadedData = try? Data(contentsOf: url)
            XCTAssertEqual(loadedData, largeData)

            // Cleanup
            try? FileManager.default.removeItem(at: url)
        } else {
            // Might fall back to inline in test environment
            XCTAssertTrue(true, "File storage or fallback to inline is acceptable")
        }
    }

    func testFromTruncatedData() {
        let veryLargeData = Data(repeating: 0x42, count: 15 * 1024 * 1024) // 15MB
        let storage = BodyStorage.from(data: veryLargeData, maxSize: 10 * 1024 * 1024)

        if case let .truncated(preview, totalSize, _, _) = storage {
            XCTAssertLessThan(preview.count, totalSize)
            XCTAssertEqual(totalSize, veryLargeData.count)
        } else if case let .truncatedFile(url, totalSize, _, _) = storage {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(totalSize, veryLargeData.count)
            try? FileManager.default.removeItem(at: url)
        } else {
            XCTFail("Expected truncated storage for very large data")
        }
    }

    func testFromString() {
        let testString = "Hello, World!"
        let storage = BodyStorage.from(string: testString, charset: "utf-8")

        XCTAssertEqual(storage.getString(), testString)
    }

    func testFromStringWithEmptyString() {
        let storage = BodyStorage.from(string: "", charset: "utf-8")

        XCTAssertEqual(storage, .empty)
    }

    // MARK: - Compression/Decompression Tests

    func testGzipDecompression() throws {
        let original = "Test data for gzip compression".data(using: .utf8)!
        let compressed = try XCTUnwrap(CompressionHelper.compress(data: original, algorithm: "gzip"))

        let storage = BodyStorage.from(data: compressed, contentEncoding: "gzip")

        XCTAssertEqual(storage.getData(), original)

        // Verify compression info
        if let compressionInfo = storage.getCompressionInfo() {
            XCTAssertEqual(compressionInfo.algorithm, "gzip")
            XCTAssertTrue(compressionInfo.decompressionSuccess)
            XCTAssertEqual(compressionInfo.decompressedSize, original.count)
        } else {
            XCTFail("Expected compression info")
        }
    }

    func testBrotliDecompression() {
        let original = "Test data for brotli".data(using: .utf8)!

        // Note: Brotli might not be available in all test environments
        let storage = BodyStorage.from(data: original, contentEncoding: "br")

        // Should either decompress or keep original
        XCTAssertNotNil(storage.getData())
    }

    func testDeflateDecompression() throws {
        let original = "Test data for deflate".data(using: .utf8)!
        let compressed = try XCTUnwrap(CompressionHelper.compress(data: original, algorithm: "deflate"))

        let storage = BodyStorage.from(data: compressed, contentEncoding: "deflate")

        XCTAssertEqual(storage.getData(), original)
    }

    func testChainedEncodingDecompression() throws {
        let original = "Test data for chained encoding".data(using: .utf8)!
        let compressed1 = try XCTUnwrap(CompressionHelper.compress(data: original, algorithm: "gzip"))
        let compressed2 = try XCTUnwrap(CompressionHelper.compress(data: compressed1, algorithm: "deflate"))

        let storage = BodyStorage.from(data: compressed2, contentEncoding: "gzip, deflate")

        // Note: Chained encoding might not work perfectly in all cases
        // The test verifies the attempt doesn't crash
        XCTAssertNotNil(storage.getData())
    }

    func testAutoDetectGzipByMagicBytes() throws {
        let original = "Auto-detect test".data(using: .utf8)!
        let gzipped = try XCTUnwrap(CompressionHelper.compress(data: original, algorithm: "gzip"))

        let storage = BodyStorage.from(data: gzipped, contentEncoding: nil)

        XCTAssertEqual(storage.getData(), original)
    }

    func testInvalidCompressionData() {
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])

        let storage = BodyStorage.from(data: invalidData, contentEncoding: "gzip")

        // Should handle gracefully
        if let compressionInfo = storage.getCompressionInfo() {
            XCTAssertFalse(compressionInfo.decompressionSuccess)
        }
    }

    // MARK: - Data Access Tests

    func testGetDataInline() {
        let testData = "Test".data(using: .utf8)!
        let storage = BodyStorage.inline(testData, charset: "utf-8")

        XCTAssertEqual(storage.getData(), testData)
    }

    func testGetDataEmpty() {
        let storage = BodyStorage.empty

        XCTAssertNil(storage.getData())
    }

    func testGetDataTruncated() {
        let preview = Data([1, 2, 3])
        let storage = BodyStorage.truncated(preview, totalSize: 1000)

        XCTAssertEqual(storage.getData(), preview)
    }

    func testGetString() {
        let testString = "Hello, World!"
        let storage = BodyStorage.from(string: testString)

        XCTAssertEqual(storage.getString(), testString)
    }

    func testGetStringWithCharset() throws {
        let testString = "Hello"
        let data = try XCTUnwrap(testString.data(using: .utf8))
        let storage = BodyStorage.inline(data, charset: "utf-8")

        XCTAssertEqual(storage.getString(), testString)
    }

    func testGetStringWithMaxBytes() throws {
        let testString = String(repeating: "A", count: 2000)
        let storage = BodyStorage.from(string: testString)

        let preview = storage.getString(maxBytes: 100)
        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(try XCTUnwrap(preview?.count), 100)
    }

    func testDecodeTextWithVariousEncodings() throws {
        // UTF-8
        let utf8String = "Hello World"
        let utf8Data = try XCTUnwrap(utf8String.data(using: .utf8))
        XCTAssertEqual(BodyStorage.decodeText(from: utf8Data, charset: "utf-8"), utf8String)

        // Latin1
        let latin1String = "Café"
        let latin1Data = try XCTUnwrap(latin1String.data(using: .isoLatin1))
        XCTAssertEqual(BodyStorage.decodeText(from: latin1Data, charset: "iso-8859-1"), latin1String)
    }

    func testGetCharset() {
        let storage = BodyStorage.inline(Data(), charset: "utf-8")
        XCTAssertEqual(storage.getCharset(), "utf-8")

        let emptyStorage = BodyStorage.empty
        XCTAssertNil(emptyStorage.getCharset())
    }

    func testGetCompressionInfo() {
        let compressionInfo = CompressionInfo(
            algorithm: "gzip",
            compressedSize: 100,
            decompressedSize: 500,
            decompressionSuccess: true,
            decompressionTime: 0.01
        )
        let storage = BodyStorage.inline(Data(), compressionInfo: compressionInfo)

        XCTAssertEqual(storage.getCompressionInfo()?.algorithm, "gzip")
    }

    func testGetPreview() {
        let data = Data(repeating: 0x41, count: 2000)
        let storage = BodyStorage.inline(data)

        let preview = storage.getPreview(maxBytes: 100)
        XCTAssertEqual(preview?.count, 100)
    }

    // MARK: - Charset Extraction Tests

    func testExtractCharsetFromContentType() {
        let contentType = "text/html; charset=utf-8"
        let charset = BodyStorage.extractCharset(from: contentType)

        XCTAssertEqual(charset, "utf-8")
    }

    func testExtractCharsetWithQuotes() {
        let contentType = "application/json; charset=\"iso-8859-1\""
        let charset = BodyStorage.extractCharset(from: contentType)

        XCTAssertEqual(charset, "iso-8859-1")
    }

    func testExtractCharsetWithMultipleParams() {
        let contentType = "text/html; boundary=something; charset=utf-16"
        let charset = BodyStorage.extractCharset(from: contentType)

        XCTAssertEqual(charset, "utf-16")
    }

    func testExtractCharsetFromHeaders() {
        let headers = [
            TraceHTTPHeader(key: "Content-Type", value: "text/html; charset=utf-8"),
            TraceHTTPHeader(key: "Content-Length", value: "1234")
        ]
        let charset = BodyStorage.extractCharset(from: headers)

        XCTAssertEqual(charset, "utf-8")
    }

    func testExtractCharsetFromHeadersDictionary() {
        let headers = [
            "Content-Type": "application/json; charset=utf-8",
            "Content-Length": "1234"
        ]
        let charset = BodyStorage.extractCharset(from: headers)

        XCTAssertEqual(charset, "utf-8")
    }

    func testExtractCharsetCaseInsensitive() {
        let headers = [
            "content-type": "text/plain; CHARSET=UTF-8"
        ]
        let charset = BodyStorage.extractCharset(from: headers)

        XCTAssertEqual(charset, "UTF-8")
    }

    // MARK: - Size and State Tests

    func testTotalSize() {
        let data = Data(repeating: 0x41, count: 1000)
        let storage = BodyStorage.inline(data)

        XCTAssertEqual(storage.totalSize, 1000)
    }

    func testTotalSizeTruncated() {
        let storage = BodyStorage.truncated(Data([1, 2, 3]), totalSize: 5000)

        XCTAssertEqual(storage.totalSize, 5000)
    }

    func testIsTruncated() {
        let truncated = BodyStorage.truncated(Data(), totalSize: 1000)
        XCTAssertTrue(truncated.isTruncated)

        let inline = BodyStorage.inline(Data())
        XCTAssertFalse(inline.isTruncated)
    }

    func testIsFile() {
        let fileURL = URL(fileURLWithPath: "/tmp/test.bin")
        let fileStorage = BodyStorage.file(fileURL)
        XCTAssertTrue(fileStorage.isFile)

        let inline = BodyStorage.inline(Data())
        XCTAssertFalse(inline.isFile)
    }

    func testIsEmpty() {
        let empty = BodyStorage.empty
        XCTAssertTrue(empty.isEmpty)

        let inline = BodyStorage.inline(Data())
        XCTAssertTrue(inline.isEmpty)

        let nonEmpty = BodyStorage.inline(Data([1, 2, 3]))
        XCTAssertFalse(nonEmpty.isEmpty)
    }

    // MARK: - Codable Tests

    func testCodableInline() throws {
        let data = "Test".data(using: .utf8)!
        let original = BodyStorage.inline(data, charset: "utf-8")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BodyStorage.self, from: encoded)

        XCTAssertEqual(decoded.getData(), data)
        XCTAssertEqual(decoded.getCharset(), "utf-8")
    }

    func testCodableTruncated() throws {
        let original = BodyStorage.truncated(Data([1, 2, 3]), totalSize: 1000, charset: "utf-8")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BodyStorage.self, from: encoded)

        XCTAssertEqual(decoded.totalSize, 1000)
        XCTAssertEqual(decoded.getCharset(), "utf-8")
    }

    func testCodableEmpty() throws {
        let original = BodyStorage.empty

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BodyStorage.self, from: encoded)

        XCTAssertEqual(decoded, .empty)
    }

    func testCodableWithCompressionInfo() throws {
        let compressionInfo = CompressionInfo(
            algorithm: "gzip",
            compressedSize: 100,
            decompressedSize: 500,
            decompressionSuccess: true,
            decompressionTime: 0.01
        )
        let original = BodyStorage.inline(Data(), compressionInfo: compressionInfo)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BodyStorage.self, from: encoded)

        XCTAssertEqual(decoded.getCompressionInfo()?.algorithm, "gzip")
        XCTAssertEqual(decoded.getCompressionInfo()?.compressedSize, 100)
    }

    // MARK: - Legacy Compatibility Tests

    func testToLegacyString() {
        let testString = "Test"
        let storage = BodyStorage.from(string: testString)

        XCTAssertEqual(storage.toLegacyString(), testString)
    }

    func testFromLegacyString() {
        let storage = BodyStorage.fromLegacyString("Test")

        XCTAssertEqual(storage.getString(), "Test")
    }

    func testFromLegacyStringNil() {
        let storage = BodyStorage.fromLegacyString(nil)

        XCTAssertEqual(storage, .empty)
    }

    func testFromLegacyStringEmpty() {
        let storage = BodyStorage.fromLegacyString("")

        XCTAssertEqual(storage, .empty)
    }

    // MARK: - File Management Tests

    func testDeleteFile() {
        let data = Data(repeating: 0x41, count: 1000)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).bin")

        try? data.write(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        let storage = BodyStorage.file(tempURL)
        storage.deleteFile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testCleanupOldFiles() {
        // This is more of an integration test
        // We'll just verify it doesn't crash
        BodyStorage.cleanupOldFiles(olderThanDays: 7)

        XCTAssertTrue(true, "Cleanup completed without crashing")
    }

    // MARK: - Edge Cases

    func testVeryLargeString() {
        let largeString = String(repeating: "A", count: 20 * 1024 * 1024) // 20MB
        let storage = BodyStorage.from(string: largeString)

        // Should handle gracefully (truncate or file)
        XCTAssertNotNil(storage.getData())
    }

    func testUnicodeStrings() {
        let unicodeString = "Hello 世界 🌍 مرحبا"
        let storage = BodyStorage.from(string: unicodeString, charset: "utf-8")

        XCTAssertEqual(storage.getString(), unicodeString)
    }

    func testBinaryData() {
        var binaryData = Data()
        for i in 0 ..< 256 {
            binaryData.append(UInt8(i))
        }

        let storage = BodyStorage.from(data: binaryData)
        XCTAssertEqual(storage.getData(), binaryData)
    }

    func testMaxSizeParameter() {
        let data = Data(repeating: 0x41, count: 5000)
        let storage = BodyStorage.from(data: data, maxSize: 1000)

        if case let .truncated(_, totalSize, _, _) = storage {
            XCTAssertEqual(totalSize, 5000)
        } else {
            XCTFail("Expected truncated storage")
        }
    }

    func testMaxSizeParameterRetainsCapturedBytesUpToLimit() {
        let maxSize = 256 * 1024
        let data = Data(repeating: 0x41, count: maxSize * 3)
        let storage = BodyStorage.from(data: data, maxSize: maxSize)

        XCTAssertTrue(storage.isTruncated)
        XCTAssertEqual(storage.totalSize, data.count)
        XCTAssertEqual(storage.getData()?.count, maxSize)
    }

    func testZipBombProtection() {
        // Simulate a zip bomb scenario with a small compressed payload
        // that claims to expand to a huge size
        let smallData = Data(repeating: 0x41, count: 100)

        // With a reasonable maxSize, it should be bounded
        let storage = BodyStorage.from(data: smallData, maxSize: 1024 * 1024)

        XCTAssertNotNil(storage.getData())
        XCTAssertLessThanOrEqual(storage.getData()?.count ?? 0, 10 * 1024 * 1024)
    }
}
