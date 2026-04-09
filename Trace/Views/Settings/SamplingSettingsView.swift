//
//  SamplingSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI
import TraceCore
import TraceUI

struct SamplingSettingsView: View {
    @State private var samplingConfig: SamplingConfig = .default
    @State private var toastMessage: String?
    @State private var isLoading = true
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section {
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
            } footer: {
                Text("Reduce overhead in high-volume environments by sampling captured requests.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    showingResetConfirmation = true
                }
            }
        }
        .navigationTitle("Request Sampling")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSettings()
        }
        .onChangeCompat(of: samplingConfig) { persistConfig() }
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
            Text("Request sampling settings will be restored to their default values.")
        }
    }

    private func loadSettings() async {
        samplingConfig = AppGroupStorage.shared.loadSamplingConfig()
        isLoading = false
    }

    private func persistConfig() {
        guard !isLoading else { return }
        let normalized = samplingConfig.normalized()
        if normalized != samplingConfig {
            samplingConfig = normalized
        }
        do {
            try AppGroupStorage.shared.saveSamplingConfig(normalized)
        } catch {
            toastMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func resetToDefaults() {
        samplingConfig = .default
        persistConfig()
    }
}

#Preview {
    NavigationStack {
        SamplingSettingsView()
    }
}
