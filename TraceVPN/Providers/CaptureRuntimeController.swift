//
//  CaptureRuntimeController.swift
//  TraceVPN
//
//  Created by Codex on 2026/02/24.
//

import Foundation
import TraceCore

enum CaptureReconfigurationKind: String, Sendable {
    case disruptive
    case nonDisruptive = "non_disruptive"
}

struct CaptureReconfigurationPlan: Sendable {
    let id: String
    let kind: CaptureReconfigurationKind
    let reason: String
    let fromMode: CaptureMode
    let toMode: CaptureMode
    let tunnelGeneration: Int
}

/// Serializes runtime reconfiguration and emits a stable begin/commit/rollback event sequence.
actor CaptureRuntimeController {
    private var nextID: UInt64 = 1
    private var tunnelGeneration: Int = 0

    func currentTunnelGeneration() -> Int {
        tunnelGeneration
    }

    func classify(currentMode: CaptureMode, newMode: CaptureMode) -> CaptureReconfigurationKind {
        currentMode == newMode ? .nonDisruptive : .disruptive
    }

    @discardableResult
    func performReconfiguration(
        currentMode: CaptureMode,
        newMode: CaptureMode,
        reason: String,
        eventSink: (String, String) -> Void,
        apply: (CaptureReconfigurationPlan) async throws -> Void
    ) async throws -> CaptureReconfigurationPlan {
        let kind = classify(currentMode: currentMode, newMode: newMode)
        let id = "reconfig_\(nextID)"
        nextID &+= 1

        let plan = CaptureReconfigurationPlan(
            id: id,
            kind: kind,
            reason: reason,
            fromMode: currentMode,
            toMode: newMode,
            tunnelGeneration: tunnelGeneration
        )

        eventSink(
            "reconfig_begin",
            "id=\(id) reason=\(reason) type=\(kind.rawValue) from=\(currentMode.rawValue) to=\(newMode.rawValue) tunnel_generation=\(tunnelGeneration)"
        )

        do {
            try await apply(plan)

            if kind == .disruptive {
                tunnelGeneration &+= 1
            }
            eventSink(
                "reconfig_commit",
                "id=\(id) reason=\(reason) type=\(kind.rawValue) from=\(currentMode.rawValue) to=\(newMode.rawValue) tunnel_generation=\(tunnelGeneration)"
            )
            return plan
        } catch {
            eventSink(
                "reconfig_rollback",
                "id=\(id) reason=\(reason) type=\(kind.rawValue) from=\(currentMode.rawValue) to=\(newMode.rawValue) tunnel_generation=\(tunnelGeneration) error=\(error.localizedDescription)"
            )
            throw error
        }
    }
}
