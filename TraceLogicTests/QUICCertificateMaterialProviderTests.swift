//
//  QUICCertificateMaterialProviderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/22.
//

import Foundation
@testable import TraceQUIC
@testable import TraceVPNKit
import XCTest

final class QUICCertificateMaterialProviderTests: XCTestCase {
    func testCacheHitReturnsWithoutDuplicateGeneration() async {
        let counter = LockedCounter()
        // Provide a cert with notAfter 1 hour out → TTL = 90% of 3600 = 3240s
        let notAfter = Date(timeIntervalSinceReferenceDate: 10000 + 3600)
        let provider = QUICCertificateMaterialProvider(
            materialGenerator: { _ in
                let seed = counter.incrementAndGet()
                return Self.material(seed: seed, notAfter: notAfter)
            }
        )
        let now = Date(timeIntervalSinceReferenceDate: 10000)

        let first = await provider.material(for: "example.com", now: now)
        let second = await provider.material(for: "example.com", now: now.addingTimeInterval(5))

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(first?.leafCertificateDER, second?.leafCertificateDER)
        XCTAssertEqual(first?.privateKeyDER, second?.privateKeyDER)
    }

    func testConcurrentSameAuthorityRequestsJoinInflightTask() async {
        let counter = LockedCounter()
        let notAfter = Date(timeIntervalSinceReferenceDate: 20000 + 3600)
        let provider = QUICCertificateMaterialProvider(
            materialGenerator: { _ in
                Thread.sleep(forTimeInterval: 0.05)
                let seed = counter.incrementAndGet()
                return Self.material(seed: seed, notAfter: notAfter)
            }
        )
        let now = Date(timeIntervalSinceReferenceDate: 20000)

        var results: [QUICMitmCertificateMaterial?] = []
        await withTaskGroup(of: QUICMitmCertificateMaterial?.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await provider.material(for: "example.com", now: now)
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(results.count, 8)
        let leafSet = Set(results.compactMap { $0?.leafCertificateDER })
        XCTAssertEqual(leafSet.count, 1)
    }

    func testTTLDerivedFromUpstreamCertExpiry() async {
        let counter = LockedCounter()
        let now = Date(timeIntervalSinceReferenceDate: 30000)
        // Upstream cert valid for exactly 100 seconds from now → derived TTL = 90s
        let notAfter = now.addingTimeInterval(100)
        let provider = QUICCertificateMaterialProvider(
            materialGenerator: { _ in
                let seed = counter.incrementAndGet()
                return Self.material(seed: seed, notAfter: notAfter)
            }
        )

        let first = await provider.material(for: "example.com", now: now)
        // At t+89 (within 90s window) → cache hit
        let second = await provider.material(for: "example.com", now: now.addingTimeInterval(89))
        // At t+91 (past derived TTL of 90s) → regenerated
        let third = await provider.material(for: "example.com", now: now.addingTimeInterval(91))

        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(first?.leafCertificateDER, second?.leafCertificateDER)
        XCTAssertNotEqual(first?.leafCertificateDER, third?.leafCertificateDER)
    }

    func testFallbackTTLUsedWhenNoNotAfter() async {
        let counter = LockedCounter()
        let now = Date(timeIntervalSinceReferenceDate: 40000)
        let provider = QUICCertificateMaterialProvider(
            materialGenerator: { _ in
                let seed = counter.incrementAndGet()
                return Self.material(seed: seed, notAfter: nil)
            }
        )

        let first = await provider.material(for: "example.com", now: now)
        // At t+3599 (under 1-hour fallback TTL) → cache hit
        let second = await provider.material(for: "example.com", now: now.addingTimeInterval(3599))
        // At t+3601 (past 1-hour fallback) → regenerated
        let third = await provider.material(for: "example.com", now: now.addingTimeInterval(3601))

        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(first?.leafCertificateDER, second?.leafCertificateDER)
        XCTAssertNotEqual(first?.leafCertificateDER, third?.leafCertificateDER)
    }

    func testMaxTTLCapsLongLivedCerts() async {
        let counter = LockedCounter()
        let now = Date(timeIntervalSinceReferenceDate: 50000)
        // Upstream cert valid for 90 days → derived TTL would be 90*86400*0.9 = ~7M seconds,
        // but is capped at maxTTL = 28800s (8 hours).
        let notAfter = now.addingTimeInterval(90 * 86400)
        let provider = QUICCertificateMaterialProvider(
            materialGenerator: { _ in
                let seed = counter.incrementAndGet()
                return Self.material(seed: seed, notAfter: notAfter)
            }
        )

        let first = await provider.material(for: "example.com", now: now)
        // At t+28799 (just inside 8-hour cap) → cache hit
        let second = await provider.material(for: "example.com", now: now.addingTimeInterval(28799))
        // At t+28801 (just past 8-hour cap) → regenerated
        let third = await provider.material(for: "example.com", now: now.addingTimeInterval(28801))

        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(first?.leafCertificateDER, second?.leafCertificateDER)
        XCTAssertNotEqual(first?.leafCertificateDER, third?.leafCertificateDER)
    }

    func testFailedInflightGenerationDoesNotPoisonNextRequest() async {
        let counter = LockedCounter()
        let notAfter = Date(timeIntervalSinceReferenceDate: 60000 + 3600)
        let provider = QUICCertificateMaterialProvider(
            materialGenerator: { _ in
                let seed = counter.incrementAndGet()
                if seed == 1 {
                    return nil
                }
                return Self.material(seed: seed, notAfter: notAfter)
            }
        )
        let now = Date(timeIntervalSinceReferenceDate: 60000)

        let first = await provider.material(for: "example.com", now: now)
        let second = await provider.material(for: "example.com", now: now.addingTimeInterval(1))

        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(counter.value, 2)
    }

    private static func material(seed: Int, notAfter: Date?) -> QUICMitmCertificateMaterial {
        let low = UInt8(seed & 0xFF)
        let high = UInt8((seed >> 8) & 0xFF)
        return QUICMitmCertificateMaterial(
            leafCertificateDER: Data([0x30, low, high]),
            privateKeyDER: Data([0x02, high, low]),
            upstreamNotAfter: notAfter
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
