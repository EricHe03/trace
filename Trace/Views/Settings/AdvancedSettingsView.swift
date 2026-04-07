//
//  AdvancedSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI
import TraceCore
import TraceUI

struct AdvancedSettingsView: View {
    @State private var bodyStorageConfig: BodyStorageConfig = .default
    @State private var samplingConfig: SamplingConfig = .default
    @State private var toastMessage: String?
    @State private var isLoading = true
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section("Body Storage Thresholds") {
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

                Text("Controls how response bodies are stored and previewed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Request Sampling") {
                Toggle("Enable Sampling", isOn: $samplingConfig.enabled)

                if samplingConfig.enabled {
                    HStack {
                        Text("Sample Rate")
                        Spacer()
                        Text("\(Int(samplingConfig.sampleRate * 100))%")
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $samplingConfig.sampleRate,
                        in: 0.05 ... 1.0,
                        step: 0.05
                    )
                    .accessibilityLabel("Sample rate")
                    .accessibilityValue("\(Int(samplingConfig.sampleRate * 100)) percent")
                    .listRowSeparator(.hidden)

                    Picker("Strategy", selection: $samplingConfig.strategy) {
                        Text("Random").tag(SamplingStrategy.random)
                        Text("Periodic").tag(SamplingStrategy.periodic)
                        Text("Adaptive").tag(SamplingStrategy.adaptive)
                    }
                }

                Text("Reduce overhead in high-volume environments by sampling captured requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    showingResetConfirmation = true
                }
            }
        }
        .navigationTitle("Advanced Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSettings()
        }
        .onChangeCompat(of: bodyStorageConfig) { persistBodyStorageConfig() }
        .onChangeCompat(of: samplingConfig) { persistSamplingConfig() }
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
            Text("All advanced settings will be restored to their default values.")
        }
    }

    private func loadSettings() async {
        bodyStorageConfig = AppGroupStorage.shared.loadBodyStorageConfig()
        samplingConfig = AppGroupStorage.shared.loadSamplingConfig()
        isLoading = false
    }

    private func persistBodyStorageConfig() {
        guard !isLoading else { return }
        let normalized = bodyStorageConfig.normalized()
        if normalized != bodyStorageConfig {
            bodyStorageConfig = normalized
            toastMessage = "Adjusted thresholds to keep Inline ≤ Truncation and Preview ≤ Truncation."
        }
        do {
            try AppGroupStorage.shared.saveBodyStorageConfig(normalized)
        } catch {
            toastMessage = "Failed to save body storage settings: \(error.localizedDescription)"
        }
    }

    private func persistSamplingConfig() {
        guard !isLoading else { return }
        let normalized = samplingConfig.normalized()
        if normalized != samplingConfig {
            samplingConfig = normalized
        }
        do {
            try AppGroupStorage.shared.saveSamplingConfig(normalized)
        } catch {
            toastMessage = "Failed to save sampling settings: \(error.localizedDescription)"
        }
    }

    private func resetToDefaults() {
        bodyStorageConfig = .default
        samplingConfig = .default
        persistBodyStorageConfig()
        persistSamplingConfig()
    }
}
