//
//  CaptureSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/21.
//

import SwiftUI
import TraceCore
import TraceFeatures
import TraceUI

struct CaptureSettingsView: View {
    @ObservedObject var vpnManager: VPNManager
    @State private var config: CaptureConfiguration = .default
    @State private var socksPortText = ""
    @State private var toastMessage: String?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Capture Mode") {
                Picker("Mode", selection: $config.captureMode) {
                    Text("Proxy Only").tag(CaptureMode.proxyOnly)
                    Text("Full Tunnel").tag(CaptureMode.fullTunnel)
                    Text("Dual MITM").tag(CaptureMode.fullTunnelDualMITM)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Capture mode")
            }

            if config.captureMode.usesPacketTunnelRouting {
                if config.captureMode.supportsCustomSocksServer {
                    Section("SOCKS5 Forwarder (Optional)") {
                        TextField("Host", text: $config.fullTunnelSocks5Host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityLabel("SOCKS5 host")

                        TextField("Port", text: $socksPortText)
                            .keyboardType(.asciiCapableNumberPad)
                            .accessibilityLabel("SOCKS5 port")

                        Label {
                            Text("Leave host empty to use Trace's built-in local SOCKS5 server. Set host and port only when using an external SOCKS5 server.")
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Section("SOCKS5 Forwarder") {
                        Label {
                            Text("Dual MITM mode always uses Trace's embedded local SOCKS5 forwarder.")
                        } icon: {
                            Image(systemName: "info.circle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if config.captureMode == .fullTunnel {
                    Section("HTTPS Decryption") {
                        Toggle("Enable Hybrid TCP MITM", isOn: $config.fullTunnelHybridTCPMITMEnabled)
                            .accessibilityLabel("Enable hybrid TCP MITM")

                        Text("Keeps Full Tunnel proxy routing enabled and also enables transparent TCP MITM for intercepted ports.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DomainListEditor(
                    title: "DNS Servers",
                    items: $config.fullTunnelDNSServers,
                    addLabel: "Add DNS Server",
                    placeholder: "8.8.8.8",
                    helperText: "Leave empty to use the system default DNS servers.",
                    emptyText: "No custom DNS servers",
                    validate: validateDNSServer
                )

                Section("IP Version") {
                    Toggle("Enable IPv6", isOn: $config.fullTunnelIPv6Enabled)
                        .accessibilityLabel("Enable IPv6")

                    Text("Disable only if your SOCKS5 path does not support IPv6.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("UDP Forwarding") {
                    Picker("Mode", selection: $config.fullTunnelUDPForwardingMode) {
                        Text("HEV Only").tag(UDPForwardingMode.hevOnly)
                        Text("Direct").tag(UDPForwardingMode.direct)
                        Text("Split (UDP/443 via HEV)").tag(UDPForwardingMode.split)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("UDP forwarding mode")

                    Text("HEV-only sends all UDP through the active SOCKS5 tunnel. Split forwards UDP/443 via HEV and other UDP directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("VPN & Proxy Mode")
        .navigationBarTitleDisplayMode(.inline)
        .dismissKeyboardOnTapAndScroll()
        .onAppear {
            loadConfiguration()
        }
        .onChangeCompat(of: config.captureMode) { scheduleSave(showErrors: true) }
        .onChangeCompat(of: config.fullTunnelSocks5Host) { scheduleSave(showErrors: false) }
        .onChangeCompat(of: socksPortText) { scheduleSave(showErrors: false) }
        .onChangeCompat(of: config.fullTunnelDNSServers) { scheduleSave(showErrors: false) }
        .onChangeCompat(of: config.fullTunnelIPv6Enabled) { scheduleSave(showErrors: false) }
        .onChangeCompat(of: config.fullTunnelUDPForwardingMode) { scheduleSave(showErrors: false) }
        .onChangeCompat(of: config.fullTunnelHybridTCPMITMEnabled) { scheduleSave(showErrors: false) }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
        }
        .toast(message: $toastMessage)
    }

    private func loadConfiguration() {
        isLoading = true
        let loaded = AppGroupStorage.shared.loadConfiguration()
        config = loaded
        if loaded.fullTunnelSocks5Port > 0 {
            socksPortText = "\(loaded.fullTunnelSocks5Port)"
        } else {
            socksPortText = ""
        }
        isLoading = false
    }

    private func scheduleSave(showErrors: Bool) {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                persistConfiguration(showErrors: showErrors)
            }
        }
    }

    private func persistConfiguration(showErrors: Bool) {
        guard !isLoading else { return }
        guard !isSaving else { return }

        let trimmedHost = config.fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPortText = socksPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = config

        if config.captureMode.supportsCustomSocksServer {
            updated.fullTunnelSocks5Host = trimmedHost
            if trimmedPortText.isEmpty {
                updated.fullTunnelSocks5Port = 0
            } else {
                guard let port = UInt16(trimmedPortText), port > 0 else {
                    if showErrors {
                        toastMessage = "Enter a valid SOCKS5 port (1-65535)."
                    }
                    return
                }
                updated.fullTunnelSocks5Port = port
            }

            if !trimmedHost.isEmpty, updated.fullTunnelSocks5Port == 0 {
                if showErrors {
                    toastMessage = "Enter a SOCKS5 port for the custom host."
                }
                return
            }
        }

        isSaving = true
        do {
            try AppGroupStorage.shared.saveConfiguration(updated)
        } catch {
            toastMessage = "Failed to save capture settings: \(error.localizedDescription)"
            isSaving = false
            return
        }

        Task {
            await vpnManager.refreshRoutingDefaultsIfNeeded()
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

    private func validateDNSServer(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "DNS server cannot be empty" }
        if Validation.isValidIPAddress(trimmed) { return nil }
        return "Enter a valid IPv4 or IPv6 address"
    }
}
