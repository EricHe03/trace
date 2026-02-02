//
//  ConnectionSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/28.
//

import SwiftUI
import TraceCore
import TraceUI

/// Consolidated connections + UDP flows (capture mode + SOCKS config live in Settings → Capture Mode).
struct ConnectionSettingsView: View {
    @State private var connectionRecords: [PacketFlowRecord] = []
    @StateObject private var udpFlowsViewModel = UDPFlowsViewModel()

    @State private var toastMessage: String?

    var body: some View {
        Form {
            activeConnectionsSection
            udpFlowsSection

            if connectionRecords.isEmpty && udpFlowsViewModel.flows.isEmpty {
                Section {
                    TraceContentUnavailableView(
                        "No Connections",
                        systemImage: "network.slash",
                        description: Text("Connection summaries and UDP flows will appear here when capture is active")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSettings() }
        .toast(message: $toastMessage)
    }

    @ViewBuilder
    private var activeConnectionsSection: some View {
        if !connectionRecords.isEmpty {
            Section("Active Connections") {
                ForEach(connectionRecords) { record in
                    NavigationLink {
                        ConnectionDetailView(record: record)
                    } label: {
                        ConnectionSummaryRow(record: record)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var udpFlowsSection: some View {
        if !udpFlowsViewModel.flows.isEmpty {
            Section("UDP Flows") {
                ForEach(udpFlowsViewModel.filteredFlows) { flow in
                    NavigationLink {
                        UDPFlowDetailView(flow: flow, viewModel: udpFlowsViewModel)
                    } label: {
                        UDPFlowSummaryRow(flow: flow, viewModel: udpFlowsViewModel)
                    }
                }
            }
        }
    }

    private func loadSettings() async {
        do {
            connectionRecords = try AppGroupStorage.shared.loadAllPacketFlowRecords()
        } catch {
            toastMessage = "Failed to load connections: \(error.localizedDescription)"
        }

        udpFlowsViewModel.startObserving()
        await udpFlowsViewModel.loadFlows()
    }
}

private struct ConnectionSummaryRow: View {
    let record: PacketFlowRecord
    private var accessibilityValue: String {
        var parts: [String] = []
        parts.append("\(record.transport.rawValue.uppercased()) from \(record.sourceIP):\(record.sourcePort) to \(record.destinationIP):\(record.destinationPort)")
        if let sni = record.tlsSNI, !sni.isEmpty {
            parts.append("TLS SNI \(sni)")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(record.sourceIP):\(record.sourcePort)")
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(record.destinationIP):\(record.destinationPort)")
            }
            .font(.system(.subheadline, design: .monospaced))
            .lineLimit(1)

            HStack(spacing: 6) {
                Text(record.transport.rawValue.uppercased())
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, DesignSystem.Spacing.xxs)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(DesignSystem.CornerRadius.sm)

                if let sni = record.tlsSNI, !sni.isEmpty {
                    Text(sni)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection")
        .accessibilityValue(accessibilityValue)
    }
}

private struct UDPFlowSummaryRow: View {
    let flow: UDPFlowMetadata
    let viewModel: UDPFlowsViewModel
    private var accessibilityValue: String {
        var parts: [String] = []
        parts.append("\(flow.sourceIP):\(flow.sourcePort) to \(flow.destinationIP):\(flow.destinationPort)")
        parts.append(flow.detectedProtocol.displayName)
        parts.append(viewModel.formatBytes(flow.totalBytes))
        if flow.isActive {
            parts.append("active")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(flow.sourceIP):\(flow.sourcePort)")
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(flow.destinationIP):\(flow.destinationPort)")
            }
            .font(.system(.subheadline, design: .monospaced))
            .lineLimit(1)

            HStack(spacing: 6) {
                Text(flow.detectedProtocol.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, DesignSystem.Spacing.xxs)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(DesignSystem.CornerRadius.sm)

                Text(viewModel.formatBytes(flow.totalBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if flow.isActive {
                    Text("• Active")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("UDP flow")
        .accessibilityValue(accessibilityValue)
    }
}
