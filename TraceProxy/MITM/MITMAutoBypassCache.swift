//
//  MITMAutoBypassCache.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/12.
//

import Darwin
import Foundation
import TraceCore

private func defaultMITMAutoBypassAliasResolver(_ host: String) -> [String] {
    MITMAutoBypassCache.resolveAliasIPs(for: host)
}

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

    private struct PersistedState: Codable {
        let entries: [Entry]
        let aliases: [Entry]
    }

    private enum Storage {
        static let key = "proxy.mitm_auto_bypass.entries.v1"
        static let cleanupLegacyTrustFailuresKey = "proxy.mitm_auto_bypass.cleanup_legacy_trust_failures.v1"
        static let cleanupLegacyTransientSetupFailuresKey = "proxy.mitm_auto_bypass.cleanup_legacy_transient_setup_failures.v1"
        static let cleanupLegacyQUICFailuresKey = "proxy.mitm_auto_bypass.cleanup_legacy_quic_failures.v1"
        static let maxEntries = 2048
        static let maxAliasEntries = 4096
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var aliasEntries: [String: Entry] = [:]
    private var resolvingHosts: Set<String> = []
    private let aliasResolutionQueue: DispatchQueue
    private let defaults: UserDefaults?
    private let defaultTTL: TimeInterval
    private let reasonTTLResolver: @Sendable (String, TimeInterval) -> TimeInterval
    private let nowProvider: @Sendable () -> Date
    private let aliasResolver: @Sendable (String) -> [String]
    private let resolveAliasesAsynchronously: Bool

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: AppGroupConfiguration.appGroupIdentifier) ?? .standard,
        ttl: TimeInterval = 60 * 60,
        reasonTTLResolver: @escaping @Sendable (String, TimeInterval) -> TimeInterval = MITMAutoBypassCache.defaultReasonTTLResolver,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        aliasResolver: @escaping @Sendable (String) -> [String] = defaultMITMAutoBypassAliasResolver,
        resolveAliasesAsynchronously: Bool = true,
        aliasResolutionQueue: DispatchQueue = DispatchQueue(
            label: "com.trace.proxy.mitm_auto_bypass.alias_resolution",
            qos: .userInitiated
        )
    ) {
        self.defaults = defaults
        defaultTTL = ttl
        self.reasonTTLResolver = reasonTTLResolver
        self.nowProvider = nowProvider
        self.aliasResolver = aliasResolver
        self.resolveAliasesAsynchronously = resolveAliasesAsynchronously
        self.aliasResolutionQueue = aliasResolutionQueue

        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        cleanupLegacyTrustFailuresLocked()
        cleanupLegacyTransientSetupFailuresLocked()
        cleanupLegacyQUICFailuresLocked()
    }

    func shouldBypass(host: String) -> Bool {
        let key = normalizedHostKey(host)
        lock.lock()
        defer { lock.unlock() }
        if pruneLocked(now: nowProvider()) {
            persistLocked()
        }
        return entries[key] != nil || aliasEntries[key] != nil
    }

    func reason(host: String) -> String? {
        let key = normalizedHostKey(host)
        lock.lock()
        defer { lock.unlock() }
        if pruneLocked(now: nowProvider()) {
            persistLocked()
        }
        return entries[key]?.reason ?? aliasEntries[key]?.reason
    }

    func record(host: String, reason: String) {
        record(host: host, reason: reason, relatedHosts: [])
    }

    func record(host: String, reason: String, relatedHosts: [String]) {
        let now = nowProvider()
        let ttlSeconds = ttl(for: reason)
        let expiresAt = now.addingTimeInterval(ttlSeconds)
        let relatedKeys = Set(([host] + relatedHosts).map(normalizedHostKey))
            .filter { !$0.isEmpty }

        var hostsNeedingAliasResolution: [String] = []
        lock.lock()
        _ = pruneLocked(now: now)
        for key in relatedKeys {
            let entry = Entry(
                host: key,
                reason: reason,
                createdAt: now,
                expiresAt: expiresAt
            )
            entries[key] = entry
            if Self.isIPAddressLiteral(key) {
                aliasEntries[key] = entry
            } else if !resolvingHosts.contains(key) {
                resolvingHosts.insert(key)
                hostsNeedingAliasResolution.append(key)
            }
        }

        _ = trimToCapacityLocked()
        _ = trimAliasesToCapacityLocked()
        persistLocked()
        lock.unlock()

        for host in hostsNeedingAliasResolution {
            resolveAliases(for: host)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        aliasEntries.removeAll()
        resolvingHosts.removeAll()
        persistLocked()
    }

    private func pruneLocked(now: Date) -> Bool {
        let originalEntryCount = entries.count
        let originalAliasCount = aliasEntries.count
        entries = entries.filter { _, entry in entry.expiresAt > now }
        aliasEntries = aliasEntries.filter { _, entry in entry.expiresAt > now }
        return entries.count != originalEntryCount || aliasEntries.count != originalAliasCount
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

    private func trimAliasesToCapacityLocked() -> Bool {
        let overflow = aliasEntries.count - Storage.maxAliasEntries
        guard overflow > 0 else { return false }

        let oldest = aliasEntries.values
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.host < rhs.host
                }
                return lhs.createdAt < rhs.createdAt
            }
            .prefix(overflow)

        for entry in oldest {
            aliasEntries.removeValue(forKey: entry.host)
        }
        return true
    }

    private func persistLocked() {
        guard let defaults else { return }

        guard !entries.isEmpty || !aliasEntries.isEmpty else {
            defaults.removeObject(forKey: Storage.key)
            return
        }

        do {
            let state = PersistedState(
                entries: Array(entries.values),
                aliases: Array(aliasEntries.values)
            )
            let data = try JSONEncoder().encode(state)
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

        if let decodedState = try? JSONDecoder().decode(PersistedState.self, from: data) {
            entries = mergedEntries(decodedState.entries)
            aliasEntries = mergedEntries(decodedState.aliases)
        } else if let decodedEntries = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = mergedEntries(decodedEntries)
            aliasEntries = [:]
        } else {
            defaults.removeObject(forKey: Storage.key)
            return
        }

        let now = nowProvider()
        let pruned = pruneLocked(now: now)
        let trimmedEntries = trimToCapacityLocked()
        let trimmedAliases = trimAliasesToCapacityLocked()
        if pruned || trimmedEntries || trimmedAliases {
            persistLocked()
        }
    }

    private func cleanupLegacyTrustFailuresLocked() {
        guard let defaults else { return }
        guard !defaults.bool(forKey: Storage.cleanupLegacyTrustFailuresKey) else { return }

        let originalEntryCount = entries.count
        let originalAliasCount = aliasEntries.count

        entries = entries.filter { _, entry in
            entry.reason.lowercased() != "upstream trust failure"
        }
        aliasEntries = aliasEntries.filter { _, entry in
            entry.reason.lowercased() != "upstream trust failure"
        }

        if entries.count != originalEntryCount || aliasEntries.count != originalAliasCount {
            persistLocked()
        }

        defaults.set(true, forKey: Storage.cleanupLegacyTrustFailuresKey)
    }

    private func cleanupLegacyTransientSetupFailuresLocked() {
        guard let defaults else { return }
        guard !defaults.bool(forKey: Storage.cleanupLegacyTransientSetupFailuresKey) else { return }

        let transientReasons: Set<String> = [
            "mitm setup failure",
            "upstream timeout",
            "upstream connection closed",
            "connection closed early"
        ]

        let originalEntryCount = entries.count
        let originalAliasCount = aliasEntries.count

        entries = entries.filter { _, entry in
            !transientReasons.contains(entry.reason.lowercased())
        }
        aliasEntries = aliasEntries.filter { _, entry in
            !transientReasons.contains(entry.reason.lowercased())
        }

        if entries.count != originalEntryCount || aliasEntries.count != originalAliasCount {
            persistLocked()
        }

        defaults.set(true, forKey: Storage.cleanupLegacyTransientSetupFailuresKey)
    }

    private func cleanupLegacyQUICFailuresLocked() {
        guard let defaults else { return }
        guard !defaults.bool(forKey: Storage.cleanupLegacyQUICFailuresKey) else { return }

        let quicReasons: Set<String> = [
            "quic no progress fail open",
            "quic handshake failure"
        ]

        let originalEntryCount = entries.count
        let originalAliasCount = aliasEntries.count

        entries = entries.filter { _, entry in
            !quicReasons.contains(entry.reason.lowercased())
        }
        aliasEntries = aliasEntries.filter { _, entry in
            !quicReasons.contains(entry.reason.lowercased())
        }

        if entries.count != originalEntryCount || aliasEntries.count != originalAliasCount {
            persistLocked()
        }

        defaults.set(true, forKey: Storage.cleanupLegacyQUICFailuresKey)
    }

    private func mergedEntries(_ source: [Entry]) -> [String: Entry] {
        var merged: [String: Entry] = [:]
        for entry in source {
            let key = normalizedHostKey(entry.host)
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
        return merged
    }

    private func resolveAliases(for host: String) {
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let resolvedIPs = self.aliasResolver(host)
                .map { self.normalizedHostKey($0) }
                .filter { !$0.isEmpty && Self.isIPAddressLiteral($0) }
            let now = self.nowProvider()

            self.lock.lock()
            defer { self.lock.unlock() }

            self.resolvingHosts.remove(host)
            guard let hostEntry = self.entries[host], hostEntry.expiresAt > now else {
                if self.pruneLocked(now: now) {
                    self.persistLocked()
                }
                return
            }

            for ip in resolvedIPs {
                let alias = Entry(
                    host: ip,
                    reason: hostEntry.reason,
                    createdAt: now,
                    expiresAt: hostEntry.expiresAt
                )
                self.aliasEntries[ip] = alias
            }

            let pruned = self.pruneLocked(now: now)
            let trimmedAliases = self.trimAliasesToCapacityLocked()
            if pruned || trimmedAliases || !resolvedIPs.isEmpty {
                self.persistLocked()
            }
        }

        if resolveAliasesAsynchronously {
            aliasResolutionQueue.async(execute: work)
        } else {
            work()
        }
    }

    private func normalizedHostKey(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if trimmed.first == "[", trimmed.last == "]" {
            let inner = String(trimmed.dropFirst().dropLast())
            if !inner.isEmpty {
                return inner
            }
        }
        return trimmed
    }

    private static func isIPAddressLiteral(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        var ipv4Address = in_addr()
        if host.withCString { inet_pton(AF_INET, $0, &ipv4Address) } == 1 {
            return true
        }
        var ipv6Address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &ipv6Address) } == 1
    }

    fileprivate static func resolveAliasIPs(for host: String) -> [String] {
        guard !host.isEmpty else { return [] }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            if info.pointee.ai_family == AF_INET {
                var address = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(buffer.count)) != nil {
                    addresses.insert(String(cString: buffer))
                }
            } else if info.pointee.ai_family == AF_INET6 {
                var address = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &address.sin6_addr, &buffer, socklen_t(buffer.count)) != nil {
                    addresses.insert(String(cString: buffer))
                }
            }
            current = info.pointee.ai_next
        }

        return Array(addresses)
    }

    private func ttl(for reason: String) -> TimeInterval {
        let resolved = reasonTTLResolver(reason, defaultTTL)
        guard resolved.isFinite else { return defaultTTL }
        return max(30, resolved)
    }

    fileprivate static func defaultReasonTTLResolver(_ reason: String, fallbackTTL: TimeInterval) -> TimeInterval {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return fallbackTTL }

        if normalized.contains("client_rejected_mitm_or_pinning") ||
            normalized.contains("certificate pinning") ||
            normalized.contains("pinning requirements") ||
            normalized.contains("pinned certificate") {
            return 86400
        }
        if normalized.contains("mitm_setup_failed") || normalized.contains("mitm setup failure") {
            return 3600
        }
        if normalized.contains("upstream_timeout") ||
            normalized.contains("upstream_connection_closed") {
            return 180
        }
        if normalized.contains("connection_closed_early") || normalized.contains("connection closed early") {
            return 180
        }
        return fallbackTTL
    }
}

/// Public read-only view of MITM auto-bypass state for cross-module routing decisions.
public enum MITMAutoBypassLookup {
    public static func shouldBypass(host: String) -> Bool {
        MITMAutoBypassCache.shared.shouldBypass(host: host)
    }

    public static func reason(for host: String) -> String? {
        MITMAutoBypassCache.shared.reason(host: host)
    }

    public static func record(host: String, reason: String) {
        MITMAutoBypassCache.shared.record(host: host, reason: reason)
    }

    public static func record(host: String, reason: String, relatedHosts: [String]) {
        MITMAutoBypassCache.shared.record(host: host, reason: reason, relatedHosts: relatedHosts)
    }

    public static func reasonForTCPMITM(host: String) -> String? {
        guard let reason = reason(for: host) else {
            return shouldBypass(host: host) ? "" : nil
        }
        return shouldApplyToTCPMITM(reason: reason) ? reason : nil
    }

    public static func shouldApplyToTCPMITM(reason: String) -> Bool {
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }

        // QUIC transport fallback must not disable TCP MITM visibility.
        if normalized.hasPrefix("quic ") || normalized.hasPrefix("quic_") {
            return false
        }
        return true
    }
}
