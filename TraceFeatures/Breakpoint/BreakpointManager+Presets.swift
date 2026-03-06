//
//  BreakpointManager+Presets.swift
//  TraceFeatures
//
//  Created by AI Assistant on 2026/03/06.
//

import Foundation
import TraceCore

@MainActor
public extension BreakpointManager {
    var presets: [BreakpointPreset] {
        BreakpointPresetManager.shared.presets
    }

    func savePreset(_ preset: BreakpointPreset) {
        BreakpointPresetManager.shared.savePreset(preset)
    }

    func loadPreset(_ presetId: UUID) -> BreakpointPreset? {
        BreakpointPresetManager.shared.loadPreset(presetId)
    }

    func applyPreset(_ presetId: UUID) {
        BreakpointPresetManager.shared.applyPreset(presetId)
    }
}
