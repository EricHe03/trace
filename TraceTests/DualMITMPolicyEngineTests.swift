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
                enforceQUICRouting: false
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
                enforceQUICRouting: true
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

    // MARK: - Store & Controller Integration

    func testHandleFailureRecordsTCPBypassToStore() {
        let store = InMemoryHostBypassStore()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            tcpBypassStore: store
        )

        let plan = engine.planNewFlow(
            protocolName: .tcpTransparent,
            destination: HostPort(host: "pinned.example.com", port: 443)
        )
        _ = engine.handleFailure(
            profile: plan.profile,
            failure: .clientRejectedMITMOrPinning
        )

        let now = Date()
        let record = store.lookup(host: "pinned.example.com", domain: .tcpMITM, now: now)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.reason, .certificatePinning)
    }

    func testHandleFailureRecordsQUICBypassToStore() {
        let store = InMemoryHostBypassStore()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            quicFailOpenStore: store
        )

        let plan = engine.planNewFlow(
            protocolName: .quic,
            destination: HostPort(host: "quic.example.com", port: 443)
        )
        _ = engine.handleFailure(
            profile: plan.profile,
            failure: .quicNoProgress(detail: .absoluteTimeout)
        )

        let now = Date()
        let record = store.lookup(host: "quic.example.com", domain: .quicMITM, now: now)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.reason, .mitmSetupInstability)
    }

    func testRecordSuccessFeedsCircuitBreakerController() {
        let spy = SpyCircuitBreakerController()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            circuitBreakerController: spy
        )

        let plan = engine.planNewFlow(
            protocolName: .tcpTransparent,
            destination: HostPort(host: "example.com", port: 443)
        )
        engine.recordSuccess(
            profile: plan.profile,
            details: SuccessDetails(establishedMITM: true)
        )

        XCTAssertEqual(spy.tcpHandshakeCalls.count, 1)
        XCTAssertEqual(spy.tcpHandshakeCalls.first?.failed, false)
    }

    func testRecordSuccessQUICFeedsCircuitBreakerController() {
        let spy = SpyCircuitBreakerController()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            circuitBreakerController: spy
        )

        let plan = engine.planNewFlow(
            protocolName: .quic,
            destination: HostPort(host: "quic.example.com", port: 443)
        )
        engine.recordSuccess(
            profile: plan.profile,
            details: SuccessDetails(establishedMITM: true)
        )

        XCTAssertEqual(spy.quicSampleCalls.count, 1)
        XCTAssertEqual(spy.quicSampleCalls.first?.failed, false)
    }

    func testPinningFailureDoesNotFeedCircuitBreakerController() {
        let spy = SpyCircuitBreakerController()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            circuitBreakerController: spy
        )

        let plan = engine.planNewFlow(
            protocolName: .tcpTransparent,
            destination: HostPort(host: "pinned.example.com", port: 443)
        )
        _ = engine.handleFailure(
            profile: plan.profile,
            failure: .clientRejectedMITMOrPinning
        )

        XCTAssertTrue(spy.tcpHandshakeCalls.isEmpty)
    }

    func testConnectionClosedEarlyDoesNotFeedCircuitBreakerController() {
        let spy = SpyCircuitBreakerController()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            circuitBreakerController: spy
        )

        let plan = engine.planNewFlow(
            protocolName: .httpConnect,
            destination: HostPort(host: "browser-preconnect.example.com", port: 443)
        )
        _ = engine.handleFailure(
            profile: plan.profile,
            failure: .connectionClosedEarly(side: .client)
        )

        XCTAssertTrue(spy.tcpHandshakeCalls.isEmpty)
    }

    func testHandleFailureWithoutSideEffectsDoesNotRecordTCPBypass() {
        let store = InMemoryHostBypassStore()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            tcpBypassStore: store
        )

        let plan = engine.planNewFlow(
            protocolName: .httpConnect,
            destination: HostPort(host: "shadow.example.com", port: 443)
        )
        _ = engine.handleFailure(
            profile: plan.profile,
            failure: .mitmSetupFailed,
            applySideEffects: false
        )

        XCTAssertNil(store.lookup(host: "shadow.example.com", domain: .tcpMITM, now: Date()))
    }

    func testHandleFailureWithoutSideEffectsDoesNotFeedCircuitBreakerController() {
        let spy = SpyCircuitBreakerController()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            circuitBreakerController: spy
        )

        let plan = engine.planNewFlow(
            protocolName: .quic,
            destination: HostPort(host: "shadow-quic.example.com", port: 443)
        )
        _ = engine.handleFailure(
            profile: plan.profile,
            failure: .quicNoProgress(detail: .idleTimeout),
            applySideEffects: false
        )

        XCTAssertTrue(spy.quicSampleCalls.isEmpty)
    }

    func testQUICNoProgressStillFeedsCircuitBreakerController() {
        let spy = SpyCircuitBreakerController()
        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            circuitBreakerController: spy
        )

        let plan = engine.planNewFlow(
            protocolName: .quic,
            destination: HostPort(host: "quic.example.com", port: 443)
        )
        _ = engine.handleFailure(
            profile: plan.profile,
            failure: .quicNoProgress(detail: .idleTimeout)
        )

        XCTAssertEqual(spy.quicSampleCalls.count, 1)
        XCTAssertEqual(spy.quicSampleCalls.first?.failed, true)
    }

    func testTCPBypassStoreUsedForInitialBypass() {
        let store = InMemoryHostBypassStore()
        let now = Date()
        store.record(host: "bypassed.example.com", domain: .tcpMITM, reason: .certificatePinning, ttl: 3600, now: now)

        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            tcpBypassStore: store
        )

        let plan = engine.planNewTCPTransparentFlow(
            destinationHost: "bypassed.example.com",
            destinationPort: 443
        )
        XCTAssertEqual(plan.decision, .direct(reason: "auto_bypass_certificate_pinning"))
    }

    func testQUICFailOpenStoreUsedForInitialBypass() {
        let store = InMemoryHostBypassStore()
        let now = Date()
        store.record(host: "quic-bypass.example.com", domain: .quicMITM, reason: .mitmSetupInstability, ttl: 1800, now: now)

        let engine = makeEngine(
            policyMode: .adaptiveFailOpen,
            quicFailOpenStore: store
        )

        let plan = engine.planNewQUICFlow(
            destinationHost: "quic-bypass.example.com",
            destinationPort: 443,
            quicHandlingMode: .intercept
        )
        XCTAssertEqual(plan.decision, .passThrough(reason: "auto_bypass_mitm_setup_instability"))
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
        lookupTCPBypass: @escaping DualMITMPolicyEngine.TCPBypassLookup = { _ in .none },
        eventSink: InterceptionEventSink = NullInterceptionEventSink(),
        tcpBypassStore: HostBypassStore? = nil,
        quicFailOpenStore: HostBypassStore? = nil,
        circuitBreakerController: CircuitBreakerController? = nil
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
            lookupTCPBypass: lookupTCPBypass,
            eventSink: eventSink,
            tcpBypassStore: tcpBypassStore,
            quicFailOpenStore: quicFailOpenStore,
            circuitBreakerController: circuitBreakerController
        )
    }
}

// MARK: - Test Helpers

private final class SpyCircuitBreakerController: CircuitBreakerController, @unchecked Sendable {
    struct TCPCall { let failed: Bool; let now: Date }
    struct QUICCall { let failed: Bool; let now: Date }

    private let lock = NSLock()
    private var _tcpCalls: [TCPCall] = []
    private var _quicCalls: [QUICCall] = []

    var tcpHandshakeCalls: [TCPCall] {
        lock.lock()
        defer { lock.unlock() }
        return _tcpCalls
    }

    var quicSampleCalls: [QUICCall] {
        lock.lock()
        defer { lock.unlock() }
        return _quicCalls
    }

    func shouldForceTCPDirect(port _: UInt16, now _: Date) -> Bool { false }
    func shouldForceQUICPassThrough(now _: Date) -> Bool { false }

    func recordTCPClientHandshake(failed: Bool, now: Date) {
        lock.lock()
        _tcpCalls.append(TCPCall(failed: failed, now: now))
        lock.unlock()
    }

    func recordQUICInterceptSample(failed: Bool, now: Date) {
        lock.lock()
        _quicCalls.append(QUICCall(failed: failed, now: now))
        lock.unlock()
    }

    func snapshot(now _: Date) -> DualMITMCircuitBreakerSnapshot {
        DualMITMCircuitBreakerSnapshot(
            enabled: false,
            tcpAttempts: 0,
            tcpFailures: 0,
            tcpFailureRate: 0,
            quicAttemptsInWindow: 0,
            quicFailuresInWindow: 0,
            quicFailureRate: 0,
            tcpIsDegraded: false,
            tcpDegradedUntil: nil,
            tcpDegradeReason: nil,
            quicIsDegraded: false,
            quicDegradedUntil: nil,
            quicDegradeReason: nil,
            isDegraded: false,
            degradedUntil: nil,
            degradeReason: nil
        )
    }
}
