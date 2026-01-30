//
//  CaptureRulesView.swift
//  Trace
//
//  Created by Justin on 2026/01/28.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

/// Consolidated capture configuration (options + domain filtering + sampling).
struct CaptureRulesView: View {
    @State private var config: CaptureConfiguration = .default
    @State private var options: CaptureOptions = .default
    @State private var samplingConfig: SamplingConfig = .default

    @State private var isLoading = true
    @State private var toastMessage: String?
    @State private var saveTask: Task<Void, Never>?

    @ObservedObject private var vpnManager = VPNManager.shared

    private let minBodySize = 10 * 1024 * 1024
    private let maxBodySize = 500 * 1024 * 1024
    private let bodyStep = 10 * 1024 * 1024

    var body: some View {
        Form {
            Section("What to Capture") {
                Toggle("Capture Headers", isOn: $options.captureHeaders)
                Toggle("Capture Body", isOn: $options.captureBody)

                ByteSizeSlider(
                    title: "Max Body Size",
                    value: $options.maxBodySize,
                    range: minBodySize ... maxBodySize,
                    step: bodyStep
                )

                Text("Body data is stored on disk, not in memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Domain Filtering") {
                Picker("Filter Mode", selection: $config.filterMode) {
                    Text("All").tag(FilterMode.all)
                    Text("Whitelist").tag(FilterMode.whitelist)
                    Text("Blacklist").tag(FilterMode.blacklist)
                }
                .pickerStyle(.segmented)

                if config.filterMode != .all {
                    DomainListEditor(
                        title: "Domains",
                        items: $config.domainFilters,
                        addLabel: "Add Domain",
                        placeholder: "example.com",
                        helperText: "Use * for wildcards (e.g., *.example.com).",
                        emptyText: "No domains added",
                        validate: validateDomainPattern
                    )
                } else {
                    Text("Captures requests for all domains.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Enable Sampling", isOn: $samplingConfig.enabled)

                if samplingConfig.enabled {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack {
                            Text("Sample Rate")
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(samplingConfig.sampleRate * 100))%")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $samplingConfig.sampleRate, in: 0.05 ... 1.0, step: 0.05)
                            .accessibilityLabel("Sample rate")
                            .accessibilityValue("\(Int(samplingConfig.sampleRate * 100)) percent")
                    }
                    .padding(.vertical, DesignSystem.Spacing.xs)

                    Picker("Strategy", selection: $samplingConfig.strategy) {
                        Text("Random").tag(SamplingStrategy.random)
                        Text("Periodic").tag(SamplingStrategy.periodic)
                        Text("Adaptive").tag(SamplingStrategy.adaptive)
                    }
                }
            } header: {
                Text("Request Sampling")
            } footer: {
                Text("Reduce overhead in high-volume environments by sampling captured requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to Defaults") {
                    resetToDefaults()
                }
            }
        }
        .navigationTitle("Capture Rules")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSettings() }
        .onChange(of: options) { _ in scheduleSave() }
        .onChange(of: config.filterMode) { _ in scheduleSave() }
        .onChange(of: config.domainFilters) { _ in scheduleSave() }
        .onChange(of: samplingConfig) { _ in scheduleSave() }
        .toast(message: $toastMessage)
    }

    private func loadSettings() async {
        config = AppGroupStorage.shared.loadConfiguration()
        options = AppGroupStorage.shared.loadCaptureOptions()
        samplingConfig = AppGroupStorage.shared.loadSamplingConfig()

        // Ensure the UI reflects the persisted config as the source of truth.
        options.captureHeaders = config.captureHeaders
        options.captureBody = config.captureBody
        options.maxBodySize = config.maxBodySize

        isLoading = false
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run {
                persistAll()
            }
        }
    }

    private func persistAll() {
        guard !isLoading else { return }

        var updatedConfig = config
        updatedConfig.captureHeaders = options.captureHeaders
        updatedConfig.captureBody = options.captureBody
        updatedConfig.maxBodySize = options.maxBodySize

        do {
            try AppGroupStorage.shared.saveConfiguration(updatedConfig)
            try AppGroupStorage.shared.saveCaptureOptions(options.normalized())
            try AppGroupStorage.shared.saveSamplingConfig(samplingConfig.normalized())
        } catch {
            toastMessage = "Failed to save: \(error.localizedDescription)"
            return
        }

        Task {
            if vpnManager.isConnected {
                do {
                    try await vpnManager.sendMessage(["command": "updateCaptureConfig"])
                } catch {
                    await MainActor.run {
                        toastMessage = "Saved locally, but failed to notify VPN: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func resetToDefaults() {
        isLoading = true
        config = .default
        options = .default
        samplingConfig = .default
        isLoading = false
        persistAll()
        toastMessage = "Reset to defaults"
    }

    private func validateDomainPattern(_ value: String) -> String? {
        Validation.isValidDomainPattern(value) ? nil : "Invalid domain pattern"
    }
}
