//
//  WebSocketListView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct WebSocketListView: View {
    @StateObject private var viewModel = WebSocketViewModel()
    @State private var showingFilters = false
    @State private var selectedConnection: WebSocketConnection?

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.filteredConnections) { connection in
                    NavigationLink(destination: WebSocketDetailView(connection: connection)) {
                        WebSocketConnectionRow(connection: connection)
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
            .navigationTitle("WebSocket")
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
                    .accessibilityHint("Double tap to configure WebSocket connection filters")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            viewModel.clearConnections()
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                        .disabled(viewModel.connections.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("More options")
                    .accessibilityHint("Double tap to clear all WebSocket connections")
                }
            }
            .overlay {
                if viewModel.filteredConnections.isEmpty {
                    TraceContentUnavailableView(
                        viewModel.searchText.isEmpty ? "No Connections" : "No Results",
                        systemImage: viewModel.searchText.isEmpty ? "network.slash" : "magnifyingglass",
                        description: Text(viewModel.searchText.isEmpty ? "WebSocket connections will appear here" : "Try a different search term")
                    )
                }
            }
            .sheet(isPresented: $showingFilters) {
                WebSocketFiltersView(viewModel: viewModel)
            }
        }
    }
}

struct WebSocketConnectionRow: View {
    let connection: WebSocketConnection

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.smPlus) {
            HStack {
                Text(connection.status.displayName)
                    .badgeStyle(backgroundColor: statusColor)

                Text("\(connection.messageCount) messages")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let duration = connection.duration {
                    Text(DesignSystem.formattedDuration(duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(connection.url)
                .font(.subheadline)
                .lineLimit(2)

            HStack {
                Text(connection.startTime, style: .relative) + Text(" ago")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text("↑ \(connection.sentMessageCount) ↓ \(connection.receivedMessageCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.rowVertical)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("WebSocket connection, \(connection.status.displayName), \(connection.messageCount) messages, \(connection.sentMessageCount) sent, \(connection.receivedMessageCount) received, \(connection.url)")
    }

    private var statusColor: Color {
        DesignSystem.Colors.statusColor(for: connection.status.color)
    }
}

struct WebSocketFiltersView: View {
    @ObservedObject var viewModel: WebSocketViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Filter by Status", selection: $viewModel.filterStatus) {
                        Text("All").tag(WebSocketConnectionStatus?.none)
                        ForEach(WebSocketConnectionStatus.allCases, id: \.self) { status in
                            Text(status.displayName).tag(WebSocketConnectionStatus?.some(status))
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
    WebSocketListView()
}
