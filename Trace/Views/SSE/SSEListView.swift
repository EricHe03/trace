//
//  SSEListView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct SSEListView: View {
    @StateObject private var viewModel = SSEViewModel()
    @State private var showingFilters = false
    @State private var showingClearAllAlert = false
    @State private var selectedConnection: SSEConnection?

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.filteredConnections) { connection in
                    NavigationLink(destination: SSEDetailView(connection: connection)) {
                        SSEConnectionRow(connection: connection)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel.deleteConnection(connection)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("SSE Connections")
            .searchable(
                text: $viewModel.searchText,
                prompt: "Search connections"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingFilters = true
                    } label: {
                        Label("Filter", systemImage: viewModel.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(viewModel.hasActiveFilters ? DesignSystem.Colors.accent : .primary)
                    }
                    .accessibilityLabel("Filters")
                    .accessibilityHint("Double tap to configure SSE connection filters")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showingClearAllAlert = true
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                        .disabled(viewModel.connections.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                    .accessibilityHint("Double tap to clear all SSE connections")
                }
            }
            .overlay {
                if viewModel.filteredConnections.isEmpty {
                    TraceContentUnavailableView(
                        viewModel.searchText.isEmpty ? "No Connections" : "No Results",
                        systemImage: viewModel.searchText.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "magnifyingglass",
                        description: Text(viewModel.searchText.isEmpty ? "SSE connections will appear here" : "Try a different search term")
                    )
                }
            }
            .sheet(isPresented: $showingFilters) {
                SSEFiltersView(viewModel: viewModel)
            }
            .alert("Clear All SSE Connections", isPresented: $showingClearAllAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    viewModel.clearConnections()
                }
            } message: {
                Text("Are you sure you want to clear all \(viewModel.connections.count) SSE connections? This action cannot be undone.")
            }
        }
    }
}

struct SSEConnectionRow: View {
    let connection: SSEConnection

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.smPlus) {
                statusBadge(text: connection.status.displayName, background: statusColor)

                Text("\(connection.eventCount) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if connection.isTruncated {
                    Text("TRUNCATED")
                        .font(DesignSystem.Badge.font)
                        .fontWeight(DesignSystem.Badge.fontWeight)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                        .padding(.vertical, DesignSystem.Badge.verticalPadding)
                        .background(DesignSystem.Colors.warning.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius, style: .continuous))
                }

                Spacer()

                if let duration = connection.duration {
                    Text(DesignSystem.formattedDuration(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(connection.url)
                .font(.subheadline)
                .lineLimit(2)

            HStack {
                Text(connection.startTime, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Text(connection.totalBytesString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.rowVertical)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SSE connection, \(connection.status.displayName), \(connection.eventCount) events\(connection.isTruncated ? ", truncated" : ""), \(connection.totalBytesString), \(connection.url)")
    }

    private var statusColor: Color {
        DesignSystem.Colors.statusColor(for: connection.status.color)
    }

    private func statusBadge(text: String, background: Color) -> some View {
        Text(text)
            .font(DesignSystem.Badge.font)
            .fontWeight(DesignSystem.Badge.fontWeight)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius, style: .continuous))
    }
}

struct SSEFiltersView: View {
    @ObservedObject var viewModel: SSEViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Filter by Status", selection: $viewModel.filterStatus) {
                        Text("All").tag(SSEConnectionStatus?.none)
                        ForEach(SSEConnectionStatus.allCases, id: \.self) { status in
                            Text(status.displayName).tag(SSEConnectionStatus?.some(status))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        viewModel.clearFilters()
                    }
                    .disabled(!viewModel.hasActiveFilters)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SSEListView()
}
