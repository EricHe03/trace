//
//  DualMITMPolicySnapshotBuilderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

@testable import TraceCore
import XCTest

final class DualMITMPolicySnapshotBuilderTests: XCTestCase {
    func testDefaultFeatureFlagsStayShadowOnly() {
        let defaults = DualMITMPolicyFeatureFlags.defaults

        #if DEBUG
        XCTAssertTrue(defaults.shadowEnabled)
        #else
        XCTAssertFalse(defaults.shadowEnabled)
        #endif
        XCTAssertFalse(defaults.enforceTCPRouting)
        XCTAssertFalse(defaults.enforceProxyRouting)
        XCTAssertFalse(defaults.enforceQUICRouting)
        XCTAssertFalse(defaults.http2MITMEnabled)
        XCTAssertTrue(defaults.strictEnforcementHardFail)
    }

    func testBuildUsesNormalizedCaptureConfigValues() {
        var config = CaptureConfiguration.default
        config.dualMITMPolicy = .strictMITM
        config.tcpBypassTTLSeconds = 1

        let snapshot = DualMITMPolicySnapshotBuilder.build(
            inputs: .init(
                captureConfiguration: config,
                mitmAllowlist: [" example.com "],
                mitmEnabled: true,
                quicHandlingMode: .intercept,
                featureFlags: .defaults
            ),
            tcpTransparentMITMEnabled: true,
            tcpInterceptPorts: [80, 443],
            mitmProxyHost: "127.0.0.1",
            mitmProxyPort: 8888
        )

        XCTAssertEqual(snapshot.policyMode, .strictMITM)
        XCTAssertGreaterThanOrEqual(snapshot.tcpBypassTTLSeconds, 30)
        XCTAssertGreaterThanOrEqual(snapshot.quicHostFailOpenSeconds, 60)
        XCTAssertGreaterThanOrEqual(snapshot.quicNoProgress.graceMs, 0)
        XCTAssertGreaterThanOrEqual(snapshot.quicNoProgress.minimumClientDatagrams, 1)
        XCTAssertEqual(snapshot.allowlist, ["example.com"])
    }
}
