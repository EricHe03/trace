//
//  GRPCListView.swift
//  Trace
//

import SwiftUI
import TraceCore
import TraceUI

struct GRPCListView: View {
    @StateObject private var viewModel = GRPCViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.filteredSessions.isEmpty {
                    TraceContentUnavailableView(
                        "No gRPC Streams",
                        systemImage: "g.circle",
                        description: Text("gRPC stream sessions will appear here when captured")
                    )
                } else {
                    List(viewModel.filteredSessions) { session in
                        NavigationLink {
                            GRPCDetailView(session: session)
                        } label: {
                            GRPCSessionRow(session: session)
                        }
                    }
                }
            }
            .navigationTitle("gRPC Streams")
            .searchable(text: $viewModel.searchText, prompt: "Search by URL")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !viewModel.sessions.isEmpty {
                        Button(role: .destructive) {
                            viewModel.clearSessions()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .task {
            await viewModel.loadSessions()
        }
    }
}

private struct GRPCSessionRow: View {
    let session: StreamSession

    private var statusColor: Color {
        switch session.status {
        case .open, .streaming: return DesignSystem.Colors.success
        case .closed: return .secondary
        case .failed: return DesignSystem.Colors.danger
        default: return DesignSystem.Colors.warning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text(URL(string: session.url)?.lastPathComponent ?? session.url)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(session.status.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack {
                Text(session.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Label("\(session.eventCount) msg", systemImage: "bubble.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(session.startTime, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("gRPC stream to \(session.url), \(session.eventCount) messages, \(session.status.rawValue)")
    }
}
