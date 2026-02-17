//
//  MITMAutoBypassCache.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/12.
//

import Foundation
import TraceCore

/// Caches hosts that should bypass MITM temporarily.
///
/// This avoids repeatedly breaking connectivity for hosts that reject MITM
/// (for example, certificate pinning or stricter trust rules). This does not
/// make pinned TLS decryptable; it only helps the proxy fall back to a
/// passthrough tunnel on subsequent attempts.
final class MITMAutoBypassCache: @unchecked Sendable {
    static let shared = MITMAutoBypassCache()

    struct Entry: Codable, Sendable {
        let host: String
        let reason: String
        let createdAt: Date
        let expiresAt: Date
    }

    private enum Storage {
        static let key = "proxy.mitm_auto_bypass.entries.v1"
        static let maxEntries = 2048
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let defaults: UserDefaults?
    private let ttl: TimeInterval
    private let nowProvider: @Sendable () -> Date

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: AppGroupConfiguration.appGroupIdentifier) ?? .standard,
        ttl: TimeInterval = 60 * 60,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.ttl = ttl
        self.nowProvider = nowProvider

        lock.lock()
        defer { lock.unlock() }
        loadLocked()
    }

    func shouldBypass(host: String) -> Bool {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if pruneLocked(now: nowProvider()) {
            persistLocked()
        }
        return entries[key] != nil
    }

    func reason(host: String) -> String? {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if pruneLocked(now: nowProvider()) {
            persistLocked()
        }
        return entries[key]?.reason
    }

    func record(host: String, reason: String) {
        let key = host.lowercased()
        let now = nowProvider()
        let entry = Entry(
            host: key,
            reason: reason,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        lock.lock()
        defer { lock.unlock() }
        _ = pruneLocked(now: now)
        entries[key] = entry
        _ = trimToCapacityLocked()
        persistLocked()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        persistLocked()
    }

    private func pruneLocked(now: Date) -> Bool {
        guard !entries.isEmpty else { return false }
        let originalCount = entries.count
        entries = entries.filter { _, entry in entry.expiresAt > now }
        return entries.count != originalCount
    }

    private func trimToCapacityLocked() -> Bool {
        let overflow = entries.count - Storage.maxEntries
        guard overflow > 0 else { return false }

        let oldest = entries.values
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.host < rhs.host
                }
                return lhs.createdAt < rhs.createdAt
            }
            .prefix(overflow)

        for entry in oldest {
            entries.removeValue(forKey: entry.host)
        }
        return true
    }

    private func persistLocked() {
        guard let defaults else { return }

        guard !entries.isEmpty else {
            defaults.removeObject(forKey: Storage.key)
            return
        }

        do {
            let data = try JSONEncoder().encode(Array(entries.values))
            defaults.set(data, forKey: Storage.key)
        } catch {
            // Keep runtime cache usable even if persistence fails.
        }
    }

    private func loadLocked() {
        guard let defaults,
              let data = defaults.data(forKey: Storage.key)
        else {
            return
        }

        guard let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            defaults.removeObject(forKey: Storage.key)
            return
        }

        var merged: [String: Entry] = [:]
        for entry in decoded {
            let key = entry.host.lowercased()
            let normalized = Entry(
                host: key,
                reason: entry.reason,
                createdAt: entry.createdAt,
                expiresAt: entry.expiresAt
            )
            if let existing = merged[key] {
                if normalized.createdAt >= existing.createdAt {
                    merged[key] = normalized
                }
            } else {
                merged[key] = normalized
            }
        }

        entries = merged

        let now = nowProvider()
        let pruned = pruneLocked(now: now)
        let trimmed = trimToCapacityLocked()
        if pruned || trimmed {
            persistLocked()
        }
    }
}
