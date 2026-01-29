//
//  ASN1Encoder.swift
//  TraceSecurity
//
//  Created by Justin on 2026/01/10.
//

import CommonCrypto
import Darwin
import Foundation
import Security
import TraceCore

/// Encodes ASN.1 DER values used to build X.509 certificates.
public class ASN1Encoder {
    // MARK: - ASN.1 Tags

    enum Tag: UInt8 {
        case boolean = 0x01
        case integer = 0x02
        case bitString = 0x03
        case octetString = 0x04
        case null = 0x05
        case objectIdentifier = 0x06
        case utf8String = 0x0C
        case printableString = 0x13
        case ia5String = 0x16
        case utcTime = 0x17
        case sequence = 0x30
        case set = 0x31
        case contextSpecific0 = 0xA0
        case contextSpecific3 = 0xA3
    }

    // MARK: - Encoding Methods

    /// Encodes an INTEGER.
    public static func encodeInteger(_ value: Data) -> Data {
        var data = value

        // Rule: DER uses the shortest encoding that preserves sign.
        while data.count > 1 {
            let start = data.startIndex
            guard data[start] == 0x00, (data[start + 1] & 0x80) == 0 else { break }
            data.removeSubrange(start ..< (start + 1))
        }

        // Rule: Prefix 0x00 when the high bit is set to keep the INTEGER positive.
        if (data.first ?? 0) & 0x80 != 0 {
            data.insert(0x00, at: data.startIndex)
        }

        return encodeTagLength(Tag.integer.rawValue, data)
    }

    /// Encodes an INTEGER from an Int.
    public static func encodeInteger(_ value: Int) -> Data {
        var val = value
        var bytes: [UInt8] = []

        if val == 0 {
            bytes = [0x00]
        } else {
            var temp = abs(val)
            while temp > 0 {
                bytes.insert(UInt8(temp & 0xFF), at: 0)
                temp >>= 8
            }

            if value < 0 {
                // Rule: Use two's complement for negative INTEGER values.
                for i in 0 ..< bytes.count {
                    bytes[i] = ~bytes[i]
                }
                var carry: UInt16 = 1
                for i in (0 ..< bytes.count).reversed() {
                    carry += UInt16(bytes[i])
                    bytes[i] = UInt8(carry & 0xFF)
                    carry >>= 8
                }
            }
        }

        return encodeInteger(Data(bytes))
    }

    /// Encodes a BIT STRING.
    public static func encodeBitString(_ data: Data, unusedBits: UInt8 = 0) -> Data {
        var content = Data([unusedBits])
        content.append(data)
        return encodeTagLength(Tag.bitString.rawValue, content)
    }

    /// Encodes an OCTET STRING.
    public static func encodeOctetString(_ data: Data) -> Data {
        encodeTagLength(Tag.octetString.rawValue, data)
    }

    /// Encodes NULL.
    public static func encodeNull() -> Data {
        Data([Tag.null.rawValue, 0x00])
    }

    /// Encodes an OBJECT IDENTIFIER.
    public static func encodeObjectIdentifier(_ oid: String) -> Data {
        let components = oid.split(separator: ".").compactMap { Int($0) }
        guard components.count >= 2 else { return Data() }

        var bytes: [UInt8] = []

        // Rule: The first byte combines the first two OID components.
        bytes.append(UInt8(components[0] * 40 + components[1]))

        // Rule: Remaining components use base-128 encoding with a continuation bit.
        for component in components[2...] {
            var value = component
            var subBytes: [UInt8] = []

            if value == 0 {
                subBytes.append(0)
            } else {
                while value > 0 {
                    subBytes.insert(UInt8(value & 0x7F), at: 0)
                    value >>= 7
                }

                // Rule: Set the continuation bit on all but the last byte.
                for i in 0 ..< (subBytes.count - 1) {
                    subBytes[i] |= 0x80
                }
            }

            bytes.append(contentsOf: subBytes)
        }

        return encodeTagLength(Tag.objectIdentifier.rawValue, Data(bytes))
    }

    /// Encodes a UTF8String.
    public static func encodeUTF8String(_ string: String) -> Data {
        guard let data = string.data(using: .utf8) else { return Data() }
        return encodeTagLength(Tag.utf8String.rawValue, data)
    }

    /// Encodes a PrintableString.
    public static func encodePrintableString(_ string: String) -> Data {
        guard let data = string.data(using: .ascii) else { return Data() }
        return encodeTagLength(Tag.printableString.rawValue, data)
    }

    /// Encodes an IA5String.
    public static func encodeIA5String(_ string: String) -> Data {
        guard let data = string.data(using: .ascii) else { return Data() }
        return encodeTagLength(Tag.ia5String.rawValue, data)
    }

    /// Encodes a UTCTime value.
    public static func encodeUTCTime(_ date: Date) -> Data {
        // DateFormatter is not thread-safe; keep a shared instance behind a lock to avoid per-call allocations.
        utcTimeFormatterLock.lock()
        let timeString = utcTimeFormatter.string(from: date)
        utcTimeFormatterLock.unlock()

        guard let data = timeString.data(using: .ascii) else { return Data() }
        return encodeTagLength(Tag.utcTime.rawValue, data)
    }

    /// Encodes a SEQUENCE.
    public static func encodeSequence(_ contents: [Data]) -> Data {
        let combined = contents.reduce(Data(), +)
        return encodeTagLength(Tag.sequence.rawValue, combined)
    }

    /// Encodes a SEQUENCE from a single value.
    public static func encodeSequence(_ content: Data) -> Data {
        encodeTagLength(Tag.sequence.rawValue, content)
    }

    /// Encodes a SET.
    public static func encodeSet(_ content: Data) -> Data {
        encodeTagLength(Tag.set.rawValue, content)
    }

    /// Encodes a context-specific tag.
    public static func encodeContextSpecific(_ tag: UInt8, _ content: Data, constructed: Bool = true) -> Data {
        let tagValue = tag | (constructed ? 0xA0 : 0x80)
        return encodeTagLength(tagValue, content)
    }

    // MARK: - Helper Methods

    private static func encodeTagLength(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(encodeLength(content.count))
        result.append(content)
        return result
    }

    private static func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            // Rule: Lengths below 128 use the short form.
            return Data([UInt8(length)])
        } else {
            // Rule: Long-form lengths are big-endian with the high bit set on the first byte.
            var lengthBytes: [UInt8] = []
            var temp = length

            while temp > 0 {
                lengthBytes.insert(UInt8(temp & 0xFF), at: 0)
                temp >>= 8
            }

            var result = Data([0x80 | UInt8(lengthBytes.count)])
            result.append(contentsOf: lengthBytes)
            return result
        }
    }
}

// MARK: - Distinguished Name Structure

/// Represents a complete X.509 Distinguished Name (DN) for a certificate subject or issuer.
public struct DistinguishedName {
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

// MARK: - X.509 Certificate Builder

/// Builds X.509 certificates using ASN.1 DER encoding.
public class X509CertificateBuilder {
    // MARK: - OIDs (Object Identifiers)

    enum OID {
        // Signature algorithms
        static let sha256WithRSAEncryption = "1.2.840.113549.1.1.11"
        static let sha1WithRSAEncryption = "1.2.840.113549.1.1.5"
        static let rsaEncryption = "1.2.840.113549.1.1.1"

        // Attributes
        static let commonName = "2.5.4.3"
        static let countryName = "2.5.4.6"
        static let organizationName = "2.5.4.10"
        static let organizationalUnitName = "2.5.4.11"

        // Extensions
        static let basicConstraints = "2.5.29.19"
        static let keyUsage = "2.5.29.15"
        static let extendedKeyUsage = "2.5.29.37"
        static let subjectAltName = "2.5.29.17"
        // Rule: RFC 5280 §4.2.1.2 requires SKI for CA certificates.
        static let subjectKeyIdentifier = "2.5.29.14"
        // Rule: RFC 5280 §4.2.1.1 recommends AKI for all certificates.
        static let authorityKeyIdentifier = "2.5.29.35"

        // Extended key usage
        static let serverAuth = "1.3.6.1.5.5.7.3.1"
        static let clientAuth = "1.3.6.1.5.5.7.3.2"
    }

    // MARK: - Building Methods

    /// Builds a complete X.509 certificate with full Distinguished Name support.
    public static func buildCertificate(
        serialNumber: Int = Int.random(in: 1 ... Int.max),
        subject: DistinguishedName,
        issuer: DistinguishedName,
        publicKey: SecKey,
        signingKey: SecKey,
        notBefore: Date = Date(),
        notAfter: Date,
        isCA: Bool = false
    ) throws -> SecCertificate {
        let tbsCertificate = try buildTBSCertificate(
            serialNumber: serialNumber,
            subject: subject,
            issuer: issuer,
            publicKey: publicKey,
            signingKey: signingKey,
            notBefore: notBefore,
            notAfter: notAfter,
            isCA: isCA
        )

        let signature = try signData(tbsCertificate, with: signingKey)

        let certificate = ASN1Encoder.encodeSequence([
            tbsCertificate,
            buildAlgorithmIdentifier(),
            ASN1Encoder.encodeBitString(signature)
        ])

        guard let secCert = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw CertificateError.notImplemented("Failed to create SecCertificate from DER data")
        }

        return secCert
    }

    /// Builds a certificate using simple DN values for backward compatibility.
    public static func buildCertificate(
        serialNumber: Int = Int.random(in: 1 ... Int.max),
        subject: String,
        issuer: String,
        publicKey: SecKey,
        signingKey: SecKey,
        notBefore: Date = Date(),
        notAfter: Date,
        isCA: Bool = false
    ) throws -> SecCertificate {
        try buildCertificate(
            serialNumber: serialNumber,
            subject: .simple(subject),
            issuer: .simple(issuer),
            publicKey: publicKey,
            signingKey: signingKey,
            notBefore: notBefore,
            notAfter: notAfter,
            isCA: isCA
        )
    }

    private static func buildTBSCertificate(
        serialNumber: Int,
        subject: DistinguishedName,
        issuer: DistinguishedName,
        publicKey: SecKey,
        signingKey: SecKey,
        notBefore: Date,
        notAfter: Date,
        isCA: Bool
    ) throws -> Data {
        var components: [Data] = []

        let version = ASN1Encoder.encodeContextSpecific(0, ASN1Encoder.encodeInteger(2))
        components.append(version)

        components.append(ASN1Encoder.encodeInteger(serialNumber))

        components.append(buildAlgorithmIdentifier())

        components.append(buildDistinguishedName(issuer))

        components.append(buildValidity(notBefore: notBefore, notAfter: notAfter))

        components.append(buildDistinguishedName(subject))

        try components.append(buildSubjectPublicKeyInfo(publicKey))

        // Rationale: Authority Key Identifier uses the issuer's public key, which matches the subject for self-signed CAs.
        guard let authorityPublicKey = SecKeyCopyPublicKey(signingKey) else {
            throw CertificateError.publicKeyExtractionFailed
        }

        let extensions = buildExtensions(
            isCA: isCA,
            subject: subject,
            publicKey: publicKey,
            authorityPublicKey: authorityPublicKey
        )
        components.append(ASN1Encoder.encodeContextSpecific(3, extensions))

        return ASN1Encoder.encodeSequence(components)
    }

    private static func buildAlgorithmIdentifier() -> Data {
        ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.sha256WithRSAEncryption),
            ASN1Encoder.encodeNull()
        ])
    }

    /// Builds an X.509 Distinguished Name in RFC 5280 order.
    /// - Important: The order is C, O, OU, CN to match standard CA practice.
    private static func buildDistinguishedName(_ dn: DistinguishedName) -> Data {
        var rdnSequence: [Data] = []

        if let country = dn.country {
            rdnSequence.append(ASN1Encoder.encodeSet(
                ASN1Encoder.encodeSequence([
                    ASN1Encoder.encodeObjectIdentifier(OID.countryName),
                    ASN1Encoder.encodePrintableString(country)
                ])
            ))
        }

        if let organization = dn.organization {
            rdnSequence.append(ASN1Encoder.encodeSet(
                ASN1Encoder.encodeSequence([
                    ASN1Encoder.encodeObjectIdentifier(OID.organizationName),
                    ASN1Encoder.encodeUTF8String(organization)
                ])
            ))
        }

        if let ou = dn.organizationalUnit {
            rdnSequence.append(ASN1Encoder.encodeSet(
                ASN1Encoder.encodeSequence([
                    ASN1Encoder.encodeObjectIdentifier(OID.organizationalUnitName),
                    ASN1Encoder.encodeUTF8String(ou)
                ])
            ))
        }

        // Rule: Common Name (CN) must always be present.
        rdnSequence.append(ASN1Encoder.encodeSet(
            ASN1Encoder.encodeSequence([
                ASN1Encoder.encodeObjectIdentifier(OID.commonName),
                ASN1Encoder.encodeUTF8String(dn.commonName)
            ])
        ))

        return ASN1Encoder.encodeSequence(rdnSequence)
    }

    private static func buildValidity(notBefore: Date, notAfter: Date) -> Data {
        ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeUTCTime(notBefore),
            ASN1Encoder.encodeUTCTime(notAfter)
        ])
    }

    private static func buildSubjectPublicKeyInfo(_ publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw CertificateError.publicKeyExtractionFailed
        }

        let algorithmId = ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.rsaEncryption),
            ASN1Encoder.encodeNull()
        ])

        return ASN1Encoder.encodeSequence([
            algorithmId,
            ASN1Encoder.encodeBitString(keyData)
        ])
    }

    /// Builds X.509 v3 extensions for a certificate.
    /// - Parameters:
    ///   - isCA: Whether this is a CA certificate.
    ///   - subject: The subject Distinguished Name.
    ///   - publicKey: The subject's public key for the Subject Key Identifier.
    ///   - authorityPublicKey: The issuer's public key for the Authority Key Identifier.
    private static func buildExtensions(
        isCA: Bool,
        subject: DistinguishedName,
        publicKey: SecKey,
        authorityPublicKey: SecKey
    ) -> Data {
        var extensions: [Data] = []

        // Rule: Only add Basic Constraints for CA certificates.
        // Rationale: Omitting it for leaf certificates avoids "Leaf has invalid basic constraints" errors from iOS trustd.
        if isCA {
            let basicConstraints = buildBasicConstraintsExtension(isCA: true)
            extensions.append(basicConstraints)
        }

        let keyUsage = buildKeyUsageExtension(isCA: isCA)
        extensions.append(keyUsage)

        // Rule: Subject Key Identifier must be present for CA certificates and should be present for all certificates.
        if let ski = buildSubjectKeyIdentifierExtension(publicKey: publicKey) {
            extensions.append(ski)
        }

        // Rule: Authority Key Identifier should be present for all certificates.
        if let aki = buildAuthorityKeyIdentifierExtension(authorityPublicKey: authorityPublicKey) {
            extensions.append(aki)
        }

        if !isCA {
            let extKeyUsage = buildExtendedKeyUsageExtension()
            extensions.append(extKeyUsage)

            // Rationale: Use the Common Name to populate the default SAN for leaf certificates.
            let san = buildSubjectAltNameExtension(subject: subject.commonName)
            extensions.append(san)
        }

        return ASN1Encoder.encodeSequence(extensions)
    }

    /// Builds a Basic Constraints extension for CA certificates.
    /// - Important: Leaf certificates must omit this extension to avoid trustd errors.
    private static func buildBasicConstraintsExtension(isCA: Bool) -> Data {
        precondition(isCA, "Basic Constraints extension should only be added for CA certificates")

        // Rule: cA must be TRUE for CA certificates.
        let bcValue = ASN1Encoder.encodeSequence(Data([0x01, 0x01, 0xFF]))

        return ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.basicConstraints),
            // Rule: Basic Constraints must be critical for CA certificates.
            Data([0x01, 0x01, 0xFF]),
            ASN1Encoder.encodeOctetString(bcValue)
        ])
    }

    /// Builds a Key Usage extension.
    /// RFC 5280 §4.2.1.3 defines the Key Usage bits (from high to low in the first byte).
    ///   bit 0: digitalSignature (0x80)
    ///   bit 1: nonRepudiation   (0x40)
    ///   bit 2: keyEncipherment  (0x20)
    ///   bit 3: dataEncipherment (0x10)
    ///   bit 4: keyAgreement     (0x08)
    ///   bit 5: keyCertSign      (0x04)
    ///   bit 6: cRLSign          (0x02)
    ///   bit 7: encipherOnly     (0x01)
    ///   bit 8: decipherOnly     (0x80 in second byte)
    private static func buildKeyUsageExtension(isCA: Bool) -> Data {
        let keyUsageByte: UInt8
        let unusedBits: UInt8

        if isCA {
            // Rule: CA certificates must allow digitalSignature, keyCertSign, and cRLSign.
            keyUsageByte = 0x86
            // Rule: All 8 bits in the first byte are meaningful for CA usage.
            unusedBits = 0
        } else {
            // Rule: Leaf certificates must allow digitalSignature and keyEncipherment.
            keyUsageByte = 0xA0
            // Rule: Only bits 0 and 2 are used for leaf certificates.
            unusedBits = 5
        }

        let bitStringData = Data([keyUsageByte])
        let keyUsageValue = ASN1Encoder.encodeBitString(bitStringData, unusedBits: unusedBits)

        return ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.keyUsage),
            // Rule: Key Usage must be critical for these certificates.
            Data([0x01, 0x01, 0xFF]),
            ASN1Encoder.encodeOctetString(keyUsageValue)
        ])
    }

    /// Builds an Extended Key Usage extension.
    private static func buildExtendedKeyUsageExtension() -> Data {
        let eku = ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.serverAuth),
            ASN1Encoder.encodeObjectIdentifier(OID.clientAuth)
        ])

        return ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.extendedKeyUsage),
            ASN1Encoder.encodeOctetString(eku)
        ])
    }

    /// Builds a Subject Alternative Name extension.
    private static func buildSubjectAltNameExtension(subject: String) -> Data {
        if let ipData = ipAddressData(subject) {
            let ipName = ASN1Encoder.encodeContextSpecific(7, ipData, constructed: false)
            let san = ASN1Encoder.encodeSequence([ipName])
            return ASN1Encoder.encodeSequence([
                ASN1Encoder.encodeObjectIdentifier(OID.subjectAltName),
                ASN1Encoder.encodeOctetString(san)
            ])
        }

        // Rationale: Convert IDNs to ASCII using punycode (RFC 3492) for DNSName.
        let encodedSubject: String = if subject.allSatisfy(\.isASCII) {
            subject
        } else {
            Punycode.encodeDomain(subject)
        }

        guard let subjectData = encodedSubject.data(using: .ascii) else {
            // Edge case: Return an empty SAN when ASCII encoding fails.
            return ASN1Encoder.encodeSequence([
                ASN1Encoder.encodeObjectIdentifier(OID.subjectAltName),
                ASN1Encoder.encodeOctetString(ASN1Encoder.encodeSequence([]))
            ])
        }

        // Rule: Use an exact DNSName SAN matching the requested host; do not widen scope with wildcards.
        let dnsName = ASN1Encoder.encodeContextSpecific(2, subjectData, constructed: false)
        let san = ASN1Encoder.encodeSequence([dnsName])

        return ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.subjectAltName),
            ASN1Encoder.encodeOctetString(san)
        ])
    }

    /// Builds a Subject Key Identifier extension.
    /// RFC 5280 §4.2.1.2 requires this for CA certificates.
    private static func buildSubjectKeyIdentifierExtension(publicKey: SecKey) -> Data? {
        guard let keyHash = computePublicKeyHash(publicKey) else { return nil }

        let skiValue = ASN1Encoder.encodeOctetString(keyHash)

        return ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.subjectKeyIdentifier),
            // Rule: Subject Key Identifier must not be marked critical per RFC 5280.
            ASN1Encoder.encodeOctetString(skiValue)
        ])
    }

    /// Builds an Authority Key Identifier extension.
    /// RFC 5280 §4.2.1.1 recommends this for all certificates.
    private static func buildAuthorityKeyIdentifierExtension(authorityPublicKey: SecKey) -> Data? {
        guard let keyHash = computePublicKeyHash(authorityPublicKey) else { return nil }

        // Rule: AKI uses the keyIdentifier [0] IMPLICIT form.
        let keyIdentifier = ASN1Encoder.encodeContextSpecific(0, keyHash, constructed: false)
        let akiValue = ASN1Encoder.encodeSequence([keyIdentifier])

        return ASN1Encoder.encodeSequence([
            ASN1Encoder.encodeObjectIdentifier(OID.authorityKeyIdentifier),
            // Rule: Authority Key Identifier must not be marked critical per RFC 5280.
            ASN1Encoder.encodeOctetString(akiValue)
        ])
    }

    /// Computes the SHA-1 hash of the public key for SKI and AKI.
    private static func computePublicKeyHash(_ publicKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }

        // Rule: SKI/AKI uses a 160-bit SHA-1 hash of the subjectPublicKey bit string.
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        keyData.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(keyData.count), &hash)
        }

        return Data(hash)
    }

    private static func ipAddressData(_ subject: String) -> Data? {
        var v4 = in_addr()
        if subject.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return Data(bytes: &v4, count: MemoryLayout<in_addr>.size)
        }

        var v6 = in6_addr()
        if subject.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return Data(bytes: &v6, count: MemoryLayout<in6_addr>.size)
        }

        return nil
    }

    /// Signs data using a private key.
    private static func signData(_ data: Data, with privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?

        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw CertificateError.keyGenerationFailed(error?.takeRetainedValue())
        }

        return signature
    }
}

// MARK: - Shared Formatters

extension ASN1Encoder {
    private static let utcTimeFormatterLock = NSLock()
    private static let utcTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
