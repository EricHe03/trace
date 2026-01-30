//
//  DNSListView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct DNSListView: View {
    @StateObject private var viewModel = DNSViewModel()
    @State private var selectedMessageID: DNSMessage.ID?
    @State private var showingFilters = false
    @State private var showingExport = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if let stats = viewModel.statistics {
                    statisticsHeader(stats)
                }

                List(selection: $selectedMessageID) {
                    ForEach(viewModel.messages, id: \.id) { message in
                        DNSMessageRow(message: message)
                            .tag(message.id)
                            .contextMenu {
                                messageContextMenu(for: message)
                            }
                    }
                }
                #if os(macOS)
                .listStyle(.inset(alternatesRowBackgrounds: true))
                #else
                .listStyle(.insetGrouped)
                #endif
                .overlay {
                    if viewModel.messages.isEmpty {
                        TraceContentUnavailableView(
                            viewModel.searchText.isEmpty ? "No DNS Queries" : "No Results",
                            systemImage: viewModel.searchText.isEmpty ? "network" : "magnifyingglass",
                            description: Text(viewModel.searchText.isEmpty ? "DNS queries will appear here as they're captured" : "Try a different search term or filter")
                        )
                    }
                }
            }
            .navigationTitle("DNS Queries")
            .toolbar {
                toolbarContent
            }
            .searchable(text: $viewModel.searchText, prompt: "Search domains, IPs...")
            .sheet(isPresented: $showingFilters) {
                DNSFilterView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingExport) {
                DNSExportView(viewModel: viewModel)
            }
        } detail: {
            if let message = selectedMessage {
                DNSDetailView(message: message)
            } else {
                TraceContentUnavailableView(
                    "No DNS Query Selected",
                    systemImage: "network",
                    description: Text("Select a DNS query to view details")
                )
            }
        }
    }

    // MARK: - Statistics Header

    @ViewBuilder
    private func statisticsHeader(_ stats: DNSStatistics) -> some View {
        HStack(spacing: 20) {
            StatItem(
                title: "Total",
                value: "\(stats.totalMessages)",
                color: DesignSystem.Colors.info
            )

            StatItem(
                title: "Queries",
                value: "\(stats.totalQueries)",
                color: DesignSystem.Colors.warning
            )

            StatItem(
                title: "Responses",
                value: "\(stats.totalResponses)",
                color: DesignSystem.Colors.success
            )

            StatItem(
                title: "Success Rate",
                value: String(format: "%.1f%%", stats.successRate * 100),
                color: DesignSystem.Colors.success
            )

            StatItem(
                title: "Avg Response",
                value: String(format: "%.0fms", stats.averageResponseTime * 1000),
                color: DesignSystem.Colors.accentAlt
            )

            StatItem(
                title: "Unanswered",
                value: "\(stats.unansweredQueries)",
                color: DesignSystem.Colors.danger
            )
        }
        .padding()
        .background(statisticsBackground)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showingFilters.toggle()
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filter DNS messages")

            Button {
                viewModel.refreshStatistics()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh statistics")

            Button {
                showingExport.toggle()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export DNS data")

            Button(role: .destructive) {
                viewModel.clearAll()
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .help("Clear all DNS messages")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func messageContextMenu(for message: DNSMessage) -> some View {
        Button {
            selectedMessageID = message.id
        } label: {
            Label("View Details", systemImage: "info.circle")
        }

        if let domain = message.queryDomain {
            Button {
                copyToPasteboard(domain)
            } label: {
                Label("Copy Domain", systemImage: "doc.on.doc")
            }
        }

        Button {
            copyToPasteboard(message.sourceIP)
        } label: {
            Label("Copy Source IP", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            viewModel.deleteMessage(message)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var selectedMessage: DNSMessage? {
        guard let selectedMessageID else { return nil }
        return viewModel.messages.first { $0.id == selectedMessageID }
    }

    private var statisticsBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }

    private func copyToPasteboard(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
    }
}

// MARK: - DNS Message Row

struct DNSMessageRow: View {
    let message: DNSMessage

    var body: some View {
        HStack(spacing: 12) {
            // Status Icon
            Image(systemName: message.statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 20)
                .accessibilityHidden(true)

            // Domain and Type
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                if let domain = message.queryDomain {
                    Text(domain)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                } else {
                    Text("Unknown")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if let type = message.queryType {
                        Text(type.displayName)
                            .font(.caption)
                            .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                            .padding(.vertical, DesignSystem.Badge.verticalPadding)
                            .background(DesignSystem.Colors.info.opacity(0.2))
                            .cornerRadius(DesignSystem.Badge.cornerRadius)
                    }

                    if message.isResponse {
                        Text(message.responseCode.displayName)
                            .font(.caption)
                            .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                            .padding(.vertical, DesignSystem.Badge.verticalPadding)
                            .background((message.isSuccessful ? DesignSystem.Colors.success : DesignSystem.Colors.danger).opacity(0.2))
                            .cornerRadius(DesignSystem.Badge.cornerRadius)
                    }
                }
            }

            Spacer()

            // Response details or source info.
            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xxs) {
                if message.isResponse {
                    if !message.resolvedIPs.isEmpty {
                        Text(message.resolvedIPs.first ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if let responseTime = message.responseTime {
                        Text(String(format: "%.0fms", responseTime * 1000))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(message.sourceIP):\(message.sourcePort)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(message.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message.isResponse ? "DNS response" : "DNS query")
        .accessibilityValue(accessibilityValue)
    }

    private var statusColor: Color {
        if !message.isResponse {
            return DesignSystem.Colors.info
        }
        return message.isSuccessful ? DesignSystem.Colors.success : DesignSystem.Colors.danger
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let domain = message.queryDomain {
            parts.append(domain)
        }
        if let type = message.queryType {
            parts.append(type.displayName)
        }
        if message.isResponse {
            parts.append(message.responseCode.displayName)
            if let responseTime = message.responseTime {
                parts.append(String(format: "%.0f milliseconds", responseTime * 1000))
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#Preview {
    DNSListView()
}
