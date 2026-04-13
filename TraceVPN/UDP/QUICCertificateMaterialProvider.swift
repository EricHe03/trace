//
//  QUICCertificateMaterialProvider.swift
//  TraceVPN
//
//  Created by Justin on 2026/02/22.
//

import Foundation
import TraceQUIC

actor QUICCertificateMaterialProvider {
    typealias MaterialGenerator = @Sendable (String) -> QUICMitmCertificateMaterial?

    private struct CachedEntry: Sendable {
        let material: QUICMitmCertificateMaterial
        let expiresAt: Date
    }

    /// Fallback TTL when the upstream certificate expiry is unknown.
    private let defaultTTL: TimeInterval = 3600
    /// Hard cap on derived TTL regardless of how long the upstream cert is valid.
    private let maxTTL: TimeInterval = 28800
    private let materialGenerator: MaterialGenerator
    private let maxCacheEntries = 4096

    private var cache: [String: CachedEntry] = [:]
    private var inflight: [String: Task<QUICMitmCertificateMaterial?, Never>] = [:]

    init(materialGenerator: @escaping MaterialGenerator) {
        self.materialGenerator = materialGenerator
    }

    func material(for authority: String, now: Date = Date()) async -> QUICMitmCertificateMaterial? {
        pruneExpired(now: now)

        if let cached = cache[authority], cached.expiresAt > now {
            return cached.material
        }

        if let task = inflight[authority] {
            return await task.value
        }

        let task = Task { [materialGenerator] in
            materialGenerator(authority)
        }
        inflight[authority] = task

        let value = await task.value
        inflight.removeValue(forKey: authority)

        if let value {
            let ttl = derivedTTL(from: value.upstreamNotAfter, now: now)
            cache[authority] = CachedEntry(
                material: value,
                expiresAt: now.addingTimeInterval(ttl)
            )
            trimIfNeeded()
        }

        return value
    }

    func clear() {
        cache.removeAll(keepingCapacity: false)
        inflight.removeAll(keepingCapacity: false)
    }

    /// Returns a TTL derived from the upstream certificate's remaining validity:
    /// 90% of remaining validity, capped at `maxTTL`, floored at 60 seconds.
    /// Falls back to `defaultTTL` when `notAfter` is nil.
    private func derivedTTL(from notAfter: Date?, now: Date) -> TimeInterval {
        guard let notAfter else { return defaultTTL }
        let remaining = notAfter.timeIntervalSince(now)
        return min(maxTTL, max(60, remaining * 0.9))
    }

    private func pruneExpired(now: Date) {
        guard !cache.isEmpty else { return }
        cache = cache.filter { _, value in
            value.expiresAt > now
        }
    }

    private func trimIfNeeded() {
        guard cache.count > maxCacheEntries else { return }

        let removeCount = cache.count - maxCacheEntries
        let oldest = cache.sorted { lhs, rhs in
            lhs.value.expiresAt < rhs.value.expiresAt
        }

        for index in 0 ..< removeCount {
            cache.removeValue(forKey: oldest[index].key)
        }
    }
}
