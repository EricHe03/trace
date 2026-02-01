//
//  LogRedactionTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class LogRedactionTests: XCTestCase {

    // MARK: - Basic Hash Tests

    func testHashBasicString() {
        let input = "hello"
        let hash = LogRedaction.hash(input)

        XCTAssertFalse(hash.isEmpty)
        XCTAssertNotEqual(hash, input)
        XCTAssertGreaterThanOrEqual(hash.count, 4)
    }

    func testHashConsistency() {
        let input = "test-string"
        let hash1 = LogRedaction.hash(input)
        let hash2 = LogRedaction.hash(input)

        XCTAssertEqual(hash1, hash2)
    }

    func testHashDifferentInputs() {
        let hash1 = LogRedaction.hash("input1")
        let hash2 = LogRedaction.hash("input2")

        XCTAssertNotEqual(hash1, hash2)
    }

    func testHashSimilarInputs() {
        let hash1 = LogRedaction.hash("test")
        let hash2 = LogRedaction.hash("test1")

        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - Prefix Length Tests

    func testHashDefaultPrefixLength() {
        let input = "test"
        let hash = LogRedaction.hash(input)

        // Default prefix length is 12
        XCTAssertEqual(hash.count, 12)
    }

    func testHashCustomPrefixLength() {
        let input = "test"

        let hash4 = LogRedaction.hash(input, prefixLength: 4)
        XCTAssertEqual(hash4.count, 4)

        let hash8 = LogRedaction.hash(input, prefixLength: 8)
        XCTAssertEqual(hash8.count, 8)

        let hash16 = LogRedaction.hash(input, prefixLength: 16)
        XCTAssertEqual(hash16.count, 16)

        let hash32 = LogRedaction.hash(input, prefixLength: 32)
        XCTAssertEqual(hash32.count, 32)
    }

    func testHashMinimumPrefixLength() {
        let input = "test"

        // Prefix length less than 4 should be clamped to 4
        let hash1 = LogRedaction.hash(input, prefixLength: 1)
        XCTAssertEqual(hash1.count, 4)

        let hash2 = LogRedaction.hash(input, prefixLength: 2)
        XCTAssertEqual(hash2.count, 4)

        let hash3 = LogRedaction.hash(input, prefixLength: 3)
        XCTAssertEqual(hash3.count, 4)
    }

    func testHashZeroPrefixLength() {
        let input = "test"
        let hash = LogRedaction.hash(input, prefixLength: 0)

        // Should be clamped to minimum 4
        XCTAssertEqual(hash.count, 4)
    }

    func testHashNegativePrefixLength() {
        let input = "test"
        let hash = LogRedaction.hash(input, prefixLength: -5)

        // Should be clamped to minimum 4
        XCTAssertEqual(hash.count, 4)
    }

    func testHashMaximumPrefixLength() {
        let input = "test"

        // SHA-256 produces 64 hex characters
        let hash = LogRedaction.hash(input, prefixLength: 100)
        XCTAssertLessThanOrEqual(hash.count, 64)
    }

    // MARK: - Hash Format Tests

    func testHashHexFormat() {
        let input = "test"
        let hash = LogRedaction.hash(input)

        // Should only contain hex characters (0-9, a-f)
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        let hashCharacterSet = CharacterSet(charactersIn: hash)

        XCTAssertTrue(hexCharacterSet.isSuperset(of: hashCharacterSet))
    }

    func testHashNoUppercase() {
        let input = "test"
        let hash = LogRedaction.hash(input)

        // Should use lowercase hex
        XCTAssertEqual(hash, hash.lowercased())
    }

    // MARK: - Empty and Special Input Tests

    func testHashEmptyString() {
        let hash = LogRedaction.hash("")
        XCTAssertEqual(hash, "invalid")
    }

    func testHashWhitespace() {
        let hash1 = LogRedaction.hash(" ")
        let hash2 = LogRedaction.hash("  ")
        let hash3 = LogRedaction.hash("\t")
        let hash4 = LogRedaction.hash("\n")

        XCTAssertNotEqual(hash1, "invalid")
        XCTAssertNotEqual(hash2, "invalid")
        XCTAssertNotEqual(hash3, "invalid")
        XCTAssertNotEqual(hash4, "invalid")

        // Different whitespace should produce different hashes
        XCTAssertNotEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
        XCTAssertNotEqual(hash1, hash4)
    }

    func testHashNewlines() {
        let hash1 = LogRedaction.hash("line1\nline2")
        let hash2 = LogRedaction.hash("line1\r\nline2")

        XCTAssertNotEqual(hash1, "invalid")
        XCTAssertNotEqual(hash2, "invalid")
        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - Unicode Tests

    func testHashUnicodeCharacters() {
        let hash1 = LogRedaction.hash("你好")
        let hash2 = LogRedaction.hash("こんにちは")
        let hash3 = LogRedaction.hash("🚀")

        XCTAssertNotEqual(hash1, "invalid")
        XCTAssertNotEqual(hash2, "invalid")
        XCTAssertNotEqual(hash3, "invalid")

        XCTAssertNotEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
        XCTAssertNotEqual(hash2, hash3)
    }

    func testHashEmoji() {
        let hash1 = LogRedaction.hash("😀")
        let hash2 = LogRedaction.hash("😀😀")

        XCTAssertNotEqual(hash1, "invalid")
        XCTAssertNotEqual(hash2, "invalid")
        XCTAssertNotEqual(hash1, hash2)
    }

    func testHashMixedUnicode() {
        let hash = LogRedaction.hash("Hello 世界 🌍")
        XCTAssertNotEqual(hash, "invalid")
        XCTAssertGreaterThanOrEqual(hash.count, 4)
    }

    // MARK: - Special Characters Tests

    func testHashSpecialCharacters() {
        let inputs = [
            "!@#$%^&*()",
            "test=value",
            "key:value",
            "path/to/file",
            "192.168.1.1",
            "user@example.com",
            "<xml>data</xml>",
            "{\"json\":\"data\"}"
        ]

        for input in inputs {
            let hash = LogRedaction.hash(input)
            XCTAssertNotEqual(hash, "invalid", "Failed for input: \(input)")
            XCTAssertGreaterThanOrEqual(hash.count, 4)
        }
    }

    // MARK: - Long String Tests

    func testHashLongString() {
        let longString = String(repeating: "a", count: 10000)
        let hash = LogRedaction.hash(longString)

        XCTAssertNotEqual(hash, "invalid")
        XCTAssertEqual(hash.count, 12)
    }

    func testHashVeryLongString() {
        let veryLongString = String(repeating: "test", count: 100000)
        let hash = LogRedaction.hash(veryLongString)

        XCTAssertNotEqual(hash, "invalid")
        XCTAssertEqual(hash.count, 12)
    }

    // MARK: - Sensitive Data Pattern Tests

    func testHashIPAddress() {
        let ip = "192.168.1.1"
        let hash = LogRedaction.hash(ip)

        XCTAssertNotEqual(hash, ip)
        XCTAssertNotEqual(hash, "invalid")
    }

    func testHashEmail() {
        let email = "user@example.com"
        let hash = LogRedaction.hash(email)

        XCTAssertNotEqual(hash, email)
        XCTAssertNotEqual(hash, "invalid")
    }

    func testHashURL() {
        let url = "https://example.com/api/v1/users/12345"
        let hash = LogRedaction.hash(url)

        XCTAssertNotEqual(hash, url)
        XCTAssertNotEqual(hash, "invalid")
    }

    func testHashUUID() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let hash = LogRedaction.hash(uuid)

        XCTAssertNotEqual(hash, uuid)
        XCTAssertNotEqual(hash, "invalid")
    }

    func testHashAPIKey() {
        let apiKey = "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
        let hash = LogRedaction.hash(apiKey)

        XCTAssertNotEqual(hash, apiKey)
        XCTAssertNotEqual(hash, "invalid")
    }

    // MARK: - Correlation Tests

    func testHashCorrelation() {
        let userId = "user-12345"
        let hash1 = LogRedaction.hash(userId)
        let hash2 = LogRedaction.hash(userId)

        // Same input should produce same hash for correlation
        XCTAssertEqual(hash1, hash2)
    }

    func testHashCorrelationAcrossLogs() {
        let requestId = "req-abc123"

        // Simulate multiple log entries with same request ID
        let hashes = (0..<10).map { _ in
            LogRedaction.hash(requestId)
        }

        // All hashes should be identical for correlation
        let uniqueHashes = Set(hashes)
        XCTAssertEqual(uniqueHashes.count, 1)
    }

    // MARK: - Security Tests

    func testHashNoReverseEngineering() {
        let password = "super-secret-password"
        let hash = LogRedaction.hash(password)

        // Hash should not contain the original password
        XCTAssertFalse(hash.contains("super"))
        XCTAssertFalse(hash.contains("secret"))
        XCTAssertFalse(hash.contains("password"))
    }

    func testHashPreventsBruteForce() {
        // Even short inputs should produce secure hashes
        let pin = "1234"
        let hash = LogRedaction.hash(pin)

        XCTAssertNotEqual(hash, pin)
        XCTAssertGreaterThanOrEqual(hash.count, 4)
    }

    func testHashResistantToCollision() {
        // Generate many hashes and check for collisions
        var hashes = Set<String>()

        for i in 0..<1000 {
            let hash = LogRedaction.hash("input-\(i)")
            XCTAssertFalse(hashes.contains(hash), "Collision detected at iteration \(i)")
            hashes.insert(hash)
        }

        XCTAssertEqual(hashes.count, 1000)
    }

    // MARK: - Edge Case Tests

    func testHashSingleCharacter() {
        let hash = LogRedaction.hash("a")
        XCTAssertNotEqual(hash, "invalid")
        XCTAssertEqual(hash.count, 12)
    }

    func testHashNumbers() {
        let hash1 = LogRedaction.hash("12345")
        let hash2 = LogRedaction.hash("67890")

        XCTAssertNotEqual(hash1, "invalid")
        XCTAssertNotEqual(hash2, "invalid")
        XCTAssertNotEqual(hash1, hash2)
    }

    func testHashFloatingPoint() {
        let hash = LogRedaction.hash("3.14159265359")
        XCTAssertNotEqual(hash, "invalid")
        XCTAssertEqual(hash.count, 12)
    }

    // MARK: - Prefix Comparison Tests

    func testHashPrefixConsistency() {
        let input = "test-value"

        let hash4 = LogRedaction.hash(input, prefixLength: 4)
        let hash8 = LogRedaction.hash(input, prefixLength: 8)
        let hash12 = LogRedaction.hash(input, prefixLength: 12)

        // Shorter prefix should be a prefix of longer one
        XCTAssertTrue(hash8.hasPrefix(hash4))
        XCTAssertTrue(hash12.hasPrefix(hash8))
        XCTAssertTrue(hash12.hasPrefix(hash4))
    }

    // MARK: - Performance Tests

    func testHashPerformance() {
        measure {
            for i in 0..<1000 {
                _ = LogRedaction.hash("test-string-\(i)")
            }
        }
    }

    func testHashPerformanceWithLongStrings() {
        let longString = String(repeating: "a", count: 10000)

        measure {
            for _ in 0..<100 {
                _ = LogRedaction.hash(longString)
            }
        }
    }

    func testHashPerformanceVariousPrefixLengths() {
        let input = "test-value"

        measure {
            for _ in 0..<1000 {
                _ = LogRedaction.hash(input, prefixLength: 4)
                _ = LogRedaction.hash(input, prefixLength: 8)
                _ = LogRedaction.hash(input, prefixLength: 12)
                _ = LogRedaction.hash(input, prefixLength: 16)
            }
        }
    }

    // MARK: - Concurrent Access Tests

    func testHashConcurrentAccess() async {
        let input = "test-concurrent"

        await withTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    LogRedaction.hash(input)
                }
            }

            var results: [String] = []
            for await result in group {
                results.append(result)
            }

            // All results should be identical
            let uniqueResults = Set(results)
            XCTAssertEqual(uniqueResults.count, 1)
        }
    }

    func testHashConcurrentDifferentInputs() async {
        await withTaskGroup(of: (Int, String).self) { group in
            for i in 0..<100 {
                group.addTask {
                    (i, LogRedaction.hash("input-\(i)"))
                }
            }

            var results: [Int: String] = [:]
            for await (index, hash) in group {
                results[index] = hash
            }

            // All hashes should be unique
            let uniqueHashes = Set(results.values)
            XCTAssertEqual(uniqueHashes.count, 100)
        }
    }
}
