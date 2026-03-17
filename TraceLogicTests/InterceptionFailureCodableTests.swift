//
//  InterceptionFailureCodableTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

import XCTest
@testable import TraceCore

final class InterceptionFailureCodableTests: XCTestCase {
    func testRoundTripCodableForRepresentativeFailures() throws {
        let failures: [InterceptionFailure] = [
            .localProxyUnreachable,
            .resourceExhausted(kind: .memory),
            .connectionClosedEarly(side: .client),
            .mitmSetupFailed(stage: .pipelineInstall),
            .protocolMismatch(expected: .http3, observed: .nonHTTP),
            .quicHandshakeFailed(detail: .timeout),
            .quicClosedBeforeHTTP3(phase: .beforeHeaders),
            .internalError(code: .nioUnhandled, context: "boom")
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for failure in failures {
            let data = try encoder.encode(failure)
            let decoded = try decoder.decode(InterceptionFailure.self, from: data)
            XCTAssertEqual(decoded, failure)
        }
    }

    func testStableTokenMapsKnownFailures() {
        XCTAssertEqual(InterceptionFailure.clientRejectedMITMOrPinning.stableToken, "client_rejected_mitm_or_pinning")
        XCTAssertEqual(InterceptionFailure.quicNoProgress(detail: .idleTimeout).stableToken, "quic_no_progress")
        XCTAssertEqual(InterceptionFailure.nonHTTPProtocol.stableToken, "non_http_protocol")
    }
}
