//
//  LegacyReasonCodecTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/24.
//

import XCTest
@testable import TraceCore

final class LegacyReasonCodecTests: XCTestCase {
    func testDecodeClientPinningToken() {
        let decoded = LegacyReasonCodec.decode("client_rejected_mitm_or_pinning")

        XCTAssertEqual(decoded.failure, .clientRejectedMITMOrPinning)
        XCTAssertEqual(decoded.bypassReason, .certificatePinning)
        XCTAssertEqual(decoded.domain, .tcpMITM)
    }

    func testDecodeMitmSetupFailedTokenWithDetail() {
        let decoded = LegacyReasonCodec.decode("mitm_setup_failed: pipeline")

        XCTAssertEqual(decoded.failure, .mitmSetupFailed(stage: .pipelineInstall))
        XCTAssertEqual(decoded.bypassReason, .mitmSetupInstability)
        XCTAssertEqual(decoded.domain, .tcpMITM)
    }

    func testDecodeQuicNoProgressToken() {
        let decoded = LegacyReasonCodec.decode("quic_no_progress_fail_open")

        XCTAssertEqual(decoded.failure, .quicNoProgress(detail: .absoluteTimeout))
        XCTAssertEqual(decoded.bypassReason, .mitmSetupInstability)
        XCTAssertEqual(decoded.domain, .quicMITM)
    }

    func testEncodeKnownFailuresUsesStableLegacyToken() {
        XCTAssertEqual(
            LegacyReasonCodec.encode(.clientRejectedMITMOrPinning),
            "client_rejected_mitm_or_pinning"
        )
        XCTAssertEqual(
            LegacyReasonCodec.encode(.quicNoProgress(detail: .idleTimeout)),
            "quic_no_progress_fail_open"
        )
    }
}
