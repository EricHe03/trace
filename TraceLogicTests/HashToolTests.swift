//
//  HashToolTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import CryptoKit
@testable import TraceUI
import XCTest

final class HashToolTests: XCTestCase {
    // MARK: - MD5 Tests

    func testMD5Hash() {
        let input = "Hello, World!"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = Insecure.MD5.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash.count, 32) // MD5 is 128 bits = 32 hex characters
        XCTAssertFalse(hash.isEmpty)
    }

    func testMD5KnownValue() {
        // MD5("The quick brown fox jumps over the lazy dog") = 9e107d9d372bb6826bd81d3542a419d6
        let input = "The quick brown fox jumps over the lazy dog"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = Insecure.MD5.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash, "9e107d9d372bb6826bd81d3542a419d6")
    }

    func testMD5EmptyString() {
        // MD5("") = d41d8cd98f00b204e9800998ecf8427e
        let input = ""
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = Insecure.MD5.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash, "d41d8cd98f00b204e9800998ecf8427e")
    }

    // MARK: - SHA1 Tests

    func testSHA1Hash() {
        let input = "Hello, World!"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = Insecure.SHA1.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash.count, 40) // SHA1 is 160 bits = 40 hex characters
        XCTAssertFalse(hash.isEmpty)
    }

    func testSHA1KnownValue() {
        // SHA1("The quick brown fox jumps over the lazy dog") = 2fd4e1c67a2d28fced849ee1bb76e7391b93eb12
        let input = "The quick brown fox jumps over the lazy dog"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = Insecure.SHA1.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash, "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
    }

    // MARK: - SHA256 Tests

    func testSHA256Hash() {
        let input = "Hello, World!"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash.count, 64) // SHA256 is 256 bits = 64 hex characters
        XCTAssertFalse(hash.isEmpty)
    }

    func testSHA256KnownValue() {
        // SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let input = "abc"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - SHA512 Tests

    func testSHA512Hash() {
        let input = "Hello, World!"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = SHA512.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash.count, 128) // SHA512 is 512 bits = 128 hex characters
        XCTAssertFalse(hash.isEmpty)
    }

    func testSHA512KnownValue() {
        // SHA512("abc") = ddaf35a193617aba...
        let input = "abc"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let digest = SHA512.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        let expected = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        XCTAssertEqual(hash, expected)
    }

    // MARK: - HMAC MD5 Tests

    func testHMACMD5() {
        let input = "Hello, World!"
        let keyString = "secret"

        guard let data = input.data(using: .utf8),
              let keyData = keyString.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let key = SymmetricKey(data: keyData)
        let hmac = HMAC<Insecure.MD5>.authenticationCode(for: data, using: key)
        let hash = hmac.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash.count, 32)
        XCTAssertFalse(hash.isEmpty)
    }

    // MARK: - HMAC SHA1 Tests

    func testHMACSHA1() {
        let input = "Hello, World!"
        let keyString = "secret"

        guard let data = input.data(using: .utf8),
              let keyData = keyString.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let key = SymmetricKey(data: keyData)
        let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key)
        let hash = hmac.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash.count, 40)
        XCTAssertFalse(hash.isEmpty)
    }

    // MARK: - HMAC SHA256 Tests

    func testHMACSHA256() {
        let input = "Hello, World!"
        let keyString = "secret"

        guard let data = input.data(using: .utf8),
              let keyData = keyString.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let key = SymmetricKey(data: keyData)
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        let hash = hmac.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash.count, 64)
        XCTAssertFalse(hash.isEmpty)
    }

    func testHMACSHA256KnownValue() {
        // Test vector from RFC 4231
        let input = "what do ya want for nothing?"
        let keyString = "Jefe"

        guard let data = input.data(using: .utf8),
              let keyData = keyString.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let key = SymmetricKey(data: keyData)
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        let hash = hmac.map { String(format: "%02x", $0) }.joined()

        let expected = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        XCTAssertEqual(hash, expected)
    }

    // MARK: - HMAC SHA512 Tests

    func testHMACSHA512() {
        let input = "Hello, World!"
        let keyString = "secret"

        guard let data = input.data(using: .utf8),
              let keyData = keyString.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let key = SymmetricKey(data: keyData)
        let hmac = HMAC<SHA512>.authenticationCode(for: data, using: key)
        let hash = hmac.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hash.count, 128)
        XCTAssertFalse(hash.isEmpty)
    }

    // MARK: - Different Hash Outputs Tests

    func testDifferentHashesProduceDifferentOutputs() {
        let input = "test"
        guard let data = input.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha512 = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()

        // All hashes should be different
        XCTAssertNotEqual(md5, sha1)
        XCTAssertNotEqual(md5, sha256)
        XCTAssertNotEqual(md5, sha512)
        XCTAssertNotEqual(sha1, sha256)
        XCTAssertNotEqual(sha1, sha512)
        XCTAssertNotEqual(sha256, sha512)
    }

    // MARK: - Different Keys Produce Different HMACs Tests

    func testDifferentKeysDifferentHMAC() {
        let input = "test"
        guard let data = input.data(using: .utf8),
              let key1Data = "key1".data(using: .utf8),
              let key2Data = "key2".data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let key1 = SymmetricKey(data: key1Data)
        let key2 = SymmetricKey(data: key2Data)

        let hmac1 = HMAC<SHA256>.authenticationCode(for: data, using: key1)
        let hmac2 = HMAC<SHA256>.authenticationCode(for: data, using: key2)

        let hash1 = hmac1.map { String(format: "%02x", $0) }.joined()
        let hash2 = hmac2.map { String(format: "%02x", $0) }.joined()

        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - Large Input Tests

    func testHashingLargeInput() {
        let largeInput = String(repeating: "A", count: 100_000)
        guard let data = largeInput.data(using: .utf8) else {
            XCTFail("Failed to create data")
            return
        }

        let md5 = Insecure.MD5.hash(data: data)
        let sha256 = SHA256.hash(data: data)

        XCTAssertFalse(md5.description.isEmpty)
        XCTAssertFalse(sha256.description.isEmpty)
    }

    // MARK: - Binary Data Tests

    func testHashingBinaryData() {
        let binaryData = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD])

        let md5 = Insecure.MD5.hash(data: binaryData)
        let sha256 = SHA256.hash(data: binaryData)

        XCTAssertFalse(md5.description.isEmpty)
        XCTAssertFalse(sha256.description.isEmpty)
    }
}
