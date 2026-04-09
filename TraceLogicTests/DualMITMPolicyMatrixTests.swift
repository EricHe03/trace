//
//  DualMITMPolicyMatrixTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

@testable import TraceCore
import XCTest

final class DualMITMPolicyMatrixTests: XCTestCase {
    func testStrictEligibleTCPFailureAlwaysFailClosed() {
        let engine = makeEngine(policy: .strictMITM)
        let start = engine.planNewFlow(
            protocolName: .tcpTransparent,
            destination: HostPort(host: "example.com", port: 443)
        )
        var monitor = StrictConformanceMonitor()

        XCTAssertEqual(start.action, .mitm(reason: "default"))
        XCTAssertTrue(start.profile.isMITMEligible)

        let failures: [InterceptionFailure] = [
            .clientRejectedMITMOrPinning,
            .upstreamTimeout,
            .mitmSetupFailed(stage: .pipelineInstall),
            .internalError(code: .nioUnhandled, context: nil)
        ]

        for failure in failures {
            let plan = engine.handleFailure(profile: start.profile, failure: failure)
            XCTAssertEqual(plan.action, .failClosedBlock(reason: LegacyReasonCodec.encode(failure)))
            monitor.record(
                isEligible: start.profile.isMITMEligible,
                policy: start.profile.snapshot.policyMode,
                action: plan.action
            )
        }
        monitor.assertNoStrictFailOpen()
    }

    func testAdaptivePinningRecordsBypassTTL() {
        let engine = makeEngine(policy: .adaptiveFailOpen)
        let start = engine.planNewFlow(
            protocolName: .httpConnect,
            destination: HostPort(host: "example.com", port: 443)
        )

        let plan = engine.handleFailure(
            profile: start.profile,
            failure: .clientRejectedMITMOrPinning
        )

        XCTAssertEqual(plan.action, .failOpenPassThrough(reason: "client_rejected_mitm_or_pinning"))
        XCTAssertEqual(plan.bypassDomain, .tcpMITM)
        XCTAssertEqual(plan.bypassReason, .certificatePinning)
        XCTAssertEqual(plan.bypassTTLSeconds, 86400)
    }

    func testStrictQUICFailureBlocks() {
        let engine = makeEngine(policy: .strictMITM)
        let start = engine.planNewFlow(
            protocolName: .quic,
            destination: HostPort(host: "example.com", port: 443)
        )

        XCTAssertEqual(start.action, .mitm(reason: "default"))
        XCTAssertTrue(start.profile.isMITMEligible)

        let plan = engine.handleFailure(
            profile: start.profile,
            failure: .quicNoProgress(detail: .idleTimeout)
        )

        XCTAssertEqual(plan.action, .failClosedBlock(reason: "quic_no_progress_fail_open"))
    }

    private func makeEngine(policy: DualMITMPolicy) -> DualMITMPolicyEngine {
        DualMITMPolicyEngine(
            snapshot: DualMITMPolicySnapshot(
                tcpTransparentMITMEnabled: true,
                tcpInterceptPorts: [80, 443],
                mitmProxyHost: "127.0.0.1",
                mitmProxyPort: 8888,
                policyMode: policy,
                circuitBreakerEnabled: true,
                allowlist: ["*"],
                mitmEnabled: true,
                quicHandlingMode: .intercept,
                featureFlags: .init(
                    shadowEnabled: true,
                    enforceTCPRouting: true,
                    enforceProxyRouting: true,
                    enforceQUICRouting: true
                )
            )
        )
    }
}
