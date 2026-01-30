//
//  CaptureOptionsView.swift
//  Trace
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

struct CaptureOptionsView: View {
    @State private var options: CaptureOptions = .default
    @State private var toastMessage: String?
    @State private var isSaving = false
    @State private var showLowBodyWarning = false
    @State private var saveTask: Task<Void, Never>?
    @ObservedObject private var vpnManager = VPNManager.shared

    private let minBodySize = 10 * 1024 * 1024
    private let maxBodySize = 500 * 1024 * 1024
    private let bodyStep = 10 * 1024 * 1024

    var body: some View {
        Form {
            Section("Basic Settings") {
                Toggle("Capture Headers", isOn: $options.captureHeaders)
                Toggle("Capture Body", isOn: $options.captureBody)
            }

            Section("Body Size Limit") {
                ByteSizeSlider(
                    title: "Max Body Size",
                    value: $options.maxBodySize,
                    range: minBodySize ... maxBodySize,
                    step: bodyStep
                )

                if showLowBodyWarning {
                    Label("Configured size was below 10 MB. Using 10 MB instead.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.warning)
                }

                Text("Body data is stored on disk, not in memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to Defaults") {
                    options = .default
                    persistOptions()
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle("Capture Options")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadConfiguration)
        .onChange(of: options.captureHeaders) { _ in scheduleSave() }
        .onChange(of: options.captureBody) { _ in scheduleSave() }
        .onChange(of: options.maxBodySize) { _ in scheduleSave() }
        .toast(message: $toastMessage)
    }

    private func loadConfiguration() {
        let config = AppGroupStorage.shared.loadConfiguration()
        let loaded = CaptureOptions(
            captureHeaders: config.captureHeaders,
            captureBody: config.captureBody,
            maxBodySize: config.maxBodySize
        )

        if loaded.maxBodySize < minBodySize {
            showLowBodyWarning = true
            options = CaptureOptions(
                captureHeaders: loaded.captureHeaders,
                captureBody: loaded.captureBody,
                maxBodySize: minBodySize
            )
        } else {
            showLowBodyWarning = false
            options = loaded
        }
    }

    private func persistOptions() {
        isSaving = true

        var config = AppGroupStorage.shared.loadConfiguration()
        config.captureHeaders = options.captureHeaders
        config.captureBody = options.captureBody
        config.maxBodySize = options.maxBodySize

        do {
            try AppGroupStorage.shared.saveConfiguration(config)
            try AppGroupStorage.shared.saveCaptureOptions(options)
        } catch {
            toastMessage = "Failed to save capture options: \(error.localizedDescription)"
            isSaving = false
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
            await MainActor.run {
                isSaving = false
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run {
                persistOptions()
            }
        }
    }
}
