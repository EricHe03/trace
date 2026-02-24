//
//  MITMProxyServerTests.swift
//  TraceTests
//
//  Updated for NIO MITM server lifecycle.
//

import XCTest
@testable import TraceCore
@testable import TraceProxy

final class MITMProxyServerTests: XCTestCase {
    override func tearDownWithError() throws {
        try NIORuntime.shared.shutdown(reason: .tests)
        try super.tearDownWithError()
    }

    func testStartStopIsIdempotent() throws {
        let server = MITMProxyServer(port: 0)

        XCTAssertNoThrow(try server.start())
        XCTAssertNoThrow(try server.start())

        XCTAssertGreaterThanOrEqual(server.activeConnectionCount(), 0)

        server.stop()
        server.stop()
    }

    func testConfigurationAndTogglesCanBeUpdatedBeforeStart() {
        let server = MITMProxyServer(port: 0)

        server.updateConfiguration([
            "transparentTLSModeEnabled": true,
            "proxyTransportBackend": "legacy"
        ])
        server.setMitmAllowlist([" Example.com ", "", "api.example.com"])
        server.setMitmEnabled(true)
        server.updateThrottlingState(.disabled)
        server.updateRawCaptureLimit(16 * 1024 * 1024)
        server.configureRawCapture(enabled: false, writer: nil, limit: 0)

        XCTAssertEqual(server.activeConnectionCount(), 0)
    }

    func testLegacyTransparentTLSConfigKeyAccepted() {
        let server = MITMProxyServer(port: 0)

        server.updateConfiguration([
            "enableTransparentTLSMode": true
        ])

        XCTAssertEqual(server.activeConnectionCount(), 0)
    }

    func testTransparentTLSModeConfigCanToggleWithoutCrash() {
        let server = MITMProxyServer(port: 0)

        server.updateConfiguration([
            "transparentTLSModeEnabled": true
        ])
        server.updateConfiguration([
            "transparentTLSModeEnabled": false
        ])
        server.updateConfiguration([
            "enableTransparentTLSMode": true
        ])

        XCTAssertEqual(server.activeConnectionCount(), 0)
    }

    func testNormalizedAutoBypassReasonMapsTransparentTLSUpgradeTimeoutToNonHTTPProtocol() {
        let reason = "mitm_non_http_protocol: transparent_tls_upgrade_timeout"
        let normalized = MITMProxyServer.normalizedAutoBypassReason(forFailureReason: reason)
        XCTAssertEqual(normalized, "mitm_non_http_protocol")
    }

    func testNormalizedAutoBypassReasonSkipsCANotTrustedFailures() {
        let reason = "ca_not_trusted: root_ca_missing"
        let normalized = MITMProxyServer.normalizedAutoBypassReason(forFailureReason: reason)
        XCTAssertNil(normalized)
    }

    func testNormalizedAutoBypassReasonMapsUpstreamHostnameMismatch() {
        let reason = "tls_upstream_hostname_mismatch: example.com"
        let normalized = MITMProxyServer.normalizedAutoBypassReason(forFailureReason: reason)
        XCTAssertEqual(normalized, "tls_upstream_hostname_mismatch")
    }

    func testNormalizedAutoBypassReasonMapsClientRejectedPinning() {
        let reason = "client_rejected_mitm_or_pinning: niossl_error_0"
        let normalized = MITMProxyServer.normalizedAutoBypassReason(forFailureReason: reason)
        XCTAssertEqual(normalized, "client_rejected_mitm_or_pinning")
    }

    func testNormalizedAutoBypassReasonSkipsConnectionClosedEarly() {
        let reason = "connection_closed_early"
        let normalized = MITMProxyServer.normalizedAutoBypassReason(forFailureReason: reason)
        XCTAssertNil(normalized)
    }

    func testRuntimeBypassCandidateReasonSkipsConnectionClosedEarly() {
        let reason = "connection_closed_early"
        let normalized = MITMProxyServer.runtimeBypassCandidateReason(forFailureReason: reason)
        XCTAssertNil(normalized)
    }

    func testRuntimeBypassCandidateReasonMapsUpstreamTimeout() {
        let reason = "upstream_timeout"
        let normalized = MITMProxyServer.runtimeBypassCandidateReason(forFailureReason: reason)
        XCTAssertEqual(normalized, "upstream_timeout")
    }

    func testRuntimeBypassCandidateReasonReturnsNilForTrustFailure() {
        let reason = "tls_upstream_trust_failed"
        let normalized = MITMProxyServer.runtimeBypassCandidateReason(forFailureReason: reason)
        XCTAssertNil(normalized)
    }

    func testTransientFailureThresholdUsesDefaultForConnectionClosedEarly() {
        let threshold = MITMProxyServer.transientFailureThreshold(
            forRuntimeBypassReason: "connection_closed_early"
        )
        XCTAssertEqual(threshold, 5)
    }

    func testTransientFailureThresholdUsesDefaultForOtherReasons() {
        let threshold = MITMProxyServer.transientFailureThreshold(
            forRuntimeBypassReason: "upstream_timeout"
        )
        XCTAssertEqual(threshold, 5)
    }
}
