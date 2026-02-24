//
//  DualMITMCircuitBreaker.swift
//  TraceCore
//
//  Created by Codex on 2026/02/21.
//

import Foundation

public struct DualMITMCircuitBreakerSnapshot: Sendable {
    public let enabled: Bool
    public let tcpAttempts: Int
    public let tcpFailures: Int
    public let tcpFailureRate: Double
    public let quicAttemptsInWindow: Int
    public let quicFailuresInWindow: Int
    public let quicFailureRate: Double
    public let isDegraded: Bool
    public let degradedUntil: Date?
    public let degradeReason: String?
}

/// Shared circuit breaker for connectivity-first dual MITM mode.
///
/// The breaker degrades interception temporarily when failure rates indicate
/// broad instability:
/// - TCP MITM client-handshake failures > 35% over the last 100 attempts.
/// - QUIC intercept failures > 40% over the last 60 seconds once enough samples exist.
public final class DualMITMCircuitBreaker: @unchecked Sendable {
    public static let shared = DualMITMCircuitBreaker()

    private struct QUICSample: Sendable {
        let timestamp: Date
        let failed: Bool
    }

    private let lock = NSLock()

    private var enabled = true
    private var cooldownSeconds: TimeInterval = 300
    private var tcpWindowSize = 100
    private var quicWindowSeconds: TimeInterval = 60
    private var quicMinimumSamples = 20
    private var tcpFailureThreshold = 0.35
    private var quicFailureThreshold = 0.40

    private var tcpClientHandshakeOutcomes: [Bool] = []
    private var quicSamples: [QUICSample] = []
    private var degradedUntil: Date?
    private var degradeReason: String?

    public init() {}

    public func configure(
        enabled: Bool,
        cooldownSeconds: TimeInterval = 300,
        tcpWindowSize: Int = 100,
        quicWindowSeconds: TimeInterval = 60,
        quicMinimumSamples: Int = 20,
        tcpFailureThreshold: Double = 0.35,
        quicFailureThreshold: Double = 0.40
    ) {
        lock.lock()
        defer { lock.unlock() }

        self.enabled = enabled
        self.cooldownSeconds = max(30, cooldownSeconds)
        self.tcpWindowSize = max(10, tcpWindowSize)
        self.quicWindowSeconds = max(10, quicWindowSeconds)
        self.quicMinimumSamples = max(1, quicMinimumSamples)
        self.tcpFailureThreshold = max(0.05, min(1.0, tcpFailureThreshold))
        self.quicFailureThreshold = max(0.05, min(1.0, quicFailureThreshold))
        // Reset rolling windows and degraded status when configuration changes so
        // stale observations from previous sessions do not leak across reconfigure.
        tcpClientHandshakeOutcomes.removeAll(keepingCapacity: false)
        quicSamples.removeAll(keepingCapacity: false)
        degradedUntil = nil
        degradeReason = nil
    }

    public func recordTCPClientHandshake(success: Bool, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }

        maybeExitDegradedLocked(now: now)

        tcpClientHandshakeOutcomes.append(success)
        let overflow = tcpClientHandshakeOutcomes.count - tcpWindowSize
        if overflow > 0 {
            tcpClientHandshakeOutcomes.removeFirst(overflow)
        }

        evaluateAndTripLocked(now: now)
    }

    public func recordQUICInterceptSample(failed: Bool, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }

        maybeExitDegradedLocked(now: now)
        quicSamples.append(QUICSample(timestamp: now, failed: failed))
        pruneQUICSamplesLocked(now: now)
        evaluateAndTripLocked(now: now)
    }

    public func shouldForceTCPDirect(port: UInt16, now: Date = Date()) -> Bool {
        guard port == 443 else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return false }
        maybeExitDegradedLocked(now: now)
        guard let degradedUntil else { return false }
        return degradedUntil > now
    }

    public func shouldForceQUICPassThrough(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return false }
        maybeExitDegradedLocked(now: now)
        guard let degradedUntil else { return false }
        return degradedUntil > now
    }

    public func snapshot(now: Date = Date()) -> DualMITMCircuitBreakerSnapshot {
        lock.lock()
        defer { lock.unlock() }

        maybeExitDegradedLocked(now: now)
        pruneQUICSamplesLocked(now: now)

        let tcpAttempts = tcpClientHandshakeOutcomes.count
        let tcpFailures = tcpClientHandshakeOutcomes.count(where: { !$0 })
        let tcpFailureRate = tcpAttempts > 0 ? Double(tcpFailures) / Double(tcpAttempts) : 0

        let quicAttempts = quicSamples.count
        let quicFailures = quicSamples.filter(\.failed).count
        let quicFailureRate = quicAttempts > 0 ? Double(quicFailures) / Double(quicAttempts) : 0

        let degradedActive = degradedUntil.map { $0 > now } ?? false
        return DualMITMCircuitBreakerSnapshot(
            enabled: enabled,
            tcpAttempts: tcpAttempts,
            tcpFailures: tcpFailures,
            tcpFailureRate: tcpFailureRate,
            quicAttemptsInWindow: quicAttempts,
            quicFailuresInWindow: quicFailures,
            quicFailureRate: quicFailureRate,
            isDegraded: degradedActive,
            degradedUntil: degradedUntil,
            degradeReason: degradeReason
        )
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        tcpClientHandshakeOutcomes.removeAll(keepingCapacity: false)
        quicSamples.removeAll(keepingCapacity: false)
        degradedUntil = nil
        degradeReason = nil
    }

    private func evaluateAndTripLocked(now: Date) {
        guard degradedUntil == nil || degradedUntil.map({ $0 <= now }) == true else {
            return
        }

        let tcpAttempts = tcpClientHandshakeOutcomes.count
        let tcpFailures = tcpClientHandshakeOutcomes.count(where: { !$0 })
        let tcpFailureRate = tcpAttempts > 0 ? Double(tcpFailures) / Double(tcpAttempts) : 0

        let quicAttempts = quicSamples.count
        let quicFailures = quicSamples.filter(\.failed).count
        let quicFailureRate = quicAttempts > 0 ? Double(quicFailures) / Double(quicAttempts) : 0

        if tcpAttempts >= tcpWindowSize, tcpFailureRate > tcpFailureThreshold {
            degradedUntil = now.addingTimeInterval(cooldownSeconds)
            degradeReason = "tcp_client_handshake_failure_rate"
            return
        }

        if quicAttempts >= quicMinimumSamples, quicFailureRate > quicFailureThreshold {
            degradedUntil = now.addingTimeInterval(cooldownSeconds)
            degradeReason = "quic_intercept_failure_rate"
        }
    }

    private func maybeExitDegradedLocked(now: Date) {
        guard let degradedUntil else { return }
        guard degradedUntil <= now else { return }
        self.degradedUntil = nil
        degradeReason = nil
    }

    private func pruneQUICSamplesLocked(now: Date) {
        guard !quicSamples.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-quicWindowSeconds)
        quicSamples = quicSamples.filter { $0.timestamp >= cutoff }
    }
}
