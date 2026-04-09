//
//  BreakpointPresetManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Combine
import Foundation
import TraceCore

@available(*, deprecated, message: "Use BreakpointManager.shared preset APIs instead.")
@MainActor
public final class BreakpointPresetManager: ObservableObject {
    public static let shared = BreakpointPresetManager()
    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    public var presets: [BreakpointPreset] {
        BreakpointManager.shared.presets
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: .breakpointPresetsUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public func savePreset(_ preset: BreakpointPreset) {
        BreakpointManager.shared.savePreset(preset)
    }

    public func loadPreset(_ presetId: UUID) -> BreakpointPreset? {
        BreakpointManager.shared.loadPreset(presetId)
    }

    public func applyPreset(_ presetId: UUID) {
        BreakpointManager.shared.applyPreset(presetId)
    }
}
