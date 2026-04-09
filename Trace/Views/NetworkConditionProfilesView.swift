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
    @State private var showingEnableConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                // Throttling Toggle
                Section {
                    Toggle("Enable Network Throttling", isOn: throttlingEnabledBinding)
                        .tint(DesignSystem.Colors.accent)

                    if viewModel.throttlingEnabled {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(DesignSystem.Colors.accent)
                            Text("Simulates network conditions for testing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                        .foregroundStyle(DesignSystem.Colors.accent)
                                        .frame(width: 30)

                                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                        Text(condition.displayName)
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        HStack(spacing: DesignSystem.Spacing.sm) {
                                            Label("\(condition.downloadSpeed) KB/s", systemImage: "arrow.down.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(DesignSystem.Colors.success)

                                            Label("\(condition.uploadSpeed) KB/s", systemImage: "arrow.up.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(DesignSystem.Colors.warning)

                                            Label("\(condition.latency)ms", systemImage: "clock.fill")
                                                .font(.caption)
                                                .foregroundStyle(DesignSystem.Colors.accentAlt)

                                            if condition.packetLoss > 0 {
                                                Label(String(format: "%.1f%%", condition.packetLoss * 100), systemImage: "exclamationmark.triangle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(DesignSystem.Colors.danger)
                                            }
                                        }
                                    }

                                    Spacer()

                                    if viewModel.selectedNetworkCondition == condition {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(DesignSystem.Colors.accent)
                                            .font(.title3)
                                    }
                                }
                                .padding(.vertical, DesignSystem.Spacing.md)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(condition.displayName) network condition. Download \(condition.downloadSpeed) KB/s, Upload \(condition.uploadSpeed) KB/s, Latency \(condition.latency)ms\(condition.packetLoss > 0 ? ", Packet loss \(String(format: "%.1f%%", condition.packetLoss * 100))" : "")")
                            .accessibilityAddTraits(viewModel.selectedNetworkCondition == condition ? [.isSelected] : [])
                        }

                        // Custom Throttling
                        Button(action: {
                            showingCustomThrottling = true
                        }) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.title3)
                                    .foregroundStyle(DesignSystem.Colors.accent)
                                    .frame(width: 30)

                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                    Text("Custom")
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    if case let .custom(down, up, lat, loss) = viewModel.selectedNetworkCondition {
                                        HStack(spacing: DesignSystem.Spacing.sm) {
                                            Label("\(down) KB/s", systemImage: "arrow.down.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(DesignSystem.Colors.success)

                                            Label("\(up) KB/s", systemImage: "arrow.up.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(DesignSystem.Colors.warning)

                                            Label("\(lat)ms", systemImage: "clock.fill")
                                                .font(.caption)
                                                .foregroundStyle(DesignSystem.Colors.accentAlt)

                                            if loss > 0 {
                                                Label(String(format: "%.1f%%", loss * 100), systemImage: "exclamationmark.triangle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(DesignSystem.Colors.danger)
                                            }
                                        }
                                    } else {
                                        Text("Configure custom network settings")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if case .custom = viewModel.selectedNetworkCondition {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DesignSystem.Colors.accent)
                                        .font(.title3)
                                }
                            }
                            .padding(.vertical, DesignSystem.Spacing.md)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Custom network condition. Configure custom network settings.")
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Enable Network Throttling?", isPresented: $showingEnableConfirmation) {
                Button("Cancel", role: .cancel) {
                    viewModel.throttlingEnabled = false
                }
                Button("Enable") {
                    viewModel.throttlingEnabled = true
                }
            } message: {
                Text("Network throttling affects captured traffic and can impact app behavior. Disable when finished testing.")
            }
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var throttlingEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.throttlingEnabled },
            set: { newValue in
                if newValue, !viewModel.throttlingEnabled {
                    showingEnableConfirmation = true
                } else {
                    viewModel.throttlingEnabled = newValue
                }
            }
        )
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
                            .accessibilityLabel("Download speed")
                            .accessibilityValue("\(downloadSpeed) kilobytes per second")
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Upload Speed: \(uploadSpeed) KB/s")
                            .font(.headline)
                        Slider(value: Binding(
                            get: { Double(uploadSpeed) },
                            set: { uploadSpeed = Int($0) }
                        ), in: 0 ... 50000, step: 50)
                            .accessibilityLabel("Upload speed")
                            .accessibilityValue("\(uploadSpeed) kilobytes per second")
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
                            .accessibilityLabel("Latency")
                            .accessibilityValue("\(latency) milliseconds")
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
                            .accessibilityLabel("Packet loss")
                            .accessibilityValue(String(format: "%.1f percent", packetLoss * 100))
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
                            .foregroundStyle(.secondary)
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
