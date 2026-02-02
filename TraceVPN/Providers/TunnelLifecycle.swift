//
//  TunnelLifecycle.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/28.
//

import Foundation

/// Serializes tunnel lifecycle operations across concurrent NE callbacks.
///
/// Motivation: iOS can call `startTunnel` multiple times concurrently. The tunnel provider must:
/// - Call each invocation's completion handler exactly once
/// - Avoid starting the underlying tunnel more than once (port binding, duplicate packet loops, etc.)
///
/// This actor deduplicates concurrent starts and serializes stop relative to start.
final actor TunnelLifecycle {
    private enum State {
        case stopped
        case starting(Task<Void, Error>)
        case running
        case stopping(Task<Void, Never>)
    }

    private var state: State = .stopped
    private var activeInvocationID: String?

    func currentInvocationID() -> String? {
        activeInvocationID
    }

    func start(
        invocationID: String,
        _ startImpl: @Sendable @escaping () async throws -> Void
    ) async throws {
        while true {
            switch state {
            case .running:
                return

            case let .starting(task):
                try await task.value
                return

            case let .stopping(task):
                await task.value
                continue

            case .stopped:
                activeInvocationID = invocationID
                let task = Task {
                    try await startImpl()
                }
                state = .starting(task)
                do {
                    try await task.value
                    state = .running
                    return
                } catch {
                    activeInvocationID = nil
                    state = .stopped
                    throw error
                }
            }
        }
    }

    func stop(_ stopImpl: @Sendable @escaping () async -> Void) async {
        switch state {
        case .stopped:
            activeInvocationID = nil
            return

        case let .stopping(task):
            await task.value
            return

        case let .starting(task):
            task.cancel()
            _ = try? await task.value

        case .running:
            break
        }

        let stopTask = Task {
            await stopImpl()
        }
        state = .stopping(stopTask)
        await stopTask.value
        activeInvocationID = nil
        state = .stopped
    }
}
