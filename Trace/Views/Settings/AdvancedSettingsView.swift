//
//  AdvancedSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceProxy
import TraceUI

struct AdvancedSettingsView: View {
    @State private var bodyStorageConfig: BodyStorageConfig = .default
    @State private var samplingConfig: SamplingConfig = .default
    @State private var mitmAllowlist: [String] = ["*"]
    @State private var blockQUICEnabled = true
    @State private var toastMessage: String?
    @State private var isLoading = true
    @ObservedObject private var vpnManager = VPNManager.shared

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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Sample Rate")
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(samplingConfig.sampleRate * 100))%")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $samplingConfig.sampleRate,
                            in: 0.05 ... 1.0,
                            step: 0.05
                        )
                    }
                    .padding(.vertical, 4)

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

            DomainListEditor(
                title: "MITM Allowlist",
                items: $mitmAllowlist,
                addLabel: "Add Domain",
                placeholder: "example.com",
                helperText: "Only allowlisted domains will be intercepted. Use * to allow all.",
                emptyText: "Allowlist is empty",
                validate: validateDomainPattern
            )

            Section("Security") {
                Toggle("Block QUIC", isOn: $blockQUICEnabled)

                if mitmAllowlist.isEmpty {
                    Text("Allowlist is empty; HTTPS interception will be disabled.")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.warning)
                }
            }

            Section {
                Button("Reset to Defaults") {
                    resetToDefaults()
                }
            }
        }
        .navigationTitle("Advanced Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSettings()
        }
        .onChange(of: bodyStorageConfig) { _ in persistBodyStorageConfig() }
        .onChange(of: samplingConfig) { _ in persistSamplingConfig() }
        .onChange(of: mitmAllowlist) { _ in persistHardeningConfig() }
        .onChange(of: blockQUICEnabled) { _ in persistHardeningConfig() }
        .toast(message: $toastMessage)
    }

    private func loadSettings() async {
        bodyStorageConfig = AppGroupStorage.shared.loadBodyStorageConfig()
        samplingConfig = AppGroupStorage.shared.loadSamplingConfig()

        let hardening = HardeningConfig.shared
        mitmAllowlist = await hardening.mitmAllowlist
        blockQUICEnabled = await hardening.blockQUIC
        isLoading = false
    }

    private func persistBodyStorageConfig() {
        guard !isLoading else { return }
        let normalized = bodyStorageConfig.normalized()
        if normalized != bodyStorageConfig {
            bodyStorageConfig = normalized
        }
        try? AppGroupStorage.shared.saveBodyStorageConfig(normalized)
    }

    private func persistSamplingConfig() {
        guard !isLoading else { return }
        let normalized = samplingConfig.normalized()
        if normalized != samplingConfig {
            samplingConfig = normalized
        }
        try? AppGroupStorage.shared.saveSamplingConfig(normalized)
    }

    private func persistHardeningConfig() {
        guard !isLoading else { return }
        let sanitized = mitmAllowlist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let appliedAllowlist = sanitized.isEmpty ? ["*"] : sanitized
        if sanitized.isEmpty {
            toastMessage = "Allowlist was empty. Using * to allow all."
            if mitmAllowlist != appliedAllowlist {
                mitmAllowlist = appliedAllowlist
            }
        }

        Task {
            let hardening = HardeningConfig.shared
            await hardening.setMitmAllowlist(appliedAllowlist)
            await hardening.setBlockQUIC(blockQUICEnabled)
            try? AppGroupStorage.shared.saveMITMAllowlist(appliedAllowlist)

            if vpnManager.isConnected {
                try? await vpnManager.sendMessage([
                    "command": "updateHardeningConfig",
                    "hardeningConfig": [
                        "mitmAllowlist": appliedAllowlist,
                        "blockQUIC": blockQUICEnabled
                    ]
                ])
            }
        }
    }

    private func resetToDefaults() {
        bodyStorageConfig = .default
        samplingConfig = .default
        mitmAllowlist = ["*"]
        blockQUICEnabled = true
        persistBodyStorageConfig()
        persistSamplingConfig()
        persistHardeningConfig()
    }

    private func validateDomainPattern(_ value: String) -> String? {
        Validation.isValidDomainPattern(value) ? nil : "Invalid domain pattern"
    }
}
