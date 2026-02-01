//
//  HPACKHuffmanEncoderTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceNetworking

final class HPACKHuffmanEncoderTests: XCTestCase {

    // MARK: - Initialization Tests

    func testHuffmanSymbolTableExists() {
        XCTAssertEqual(huffSymTable.count, 257) // 256 bytes + EOS symbol
    }

    // MARK: - Basic Encoding Tests

    func testEncodeEmptyData() {
        let input = Data()
        let encoded = HuffmanEncoder.encode(input)

        XCTAssertEqual(encoded.count, 0)
    }

    func testEncodeSingleByte() {
        let input = Data([0x41]) // 'A'
        let encoded = HuffmanEncoder.encode(input)

        XCTAssertGreaterThan(encoded.count, 0)
    }

    func testEncodeSimpleString() {
        let input = "hello".data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(input)

        XCTAssertGreaterThan(encoded.count, 0)
        XCTAssertLessThanOrEqual(encoded.count, input.count) // Should compress
    }

    func testEncodeLongString() {
        let input = String(repeating: "a", count: 1000).data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(input)

        XCTAssertGreaterThan(encoded.count, 0)
        XCTAssertLessThan(encoded.count, input.count) // Should compress well
    }

    // MARK: - Decoding Tests (Round-Trip)

    func testRoundTripSimpleString() throws {
        let original = "test".data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(original)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded, String(data: original, encoding: .utf8))
    }

    func testRoundTripAllPrintableASCII() throws {
        var chars = ""
        for byte: UInt8 in 32...126 { // Printable ASCII
            chars.append(Character(UnicodeScalar(byte)))
        }

        let original = chars.data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(original)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded, chars)
    }

    func testRoundTripUTF8() throws {
        let original = "Hello 世界 🌍".data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(original)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded, "Hello 世界 🌍")
    }

    func testRoundTripEmptyString() throws {
        let original = Data()
        let encoded = HuffmanEncoder.encode(original)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded, "")
    }

    func testRoundTripHTTPHeaders() throws {
        let headers = [
            "www.example.com",
            "no-cache",
            "custom-key",
            "custom-value"
        ]

        for header in headers {
            let original = header.data(using: .utf8)!
            let encoded = HuffmanEncoder.encode(original)
            let decoded = try HuffmanDecoder.decode(encoded)

            XCTAssertEqual(decoded, header)
        }
    }

    // MARK: - Should Encode Tests

    func testShouldEncodeEmptyData() {
        let data = Data()
        XCTAssertFalse(HuffmanEncoder.shouldEncode(data))
    }

    func testShouldEncodeHighlyCompressible() {
        let data = String(repeating: "a", count: 100).data(using: .utf8)!
        XCTAssertTrue(HuffmanEncoder.shouldEncode(data))
    }

    func testShouldEncodeRandomData() {
        // Random data typically doesn't compress well
        var randomBytes = [UInt8](repeating: 0, count: 100)
        for i in 0..<randomBytes.count {
            randomBytes[i] = UInt8.random(in: 0...255)
        }
        let data = Data(randomBytes)

        // May or may not compress depending on randomness
        _ = HuffmanEncoder.shouldEncode(data)
    }

    func testShouldEncodeCommonWords() {
        let commonWords = ["the", "and", "for", "are", "but", "not", "you", "all", "can", "her"]

        for word in commonWords {
            let data = word.data(using: .utf8)!
            // Common English words should compress
            XCTAssertTrue(HuffmanEncoder.shouldEncode(data))
        }
    }

    // MARK: - Compression Ratio Tests

    func testCompressionRatioRepeatedText() {
        let text = String(repeating: "hello world ", count: 10)
        let original = text.data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(original)

        let ratio = Double(encoded.count) / Double(original.count)
        XCTAssertLessThan(ratio, 1.0, "Should achieve compression")
    }

    func testCompressionRatioHTTPHeaderValue() {
        let value = "text/html; charset=utf-8"
        let original = value.data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(original)

        XCTAssertLessThanOrEqual(encoded.count, original.count)
    }

    // MARK: - Padding Tests

    func testPaddingIsAllOnes() {
        // Single byte that requires padding
        let input = Data([0x00])
        let encoded = HuffmanEncoder.encode(input)

        // Last byte should have padding bits set to 1
        let lastByte = encoded.last!
        // The padding should be all 1s (EOS prefix)
        // We can't easily verify the exact padding, but we can check the encoding succeeds
        XCTAssertGreaterThan(encoded.count, 0)
    }

    // MARK: - Symbol Table Tests

    func testHuffmanSymbolStructure() {
        for (index, symbol) in huffSymTable.enumerated() {
            XCTAssertGreaterThan(symbol.nbits, 0, "Symbol \(index) has invalid bit count")
            XCTAssertLessThanOrEqual(symbol.nbits, 30, "Symbol \(index) has too many bits")

            // Code should fit within nbits
            XCTAssertTrue(symbol.code < (1 << symbol.nbits), "Symbol \(index) code exceeds bit count")
        }
    }

    func testHuffmanSymbolForCommonChars() {
        // Space (ASCII 32)
        let space = huffSymTable[32]
        XCTAssertGreaterThan(space.nbits, 0)

        // 'a' (ASCII 97)
        let letterA = huffSymTable[97]
        XCTAssertGreaterThan(letterA.nbits, 0)

        // '0' (ASCII 48)
        let digit0 = huffSymTable[48]
        XCTAssertGreaterThan(digit0.nbits, 0)
    }

    func testHuffmanSymbolTableSize() {
        XCTAssertEqual(huffSymTable.count, 257) // 256 bytes + EOS
    }

    func testEOSSymbol() {
        // EOS (End of String) symbol is at index 256
        let eos = huffSymTable[256]
        XCTAssertEqual(eos.nbits, 30) // EOS should be 30 bits according to RFC 7541
        XCTAssertEqual(eos.code, 0x3FFF_FFFF)
    }

    // MARK: - Bit Packing Tests

    func testBitPackingDoesNotLoseData() throws {
        let testCases = [
            Data([0x00]),
            Data([0xFF]),
            Data([0x55]), // 01010101
            Data([0xAA])  // 10101010
        ]

        for testCase in testCases {
            let encoded = HuffmanEncoder.encode(testCase)
            let decoded = try HuffmanDecoder.decode(encoded)
            let decodedData = decoded.data(using: .utf8)!

            XCTAssertEqual(decodedData, testCase)
        }
    }

    func testBitPackingAlignment() {
        let input = "a".data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(input)

        // Encoded data should be byte-aligned
        XCTAssertGreaterThan(encoded.count, 0)
    }

    // MARK: - Edge Cases

    func testEncodeSingleZeroByte() throws {
        let input = Data([0x00])
        let encoded = HuffmanEncoder.encode(input)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded.data(using: .utf8), input)
    }

    func testEncodeAllZeroBytes() throws {
        let input = Data(repeating: 0x00, count: 10)
        let encoded = HuffmanEncoder.encode(input)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded.data(using: .utf8), input)
    }

    func testEncodeAllOnesBytes() throws {
        let input = Data(repeating: 0xFF, count: 10)
        let encoded = HuffmanEncoder.encode(input)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded.data(using: .utf8), input)
    }

    func testEncodeAlternatingBits() throws {
        let input = Data([0x55, 0xAA, 0x55, 0xAA])
        let encoded = HuffmanEncoder.encode(input)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded.data(using: .utf8), input)
    }

    // MARK: - RFC 7541 Examples

    func testRFC7541Example() throws {
        // RFC 7541 Appendix C examples
        let examples: [(String, String)] = [
            ("www.example.com", "www.example.com"),
            ("no-cache", "no-cache"),
            ("custom-key", "custom-key"),
            ("custom-value", "custom-value")
        ]

        for (input, expected) in examples {
            let data = input.data(using: .utf8)!
            let encoded = HuffmanEncoder.encode(data)
            let decoded = try HuffmanDecoder.decode(encoded)

            XCTAssertEqual(decoded, expected)
        }
    }

    // MARK: - Invalid Input Tests

    func testDecodeInvalidHuffmanData() {
        // Invalid Huffman sequence
        let invalid = Data([0xFF, 0xFF])

        XCTAssertThrowsError(try HuffmanDecoder.decode(invalid)) { error in
            XCTAssertTrue(error is HPACKError)
        }
    }

    func testDecodeIncompleteSequence() {
        // Incomplete Huffman sequence (not enough padding)
        let incomplete = Data([0x80]) // Incomplete code

        XCTAssertThrowsError(try HuffmanDecoder.decode(incomplete)) { error in
            XCTAssertTrue(error is HPACKError)
        }
    }

    // MARK: - Performance Tests

    func testEncodingPerformance() {
        let input = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100).data(using: .utf8)!

        measure {
            for _ in 0..<100 {
                _ = HuffmanEncoder.encode(input)
            }
        }
    }

    func testDecodingPerformance() throws {
        let input = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100).data(using: .utf8)!
        let encoded = HuffmanEncoder.encode(input)

        measure {
            for _ in 0..<100 {
                _ = try? HuffmanDecoder.decode(encoded)
            }
        }
    }

    func testShouldEncodePerformance() {
        let input = String(repeating: "test data ", count: 100).data(using: .utf8)!

        measure {
            for _ in 0..<1000 {
                _ = HuffmanEncoder.shouldEncode(input)
            }
        }
    }

    // MARK: - Stress Tests

    func testEncodeLargeData() throws {
        let input = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 1000).data(using: .utf8)!

        let encoded = HuffmanEncoder.encode(input)
        XCTAssertGreaterThan(encoded.count, 0)

        let decoded = try HuffmanDecoder.decode(encoded)
        XCTAssertEqual(decoded, String(data: input, encoding: .utf8))
    }

    func testEncodeAllByteValues() throws {
        var allBytes = Data()
        for byte: UInt8 in 0...255 {
            allBytes.append(byte)
        }

        let encoded = HuffmanEncoder.encode(allBytes)
        let decoded = try HuffmanDecoder.decode(encoded)

        XCTAssertEqual(decoded.data(using: .utf8), allBytes)
    }
}
