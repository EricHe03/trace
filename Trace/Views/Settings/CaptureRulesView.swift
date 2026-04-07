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

    @State private var isLoading = true
    @State private var toastMessage: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var showingResetConfirmation = false

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
                Button("Reset to Defaults", role: .destructive) {
                    showingResetConfirmation = true
                }
            }
        }
        .navigationTitle("Capture Rules")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSettings() }
        .onChangeCompat(of: options) { scheduleSave() }
        .onChangeCompat(of: config.filterMode) { scheduleSave() }
        .onChangeCompat(of: config.domainFilters) { scheduleSave() }
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
            Text("Capture rules will be restored to their default values.")
        }
    }

    private func loadSettings() async {
        config = AppGroupStorage.shared.loadConfiguration()
        options = AppGroupStorage.shared.loadCaptureOptions()

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
            guard !Task.isCancelled else { return }
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
        isLoading = false
        persistAll()
        toastMessage = "Reset to defaults"
    }

    private func validateDomainPattern(_ value: String) -> String? {
        Validation.isValidDomainPattern(value) ? nil : "Invalid domain pattern"
    }
}
