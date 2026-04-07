//
//  BodyStorageSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI
import TraceCore
import TraceUI

struct BodyStorageSettingsView: View {
    @State private var bodyStorageConfig: BodyStorageConfig = .default
    @State private var toastMessage: String?
    @State private var isLoading = true
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section {
                ThresholdStepper(
                    title: "Inline Threshold",
                    value: $bodyStorageConfig.inlineThreshold,
                    range: 64 * 1024 ... 50 * 1024 * 1024,
                    step: 256 * 1024
                )

                ThresholdStepper(
                    title: "Truncation Threshold",
                    value: $bodyStorageConfig.truncationThreshold,
                    range: 256 * 1024 ... 200 * 1024 * 1024,
                    step: 1024 * 1024
                )

                ThresholdStepper(
                    title: "Preview Size",
                    value: $bodyStorageConfig.previewSize,
                    range: 64 * 1024 ... 10 * 1024 * 1024,
                    step: 256 * 1024
                )
            } footer: {
                Text("Controls how response bodies are stored and previewed. Inline ≤ Truncation and Preview ≤ Truncation are enforced automatically.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    showingResetConfirmation = true
                }
            }
        }
        .navigationTitle("Body Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSettings()
        }
        .onChangeCompat(of: bodyStorageConfig) { persistConfig() }
        .toast(message: $toastMessage)
        .confirmationDialog(
            "Reset to Defaults",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Body storage thresholds will be restored to their default values.")
        }
    }

    private func loadSettings() async {
        bodyStorageConfig = AppGroupStorage.shared.loadBodyStorageConfig()
        isLoading = false
    }

    private func persistConfig() {
        guard !isLoading else { return }
        let normalized = bodyStorageConfig.normalized()
        if normalized != bodyStorageConfig {
            bodyStorageConfig = normalized
            toastMessage = "Adjusted thresholds to keep Inline ≤ Truncation and Preview ≤ Truncation."
        }
        do {
            try AppGroupStorage.shared.saveBodyStorageConfig(normalized)
        } catch {
            toastMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func resetToDefaults() {
        bodyStorageConfig = .default
        persistConfig()
    }
}
