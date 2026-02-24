//
//  UDPFlowsView.swift
//  Trace
//
//  Created by Justin on 2026/01/21.
//

import SwiftUI
import TraceCore
import TraceUI

struct UDPFlowsView: View {
    @StateObject private var viewModel = UDPFlowsViewModel()
    @State private var showingFilters = false
    @State private var showingExport = false
    @State private var showingClearAllAlert = false
    @State private var shareSheetItem: ShareSheetItem?
    @State private var toastMessage: String?

    var body: some View {
        List {
            if !viewModel.flows.isEmpty {
                Section {
                    statsHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .padding(.bottom, 8)
                }
            }

            Section {
                ForEach(viewModel.filteredFlows) { flow in
                    NavigationLink {
                        UDPFlowDetailView(flow: flow, viewModel: viewModel)
                    } label: {
                        UDPFlowRow(flow: flow, viewModel: viewModel)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            viewModel.deleteFlow(flow)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = "\(flow.sourceIP):\(flow.sourcePort)"
                        } label: {
                            Label("Copy Source", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = "\(flow.destinationIP):\(flow.destinationPort)"
                        } label: {
                            Label("Copy Destination", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("UDP Flows")
        .searchable(text: $viewModel.searchText, prompt: "Search IP, port, protocol")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.filteredFlows.isEmpty)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showingClearAllAlert = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(viewModel.flows.isEmpty)
            }
        }
        .sheet(isPresented: $showingFilters) {
            NavigationStack {
                UDPFlowFiltersView(viewModel: viewModel)
            }
        }
        .shareSheet(item: $shareSheetItem)
        .confirmationDialog("Export UDP Flows", isPresented: $showingExport, titleVisibility: .visible) {
            Button("Export CSV") {
                exportCSV()
            }
            Button("Export JSON") {
                exportJSON()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Clear All UDP Flows", isPresented: $showingClearAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                viewModel.clearAll()
            }
        } message: {
            Text("Are you sure you want to clear all \(viewModel.flows.count) UDP flows? This action cannot be undone.")
        }
        .overlay {
            if viewModel.flows.isEmpty {
                TraceContentUnavailableView(
                    "No UDP Flows",
                    systemImage: "network.slash",
                    description: Text("UDP flows will appear here when capture is active")
                )
            } else if viewModel.filteredFlows.isEmpty {
                TraceContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try adjusting your filters")
                )
            }
        }
        .refreshable {
            await viewModel.loadFlows()
        }
        .toast(message: $toastMessage)
        .onAppear {
            viewModel.startObserving()
            Task { await viewModel.loadFlows() }
        }
        .onChangeCompat(of: viewModel.lastError) { newValue in
            guard let message = newValue else { return }
            toastMessage = message
        }
    }

    private var statsHeader: some View {
        let stats = viewModel.statistics
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                StatCard(title: "Active", value: "\(stats.activeFlows)", color: .green)
                StatCard(title: "Total", value: "\(stats.totalFlows)", color: .blue)
                StatCard(title: "Data", value: viewModel.formatBytes(stats.totalBytes), color: .orange)
                StatCard(title: "Datagrams", value: "\(stats.totalDatagrams)", color: .purple)
            }
            .padding(.horizontal)
        }
    }

    private func exportCSV() {
        do {
            let url = try viewModel.exportCSV()
            shareSheetItem = ShareSheetItem([url])
        } catch {
            toastMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func exportJSON() {
        do {
            let url = try viewModel.exportJSON()
            shareSheetItem = ShareSheetItem([url])
        } catch {
            toastMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

private struct UDPFlowRow: View {
    let flow: UDPFlowMetadata
    let viewModel: UDPFlowsViewModel
    private var accessibilityValue: String {
        var parts: [String] = []
        parts.append("\(flow.sourceIP):\(flow.sourcePort) to \(flow.destinationIP):\(flow.destinationPort)")
        parts.append(flow.detectedProtocol.displayName)
        parts.append(viewModel.formatBytes(flow.totalBytes))
        parts.append(viewModel.formatDuration(flow.duration))
        if flow.isActive {
            parts.append("active")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Protocol Icon/Initial
            ZStack {
                Circle()
                    .fill(protocolColor.opacity(0.15))
                    .frame(width: 36, height: 36)

                Text(flow.detectedProtocol.displayName.prefix(1))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(protocolColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                // IPs
                HStack(spacing: 4) {
                    Text("\(flow.sourceIP):\(flow.sourcePort)")
                        .foregroundStyle(.primary)

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("\(flow.destinationIP):\(flow.destinationPort)")
                        .foregroundStyle(.primary)
                }
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1)

                // Metadata
                HStack(spacing: 6) {
                    Text(flow.detectedProtocol.displayName)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                        .padding(.vertical, DesignSystem.Badge.verticalPadding)
                        .frame(minHeight: DesignSystem.Accessibility.absoluteMinimumTapTarget)
                        .background(protocolColor.opacity(0.1))
                        .foregroundStyle(protocolColor)
                        .cornerRadius(DesignSystem.Badge.cornerRadius)

                    if let quicOutcome = flow.quicInspectionOutcome {
                        Text(quicOutcomeBadgeTitle(quicOutcome))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                            .padding(.vertical, DesignSystem.Badge.verticalPadding)
                            .frame(minHeight: DesignSystem.Accessibility.absoluteMinimumTapTarget)
                            .background(quicOutcomeBadgeColor(quicOutcome).opacity(0.1))
                            .foregroundStyle(quicOutcomeBadgeColor(quicOutcome))
                            .cornerRadius(DesignSystem.Badge.cornerRadius)
                    }

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(viewModel.formatBytes(flow.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if flow.isActive {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label("Active", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(DesignSystem.Colors.success)
                    }
                }
            }

            Spacer()

            // Timestamp/Duration (optional, but good for list context)
            VStack(alignment: .trailing) {
                Text(viewModel.formatDuration(flow.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("UDP flow")
        .accessibilityValue(accessibilityValue)
    }

    private var protocolColor: Color {
        switch flow.detectedProtocol {
        case .dns: .purple
        case .quic: .blue
        case .dhcp: .orange
        case .ntp: .yellow
        case .mdns: .teal
        case .snmp: .indigo
        case .unknown: .gray
        }
    }

    private func quicOutcomeBadgeTitle(_ outcome: QUICInspectionOutcome) -> String {
        switch outcome {
        case .intercepted:
            "MITM"
        case .passThroughMarked:
            "Pass Through"
        case .blocked:
            "Blocked"
        case .tunnelForwarded:
            "Tunnel"
        }
    }

    private func quicOutcomeBadgeColor(_ outcome: QUICInspectionOutcome) -> Color {
        switch outcome {
        case .intercepted:
            .green
        case .passThroughMarked:
            .orange
        case .blocked:
            .red
        case .tunnelForwarded:
            .teal
        }
    }
}

private struct UDPFlowFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: UDPFlowsViewModel

    var body: some View {
        Form {
            Section("Search") {
                TextField("Search by IP or port", text: $viewModel.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.search)
            }

            Section("Status") {
                Toggle("Active Only", isOn: $viewModel.activeOnly)
            }

            Section("Protocol") {
                Picker("Protocol", selection: $viewModel.selectedProtocol) {
                    Text("All").tag(UDPFlowProtocol?.none)
                    ForEach(UDPFlowProtocol.allCases, id: \.self) { proto in
                        Text(proto.displayName).tag(Optional(proto))
                    }
                }
            }

            Section("Port") {
                TextField("Port", text: $viewModel.portFilter)
                    .keyboardType(.asciiCapableNumberPad)
            }

            Section("Sort") {
                Picker("Sort Order", selection: $viewModel.sortOrder) {
                    ForEach(UDPFlowsViewModel.SortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
            }

            Section {
                Button("Reset Filters") {
                    viewModel.searchText = ""
                    viewModel.activeOnly = false
                    viewModel.selectedProtocol = nil
                    viewModel.portFilter = ""
                    viewModel.sortOrder = .startTimeDescending
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Filters")
        .dismissKeyboardOnTapAndScroll()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
