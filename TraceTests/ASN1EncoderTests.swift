//
//  ASN1EncoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import Security
import XCTest
import X509
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

        let parsed = try parseCertificate(cert)
        try assertCAProfile(parsed)
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

        let parsed = try parseCertificate(cert)
        try assertLeafProfile(parsed, expectedDNSName: "api.example.com")
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

        let parsed = try parseCertificate(cert)
        try assertLeafProfile(parsed, expectedIPAddress: [127, 0, 0, 1])
    }

    // MARK: - Helpers

    private func parseCertificate(_ certificate: SecCertificate) throws -> Certificate {
        try Certificate(certificate)
    }

    private func assertCAProfile(_ certificate: Certificate) throws {
        XCTAssertEqual(certificate.subject, certificate.issuer)

        let basicConstraintsExtension = try XCTUnwrap(
            certificate.extensions[oid: .X509ExtensionID.basicConstraints]
        )
        XCTAssertTrue(basicConstraintsExtension.critical)

        let basicConstraints = try XCTUnwrap(certificate.extensions.basicConstraints)
        switch basicConstraints {
        case .isCertificateAuthority(let maxPathLength):
            XCTAssertNil(maxPathLength)
        default:
            XCTFail("Expected CA basic constraints")
        }

        let keyUsageExtension = try XCTUnwrap(certificate.extensions[oid: .X509ExtensionID.keyUsage])
        XCTAssertTrue(keyUsageExtension.critical)

        let keyUsage = try XCTUnwrap(certificate.extensions.keyUsage)
        XCTAssertTrue(keyUsage.digitalSignature)
        XCTAssertTrue(keyUsage.keyCertSign)
        XCTAssertTrue(keyUsage.cRLSign)
        XCTAssertFalse(keyUsage.keyEncipherment)

        XCTAssertNil(try certificate.extensions.extendedKeyUsage)
        XCTAssertNil(try certificate.extensions.subjectAlternativeNames)

        let ski = try XCTUnwrap(certificate.extensions.subjectKeyIdentifier)
        let aki = try XCTUnwrap(certificate.extensions.authorityKeyIdentifier)
        XCTAssertEqual(aki.keyIdentifier, ski.keyIdentifier)
    }

    private func assertLeafProfile(
        _ certificate: Certificate,
        expectedDNSName: String? = nil,
        expectedIPAddress: [UInt8]? = nil
    ) throws {
        XCTAssertNil(try certificate.extensions.basicConstraints)

        let keyUsageExtension = try XCTUnwrap(certificate.extensions[oid: .X509ExtensionID.keyUsage])
        XCTAssertTrue(keyUsageExtension.critical)

        let keyUsage = try XCTUnwrap(certificate.extensions.keyUsage)
        XCTAssertTrue(keyUsage.digitalSignature)
        XCTAssertTrue(keyUsage.keyEncipherment)
        XCTAssertFalse(keyUsage.keyCertSign)
        XCTAssertFalse(keyUsage.cRLSign)

        let eku = try XCTUnwrap(certificate.extensions.extendedKeyUsage)
        XCTAssertTrue(eku.contains(.serverAuth))
        XCTAssertTrue(eku.contains(.clientAuth))

        let san = try XCTUnwrap(certificate.extensions.subjectAlternativeNames)
        if let expectedDNSName {
            XCTAssertTrue(san.contains(.dnsName(expectedDNSName)))
        }
        if let expectedIPAddress {
            let hasIPAddress = san.contains { name in
                if case .ipAddress(let address) = name {
                    return Array(address.bytes) == expectedIPAddress
                }
                return false
            }
            XCTAssertTrue(hasIPAddress)
        }

        XCTAssertNotNil(try certificate.extensions.subjectKeyIdentifier)
        XCTAssertNotNil(try certificate.extensions.authorityKeyIdentifier)
    }

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
