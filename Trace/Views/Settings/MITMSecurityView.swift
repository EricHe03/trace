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
    @State private var blockQUICEnabled = true

    @State private var isLoading = true
    @State private var toastMessage: String?

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
                Toggle("Block QUIC", isOn: $blockQUICEnabled)
            } header: {
                Text("QUIC Protocol")
            } footer: {
                Text("Blocks QUIC/HTTP3 connections to force HTTP/2. Useful for capturing traffic from apps that prefer QUIC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isAllowlistEffectivelyEmpty {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DesignSystem.Colors.warning)
                        Text("Allowlist is empty. HTTPS interception will be disabled.")
                            .font(.subheadline)
                    }
                }
            }

            Section {
                Button("Reset to Defaults") {
                    resetToDefaults()
                }
            }
        }
        .navigationTitle("MITM & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSettings() }
        .onChange(of: mitmAllowlist) { _ in persistHardeningConfig() }
        .onChange(of: blockQUICEnabled) { _ in persistHardeningConfig() }
        .toast(message: $toastMessage)
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
        blockQUICEnabled = await hardening.blockQUIC
        isLoading = false
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
        isLoading = true
        mitmAllowlist = ["*"]
        blockQUICEnabled = true
        isLoading = false
        persistHardeningConfig()
        toastMessage = "Reset to defaults"
    }

    private func validateDomainPattern(_ value: String) -> String? {
        Validation.isValidDomainPattern(value) ? nil : "Invalid domain pattern"
    }
}
