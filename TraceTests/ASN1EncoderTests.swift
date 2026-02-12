//
//  ASN1EncoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import Security
import XCTest
@testable import Trace
@testable import TraceSecurity

final class ASN1EncoderTests: XCTestCase {
    // MARK: - Distinguished Name Tests

    func testDistinguishedNameSimpleFactory() {
        let name = DistinguishedName.simple("example.com")

        XCTAssertEqual(name.commonName, "example.com")
        XCTAssertNil(name.organization)
        XCTAssertNil(name.country)
        XCTAssertNil(name.organizationalUnit)
    }

    func testDistinguishedNameForCAFactory() {
        let name = DistinguishedName.forCA(commonName: "Trace Root CA")

        XCTAssertEqual(name.commonName, "Trace Root CA")
        XCTAssertEqual(name.organization, "Trace Network Debugger")
        XCTAssertEqual(name.country, "US")
    }

    // MARK: - Certificate Builder Tests

    func testX509CertificateBuilderBuildsSelfSignedCA() throws {
        let caKey = try makeEphemeralRSAKey()
        let subject = DistinguishedName.forCA(commonName: "Trace Unit Test Root")

        let cert = try X509CertificateBuilder.buildCertificate(
            subject: subject,
            issuer: subject,
            subjectPrivateKey: caKey,
            signingKey: caKey,
            notBefore: Date(),
            notAfter: Date().addingTimeInterval(60 * 60 * 24 * 365),
            isCA: true
        )

        let der = SecCertificateCopyData(cert) as Data
        XCTAssertFalse(der.isEmpty)
        XCTAssertTrue((cert.summary).contains("Trace Unit Test Root"))
    }

    func testX509CertificateBuilderBuildsLeafCertificate() throws {
        let caKey = try makeEphemeralRSAKey()
        let leafKey = try makeEphemeralRSAKey()

        let issuer = DistinguishedName.forCA(commonName: "Trace Unit Test Root")
        let subject = DistinguishedName.simple("api.example.com")

        let cert = try X509CertificateBuilder.buildCertificate(
            subject: subject,
            issuer: issuer,
            subjectPrivateKey: leafKey,
            signingKey: caKey,
            notBefore: Date(),
            notAfter: Date().addingTimeInterval(60 * 60 * 24 * 365),
            isCA: false
        )

        let der = SecCertificateCopyData(cert) as Data
        XCTAssertFalse(der.isEmpty)
        XCTAssertEqual(cert.commonName, "api.example.com")
    }

    func testX509CertificateBuilderSupportsIPAddressSubject() throws {
        let caKey = try makeEphemeralRSAKey()
        let leafKey = try makeEphemeralRSAKey()

        let issuer = DistinguishedName.forCA(commonName: "Trace Unit Test Root")
        let subject = DistinguishedName.simple("127.0.0.1")

        let cert = try X509CertificateBuilder.buildCertificate(
            subject: subject,
            issuer: issuer,
            subjectPrivateKey: leafKey,
            signingKey: caKey,
            notBefore: Date(),
            notAfter: Date().addingTimeInterval(60 * 60 * 24 * 365),
            isCA: false
        )

        XCTAssertFalse((SecCertificateCopyData(cert) as Data).isEmpty)
        XCTAssertEqual(cert.commonName, "127.0.0.1")
    }

    // MARK: - Helpers

    private func makeEphemeralRSAKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]

        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error? ?? CertificateError.keyGenerationFailed(nil)
        }

        return key
    }
}
