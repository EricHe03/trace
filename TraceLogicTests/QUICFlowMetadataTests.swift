//
//  QUICFlowMetadataTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/18.
//

import XCTest
@testable import TraceCore

final class QUICFlowMetadataTests: XCTestCase {
    func testInspectionOutcomeDisplayNames() {
        XCTAssertEqual(QUICInspectionOutcome.intercepted.displayName, "Intercepted")
        XCTAssertEqual(QUICInspectionOutcome.passThroughMarked.displayName, "Pass Through (Marked)")
        XCTAssertEqual(QUICInspectionOutcome.blocked.displayName, "Blocked")
        XCTAssertEqual(QUICInspectionOutcome.tunnelForwarded.displayName, "Tunnel Forwarded")
    }

    func testHandshakeOutcomeDisplayNames() {
        XCTAssertEqual(QUICHandshakeOutcome.negotiated.displayName, "Negotiated")
        XCTAssertEqual(QUICHandshakeOutcome.failed.displayName, "Failed")
        XCTAssertEqual(QUICHandshakeOutcome.passThrough.displayName, "Pass Through")
        XCTAssertEqual(QUICHandshakeOutcome.blocked.displayName, "Blocked")
    }

    func testQUICFlowMetadataCodableRoundTrip() throws {
        let original = QUICFlowMetadata(
            version: "0x00000001",
            alpn: "h3",
            sniHash: "hash",
            sourceConnectionIDLength: 8,
            destinationConnectionIDLength: 12,
            handshakeOutcome: .passThrough,
            failureReason: "quic_mitm_pipeline_not_ready",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(QUICFlowMetadata.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
