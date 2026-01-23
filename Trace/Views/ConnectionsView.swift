//
//  ConnectionsView.swift
//  Trace
//
//  Created by Justin on 2026/01/20.
//

import SwiftUI
import TraceCore
import TraceUI

struct ConnectionsView: View {
    @State private var records: [PacketFlowRecord] = []
    @State private var searchText = ""
    @State private var showingClearAlert = false
    @State private var toastMessage: String?

    var body: some View {
        List {
            if !records.isEmpty {
                Section {
                    ForEach(filteredRecords) { record in
                        NavigationLink {
                            ConnectionDetailView(record: record)
                        } label: {
                            ConnectionRow(record: record)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = "\(record.sourceIP):\(record.sourcePort)"
                            } label: {
                                Label("Copy Source", systemImage: "doc.on.doc")
                            }
                            Button {
                                UIPasteboard.general.string = "\(record.destinationIP):\(record.destinationPort)"
                            } label: {
                                Label("Copy Destination", systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connections")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showingClearAlert = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(records.isEmpty)
            }
        }
        .overlay {
            if records.isEmpty {
                TraceContentUnavailableView(
                    "No Connections",
                    systemImage: "network.slash",
                    description: Text("Connection summaries will appear here")
                )
            } else if filteredRecords.isEmpty {
                TraceContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No connections match your search")
                )
            }
        }
        .refreshable {
            loadRecords()
        }
        .onAppear {
            loadRecords()
        }
        .alert("Clear Connections", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearRecords()
            }
        } message: {
            Text("Remove all recorded connection summaries?")
        }
        .toast(message: $toastMessage)
    }

    private var filteredRecords: [PacketFlowRecord] {
        guard !searchText.isEmpty else { return records }
        let lowered = searchText.lowercased()
        return records.filter { record in
            record.sourceIP.lowercased().contains(lowered) ||
                record.destinationIP.lowercased().contains(lowered) ||
                (record.tlsSNI?.lowercased().contains(lowered) ?? false)
        }
    }

    private func loadRecords() {
        do {
            records = try AppGroupStorage.shared.loadAllPacketFlowRecords()
        } catch {
            toastMessage = "Failed to load connections: \(error.localizedDescription)"
        }
    }

    private func clearRecords() {
        do {
            try AppGroupStorage.shared.clearAllPacketFlowRecords()
            records = []
        } catch {
            toastMessage = "Failed to clear connections: \(error.localizedDescription)"
        }
    }
}

private struct ConnectionRow: View {
    let record: PacketFlowRecord

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Protocol Icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 36, height: 36)

                Image(systemName: transportIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                // IPs
                HStack(spacing: 4) {
                    Text("\(record.sourceIP):\(record.sourcePort)")
                        .foregroundStyle(.primary)

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("\(record.destinationIP):\(record.destinationPort)")
                        .foregroundStyle(.primary)
                }
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1)

                // Metadata
                HStack(spacing: 6) {
                    Text(record.transport.rawValue.uppercased())
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)

                    if let sni = record.tlsSNI {
                        Text(sni)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(protocolHintText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var transportIcon: String {
        switch record.transport {
        case .tcp: "arrow.up.arrow.down"
        case .udp: "arrow.triangle.2.circlepath"
        case .unknown: "questionmark.circle"
        }
    }

    private var protocolHintText: String {
        if record.protocolHints.isEmpty {
            return "Unknown"
        }
        if record.protocolHints.contains(.tls), record.tlsSNI == nil {
            return "TLS (No SNI)"
        }
        return record.protocolHints.map(\.rawValue).joined(separator: ", ")
    }
}
