//
//  DirtyFlags.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation

final class DirtyFlags: @unchecked Sendable {
    private var rulesDirty = false
    private var mapsDirty = false
    private var scriptsDirty = false
    private let lock = NSLock()

    var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rulesDirty || mapsDirty || scriptsDirty
    }

    func markRulesDirty() {
        lock.lock()
        defer { lock.unlock() }
        rulesDirty = true
    }

    func markMapsDirty() {
        lock.lock()
        defer { lock.unlock() }
        mapsDirty = true
    }

    func markScriptsDirty() {
        lock.lock()
        defer { lock.unlock() }
        scriptsDirty = true
    }

    func clearAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasDirty = rulesDirty || mapsDirty || scriptsDirty
        rulesDirty = false
        mapsDirty = false
        scriptsDirty = false
        return wasDirty
    }
}
