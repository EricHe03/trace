//
//  NetworkThrottlingController.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Stores the current throttling state for use across the app and extensions.
public final class NetworkThrottlingController: @unchecked Sendable {
    public static let shared = NetworkThrottlingController()

    private let queue = DispatchQueue(label: "com.trace.throttling.state")
    private var state: NetworkThrottlingState = .disabled
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueToken: UInt8 = 1

    private init() {
        queue.setSpecific(key: queueKey, value: queueToken)
    }

    public func updateState(_ newState: NetworkThrottlingState) {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            state = newState
            return
        }
        queue.sync {
            self.state = newState
        }
    }

    public func currentState() -> NetworkThrottlingState {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            return state
        }
        return queue.sync { state }
    }

    public func applyMetadata(to request: inout NetworkRequest) {
        let current = currentState()
        guard current.enabled, let condition = current.condition else { return }
        request.wasThrottled = true
        request.throttlingProfile = condition.displayName
    }
}
