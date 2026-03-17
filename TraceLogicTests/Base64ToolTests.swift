//
//  Base64ToolTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceUI
import XCTest

final class Base64ToolTests: XCTestCase {
    // MARK: - Base64 Encoding Tests

    func testBase64Encoding() {
        let input = "Hello, World!"
        let expected = "SGVsbG8sIFdvcmxkIQ=="

        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data from string")
            return
        }

        let encoded = data.base64EncodedString()
        XCTAssertEqual(encoded, expected)
    }

    func testBase64EncodingEmpty() {
        let input = ""

        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data from string")
            return
        }

        let encoded = data.base64EncodedString()
        XCTAssertEqual(encoded, "")
    }

    func testBase64EncodingUnicode() {
        let input = "Hello 世界 🌍"

        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data from string")
            return
        }

        let encoded = data.base64EncodedString()
        XCTAssertFalse(encoded.isEmpty)

        // Verify it can be decoded back
        guard let decoded = Data(base64Encoded: encoded),
              let decodedString = String(data: decoded, encoding: .utf8) else {
            XCTFail("Failed to decode")
            return
        }

        XCTAssertEqual(decodedString, input)
    }

    func testBase64EncodingLongString() {
        let input = String(repeating: "A", count: 1000)

        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data from string")
            return
        }

        let encoded = data.base64EncodedString()
        XCTAssertFalse(encoded.isEmpty)

        // Verify it can be decoded back
        guard let decoded = Data(base64Encoded: encoded),
              let decodedString = String(data: decoded, encoding: .utf8) else {
            XCTFail("Failed to decode")
            return
        }

        XCTAssertEqual(decodedString, input)
    }

    // MARK: - Base64 Decoding Tests

    func testBase64Decoding() {
        let input = "SGVsbG8sIFdvcmxkIQ=="
        let expected = "Hello, World!"

        guard let data = Data(base64Encoded: input),
              let decoded = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to decode")
            return
        }

        XCTAssertEqual(decoded, expected)
    }

    func testBase64DecodingInvalid() {
        let input = "Invalid@Base64!"

        let data = Data(base64Encoded: input)
        XCTAssertNil(data)
    }

    func testBase64DecodingWithWhitespace() {
        let input = "SGVsbG8sIFdvcmxkIQ==   "
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to decode")
            return
        }

        XCTAssertEqual(decoded, "Hello, World!")
    }

    // MARK: - URL-Safe Base64 Tests

    func testURLSafeBase64Encoding() {
        let input = "Hello+World/Test="

        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data from string")
            return
        }

        var encoded = data.base64EncodedString()

        // Apply URL-safe transformation
        encoded = encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }

    func testURLSafeBase64Decoding() {
        // URL-safe encoded "Hello+World/Test="
        var input = "SGVsbG8rV29ybGQvVGVzdD0"

        // Add padding
        let remainder = input.count % 4
        if remainder > 0 {
            input += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: input),
              let decoded = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to decode")
            return
        }

        XCTAssertEqual(decoded, "Hello+World/Test=")
    }

    func testURLSafeBase64PaddingCalculation() {
        // Test padding calculation for different lengths
        let testCases: [(input: String, expectedPadding: Int)] = [
            ("ABC", 1), // 3 chars, needs 1 padding
            ("ABCD", 0), // 4 chars, needs 0 padding
            ("ABCDE", 3), // 5 chars, needs 3 padding
            ("ABCDEF", 2), // 6 chars, needs 2 padding
            ("ABCDEFGH", 0) // 8 chars, needs 0 padding
        ]

        for (input, expectedPadding) in testCases {
            let remainder = input.count % 4
            let actualPadding = remainder > 0 ? 4 - remainder : 0
            XCTAssertEqual(actualPadding, expectedPadding, "Failed for input: \(input)")
        }
    }

    // MARK: - Round-trip Tests

    func testBase64RoundTrip() {
        let testStrings = [
            "Hello, World!",
            "123456",
            "!@#$%^&*()",
            "The quick brown fox jumps over the lazy dog",
            ""
        ]

        for testString in testStrings {
            guard let data = testString.data(using: .utf8) else {
                XCTFail("Failed to create data")
                continue
            }

            let encoded = data.base64EncodedString()

            guard let decoded = Data(base64Encoded: encoded),
                  let decodedString = String(data: decoded, encoding: .utf8) else {
                XCTFail("Failed to decode")
                continue
            }

            XCTAssertEqual(decodedString, testString)
        }
    }

    func testURLSafeBase64RoundTrip() {
        let testStrings = [
            "Hello+World/Test",
            "URL/Safe+Base64=",
            "Test+/+Test"
        ]

        for testString in testStrings {
            guard let data = testString.data(using: .utf8) else {
                XCTFail("Failed to create data")
                continue
            }

            // Encode
            var encoded = data.base64EncodedString()
            encoded = encoded
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")

            // Decode
            var toDecode = encoded
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")

            // Add padding
            let remainder = toDecode.count % 4
            if remainder > 0 {
                toDecode += String(repeating: "=", count: 4 - remainder)
            }

            guard let decoded = Data(base64Encoded: toDecode),
                  let decodedString = String(data: decoded, encoding: .utf8) else {
                XCTFail("Failed to decode")
                continue
            }

            XCTAssertEqual(decodedString, testString)
        }
    }

    // MARK: - Binary Data Tests

    func testBase64EncodingBinaryData() {
        let binaryData = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD])
        let encoded = binaryData.base64EncodedString()

        XCTAssertFalse(encoded.isEmpty)

        guard let decoded = Data(base64Encoded: encoded) else {
            XCTFail("Failed to decode")
            return
        }

        XCTAssertEqual(decoded, binaryData)
    }
}
