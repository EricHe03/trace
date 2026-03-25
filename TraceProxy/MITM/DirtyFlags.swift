//
//  DirtyFlags.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation

final class DirtyFlags: @unchecked Sendable {
    private var dirty = false
    private let lock = NSLock()

    var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dirty
    }

    func markDirty() {
        lock.lock()
        defer { lock.unlock() }
        dirty = true
    }

    func clearAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasDirty = dirty
        dirty = false
        return wasDirty
    }
}
