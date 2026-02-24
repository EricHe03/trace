//
//  QUICCertificateMaterialProviderTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/22.
//

import Foundation
import XCTest
@testable import TraceQUIC
@testable import TraceVPN

final class QUICCertificateMaterialProviderTests: XCTestCase {
    func testCacheHitReturnsWithoutDuplicateGeneration() async {
        let counter = LockedCounter()
        let provider = QUICCertificateMaterialProvider(
            ttl: 600,
            materialGenerator: { _ in
                let seed = counter.incrementAndGet()
                return Self.material(seed: seed)
            }
        )
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        let first = await provider.material(for: "example.com", now: now)
        let second = await provider.material(for: "example.com", now: now.addingTimeInterval(5))

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(first?.leafCertificateDER, second?.leafCertificateDER)
        XCTAssertEqual(first?.privateKeyDER, second?.privateKeyDER)
    }

    func testConcurrentSameAuthorityRequestsJoinInflightTask() async {
        let counter = LockedCounter()
        let provider = QUICCertificateMaterialProvider(
            ttl: 600,
            materialGenerator: { _ in
                Thread.sleep(forTimeInterval: 0.05)
                let seed = counter.incrementAndGet()
                return Self.material(seed: seed)
            }
        )
        let now = Date(timeIntervalSinceReferenceDate: 20_000)

        var results: [QUICMitmCertificateMaterial?] = []
        await withTaskGroup(of: QUICMitmCertificateMaterial?.self) { group in
            for _ in 0..<8 {
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

    func testTTLExpiryCausesRegeneration() async {
        let counter = LockedCounter()
        let provider = QUICCertificateMaterialProvider(
            ttl: 60,
            materialGenerator: { _ in
                let seed = counter.incrementAndGet()
                return Self.material(seed: seed)
            }
        )
        let now = Date(timeIntervalSinceReferenceDate: 30_000)

        let first = await provider.material(for: "example.com", now: now)
        let second = await provider.material(for: "example.com", now: now.addingTimeInterval(30))
        let third = await provider.material(for: "example.com", now: now.addingTimeInterval(61))

        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(first?.leafCertificateDER, second?.leafCertificateDER)
        XCTAssertNotEqual(first?.leafCertificateDER, third?.leafCertificateDER)
    }

    func testFailedInflightGenerationDoesNotPoisonNextRequest() async {
        let counter = LockedCounter()
        let provider = QUICCertificateMaterialProvider(
            ttl: 60,
            materialGenerator: { _ in
                let seed = counter.incrementAndGet()
                if seed == 1 {
                    return nil
                }
                return Self.material(seed: seed)
            }
        )
        let now = Date(timeIntervalSinceReferenceDate: 40_000)

        let first = await provider.material(for: "example.com", now: now)
        let second = await provider.material(for: "example.com", now: now.addingTimeInterval(1))

        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(counter.value, 2)
    }

    private static func material(seed: Int) -> QUICMitmCertificateMaterial {
        let low = UInt8(seed & 0xFF)
        let high = UInt8((seed >> 8) & 0xFF)
        return QUICMitmCertificateMaterial(
            leafCertificateDER: Data([0x30, low, high]),
            privateKeyDER: Data([0x02, high, low])
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
