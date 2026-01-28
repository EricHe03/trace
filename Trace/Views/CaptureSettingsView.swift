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
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("Capture Mode") {
                Picker("Mode", selection: $config.captureMode) {
                    Text("Proxy Only").tag(CaptureMode.proxyOnly)
                    Text("Full Tunnel").tag(CaptureMode.fullTunnel)
                }
                .pickerStyle(.segmented)

                Button {
                    saveConfiguration()
                } label: {
                    Label("Apply Capture Mode", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSaving)
            }

            if config.captureMode == .fullTunnel {
                Section("SOCKS5 Forwarder") {
                    TextField("Host", text: $config.fullTunnelSocks5Host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Port", text: $socksPortText)
                        .keyboardType(.numberPad)

                    Text("Full-tunnel mode forwards traffic to the configured SOCKS5 server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                    Text("Disable only if your SOCKS5 server or upstream network does not support IPv6.")
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

                    Text("HEV-only sends all UDP through the SOCKS5 tunnel. Split forwards UDP/443 via HEV and other UDP directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Capture Mode")
        .onAppear {
            loadConfiguration()
        }
        .toast(message: $toastMessage)
    }

    private func loadConfiguration() {
        let loaded = AppGroupStorage.shared.loadConfiguration()
        config = loaded
        if loaded.fullTunnelSocks5Port > 0 {
            socksPortText = "\(loaded.fullTunnelSocks5Port)"
        } else {
            socksPortText = ""
        }
    }

    private func saveConfiguration() {
        let trimmedHost = config.fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = config

        if config.captureMode == .fullTunnel {
            guard !trimmedHost.isEmpty else {
                toastMessage = "Enter a SOCKS5 host for full-tunnel mode."
                return
            }
            guard let port = UInt16(socksPortText), port > 0 else {
                toastMessage = "Enter a valid SOCKS5 port (1-65535)."
                return
            }
            updated.fullTunnelSocks5Host = trimmedHost
            updated.fullTunnelSocks5Port = port
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
                try? await vpnManager.sendMessage(["command": "updateCaptureConfig"])
            }
            isSaving = false
            toastMessage = "Capture settings updated."
        }
    }

    private func validateDNSServer(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "DNS server cannot be empty" }
        if Validation.isValidIPAddress(trimmed) { return nil }
        return "Enter a valid IPv4 or IPv6 address"
    }
}
