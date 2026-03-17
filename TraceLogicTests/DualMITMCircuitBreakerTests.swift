//
//  DualMITMCircuitBreakerTests.swift
//  TraceTests
//

import XCTest
@testable import TraceCore

final class DualMITMCircuitBreakerTests: XCTestCase {
    func testTripsOnTCPClientHandshakeFailureRateOverThreshold() {
        let breaker = DualMITMCircuitBreaker()
        let now = Date(timeIntervalSince1970: 10_000)
        breaker.configure(
            enabled: true,
            cooldownSeconds: 300,
            tcpWindowSize: 100
        )

        for _ in 0..<40 {
            breaker.recordTCPClientHandshake(success: false, now: now)
        }
        for _ in 0..<60 {
            breaker.recordTCPClientHandshake(success: true, now: now)
        }

        let snapshot = breaker.snapshot(now: now)
        XCTAssertTrue(snapshot.isDegraded)
        XCTAssertTrue(snapshot.tcpIsDegraded)
        XCTAssertFalse(snapshot.quicIsDegraded)
        XCTAssertTrue(breaker.shouldForceTCPDirect(port: 443, now: now))
        XCTAssertFalse(breaker.shouldForceTCPDirect(port: 80, now: now))
        XCTAssertFalse(breaker.shouldForceQUICPassThrough(now: now))
    }

    func testTripsOnQUICFailureRateWindowThreshold() {
        let breaker = DualMITMCircuitBreaker()
        let now = Date(timeIntervalSince1970: 20_000)
        breaker.configure(
            enabled: true,
            cooldownSeconds: 300,
            quicWindowSeconds: 60,
            quicMinimumSamples: 5
        )

        breaker.recordQUICInterceptSample(failed: true, now: now)
        breaker.recordQUICInterceptSample(failed: true, now: now)
        breaker.recordQUICInterceptSample(failed: true, now: now)
        breaker.recordQUICInterceptSample(failed: false, now: now)
        breaker.recordQUICInterceptSample(failed: false, now: now)

        let snapshot = breaker.snapshot(now: now)
        XCTAssertTrue(snapshot.isDegraded)
        XCTAssertFalse(snapshot.tcpIsDegraded)
        XCTAssertTrue(snapshot.quicIsDegraded)
        XCTAssertTrue(breaker.shouldForceQUICPassThrough(now: now))
        XCTAssertFalse(breaker.shouldForceTCPDirect(port: 443, now: now))
    }

    func testCooldownExitClearsDegradedMode() {
        let breaker = DualMITMCircuitBreaker()
        let now = Date(timeIntervalSince1970: 30_000)
        breaker.configure(
            enabled: true,
            cooldownSeconds: 30,
            quicWindowSeconds: 60,
            quicMinimumSamples: 1
        )

        breaker.recordQUICInterceptSample(failed: true, now: now)
        XCTAssertTrue(breaker.snapshot(now: now).isDegraded)
        XCTAssertFalse(breaker.snapshot(now: now.addingTimeInterval(31)).isDegraded)
        XCTAssertFalse(breaker.shouldForceQUICPassThrough(now: now.addingTimeInterval(31)))
        XCTAssertFalse(breaker.shouldForceTCPDirect(port: 443, now: now.addingTimeInterval(31)))
    }

    func testDoesNotTripQUICBeforeMinimumSamples() {
        let breaker = DualMITMCircuitBreaker()
        let now = Date(timeIntervalSince1970: 35_000)
        breaker.configure(
            enabled: true,
            cooldownSeconds: 300,
            quicWindowSeconds: 60,
            quicMinimumSamples: 10,
            quicFailureThreshold: 0.4
        )

        for _ in 0..<5 {
            breaker.recordQUICInterceptSample(failed: true, now: now)
        }

        XCTAssertFalse(breaker.snapshot(now: now).isDegraded)
        XCTAssertFalse(breaker.shouldForceQUICPassThrough(now: now))
    }

    func testConfigureResetsCollectedSamplesAndDegradedState() {
        let breaker = DualMITMCircuitBreaker()
        let now = Date(timeIntervalSince1970: 40_000)
        breaker.configure(
            enabled: true,
            cooldownSeconds: 300,
            tcpWindowSize: 100
        )

        for _ in 0..<40 {
            breaker.recordTCPClientHandshake(success: false, now: now)
        }
        for _ in 0..<60 {
            breaker.recordTCPClientHandshake(success: true, now: now)
        }

        XCTAssertTrue(breaker.snapshot(now: now).isDegraded)
        XCTAssertTrue(breaker.shouldForceTCPDirect(port: 443, now: now))

        breaker.configure(
            enabled: true,
            cooldownSeconds: 300,
            tcpWindowSize: 100
        )

        let snapshotAfterConfigure = breaker.snapshot(now: now)
        XCTAssertFalse(snapshotAfterConfigure.isDegraded)
        XCTAssertEqual(snapshotAfterConfigure.tcpAttempts, 0)
        XCTAssertEqual(snapshotAfterConfigure.tcpFailures, 0)
        XCTAssertEqual(snapshotAfterConfigure.quicAttemptsInWindow, 0)
        XCTAssertEqual(snapshotAfterConfigure.quicFailuresInWindow, 0)
        XCTAssertFalse(breaker.shouldForceTCPDirect(port: 443, now: now))
    }

    func testAllowsSmallTCPWindowForFastFailOpen() {
        let breaker = DualMITMCircuitBreaker()
        let now = Date(timeIntervalSince1970: 50_000)
        breaker.configure(
            enabled: true,
            cooldownSeconds: 300,
            tcpWindowSize: 16,
            tcpFailureThreshold: 0.40
        )

        for _ in 0..<7 {
            breaker.recordTCPClientHandshake(success: false, now: now)
        }
        for _ in 0..<9 {
            breaker.recordTCPClientHandshake(success: true, now: now)
        }

        let snapshot = breaker.snapshot(now: now)
        XCTAssertEqual(snapshot.tcpAttempts, 16)
        XCTAssertEqual(snapshot.tcpFailures, 7)
        XCTAssertTrue(snapshot.isDegraded)
        XCTAssertTrue(snapshot.tcpIsDegraded)
        XCTAssertFalse(snapshot.quicIsDegraded)
        XCTAssertTrue(breaker.shouldForceTCPDirect(port: 443, now: now))
    }

    func testTCPDegradationDoesNotForceQUICPassThrough() {
        let breaker = DualMITMCircuitBreaker()
        let now = Date(timeIntervalSince1970: 60_000)
        breaker.configure(
            enabled: true,
            cooldownSeconds: 300,
            tcpWindowSize: 10,
            quicMinimumSamples: 5,
            tcpFailureThreshold: 0.4
        )

        for _ in 0..<5 {
            breaker.recordTCPClientHandshake(success: false, now: now)
        }
        for _ in 0..<5 {
            breaker.recordTCPClientHandshake(success: true, now: now)
        }

        let snapshot = breaker.snapshot(now: now)
        XCTAssertTrue(snapshot.tcpIsDegraded)
        XCTAssertFalse(snapshot.quicIsDegraded)
        XCTAssertTrue(breaker.shouldForceTCPDirect(port: 443, now: now))
        XCTAssertFalse(breaker.shouldForceQUICPassThrough(now: now))
    }

    func testQUICDegradationDoesNotForceTCPDirect() {
        let breaker = DualMITMCircuitBreaker()
        let now = Date(timeIntervalSince1970: 70_000)
        breaker.configure(
            enabled: true,
            cooldownSeconds: 300,
            tcpWindowSize: 10,
            quicMinimumSamples: 5,
            quicFailureThreshold: 0.4
        )

        breaker.recordQUICInterceptSample(failed: true, now: now)
        breaker.recordQUICInterceptSample(failed: true, now: now)
        breaker.recordQUICInterceptSample(failed: true, now: now)
        breaker.recordQUICInterceptSample(failed: false, now: now)
        breaker.recordQUICInterceptSample(failed: false, now: now)

        let snapshot = breaker.snapshot(now: now)
        XCTAssertFalse(snapshot.tcpIsDegraded)
        XCTAssertTrue(snapshot.quicIsDegraded)
        XCTAssertFalse(breaker.shouldForceTCPDirect(port: 443, now: now))
        XCTAssertTrue(breaker.shouldForceQUICPassThrough(now: now))
    }
}
