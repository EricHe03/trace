//
//  ASN1EncoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceSecurity

final class ASN1EncoderTests: XCTestCase {

    // MARK: - Integer Encoding Tests

    func testEncodeInteger() {
        let data = Data([0x01, 0x02, 0x03])
        let encoded = ASN1Encoder.encodeInteger(data)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.integer.rawValue)
        XCTAssertGreaterThan(encoded.count, 1)
    }

    func testEncodeIntegerFromInt() {
        let encoded = ASN1Encoder.encodeInteger(42)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.integer.rawValue)
        XCTAssertEqual(encoded[1], 0x01) // Length
        XCTAssertEqual(encoded[2], 0x2A) // 42 in hex
    }

    func testEncodeIntegerZero() {
        let encoded = ASN1Encoder.encodeInteger(0)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.integer.rawValue)
        XCTAssertEqual(encoded[1], 0x01)
        XCTAssertEqual(encoded[2], 0x00)
    }

    func testEncodeIntegerNegative() {
        let encoded = ASN1Encoder.encodeInteger(-1)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.integer.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    // MARK: - Bit String Tests

    func testEncodeBitString() {
        let data = Data([0xFF, 0x00])
        let encoded = ASN1Encoder.encodeBitString(data)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.bitString.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    func testEncodeBitStringWithUnusedBits() {
        let data = Data([0xFF])
        let encoded = ASN1Encoder.encodeBitString(data, unusedBits: 3)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.bitString.rawValue)
        XCTAssertEqual(encoded[2], 0x03) // Unused bits count
    }

    // MARK: - Octet String Tests

    func testEncodeOctetString() {
        let data = "Hello".data(using: .utf8)!
        let encoded = ASN1Encoder.encodeOctetString(data)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.octetString.rawValue)
        XCTAssertEqual(encoded[1], 0x05) // Length
    }

    func testEncodeEmptyOctetString() {
        let data = Data()
        let encoded = ASN1Encoder.encodeOctetString(data)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.octetString.rawValue)
        XCTAssertEqual(encoded[1], 0x00) // Length = 0
    }

    // MARK: - Null Tests

    func testEncodeNull() {
        let encoded = ASN1Encoder.encodeNull()

        XCTAssertEqual(encoded.count, 2)
        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.null.rawValue)
        XCTAssertEqual(encoded[1], 0x00)
    }

    // MARK: - Object Identifier Tests

    func testEncodeObjectIdentifier() {
        let oid = "2.5.4.3" // Common Name
        let encoded = ASN1Encoder.encodeObjectIdentifier(oid)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.objectIdentifier.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    func testEncodeObjectIdentifierSHA256() {
        let oid = "1.2.840.113549.1.1.11" // SHA-256 with RSA
        let encoded = ASN1Encoder.encodeObjectIdentifier(oid)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.objectIdentifier.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    func testEncodeObjectIdentifierInvalid() {
        let oid = "1" // Invalid (needs at least 2 components)
        let encoded = ASN1Encoder.encodeObjectIdentifier(oid)

        XCTAssertEqual(encoded.count, 0, "Invalid OID should return empty data")
    }

    // MARK: - String Encoding Tests

    func testEncodeUTF8String() {
        let string = "Hello World"
        let encoded = ASN1Encoder.encodeUTF8String(string)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.utf8String.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    func testEncodePrintableString() {
        let string = "ExampleCA"
        let encoded = ASN1Encoder.encodePrintableString(string)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.printableString.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    func testEncodeIA5String() {
        let string = "test@example.com"
        let encoded = ASN1Encoder.encodeIA5String(string)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.ia5String.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    // MARK: - UTC Time Tests

    func testEncodeUTCTime() {
        let date = Date()
        let encoded = ASN1Encoder.encodeUTCTime(date)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.utcTime.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    func testEncodeUTCTimeFormat() {
        // Create a specific date
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2025
        components.month = 12
        components.day = 30
        components.hour = 10
        components.minute = 30
        components.second = 00
        components.timeZone = TimeZone(identifier: "UTC")

        guard let date = calendar.date(from: components) else {
            XCTFail("Failed to create test date")
            return
        }

        let encoded = ASN1Encoder.encodeUTCTime(date)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.utcTime.rawValue)
        // UTC time should be in format: YYMMDDhhmmssZ
        XCTAssertEqual(encoded[1], 13) // Length of "251230103000Z"
    }

    // MARK: - Sequence Tests

    func testEncodeSequenceFromArray() {
        let data1 = Data([0x01, 0x02])
        let data2 = Data([0x03, 0x04])
        let encoded = ASN1Encoder.encodeSequence([data1, data2])

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.sequence.rawValue)
        XCTAssertGreaterThan(encoded.count, 2)
    }

    func testEncodeSequenceFromData() {
        let data = Data([0x01, 0x02, 0x03])
        let encoded = ASN1Encoder.encodeSequence(data)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.sequence.rawValue)
        XCTAssertEqual(encoded[1], 0x03) // Length
    }

    func testEncodeEmptySequence() {
        let encoded = ASN1Encoder.encodeSequence([])

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.sequence.rawValue)
        XCTAssertEqual(encoded[1], 0x00) // Length = 0
    }

    // MARK: - Set Tests

    func testEncodeSet() {
        let data = Data([0x01, 0x02])
        let encoded = ASN1Encoder.encodeSet(data)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.set.rawValue)
        XCTAssertEqual(encoded[1], 0x02) // Length
    }

    // MARK: - Context Specific Tests

    func testEncodeContextSpecific() {
        let data = Data([0x01, 0x02])
        let encoded = ASN1Encoder.encodeContextSpecific(0, data, constructed: true)

        XCTAssertEqual(encoded[0], 0xA0) // Context-specific tag 0, constructed
        XCTAssertGreaterThan(encoded.count, 2)
    }

    func testEncodeContextSpecificNotConstructed() {
        let data = Data([0x01, 0x02])
        let encoded = ASN1Encoder.encodeContextSpecific(2, data, constructed: false)

        XCTAssertEqual(encoded[0], 0x82) // Context-specific tag 2, primitive
        XCTAssertGreaterThan(encoded.count, 2)
    }

    // MARK: - X509CertificateBuilder OID Tests

    func testOIDConstants() {
        XCTAssertEqual(X509CertificateBuilder.OID.commonName, "2.5.4.3")
        XCTAssertEqual(X509CertificateBuilder.OID.sha256WithRSAEncryption, "1.2.840.113549.1.1.11")
        XCTAssertEqual(X509CertificateBuilder.OID.rsaEncryption, "1.2.840.113549.1.1.1")
        XCTAssertEqual(X509CertificateBuilder.OID.basicConstraints, "2.5.29.19")
        XCTAssertEqual(X509CertificateBuilder.OID.keyUsage, "2.5.29.15")
        XCTAssertEqual(X509CertificateBuilder.OID.serverAuth, "1.3.6.1.5.5.7.3.1")
    }

    // MARK: - Length Encoding Tests

    func testShortFormLength() {
        // Test that lengths < 128 use short form
        let data = Data(repeating: 0x00, count: 100)
        let encoded = ASN1Encoder.encodeOctetString(data)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.octetString.rawValue)
        XCTAssertEqual(encoded[1], 100) // Short form length
    }

    func testLongFormLength() {
        // Test that lengths >= 128 use long form
        let data = Data(repeating: 0x00, count: 200)
        let encoded = ASN1Encoder.encodeOctetString(data)

        XCTAssertEqual(encoded[0], ASN1Encoder.Tag.octetString.rawValue)
        XCTAssertTrue(encoded[1] & 0x80 != 0, "Should use long form length")
    }

    // MARK: - Integration Tests

    func testEncodeComplexSequence() {
        // Build a complex nested structure
        let innerSeq = ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeInteger(1),
            ASN1Encoder.encodeUTF8String("test")
        ])

        let outerSeq = ASN1Encoder.encodeSequence([
            innerSeq,
            ASN1Encoder.encodeNull()
        ])

        XCTAssertEqual(outerSeq[0], ASN1Encoder.Tag.sequence.rawValue)
        XCTAssertGreaterThan(outerSeq.count, 4)
    }
}
