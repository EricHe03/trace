//
//  HostBypassStore.swift
//  TraceCore
//
//  Created by Justin on 2026/02/24.
//

import Foundation

public struct HostBypassRecord: Codable, Sendable, Equatable {
    public var host: String
    public var domain: HostBypassDomain
    public var reason: BypassReason
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        host: String,
        domain: HostBypassDomain,
        reason: BypassReason,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.host = host
        self.domain = domain
        self.reason = reason
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public protocol HostBypassStore: AnyObject, Sendable {
    func lookup(host: String, domain: HostBypassDomain, now: Date) -> HostBypassRecord?
    func record(host: String, domain: HostBypassDomain, reason: BypassReason, ttl: TimeInterval, now: Date)
    func clear(host: String?, domain: HostBypassDomain?)
}

public final class InMemoryHostBypassStore: HostBypassStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: HostBypassRecord] = [:]
    private let maxEntries: Int

    public init(maxEntries: Int = 4096) {
        self.maxEntries = max(64, maxEntries)
    }

    public func lookup(host: String, domain: HostBypassDomain, now: Date) -> HostBypassRecord? {
        let normalizedHost = Self.normalizedHost(host)
        guard !normalizedHost.isEmpty else { return nil }

        let key = Self.key(host: normalizedHost, domain: domain)
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        guard let record = records[key], record.expiresAt > now else { return nil }
        return record
    }

    public func record(
        host: String,
        domain: HostBypassDomain,
        reason: BypassReason,
        ttl: TimeInterval,
        now: Date
    ) {
        let normalizedHost = Self.normalizedHost(host)
        guard !normalizedHost.isEmpty else { return }

        let safeTTL = max(1, ttl)
        let record = HostBypassRecord(
            host: normalizedHost,
            domain: domain,
            reason: reason,
            createdAt: now,
            expiresAt: now.addingTimeInterval(safeTTL)
        )

        lock.lock()
        records[Self.key(host: normalizedHost, domain: domain)] = record
        trimToCapacityLocked()
        lock.unlock()
    }

    public func clear(host: String? = nil, domain: HostBypassDomain? = nil) {
        lock.lock()
        defer { lock.unlock() }

        guard host != nil || domain != nil else {
            records.removeAll()
            return
        }

        let normalizedHost = host.map(Self.normalizedHost)
        records = records.filter { _, value in
            if let normalizedHost, !normalizedHost.isEmpty, value.host != normalizedHost {
                return true
            }
            if let domain, value.domain != domain {
                return true
            }
            return false
        }
    }

    private func pruneLocked(now: Date) {
        guard !records.isEmpty else { return }
        records = records.filter { _, record in
            record.expiresAt > now
        }
    }

    private func trimToCapacityLocked() {
        let overflow = records.count - maxEntries
        guard overflow > 0 else { return }

        let oldestKeys = records
            .sorted { lhs, rhs in
                if lhs.value.createdAt == rhs.value.createdAt {
                    return lhs.key < rhs.key
                }
                return lhs.value.createdAt < rhs.value.createdAt
            }
            .prefix(overflow)
            .map(\.key)

        for key in oldestKeys {
            records.removeValue(forKey: key)
        }
    }

    private static func key(host: String, domain: HostBypassDomain) -> String {
        "\(domain.rawValue)|\(host)"
    }

    private static func normalizedHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.first == "[", normalized.last == "]", normalized.count > 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized
    }
}

public final class CompositeHostBypassStore: HostBypassStore, @unchecked Sendable {
    private let stores: [HostBypassStore]

    public init(stores: [HostBypassStore]) {
        self.stores = stores
    }

    public func lookup(host: String, domain: HostBypassDomain, now: Date) -> HostBypassRecord? {
        for store in stores {
            if let record = store.lookup(host: host, domain: domain, now: now) {
                return record
            }
        }
        return nil
    }

    public func record(host: String, domain: HostBypassDomain, reason: BypassReason, ttl: TimeInterval, now: Date) {
        for store in stores {
            store.record(host: host, domain: domain, reason: reason, ttl: ttl, now: now)
        }
    }

    public func clear(host: String?, domain: HostBypassDomain?) {
        for store in stores {
            store.clear(host: host, domain: domain)
        }
    }
}
