//
//  LogThrottle.swift
//  TraceCore
//
//  Created by Justin on 2026/02/01.
//

import Foundation

public final class LogThrottle: @unchecked Sendable {
    private var lastEmit: [String: Date] = [:]
    private let lock = NSLock()

    public static let shared = LogThrottle()

    public init() {}

    public func shouldLog(key: String, minInterval: TimeInterval) -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }

        if let last = lastEmit[key], now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastEmit[key] = now
        return true
    }

    /// Namespaces a key under a logical event group.
    public func shouldLog(event: String, key: String, minInterval: TimeInterval) -> Bool {
        shouldLog(key: "\(event).\(key)", minInterval: minInterval)
    }
}
