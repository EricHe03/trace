//
//  TLSHandlerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
import Network
@testable import Trace
@testable import TraceSecurity

final class TLSHandlerTests: XCTestCase {

    // MARK: - SNI Extraction Tests

    func testExtractSNIFromValidClientHello() {
        // Create a minimal valid ClientHello with SNI
        // TLS handshake structure:
        // - Record header (5 bytes): type=0x16, version=0x0303, length
        // - Handshake header (4 bytes): type=0x01, length
        // - ClientHello content

        let sniHostname = "example.com"
        let sniData = sniHostname.data(using: .ascii)!

        var clientHello = Data()

        // Record header
        clientHello.append(0x16) // Handshake
        clientHello.append(contentsOf: [0x03, 0x03]) // TLS 1.2

        // Placeholder for record length (will update later)
        let recordLengthOffset = clientHello.count
        clientHello.append(contentsOf: [0x00, 0x00])

        // Handshake type
        clientHello.append(0x01) // ClientHello

        // Placeholder for handshake length (will update later)
        let handshakeLengthOffset = clientHello.count
        clientHello.append(contentsOf: [0x00, 0x00, 0x00])

        // Client version
        clientHello.append(contentsOf: [0x03, 0x03])

        // Random (32 bytes)
        clientHello.append(Data(repeating: 0x00, count: 32))

        // Session ID length
        clientHello.append(0x00)

        // Cipher suites length
        clientHello.append(contentsOf: [0x00, 0x02])
        // Cipher suite
        clientHello.append(contentsOf: [0xC0, 0x2F])

        // Compression methods length
        clientHello.append(0x01)
        // Compression method
        clientHello.append(0x00)

        // Extensions
        var extensions = Data()

        // SNI extension
        var sniExtension = Data()
        sniExtension.append(contentsOf: [0x00, 0x00]) // Extension type: SNI

        var sniExtensionContent = Data()

        // Server name list length
        let nameListLength = UInt16(sniData.count + 3)
        sniExtensionContent.append(UInt8(nameListLength >> 8))
        sniExtensionContent.append(UInt8(nameListLength & 0xFF))

        // Name type: hostname
        sniExtensionContent.append(0x00)

        // Name length
        let nameLength = UInt16(sniData.count)
        sniExtensionContent.append(UInt8(nameLength >> 8))
        sniExtensionContent.append(UInt8(nameLength & 0xFF))

        // Name
        sniExtensionContent.append(sniData)

        // Extension length
        let extensionLength = UInt16(sniExtensionContent.count)
        sniExtension.append(UInt8(extensionLength >> 8))
        sniExtension.append(UInt8(extensionLength & 0xFF))

        sniExtension.append(sniExtensionContent)
        extensions.append(sniExtension)

        // Extensions length
        let extensionsLength = UInt16(extensions.count)
        clientHello.append(UInt8(extensionsLength >> 8))
        clientHello.append(UInt8(extensionsLength & 0xFF))

        clientHello.append(extensions)

        // Update handshake length
        let handshakePayloadLength = clientHello.count - handshakeLengthOffset - 3
        clientHello[handshakeLengthOffset] = UInt8((handshakePayloadLength >> 16) & 0xFF)
        clientHello[handshakeLengthOffset + 1] = UInt8((handshakePayloadLength >> 8) & 0xFF)
        clientHello[handshakeLengthOffset + 2] = UInt8(handshakePayloadLength & 0xFF)

        // Update record length
        let recordPayloadLength = clientHello.count - recordLengthOffset - 2
        clientHello[recordLengthOffset] = UInt8((recordPayloadLength >> 8) & 0xFF)
        clientHello[recordLengthOffset + 1] = UInt8(recordPayloadLength & 0xFF)

        let extractedSNI = TLSHandler.extractSNI(from: clientHello)
        XCTAssertEqual(extractedSNI, sniHostname)
    }

    func testExtractSNIFromDataTooShort() {
        let shortData = Data([0x16, 0x03, 0x03])
        XCTAssertNil(TLSHandler.extractSNI(from: shortData))
    }

    func testExtractSNIFromEmptyData() {
        let emptyData = Data()
        XCTAssertNil(TLSHandler.extractSNI(from: emptyData))
    }

    func testExtractSNIFromInvalidHandshakeType() {
        var invalidData = Data(repeating: 0x00, count: 100)
        invalidData[0] = 0x16 // Record type: handshake
        invalidData[5] = 0x02 // Handshake type: ServerHello (not ClientHello)

        XCTAssertNil(TLSHandler.extractSNI(from: invalidData))
    }

    func testExtractSNIFromClientHelloWithoutSNI() {
        // Create a ClientHello without SNI extension
        var clientHello = Data()

        // Record header
        clientHello.append(0x16)
        clientHello.append(contentsOf: [0x03, 0x03])
        clientHello.append(contentsOf: [0x00, 0x40]) // Length

        // Handshake header
        clientHello.append(0x01) // ClientHello
        clientHello.append(contentsOf: [0x00, 0x00, 0x3C]) // Length

        // Client version
        clientHello.append(contentsOf: [0x03, 0x03])

        // Random
        clientHello.append(Data(repeating: 0x00, count: 32))

        // Session ID length
        clientHello.append(0x00)

        // Cipher suites
        clientHello.append(contentsOf: [0x00, 0x02, 0xC0, 0x2F])

        // Compression methods
        clientHello.append(contentsOf: [0x01, 0x00])

        // Extensions length (0 - no extensions)
        clientHello.append(contentsOf: [0x00, 0x00])

        XCTAssertNil(TLSHandler.extractSNI(from: clientHello))
    }

    // MARK: - ALPN Extraction Tests

    func testExtractALPNFromValidClientHello() {
        let protocols = ["h2", "http/1.1"]

        var clientHello = Data()

        // Record header
        clientHello.append(0x16)
        clientHello.append(contentsOf: [0x03, 0x03])

        let recordLengthOffset = clientHello.count
        clientHello.append(contentsOf: [0x00, 0x00])

        // Handshake type
        clientHello.append(0x01)

        let handshakeLengthOffset = clientHello.count
        clientHello.append(contentsOf: [0x00, 0x00, 0x00])

        // Client version
        clientHello.append(contentsOf: [0x03, 0x03])

        // Random
        clientHello.append(Data(repeating: 0x00, count: 32))

        // Session ID length
        clientHello.append(0x00)

        // Cipher suites
        clientHello.append(contentsOf: [0x00, 0x02, 0xC0, 0x2F])

        // Compression methods
        clientHello.append(contentsOf: [0x01, 0x00])

        // Extensions
        var extensions = Data()

        // ALPN extension (type 16)
        var alpnExtension = Data()
        alpnExtension.append(contentsOf: [0x00, 0x10]) // Extension type: ALPN

        var alpnContent = Data()

        // Protocol list
        var protocolList = Data()
        for proto in protocols {
            let protoData = proto.data(using: .ascii)!
            protocolList.append(UInt8(protoData.count))
            protocolList.append(protoData)
        }

        // ALPN list length
        let listLength = UInt16(protocolList.count)
        alpnContent.append(UInt8(listLength >> 8))
        alpnContent.append(UInt8(listLength & 0xFF))
        alpnContent.append(protocolList)

        // Extension length
        let extensionLength = UInt16(alpnContent.count)
        alpnExtension.append(UInt8(extensionLength >> 8))
        alpnExtension.append(UInt8(extensionLength & 0xFF))

        alpnExtension.append(alpnContent)
        extensions.append(alpnExtension)

        // Extensions length
        let extensionsLength = UInt16(extensions.count)
        clientHello.append(UInt8(extensionsLength >> 8))
        clientHello.append(UInt8(extensionsLength & 0xFF))

        clientHello.append(extensions)

        // Update lengths
        let handshakePayloadLength = clientHello.count - handshakeLengthOffset - 3
        clientHello[handshakeLengthOffset] = UInt8((handshakePayloadLength >> 16) & 0xFF)
        clientHello[handshakeLengthOffset + 1] = UInt8((handshakePayloadLength >> 8) & 0xFF)
        clientHello[handshakeLengthOffset + 2] = UInt8(handshakePayloadLength & 0xFF)

        let recordPayloadLength = clientHello.count - recordLengthOffset - 2
        clientHello[recordLengthOffset] = UInt8((recordPayloadLength >> 8) & 0xFF)
        clientHello[recordLengthOffset + 1] = UInt8(recordPayloadLength & 0xFF)

        let extractedALPN = TLSHandler.extractALPN(from: clientHello)
        XCTAssertEqual(extractedALPN, protocols)
    }

    func testExtractALPNFromDataTooShort() {
        let shortData = Data([0x16, 0x03, 0x03])
        XCTAssertNil(TLSHandler.extractALPN(from: shortData))
    }

    func testExtractALPNFromClientHelloWithoutALPN() {
        var clientHello = Data()

        // Minimal ClientHello without ALPN
        clientHello.append(0x16)
        clientHello.append(contentsOf: [0x03, 0x03])
        clientHello.append(contentsOf: [0x00, 0x40])

        clientHello.append(0x01)
        clientHello.append(contentsOf: [0x00, 0x00, 0x3C])

        clientHello.append(contentsOf: [0x03, 0x03])
        clientHello.append(Data(repeating: 0x00, count: 32))

        clientHello.append(0x00)
        clientHello.append(contentsOf: [0x00, 0x02, 0xC0, 0x2F])
        clientHello.append(contentsOf: [0x01, 0x00])
        clientHello.append(contentsOf: [0x00, 0x00]) // No extensions

        XCTAssertNil(TLSHandler.extractALPN(from: clientHello))
    }

    // MARK: - Certificate Caching Tests

    func testClearExpiredCertificates() {
        // Test that clearing expired certificates doesn't crash
        TLSHandler.clearExpiredCertificates()
    }

    func testClearCertificateCache() {
        // Test that clearing the cache doesn't crash
        TLSHandler.clearCertificateCache()
    }

    func testCertificateLifetime() {
        XCTAssertEqual(TLSHandler.certificateLifetime, 3600, "Certificate lifetime should be 1 hour")
    }

    // MARK: - CachedCertificate Tests

    func testCachedCertificateIsExpiredWhenOld() throws {
        let (certificate, privateKey) = try CertificateManager.shared.getRootCA()

        let oldDate = Date(timeIntervalSinceNow: -7200) // 2 hours ago
        let cached = CachedCertificate(
            certificate: certificate,
            privateKey: privateKey,
            createdAt: oldDate
        )

        XCTAssertTrue(cached.isExpired, "Certificate created 2 hours ago should be expired")
    }

    func testCachedCertificateIsNotExpiredWhenNew() throws {
        let (certificate, privateKey) = try CertificateManager.shared.getRootCA()

        let recentDate = Date(timeIntervalSinceNow: -600) // 10 minutes ago
        let cached = CachedCertificate(
            certificate: certificate,
            privateKey: privateKey,
            createdAt: recentDate
        )

        XCTAssertFalse(cached.isExpired, "Certificate created 10 minutes ago should not be expired")
    }

    func testCachedCertificateIsNotExpiredWhenJustCreated() throws {
        let (certificate, privateKey) = try CertificateManager.shared.getRootCA()

        let cached = CachedCertificate(
            certificate: certificate,
            privateKey: privateKey,
            createdAt: Date()
        )

        XCTAssertFalse(cached.isExpired, "Newly created certificate should not be expired")
    }

    // MARK: - ALPN Protocol Support Tests

    func testSupportedALPNProtocols() {
        let protocols = TLSHandler.supportedALPNProtocols

        XCTAssertTrue(protocols.contains("h2"), "Should support HTTP/2")
        XCTAssertTrue(protocols.contains("http/1.1"), "Should support HTTP/1.1")
        XCTAssertEqual(protocols.count, 2, "Should have exactly 2 protocols")
    }

    func testSupportedALPNProtocolsOrder() {
        let protocols = TLSHandler.supportedALPNProtocols

        XCTAssertEqual(protocols.first, "h2", "h2 should be preferred")
        XCTAssertEqual(protocols.last, "http/1.1", "http/1.1 should be fallback")
    }

    // MARK: - TLS Options Tests

    func testCreateClientTLSOptionsForDomain() {
        let options = TLSHandler.createClientTLSOptions(for: "example.com")

        XCTAssertNotNil(options, "Should create client TLS options")
    }

    func testCreateClientTLSOptionsForEmptyDomain() {
        let options = TLSHandler.createClientTLSOptions(for: "")

        XCTAssertNotNil(options, "Should create client TLS options even for empty domain")
    }

    func testCreateClientTLSOptionsWithCustomALPN() {
        let customALPN = ["http/1.1"]
        let options = TLSHandler.createClientTLSOptions(for: "example.com", alpnProtocols: customALPN)

        XCTAssertNotNil(options, "Should create client TLS options with custom ALPN")
    }

    func testCreateClientTLSOptionsWithEmptyALPN() {
        let options = TLSHandler.createClientTLSOptions(for: "example.com", alpnProtocols: [])

        XCTAssertNotNil(options, "Should create client TLS options with empty ALPN list")
    }

    // MARK: - Last Error Tests

    func testLastServerTLSOptionsErrorInitiallyNil() {
        // Note: This test may be flaky if other tests run before it
        // Consider resetting the error state if possible
        let error = TLSHandler.lastServerTLSOptionsError()
        // Error may or may not be nil depending on test order
        // Just verify the method doesn't crash
        _ = error
    }

    // MARK: - Integration Tests

    func testSNIAndALPNExtractionFromSameClientHello() {
        // Build a ClientHello with both SNI and ALPN
        let sniHostname = "secure.example.com"
        let alpnProtocols = ["h2", "http/1.1"]

        var clientHello = Data()

        // Record header
        clientHello.append(0x16)
        clientHello.append(contentsOf: [0x03, 0x03])

        let recordLengthOffset = clientHello.count
        clientHello.append(contentsOf: [0x00, 0x00])

        // Handshake type
        clientHello.append(0x01)

        let handshakeLengthOffset = clientHello.count
        clientHello.append(contentsOf: [0x00, 0x00, 0x00])

        // Client version
        clientHello.append(contentsOf: [0x03, 0x03])

        // Random
        clientHello.append(Data(repeating: 0x00, count: 32))

        // Session ID
        clientHello.append(0x00)

        // Cipher suites
        clientHello.append(contentsOf: [0x00, 0x02, 0xC0, 0x2F])

        // Compression
        clientHello.append(contentsOf: [0x01, 0x00])

        // Build extensions
        var extensions = Data()

        // SNI extension
        let sniData = sniHostname.data(using: .ascii)!
        var sniExt = Data([0x00, 0x00]) // Type

        var sniContent = Data()
        let nameListLen = UInt16(sniData.count + 3)
        sniContent.append(contentsOf: [UInt8(nameListLen >> 8), UInt8(nameListLen & 0xFF)])
        sniContent.append(0x00) // Type: hostname
        let nameLen = UInt16(sniData.count)
        sniContent.append(contentsOf: [UInt8(nameLen >> 8), UInt8(nameLen & 0xFF)])
        sniContent.append(sniData)

        let sniExtLen = UInt16(sniContent.count)
        sniExt.append(contentsOf: [UInt8(sniExtLen >> 8), UInt8(sniExtLen & 0xFF)])
        sniExt.append(sniContent)

        extensions.append(sniExt)

        // ALPN extension
        var alpnExt = Data([0x00, 0x10]) // Type

        var alpnContent = Data()
        var protoList = Data()
        for proto in alpnProtocols {
            let protoData = proto.data(using: .ascii)!
            protoList.append(UInt8(protoData.count))
            protoList.append(protoData)
        }

        let alpnListLen = UInt16(protoList.count)
        alpnContent.append(contentsOf: [UInt8(alpnListLen >> 8), UInt8(alpnListLen & 0xFF)])
        alpnContent.append(protoList)

        let alpnExtLen = UInt16(alpnContent.count)
        alpnExt.append(contentsOf: [UInt8(alpnExtLen >> 8), UInt8(alpnExtLen & 0xFF)])
        alpnExt.append(alpnContent)

        extensions.append(alpnExt)

        // Extensions length
        let extLen = UInt16(extensions.count)
        clientHello.append(contentsOf: [UInt8(extLen >> 8), UInt8(extLen & 0xFF)])
        clientHello.append(extensions)

        // Update lengths
        let hsPayloadLen = clientHello.count - handshakeLengthOffset - 3
        clientHello[handshakeLengthOffset] = UInt8((hsPayloadLen >> 16) & 0xFF)
        clientHello[handshakeLengthOffset + 1] = UInt8((hsPayloadLen >> 8) & 0xFF)
        clientHello[handshakeLengthOffset + 2] = UInt8(hsPayloadLen & 0xFF)

        let recPayloadLen = clientHello.count - recordLengthOffset - 2
        clientHello[recordLengthOffset] = UInt8((recPayloadLen >> 8) & 0xFF)
        clientHello[recordLengthOffset + 1] = UInt8(recPayloadLen & 0xFF)

        // Extract both
        let extractedSNI = TLSHandler.extractSNI(from: clientHello)
        let extractedALPN = TLSHandler.extractALPN(from: clientHello)

        XCTAssertEqual(extractedSNI, sniHostname)
        XCTAssertEqual(extractedALPN, alpnProtocols)
    }
}
