//
//  StartCompletionGate.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/11.
//

import Foundation

/// Guards a `startTunnel` invocation's completion handler, ensuring it is called at most once.
///
/// iOS may call `startTunnel` concurrently. When this happens, the provider may decide to treat
/// one invocation as the active one; older invocations must not be completed after a newer
/// invocation becomes active.
final actor StartCompletionGate {
    private var activeInvocationID: String?
    private var didCompleteActiveInvocation = false

    func begin(invocationID: String) {
        activeInvocationID = invocationID
        didCompleteActiveInvocation = false
    }

    func shouldComplete(invocationID: String) -> Bool {
        guard invocationID == activeInvocationID else { return false }
        guard !didCompleteActiveInvocation else { return false }
        didCompleteActiveInvocation = true
        return true
    }
}
