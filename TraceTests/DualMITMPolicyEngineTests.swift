//
//  DualMITMPolicyEngineTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

import XCTest
@testable import TraceCore

final class DualMITMPolicyEngineTests: XCTestCase {
    func testPlanNewTCPTransparentFlowReturnsMITMWhenEligible() {
        let engine = makeEngine()

        let plan = engine.planNewTCPTransparentFlow(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(plan.decision, .mitm)
        XCTAssertTrue(plan.shadowEnabled)
        XCTAssertFalse(plan.enforceTCPRouting)
    }

    func testPlanNewTCPTransparentFlowReturnsDirectWhenPortNotIntercepted() {
        let engine = makeEngine(interceptPorts: [443])

        let plan = engine.planNewTCPTransparentFlow(destinationHost: "example.com", destinationPort: 80)

        XCTAssertEqual(plan.decision, .direct(reason: "port_not_intercepted"))
    }

    func testPlanNewTCPTransparentFlowReturnsDirectWhenProxyEndpoint() {
        let engine = makeEngine(mitmProxyHost: "example.com", mitmProxyPort: 443)

        let plan = engine.planNewTCPTransparentFlow(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(plan.decision, .direct(reason: "proxy_endpoint"))
    }

    func testPlanNewTCPTransparentFlowUsesCircuitBreakerInAdaptiveMode() {
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            shouldForceTCPDirect: { port, _ in port == 443 }
        )

        let plan = engine.planNewTCPTransparentFlow(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(plan.decision, .direct(reason: "dual_mitm_circuit_breaker"))
    }

    func testPlanNewTCPTransparentFlowIgnoresCircuitBreakerInStrictMode() {
        let engine = makeEngine(
            policyMode: .strictMITM,
            shouldForceTCPDirect: { _, _ in true }
        )

        let plan = engine.planNewTCPTransparentFlow(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(plan.decision, .mitm)
    }

    func testPlanNewTCPTransparentFlowAppliesAdaptiveBypassReason() {
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            lookupTCPBypass: { host in
                XCTAssertEqual(host, "example.com")
                return DualMITMTCPBypassLookupResult(shouldBypass: true, reason: "Upstream Trust Failure")
            }
        )

        let plan = engine.planNewTCPTransparentFlow(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(plan.decision, .direct(reason: "auto_bypass_upstream_trust_failure"))
    }

    func testPlanNewTCPTransparentFlowIgnoresQUICBypassReason() {
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            lookupTCPBypass: { _ in
                DualMITMTCPBypassLookupResult(shouldBypass: true, reason: "quic_no_progress_fail_open")
            }
        )

        let plan = engine.planNewTCPTransparentFlow(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(plan.decision, .mitm)
    }

    func testPlanNewTCPTransparentFlowIgnoresBypassInStrictMode() {
        let engine = makeEngine(
            policyMode: .strictMITM,
            lookupTCPBypass: { _ in
                DualMITMTCPBypassLookupResult(shouldBypass: true, reason: "client_rejected_mitm_or_pinning")
            }
        )

        let plan = engine.planNewTCPTransparentFlow(destinationHost: "example.com", destinationPort: 443)

        XCTAssertEqual(plan.decision, .mitm)
    }

    func testPlanNewProxyFlowUsesAdaptiveBypassReason() {
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            lookupTCPBypass: { _ in
                DualMITMTCPBypassLookupResult(shouldBypass: true, reason: "mitm_setup_failed")
            }
        )

        let plan = engine.planNewProxyFlow(
            destinationHost: "example.com",
            destinationPort: 443,
            mitmEnabled: true,
            allowlist: ["*"]
        )

        XCTAssertEqual(plan.decision, .passThrough(reason: "auto_bypass_mitm_setup_failed"))
    }

    func testPlanProxyFailureBlocksEligibleStrictFlowWhenEnforced() {
        let engine = makeEngine(
            policyMode: .strictMITM,
            featureFlags: .init(
                shadowEnabled: true,
                enforceTCPRouting: false,
                enforceProxyRouting: true,
                enforceQUICRouting: false,
                mitmEngineV2Enabled: false
            )
        )

        let plan = engine.planProxyFailure(
            destinationHost: "example.com",
            destinationPort: 443,
            failureReason: "mitm_setup_failed",
            mitmEnabled: true,
            allowlist: ["*"]
        )

        XCTAssertEqual(plan.action, .failClosedBlock(reason: "mitm_setup_failed"))
        XCTAssertTrue(plan.enforceProxyRouting)
    }

    func testPlanQUICFailureBlocksStrictFlowWhenEnforced() {
        let engine = makeEngine(
            policyMode: .strictMITM,
            featureFlags: .init(
                shadowEnabled: true,
                enforceTCPRouting: false,
                enforceProxyRouting: false,
                enforceQUICRouting: true,
                mitmEngineV2Enabled: false
            )
        )

        let plan = engine.planQUICFailure(
            destinationHost: "example.com",
            destinationPort: 443,
            failureReason: "quic_no_progress_fail_open",
            quicHandlingMode: .intercept
        )

        XCTAssertEqual(plan.action, .block(reason: "quic_no_progress_fail_open"))
        XCTAssertTrue(plan.enforceQUICRouting)
    }

    private func makeEngine(
        enabled: Bool = true,
        interceptPorts: Set<UInt16> = [443],
        mitmProxyHost: String = "127.0.0.1",
        mitmProxyPort: UInt16 = 8888,
        policyMode: DualMITMPolicy = .adaptiveFailOpen,
        circuitBreakerEnabled: Bool = true,
        featureFlags: DualMITMPolicyFeatureFlags = .init(
            shadowEnabled: true,
            enforceTCPRouting: false
        ),
        shouldForceTCPDirect: @escaping DualMITMPolicyEngine.TCPBreakerLookup = { _, _ in false },
        lookupTCPBypass: @escaping DualMITMPolicyEngine.TCPBypassLookup = { _ in .none }
    ) -> DualMITMPolicyEngine {
        let snapshot = DualMITMPolicySnapshot(
            tcpTransparentMITMEnabled: enabled,
            tcpInterceptPorts: interceptPorts,
            mitmProxyHost: mitmProxyHost,
            mitmProxyPort: mitmProxyPort,
            policyMode: policyMode,
            circuitBreakerEnabled: circuitBreakerEnabled,
            featureFlags: featureFlags
        )
        return DualMITMPolicyEngine(
            snapshot: snapshot,
            shouldForceTCPDirect: shouldForceTCPDirect,
            lookupTCPBypass: lookupTCPBypass
        )
    }
}
