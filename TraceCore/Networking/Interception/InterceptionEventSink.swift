//
//  InterceptionEventSink.swift
//  TraceCore
//
//  Created by Codex on 2026/02/24.
//

import Foundation

public protocol InterceptionEventSink: Sendable {
    func emit(_ event: InterceptionEvent)
}

public struct NullInterceptionEventSink: InterceptionEventSink {
    public init() {}

    public func emit(_: InterceptionEvent) {}
}

public final class ClosureInterceptionEventSink: InterceptionEventSink, @unchecked Sendable {
    private let callback: @Sendable (InterceptionEvent) -> Void

    public init(callback: @escaping @Sendable (InterceptionEvent) -> Void) {
        self.callback = callback
    }

    public func emit(_ event: InterceptionEvent) {
        callback(event)
    }
}

public final class MultiplexInterceptionEventSink: InterceptionEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [InterceptionEventSink]

    public init(sinks: [InterceptionEventSink]) {
        self.sinks = sinks
    }

    public func setSinks(_ sinks: [InterceptionEventSink]) {
        lock.lock()
        self.sinks = sinks
        lock.unlock()
    }

    public func emit(_ event: InterceptionEvent) {
        lock.lock()
        let snapshot = sinks
        lock.unlock()
        for sink in snapshot {
            sink.emit(event)
        }
    }
}
