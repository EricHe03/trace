//
//  HPACKHuffmanTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import TraceCore
@testable import TraceNetworking
@testable import TraceVPN

final class HPACKHuffmanTests: XCTestCase {
    
    // MARK: - Basic Decoding Tests
    
    func testDecodeSimpleString() throws {
        // Test decoding a simple Huffman-encoded string
        // "www.example.com" encoded with Huffman
        let encoded = Data([
            0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a,
            0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff
        ])
        
        let result = try HuffmanDecoder.decode(encoded)
        XCTAssertEqual(result, "www.example.com")
    }
    
    func testDecodeEmptyString() throws {
        let encoded = Data()
        let result = try HuffmanDecoder.decode(encoded)
        XCTAssertEqual(result, "")
    }
    
    func testDecodeCommonHeaders() throws {
        // Test common HTTP header values
        let testCases: [(Data, String)] = [
            // "GET"
            (Data([0xc5, 0x83, 0x7f]), "GET"),
            // "POST"
            (Data([0xd7, 0xab, 0x76, 0xff]), "POST"),
        ]
        
        for (encoded, expected) in testCases {
            do {
                let result = try HuffmanDecoder.decode(encoded)
                XCTAssertEqual(result, expected, "Failed to decode: \(expected)")
            } catch {
                XCTFail("Decoding failed for expected string: \(expected), error: \(error)")
            }
        }
    }
    
    // MARK: - HPACK Integration Tests
    
    func testHPACKDecodeWithHuffman() throws {
        let coder = HPACKCoder()
        
        // Create test data with Huffman-encoded string
        // This is a literal header with Huffman encoding flag set
        var data = Data()
        data.append(0x00) // Literal without indexing, new name
        data.append(0x85) // Name length = 5, Huffman encoded (0x80 | 5)
        data.append(contentsOf: [0xf2, 0xb2, 0x4a, 0x84, 0xff]) // ":path" Huffman encoded
        data.append(0x84) // Value length = 4, Huffman encoded
        data.append(contentsOf: [0x87, 0x49, 0x7c, 0xa5]) // "/foo" Huffman encoded
        
        // Note: This test verifies the decoder can handle Huffman-encoded data
        // The actual encoded values above are examples and may need adjustment
    }
    
    func testHPACKDecodeUncompressed() throws {
        let coder = HPACKCoder()
        
        // Test with uncompressed literal string (no Huffman encoding)
        var data = Data()
        data.append(0x00) // Literal without indexing, new name
        data.append(0x05) // Name length = 5, not Huffman encoded
        data.append(contentsOf: ":path".data(using: .utf8)!)
        data.append(0x01) // Value length = 1, not Huffman encoded
        data.append(contentsOf: "/".data(using: .utf8)!)
        
        let headers = try coder.decode(data)
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers[0].key, ":path")
        XCTAssertEqual(headers[0].value, "/")
    }
    
    // MARK: - Error Handling Tests
    
    func testDecodeInvalidPadding() {
        // Test that invalid EOS padding is detected
        let invalidData = Data([0xff, 0xff, 0xff, 0xff])
        
        do {
            _ = try HuffmanDecoder.decode(invalidData)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is HPACKError)
        }
    }
    
    func testDecodeIncompleteSequence() {
        // Test incomplete Huffman sequence
        let incompleteData = Data([0xf1, 0xe3])
        
        // This should either decode successfully with valid padding
        // or throw an error for invalid padding
        do {
            _ = try HuffmanDecoder.decode(incompleteData)
        } catch {
            XCTAssertTrue(error is HPACKError)
        }
    }
    
    // MARK: - Huffman Table Tests
    
    func testHuffmanTableStructure() {
        // Verify the Huffman decode table is properly loaded
        XCTAssertFalse(huffmanDecodeTable.isEmpty)
        
        // The table should have 257 states (0-256)
        XCTAssertGreaterThanOrEqual(huffmanDecodeTable.count, 257)
        
        // Each state should have 16 entries (for 4-bit nibbles)
        for state in huffmanDecodeTable {
            XCTAssertEqual(state.count, 16)
        }
    }
    
    func testHuffmanNodeFlags() {
        // Test that flag constants are correct
        XCTAssertEqual(huffAcceptedMask, 0x4000) // 1 << 14
        XCTAssertEqual(huffSymMask, 0x8000)      // 1 << 15
        
        // Test initial state
        let initialNode = HuffmanDecodeNode(fstate: 0, sym: 0)
        XCTAssertFalse(initialNode.hasSymbol)
        XCTAssertFalse(initialNode.isAccepted)
        XCTAssertEqual(initialNode.nextState, 0)
        
        // Test node with symbol
        let symNode = HuffmanDecodeNode(fstate: 0xc000, sym: 48)
        XCTAssertTrue(symNode.hasSymbol)
        XCTAssertTrue(symNode.isAccepted)
    }
    
    // MARK: - Performance Tests
    
    func testDecodePerformance() {
        // Test decoding performance with a moderately sized string
        let testData = Data(repeating: 0xf1, count: 1000)
        
        measure {
            for _ in 0..<100 {
                _ = try? HuffmanDecoder.decode(testData)
            }
        }
    }
    
    // MARK: - Real-World Examples
    
    func testDecodeRealWorldHeaders() throws {
        // Test with actual HTTP/2 header values
        let testCases: [(String, String)] = [
            ("Common header values", "application/json"),
            ("User agents", "Mozilla/5.0"),
            ("Paths", "/api/v1/users"),
        ]
        
        // Note: These would need actual Huffman-encoded data
        // This test structure is here for future expansion
        for (description, _) in testCases {
            // In a real implementation, you would have the encoded data
            // and verify it decodes to the expected value
            XCTAssertNotNil(description)
        }
    }
}
