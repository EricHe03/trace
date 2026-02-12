//
//  X509CertificateBuilder.swift
//  TraceSecurity
//
//  Created by Justin on 2026/01/10.
//

import Darwin
import Foundation
import Security
import SwiftASN1
import TraceCore
import X509

/// Represents a complete X.509 Distinguished Name (DN) for a certificate subject or issuer.
public struct DistinguishedName: Sendable {
    /// Common Name (CN). Must be provided for all certificates.
    public let commonName: String
    /// Organization Name (O). Recommended for CA certificates.
    public let organization: String?
    /// Country Name (C). Must be a two-letter ISO 3166-1 country code.
    public let country: String?
    /// Organizational Unit Name (OU).
    public let organizationalUnit: String?

    public init(
        commonName: String,
        organization: String? = nil,
        country: String? = nil,
        organizationalUnit: String? = nil
    ) {
        self.commonName = commonName
        self.organization = organization
        self.country = country
        self.organizationalUnit = organizationalUnit
    }

    /// Creates a DN with only the Common Name for leaf certificates.
    public static func simple(_ commonName: String) -> DistinguishedName {
        DistinguishedName(commonName: commonName)
    }

    /// Creates a full DN for CA certificates.
    public static func forCA(
        commonName: String,
        organization: String = "Trace Network Debugger",
        country: String = "US"
    ) -> DistinguishedName {
        DistinguishedName(
            commonName: commonName,
            organization: organization,
            country: country
        )
    }
}

/// Builds X.509 certificates using apple/swift-certificates.
public enum X509CertificateBuilder {
    /// Builds a complete X.509 certificate with full Distinguished Name support.
    public static func buildCertificate(
        serialNumber: Certificate.SerialNumber = .init(),
        subject: DistinguishedName,
        issuer: DistinguishedName,
        subjectPrivateKey: SecKey,
        signingKey: SecKey,
        notBefore: Date = Date(),
        notAfter: Date,
        isCA: Bool = false
    ) throws -> SecCertificate {
        let subjectKey = try Certificate.PrivateKey(subjectPrivateKey)
        let issuerKey = try Certificate.PrivateKey(signingKey)

        let certificate = try Certificate(
            version: .v3,
            serialNumber: serialNumber,
            publicKey: subjectKey.publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: try makeDistinguishedName(issuer),
            subject: try makeDistinguishedName(subject),
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: try makeExtensions(
                isCA: isCA,
                subject: subject,
                subjectPublicKey: subjectKey.publicKey,
                authorityPublicKey: issuerKey.publicKey
            ),
            issuerPrivateKey: issuerKey
        )

        return try SecCertificate.makeWithCertificate(certificate)
    }

    /// Builds a certificate using simple DN values for backward compatibility.
    public static func buildCertificate(
        serialNumber: Certificate.SerialNumber = .init(),
        subject: String,
        issuer: String,
        subjectPrivateKey: SecKey,
        signingKey: SecKey,
        notBefore: Date = Date(),
        notAfter: Date,
        isCA: Bool = false
    ) throws -> SecCertificate {
        try buildCertificate(
            serialNumber: serialNumber,
            subject: .simple(subject),
            issuer: .simple(issuer),
            subjectPrivateKey: subjectPrivateKey,
            signingKey: signingKey,
            notBefore: notBefore,
            notAfter: notAfter,
            isCA: isCA
        )
    }

    private static func makeDistinguishedName(_ name: DistinguishedName) throws -> X509.DistinguishedName {
        var attributes: [RelativeDistinguishedName.Attribute] = []

        if let country = name.country, !country.isEmpty {
            attributes.append(try .init(type: .RDNAttributeType.countryName, printableString: country))
        }

        if let organization = name.organization, !organization.isEmpty {
            attributes.append(.init(type: .RDNAttributeType.organizationName, utf8String: organization))
        }

        if let organizationalUnit = name.organizationalUnit, !organizationalUnit.isEmpty {
            attributes.append(.init(type: .RDNAttributeType.organizationalUnitName, utf8String: organizationalUnit))
        }

        attributes.append(.init(type: .RDNAttributeType.commonName, utf8String: name.commonName))

        return try X509.DistinguishedName(attributes)
    }

    private static func makeExtensions(
        isCA: Bool,
        subject: DistinguishedName,
        subjectPublicKey: Certificate.PublicKey,
        authorityPublicKey: Certificate.PublicKey
    ) throws -> Certificate.Extensions {
        var extensions: [Certificate.Extension] = []

        if isCA {
            extensions.append(try .init(.isCertificateAuthority(maxPathLength: nil), critical: true))
        }

        let keyUsage = isCA
            ? KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true)
            : KeyUsage(digitalSignature: true, keyEncipherment: true)
        extensions.append(try .init(keyUsage, critical: true))

        let subjectKeyIdentifier = SubjectKeyIdentifier(hash: subjectPublicKey)
        extensions.append(try .init(subjectKeyIdentifier, critical: false))

        let authorityKeyIdentifier = AuthorityKeyIdentifier(
            keyIdentifier: SubjectKeyIdentifier(hash: authorityPublicKey).keyIdentifier
        )
        extensions.append(try .init(authorityKeyIdentifier, critical: false))

        if !isCA {
            extensions.append(try .init(ExtendedKeyUsage([.serverAuth, .clientAuth]), critical: false))
            extensions.append(try .init(makeSubjectAlternativeNames(for: subject.commonName), critical: false))
        }

        return try Certificate.Extensions(extensions)
    }

    private static func makeSubjectAlternativeNames(for subject: String) -> SubjectAlternativeNames {
        if let ipBytes = ipAddressBytes(subject) {
            return SubjectAlternativeNames([
                .ipAddress(ASN1OctetString(contentBytes: ipBytes[...]))
            ])
        }

        // Rationale: Convert IDNs to ASCII using punycode (RFC 3492) for DNSName.
        let encodedSubject: String = if subject.allSatisfy(\.isASCII) {
            subject
        } else {
            Punycode.encodeDomain(subject)
        }

        return SubjectAlternativeNames([.dnsName(encodedSubject)])
    }

    private static func ipAddressBytes(_ subject: String) -> [UInt8]? {
        var v4 = in_addr()
        if subject.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }

        var v6 = in6_addr()
        if subject.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }

        return nil
    }
}
