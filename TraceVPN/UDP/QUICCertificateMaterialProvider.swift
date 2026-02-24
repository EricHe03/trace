//
//  QUICCertificateMaterialProvider.swift
//  TraceVPN
//
//  Created by Codex on 2026/02/22.
//

import Foundation
import TraceQUIC

actor QUICCertificateMaterialProvider {
    typealias MaterialGenerator = @Sendable (String) -> QUICMitmCertificateMaterial?

    private struct CachedEntry: Sendable {
        let material: QUICMitmCertificateMaterial
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private let materialGenerator: MaterialGenerator
    private let maxCacheEntries = 4096

    private var cache: [String: CachedEntry] = [:]
    private var inflight: [String: Task<QUICMitmCertificateMaterial?, Never>] = [:]

    init(
        ttl: TimeInterval = 1800,
        materialGenerator: @escaping MaterialGenerator
    ) {
        self.ttl = max(60, ttl)
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
