//
//  MITMFailureMapperTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

@testable import TraceCore
@testable import TraceProxy
import XCTest

final class MITMFailureMapperTests: XCTestCase {
    func testMapsTransparentFailureKinds() {
        XCTAssertEqual(
            MITMFailureMapper.mapTransparentFailure(.clientRejectedMITMOrPinning(detail: nil)),
            .clientRejectedMITMOrPinning
        )
        XCTAssertEqual(
            MITMFailureMapper.mapTransparentFailure(.upstreamTimeout(detail: nil)),
            .upstreamTimeout
        )
        XCTAssertEqual(
            MITMFailureMapper.mapTransparentFailure(.upstreamConnectionClosed(detail: nil)),
            .upstreamConnectionClosed
        )
        XCTAssertEqual(
            MITMFailureMapper.mapTransparentFailure(.tlsUpstreamTrustFailed(detail: nil)),
            .upstreamTLSTrustFailed
        )
        XCTAssertEqual(
            MITMFailureMapper.mapTransparentFailure(.tlsUpstreamHostnameMismatch(detail: nil)),
            .upstreamTLSHostnameMismatch
        )
        XCTAssertEqual(
            MITMFailureMapper.mapTransparentFailure(.mitmSetupFailed(detail: nil)),
            .mitmSetupFailed(stage: .pipelineInstall)
        )
    }

    func testMapsLegacyReasonTokenFallback() {
        XCTAssertEqual(
            MITMFailureMapper.mapLegacyReason("quic_no_progress_fail_open"),
            .quicNoProgress(detail: .absoluteTimeout)
        )
    }
}
