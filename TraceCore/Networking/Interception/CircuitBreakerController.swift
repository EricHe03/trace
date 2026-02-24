//
//  CircuitBreakerController.swift
//  TraceCore
//
//  Created by Codex on 2026/02/24.
//

import Foundation

public protocol CircuitBreakerController: AnyObject, Sendable {
    func shouldForceTCPDirect(port: UInt16, now: Date) -> Bool
    func shouldForceQUICPassThrough(now: Date) -> Bool
    func recordTCPClientHandshake(failed: Bool, now: Date)
    func recordQUICInterceptSample(failed: Bool, now: Date)
    func snapshot(now: Date) -> DualMITMCircuitBreakerSnapshot
}

public final class DualMITMCircuitBreakerController: CircuitBreakerController, @unchecked Sendable {
    private let breaker: DualMITMCircuitBreaker

    public init(breaker: DualMITMCircuitBreaker = .shared) {
        self.breaker = breaker
    }

    public func shouldForceTCPDirect(port: UInt16, now: Date) -> Bool {
        breaker.shouldForceTCPDirect(port: port, now: now)
    }

    public func shouldForceQUICPassThrough(now: Date) -> Bool {
        breaker.shouldForceQUICPassThrough(now: now)
    }

    public func recordTCPClientHandshake(failed: Bool, now: Date) {
        breaker.recordTCPClientHandshake(success: !failed, now: now)
    }

    public func recordQUICInterceptSample(failed: Bool, now: Date) {
        breaker.recordQUICInterceptSample(failed: failed, now: now)
    }

    public func snapshot(now: Date) -> DualMITMCircuitBreakerSnapshot {
        breaker.snapshot(now: now)
    }
}

public final class NoopCircuitBreakerController: CircuitBreakerController, @unchecked Sendable {
    public init() {}

    public func shouldForceTCPDirect(port _: UInt16, now _: Date) -> Bool {
        false
    }

    public func shouldForceQUICPassThrough(now _: Date) -> Bool {
        false
    }

    public func recordTCPClientHandshake(failed _: Bool, now _: Date) {}
    public func recordQUICInterceptSample(failed _: Bool, now _: Date) {}
    public func snapshot(now _: Date) -> DualMITMCircuitBreakerSnapshot {
        DualMITMCircuitBreakerSnapshot(
            enabled: false,
            tcpAttempts: 0,
            tcpFailures: 0,
            tcpFailureRate: 0,
            quicAttemptsInWindow: 0,
            quicFailuresInWindow: 0,
            quicFailureRate: 0,
            isDegraded: false,
            degradedUntil: nil,
            degradeReason: nil
        )
    }
}
