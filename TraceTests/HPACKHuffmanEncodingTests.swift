//
//  HPACKHuffmanEncodingTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import TraceCore
@testable import TraceNetworking
@testable import TraceVPN

final class HPACKHuffmanEncodingTests: XCTestCase {
    // MARK: - Basic Encoding Tests

    func testHuffmanEncoding_EmptyString_ReturnsEmpty() {
        let data = Data()
        let encoded = HuffmanEncoder.encode(data)
        XCTAssertTrue(encoded.isEmpty)
    }

    func testHuffmanEncoding_SingleCharacter_Encodes() {
        // 'a' (97) has code 0x3 with 5 bits
        let data = "a".data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(data)
        
        // 5 bits: 00011, padded with 111 to make 8 bits: 00011111 = 0x1F
        XCTAssertEqual(encoded.count, 1)
        XCTAssertEqual(encoded[0], 0x1F)
    }

    func testHuffmanEncoding_CommonString_Compresses() {
        let data = "www-authenticate".data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(data)
        
        // Should be smaller than original
        XCTAssertLessThan(encoded.count, data.count)
    }

    func testHuffmanEncoding_Roundtrip_PreservesData() throws {
        let original = "content-type"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    func testHuffmanEncoding_AllLowercase_Compresses() throws {
        let original = "abcdefghijklmnopqrstuvwxyz"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
        XCTAssertLessThan(encoded.count, originalData.count)
    }

    func testHuffmanEncoding_AllUppercase_Compresses() throws {
        let original = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    func testHuffmanEncoding_Digits_Compresses() throws {
        let original = "0123456789"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
        XCTAssertLessThan(encoded.count, originalData.count)
    }

    func testHuffmanEncoding_MixedCase_Compresses() throws {
        let original = "Content-Type"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    // MARK: - HTTP Header Tests

    func testHuffmanEncoding_CommonHeaderName_Compresses() throws {
        let headers = [
            "accept",
            "accept-encoding",
            "accept-language",
            "authorization",
            "cache-control",
            "content-type",
            "cookie",
            "host",
            "user-agent"
        ]
        
        for header in headers {
            let originalData = header.data(using: .utf8)!
            let encoded = HuffmanEncoder.encode(originalData)
            let decoded = try HuffmanDecoder.decode(encoded)
            
            XCTAssertEqual(decoded, header, "Failed for header: \(header)")
            XCTAssertLessThanOrEqual(encoded.count, originalData.count, "No compression for: \(header)")
        }
    }

    func testHuffmanEncoding_CommonHeaderValue_Compresses() throws {
        let values = [
            "application/json",
            "text/html",
            "gzip, deflate, br",
            "en-US,en;q=0.9",
            "max-age=3600",
            "no-cache",
            "Mozilla/5.0"
        ]
        
        for value in values {
            let originalData = value.data(using: .utf8)!
            let encoded = HuffmanEncoder.encode(originalData)
            let decoded = try HuffmanDecoder.decode(encoded)
            
            XCTAssertEqual(decoded, value, "Failed for value: \(value)")
        }
    }

    // MARK: - Edge Cases

    func testHuffmanEncoding_Space_Compresses() throws {
        let original = "hello world"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    func testHuffmanEncoding_SpecialCharacters_Encodes() throws {
        let original = "!@#$%^&*()"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    func testHuffmanEncoding_Slash_Encodes() throws {
        let original = "/api/v1/users"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    func testHuffmanEncoding_Colon_Encodes() throws {
        let original = "https://example.com:8080"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    func testHuffmanEncoding_Equals_Encodes() throws {
        let original = "key=value"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Compression Ratio Tests

    func testHuffmanEncoding_ShouldEncode_ReturnsTrueForCompressible() {
        // Common HTTP headers compress well
        let compressible = [
            "www-authenticate",
            "content-encoding",
            "accept-language"
        ]
        
        for str in compressible {
            let data = str.data(using: .utf8)!
            XCTAssertTrue(HuffmanEncoder.shouldEncode(data), "Should compress: \(str)")
        }
    }

    func testHuffmanEncoding_ShouldEncode_ReturnsFalseForEmpty() {
        let data = Data()
        XCTAssertFalse(HuffmanEncoder.shouldEncode(data))
    }

    func testHuffmanEncoding_CompressionRatio_IsReasonable() {
        let testStrings = [
            "accept": 0.7,  // Should compress to ~70% or less
            "content-type": 0.8,
            "www-authenticate": 0.75
        ]
        
        for (str, maxRatio) in testStrings {
            let originalData = str.data(using: .utf8)!
            let encoded = HuffmanEncoder.encode(originalData)
            let ratio = Double(encoded.count) / Double(originalData.count)
            
            XCTAssertLessThanOrEqual(ratio, maxRatio,
                "Compression ratio for '\(str)' is \(ratio), expected ≤ \(maxRatio)")
        }
    }

    // MARK: - Integration with HPACK

    func testHPACKEncoder_UsesHuffmanEncoding() throws {
        let coder = HPACKCoder()
        
        let headers = [
            TraceHTTPHeader(key: "content-type", value: "application/json"),
            TraceHTTPHeader(key: "accept", value: "application/json")
        ]
        
        let encoded = try coder.encode(headers)
        
        // Encoded data should exist
        XCTAssertFalse(encoded.isEmpty)
        
        // Decode to verify correctness
        let decoded = try coder.decode(encoded)
        XCTAssertEqual(decoded.count, headers.count)
        
        for (original, decoded) in zip(headers, decoded) {
            XCTAssertEqual(original.key.lowercased(), decoded.key.lowercased())
            XCTAssertEqual(original.value, decoded.value)
        }
    }

    func testHPACKEncoder_HuffmanRoundtrip_PreservesHeaders() throws {
        let coder = HPACKCoder()
        
        let headers = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":path", value: "/api/v1/users"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":authority", value: "example.com"),
            TraceHTTPHeader(key: "user-agent", value: "Mozilla/5.0"),
            TraceHTTPHeader(key: "accept", value: "application/json"),
            TraceHTTPHeader(key: "accept-encoding", value: "gzip, deflate, br")
        ]
        
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)
        
        XCTAssertEqual(decoded.count, headers.count)
        
        for (original, decoded) in zip(headers, decoded) {
            XCTAssertEqual(original.key.lowercased(), decoded.key.lowercased())
            XCTAssertEqual(original.value, decoded.value)
        }
    }

    // MARK: - Performance Tests

    func testHuffmanEncoding_Performance_LargeString() {
        let largeString = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 100)
        let data = largeString.data(using: .utf8)!
        
        measure {
            _ = HuffmanEncoder.encode(data)
        }
    }

    func testHuffmanEncoding_Performance_ManySmallStrings() {
        let strings = (0..<1000).map { "header-\($0)" }
        let dataArray = strings.map { $0.data(using: .utf8)! }
        
        measure {
            for data in dataArray {
                _ = HuffmanEncoder.encode(data)
            }
        }
    }

    // MARK: - Specific Byte Sequences

    func testHuffmanEncoding_AllZeros_Encodes() {
        let data = Data(repeating: 0, count: 10)
        let encoded = HuffmanEncoder.encode(data)
        
        // Should encode without crashing
        XCTAssertFalse(encoded.isEmpty)
    }

    func testHuffmanEncoding_AllOnes_Encodes() {
        let data = Data(repeating: 0xFF, count: 10)
        let encoded = HuffmanEncoder.encode(data)
        
        // Should encode without crashing
        XCTAssertFalse(encoded.isEmpty)
    }

    func testHuffmanEncoding_SequentialBytes_Encodes() {
        let data = Data((0..<256).map { UInt8($0 % 256) })
        let encoded = HuffmanEncoder.encode(data)
        
        // Should encode without crashing
        XCTAssertFalse(encoded.isEmpty)
    }

    // MARK: - Real-World Examples

    func testHuffmanEncoding_RealWorldURL_Compresses() throws {
        let original = "https://api.example.com/v1/users/123/profile?format=json&include=avatar"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
        XCTAssertLessThan(encoded.count, originalData.count)
    }

    func testHuffmanEncoding_RealWorldUserAgent_Compresses() throws {
        let original = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
    }

    func testHuffmanEncoding_RealWorldContentType_Compresses() throws {
        let original = "application/json; charset=utf-8"
        let originalData = original.data(using: .utf8)!
        
        let encoded = HuffmanEncoder.encode(originalData)
        let decoded = try HuffmanDecoder.decode(encoded)
        
        XCTAssertEqual(decoded, original)
        XCTAssertLessThan(encoded.count, originalData.count)
    }
}
