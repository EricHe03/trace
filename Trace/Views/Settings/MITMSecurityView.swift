//
//  MITMSecurityView.swift
//  Trace
//
//  Created by Justin on 2026/01/28.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceProxy
import TraceUI

/// Dedicated page for HTTPS interception allowlist + QUIC blocking.
struct MITMSecurityView: View {
    @State private var mitmAllowlist: [String] = ["*"]
    @State private var quicHandlingMode: QUICHandlingMode = .intercept

    @State private var isLoading = true
    @State private var toastMessage: String?
    @State private var showingResetConfirmation = false

    @ObservedObject private var vpnManager = VPNManager.shared

    var body: some View {
        Form {
            DomainListEditor(
                title: "MITM Allowlist",
                items: $mitmAllowlist,
                addLabel: "Add Domain",
                placeholder: "example.com",
                helperText: "Only allowlisted domains will be intercepted for HTTPS. Use * to allow all.",
                emptyText: "No domains allowlisted (HTTPS interception disabled)",
                validate: validateDomainPattern
            )

            Section {
                Picker("Handling Mode", selection: $quicHandlingMode) {
                    ForEach(QUICHandlingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("QUIC Protocol")
            } footer: {
                Text("\"Intercept\" attempts QUIC/HTTP3 interception, \"Pass Through\" keeps connectivity and marks flow state, and \"Block\" drops QUIC (UDP/443).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isAllowlistEffectivelyEmpty {
                Section {
                    Label("Allowlist is empty. HTTPS interception will be disabled.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .font(.subheadline)
                }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    showingResetConfirmation = true
                }
            }
        }
        .navigationTitle("Interception Rules")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSettings() }
        .onChangeCompat(of: mitmAllowlist) { persistHardeningConfig() }
        .onChangeCompat(of: quicHandlingMode) { persistHardeningConfig() }
        .toast(message: $toastMessage)
        .dismissKeyboardOnTapAndScroll()
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
            Text("MITM allowlist and QUIC settings will be restored to their default values.")
        }
    }

    private var isAllowlistEffectivelyEmpty: Bool {
        let cleaned = mitmAllowlist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty
    }

    private func loadSettings() async {
        let hardening = HardeningConfig.shared
        mitmAllowlist = await hardening.mitmAllowlist
        quicHandlingMode = await hardening.quicHandlingMode
        isLoading = false
    }

    private func persistHardeningConfig() {
        guard !isLoading else { return }

        let sanitized = mitmAllowlist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let appliedAllowlist = sanitized
        if sanitized.isEmpty {
            toastMessage = "HTTPS interception disabled (allowlist empty)."
        }

        Task {
            let hardening = HardeningConfig.shared
            await hardening.setMitmAllowlist(appliedAllowlist)
            await hardening.setQUICHandlingMode(quicHandlingMode)
            do {
                try AppGroupStorage.shared.saveMITMAllowlist(appliedAllowlist)
            } catch {
                await MainActor.run {
                    toastMessage = "Failed to save allowlist: \(error.localizedDescription)"
                }
            }

            if vpnManager.isConnected {
                do {
                    try await vpnManager.sendMessage([
                        "command": "updateHardeningConfig",
                        "hardeningConfig": [
                            "mitmAllowlist": appliedAllowlist,
                            "quicHandlingMode": quicHandlingMode.rawValue,
                            // Legacy key for backwards compatibility.
                            "blockQUIC": quicHandlingMode.blocksQUIC
                        ]
                    ])
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
        mitmAllowlist = ["*"]
        quicHandlingMode = .intercept
        isLoading = false
        persistHardeningConfig()
        toastMessage = "Reset to defaults"
    }

    private func validateDomainPattern(_ value: String) -> String? {
        Validation.isValidDomainPattern(value) ? nil : "Invalid domain pattern"
    }
}
