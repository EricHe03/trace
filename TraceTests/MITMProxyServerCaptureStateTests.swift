//
//  MITMProxyServerCaptureStateTests.swift
//  TraceTests
//
//  Created by Codex on 2026/03/12.
//

import XCTest
@testable import TraceCore
@testable import TraceProxy

final class MITMProxyServerCaptureStateTests: XCTestCase {
    func testCaptureLifecycleStateTreatsBareTunneledSnapshotAsPending() {
        let request = NetworkRequest(
            url: "https://example.com/pending",
            method: .get,
            duration: 0.25
        )

        XCTAssertEqual(
            MITMProxyServer.captureLifecycleState(for: request),
            .pending
        )
    }

    func testCaptureLifecycleStateTreatsCancelledSnapshotAsTerminalFailure() {
        var request = NetworkRequest(
            url: "https://example.com/cancelled",
            method: .get,
            duration: 0.25
        )
        request.wasCancelled = true

        XCTAssertEqual(
            MITMProxyServer.captureLifecycleState(for: request),
            .terminalFailure(reason: "client_cancelled_before_response")
        )
    }

    func testCaptureLifecycleStateTreatsExecutionErrorAsTerminalFailure() {
        var request = NetworkRequest(
            url: "https://example.com/failed",
            method: .get,
            duration: 0.25
        )
        request.executionErrors = [ExecutionError(message: "upstream_connection_closed")]

        XCTAssertEqual(
            MITMProxyServer.captureLifecycleState(for: request),
            .terminalFailure(reason: "upstream_connection_closed")
        )
    }

    func testCaptureLifecycleStateTreatsResponseAsTerminalSuccess() {
        var request = NetworkRequest(
            url: "https://example.com/success",
            method: .get,
            duration: 0.25
        )
        request.statusCode = 200
        request.statusMessage = "OK"

        XCTAssertEqual(
            MITMProxyServer.captureLifecycleState(for: request),
            .terminalSuccess
        )
    }
}
