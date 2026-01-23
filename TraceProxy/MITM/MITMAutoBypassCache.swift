//
//  MITMAutoBypassCache.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/12.
//

import Foundation

/// Caches hosts that should bypass MITM temporarily.
///
/// This avoids repeatedly breaking connectivity for hosts that reject MITM
/// (for example, certificate pinning or stricter trust rules). This does not
/// make pinned TLS decryptable; it only helps the proxy fall back to a
/// passthrough tunnel on subsequent attempts.
final class MITMAutoBypassCache: @unchecked Sendable {
    static let shared = MITMAutoBypassCache()

    struct Entry: Sendable {
        let host: String
        let reason: String
        let createdAt: Date
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Defines the default TTL for bypass entries.
    private let ttl: TimeInterval = 60 * 60 // Default TTL is 1 hour.

    private init() {}

    func shouldBypass(host: String) -> Bool {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: Date())
        return entries[key] != nil
    }

    func reason(host: String) -> String? {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: Date())
        return entries[key]?.reason
    }

    func record(host: String, reason: String) {
        let key = host.lowercased()
        let now = Date()
        let entry = Entry(
            host: key,
            reason: reason,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        lock.lock()
        defer { lock.unlock() }
        entries[key] = entry
    }

    private func pruneLocked(now: Date) {
        guard !entries.isEmpty else { return }
        entries = entries.filter { _, entry in entry.expiresAt > now }
    }
}
