//
//  TLSProxyConnectionTests.swift
//  TraceTests
//
//  Updated for NIO TLS data-plane models.
//

@testable import TraceCore
import XCTest

final class TLSProxyConnectionTests: XCTestCase {
    func testTLSConnectionInfoStoresALPNMetadata() {
        let info = TLSConnectionInfo(
            protocolVersion: "TLSv1.3",
            cipherSuite: "TLS_AES_128_GCM_SHA256",
            certificateChain: nil,
            certificatePinningEnabled: false,
            certificateTrusted: true,
            alpnProtocol: "h2",
            alpnOffered: ["h2", "http/1.1"],
            alpnAvailable: ["h2", "http/1.1"]
        )

        XCTAssertEqual(info.protocolVersion, "TLSv1.3")
        XCTAssertEqual(info.cipherSuite, "TLS_AES_128_GCM_SHA256")
        XCTAssertEqual(info.alpnProtocol, "h2")
        XCTAssertEqual(info.alpnOffered, ["h2", "http/1.1"])
        XCTAssertEqual(info.alpnAvailable, ["h2", "http/1.1"])
        XCTAssertTrue(info.certificateTrusted)
    }

    func testCertificateInfoValidityWindow() {
        let now = Date()
        let cert = CertificateInfo(
            subject: "CN=example.com",
            issuer: "CN=Trace Test Root",
            validFrom: now.addingTimeInterval(-60),
            validUntil: now.addingTimeInterval(45 * 24 * 60 * 60),
            fingerprint: "abc123",
            publicKeyAlgorithm: "ECDSA P-256",
            serialNumber: "01"
        )

        XCTAssertTrue(cert.isValid)
        XCTAssertFalse(cert.isExpiringSoon)
    }

    func testCertificateInfoExpiringSoon() {
        let now = Date()
        let cert = CertificateInfo(
            subject: "CN=soon.example.com",
            issuer: "CN=Trace Test Root",
            validFrom: now.addingTimeInterval(-60),
            validUntil: now.addingTimeInterval(2 * 24 * 60 * 60),
            fingerprint: "def456",
            publicKeyAlgorithm: "RSA 2048",
            serialNumber: nil
        )

        XCTAssertTrue(cert.isValid)
        XCTAssertTrue(cert.isExpiringSoon)
    }

    func testNetworkTimingPhasesTotalMatchesSum() {
        let phases = NetworkTimingPhases(
            dnsLookup: 0.01,
            tcpConnection: 0.02,
            tlsHandshake: 0.03,
            requestSent: 0.04,
            ttfb: 0.05,
            contentDownload: 0.06,
            redirectTime: 0.07
        )

        XCTAssertEqual(phases.total, 0.28, accuracy: 0.0001)
        XCTAssertTrue(phases.hasData)
        XCTAssertEqual(phases.breakdown.count, 7)
    }

    func testNetworkRequestDurationIsMutableForStreamingUpdates() {
        var request = NetworkRequest(
            url: "https://example.com/stream",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 0,
            requestHeaders: [],
            responseHeaders: [],
            requestBody: .empty,
            responseBody: .empty
        )

        request.duration = 1.25

        XCTAssertEqual(request.duration, 1.25, accuracy: 0.0001)
    }
}
