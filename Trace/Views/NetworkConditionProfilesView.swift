//
//  NetworkConditionProfilesView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct NetworkConditionProfilesView: View {
    @ObservedObject var viewModel: CaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingCustomThrottling = false
    @State private var customDownload = 1000
    @State private var customUpload = 500
    @State private var customLatency = 50
    @State private var customPacketLoss = 0.0

    var body: some View {
        NavigationStack {
            Form {
                // Throttling Toggle
                Section {
                    Toggle("Enable Network Throttling", isOn: $viewModel.throttlingEnabled)
                        .tint(DesignSystem.Colors.accent)

                    if viewModel.throttlingEnabled {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(DesignSystem.Colors.accent)
                            Text("Simulates network conditions for testing")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Throttling")
                } footer: {
                    if viewModel.throttlingEnabled {
                        Text("Network traffic will be limited based on the selected profile")
                    } else {
                        Text("Enable to simulate different network conditions")
                    }
                }

                // Network Condition Presets
                if viewModel.throttlingEnabled {
                    Section {
                        ForEach([
                            NetworkCondition.wifi,
                            .cellular5G,
                            .cellular4G,
                            .cellular3G,
                            .cellular2G,
                            .satellite,
                            .offline
                        ], id: \.self) { condition in
                            Button(action: {
                                viewModel.selectedNetworkCondition = condition
                            }) {
                                HStack(spacing: DesignSystem.Spacing.md) {
                                    Image(systemName: condition.icon)
                                        .font(.title3)
                                        .foregroundColor(DesignSystem.Colors.accent)
                                        .frame(width: 30)

                                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                        Text(condition.displayName)
                                            .font(.headline)
                                            .foregroundColor(.primary)

                                        HStack(spacing: DesignSystem.Spacing.sm) {
                                            Label("\(condition.downloadSpeed) KB/s", systemImage: "arrow.down.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(DesignSystem.Colors.success)

                                            Label("\(condition.uploadSpeed) KB/s", systemImage: "arrow.up.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(DesignSystem.Colors.warning)

                                            Label("\(condition.latency)ms", systemImage: "clock.fill")
                                                .font(.caption)
                                                .foregroundColor(DesignSystem.Colors.accentAlt)

                                            if condition.packetLoss > 0 {
                                                Label(String(format: "%.1f%%", condition.packetLoss * 100), systemImage: "exclamationmark.triangle.fill")
                                                    .font(.caption)
                                                    .foregroundColor(DesignSystem.Colors.danger)
                                            }
                                        }
                                    }

                                    Spacer()

                                    if viewModel.selectedNetworkCondition == condition {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(DesignSystem.Colors.accent)
                                            .font(.title3)
                                    }
                                }
                                .padding(.vertical, DesignSystem.Spacing.xs)
                            }
                            .buttonStyle(.plain)
                        }

                        // Custom Throttling
                        Button(action: {
                            showingCustomThrottling = true
                        }) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.title3)
                                    .foregroundColor(DesignSystem.Colors.accent)
                                    .frame(width: 30)

                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                    Text("Custom")
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    if case let .custom(down, up, lat, loss) = viewModel.selectedNetworkCondition {
                                        HStack(spacing: DesignSystem.Spacing.sm) {
                                            Label("\(down) KB/s", systemImage: "arrow.down.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(DesignSystem.Colors.success)

                                            Label("\(up) KB/s", systemImage: "arrow.up.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(DesignSystem.Colors.warning)

                                            Label("\(lat)ms", systemImage: "clock.fill")
                                                .font(.caption)
                                                .foregroundColor(DesignSystem.Colors.accentAlt)

                                            if loss > 0 {
                                                Label(String(format: "%.1f%%", loss * 100), systemImage: "exclamationmark.triangle.fill")
                                                    .font(.caption)
                                                    .foregroundColor(DesignSystem.Colors.danger)
                                            }
                                        }
                                    } else {
                                        Text("Configure custom network settings")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Spacer()

                                if case .custom = viewModel.selectedNetworkCondition {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(DesignSystem.Colors.accent)
                                        .font(.title3)
                                }
                            }
                            .padding(.vertical, DesignSystem.Spacing.xs)
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text("Network Conditions")
                    } footer: {
                        Text("Select a preset or create a custom network condition profile")
                    }
                }

                // Current Statistics (if throttling is enabled)
                if viewModel.throttlingEnabled, let condition = viewModel.selectedNetworkCondition {
                    Section {
                        LabeledContent("Download Speed", value: "\(condition.downloadSpeed) KB/s")
                        LabeledContent("Upload Speed", value: "\(condition.uploadSpeed) KB/s")
                        LabeledContent("Latency", value: "\(condition.latency) ms")
                        LabeledContent("Packet Loss", value: String(format: "%.1f%%", condition.packetLoss * 100))
                    } header: {
                        Text("Current Profile")
                    } footer: {
                        Text(condition.description)
                    }
                }
            }
            .navigationTitle("Network Throttling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {}
            .sheet(isPresented: $showingCustomThrottling) {
                CustomThrottlingSheet(
                    downloadSpeed: $customDownload,
                    uploadSpeed: $customUpload,
                    latency: $customLatency,
                    packetLoss: $customPacketLoss
                ) {
                    viewModel.selectedNetworkCondition = .custom(
                        download: customDownload,
                        upload: customUpload,
                        latency: customLatency,
                        packetLoss: customPacketLoss
                    )
                    showingCustomThrottling = false
                }
            }
        }
    }
}

// MARK: - Custom Throttling Sheet

struct CustomThrottlingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var downloadSpeed: Int
    @Binding var uploadSpeed: Int
    @Binding var latency: Int
    @Binding var packetLoss: Double
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Download Speed: \(downloadSpeed) KB/s")
                            .font(.headline)
                        Slider(value: Binding(
                            get: { Double(downloadSpeed) },
                            set: { downloadSpeed = Int($0) }
                        ), in: 0 ... 100_000, step: 100)
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Upload Speed: \(uploadSpeed) KB/s")
                            .font(.headline)
                        Slider(value: Binding(
                            get: { Double(uploadSpeed) },
                            set: { uploadSpeed = Int($0) }
                        ), in: 0 ... 50000, step: 50)
                    }
                } header: {
                    Text("Bandwidth")
                } footer: {
                    Text("Set maximum download and upload speeds in KB/s")
                }

                Section {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Latency: \(latency) ms")
                            .font(.headline)
                        Slider(value: Binding(
                            get: { Double(latency) },
                            set: { latency = Int($0) }
                        ), in: 0 ... 2000, step: 10)
                    }
                } header: {
                    Text("Network Delay")
                } footer: {
                    Text("Round-trip time in milliseconds")
                }

                Section {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text(String(format: "Packet Loss: %.1f%%", packetLoss * 100))
                            .font(.headline)
                        Slider(value: $packetLoss, in: 0 ... 0.5, step: 0.001)
                    }
                } header: {
                    Text("Packet Loss")
                } footer: {
                    Text("Percentage of packets that will be dropped")
                }

                Section {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(profileDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Profile Simulation")
                }
            }
            .navigationTitle("Custom Throttling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply()
                    }
                }
            }
        }
    }

    private var profileDescription: String {
        if downloadSpeed >= 50000 {
            "Simulates high-speed WiFi or fiber connection"
        } else if downloadSpeed >= 10000 {
            "Simulates 4G/LTE cellular connection"
        } else if downloadSpeed >= 750 {
            "Simulates 3G cellular connection"
        } else if downloadSpeed >= 40 {
            "Simulates 2G/EDGE cellular connection"
        } else {
            "Simulates very slow or offline connection"
        }
    }
}

// MARK: - Preview

#Preview {
    NetworkConditionProfilesView(viewModel: CaptureViewModel())
}
