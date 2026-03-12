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

    private let baseManager: PersistentCollectionManager<BreakpointPreset>
    private var cancellables: Set<AnyCancellable> = []
    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    public var presets: [BreakpointPreset] {
        baseManager.items
    }

    private init() {
        self.baseManager = PersistentCollectionManager(
            fileName: "BreakpointPresets.json",
            notificationName: "BreakpointPresetsChanged",
            logger: FeatureLog.breakpoint,
            itemName: "breakpoint_preset"
        )

        baseManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    public func savePreset(_ preset: BreakpointPreset) {
        baseManager.add(preset)
    }

    public func loadPreset(_ presetId: UUID) -> BreakpointPreset? {
        presets.first { $0.id == presetId }
    }

    public func applyPreset(_ presetId: UUID) {
        guard let preset = loadPreset(presetId) else { return }
        Task {
            await BreakpointManager.shared.updateConfiguration(preset.configuration)
        }
    }
}
