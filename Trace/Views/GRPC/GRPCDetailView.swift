//
//  GRPCDetailView.swift
//  Trace
//

import SwiftUI
import TraceCore
import TraceUI

struct GRPCDetailView: View {
    let session: StreamSession

    @State private var events: [StreamEvent] = []
    @State private var selectedEvent: StreamEvent?
    @State private var searchText = ""
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lg) {
                sessionInfoCard
                messagesCard
            }
            .padding()
        }
        .navigationTitle("gRPC Stream")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search messages")
        .sheet(item: $selectedEvent) { event in
            GRPCMessageDetailView(event: event)
        }
        .task(id: session.id) {
            await loadEvents()
        }
    }

    @ViewBuilder
    private var sessionInfoCard: some View {
        SectionCard(title: "Session", systemImage: "g.circle") {
            InfoRow(label: "URL", value: session.url)
            Divider()
            InfoRow(label: "Status", value: session.status.rawValue.capitalized)
            Divider()
            InfoRow(label: "Messages", value: "\(session.eventCount)")
            Divider()
            InfoRow(label: "Received", value: formattedBytes(session.bytesIn))
            Divider()
            InfoRow(label: "Sent", value: formattedBytes(session.bytesOut))
            Divider()
            InfoRow(label: "Started", value: session.startTime.formatted(date: .abbreviated, time: .standard))
            if let endTime = session.endTime {
                Divider()
                InfoRow(label: "Ended", value: endTime.formatted(date: .abbreviated, time: .standard))
            }
        }
    }

    @ViewBuilder
    private var messagesCard: some View {
        if isLoading && events.isEmpty {
            LoadingPlaceholderCard(
                title: "Messages",
                message: "Loading stream events..."
            )
        } else if filteredEvents.isEmpty {
            TraceContentUnavailableView(
                "No Messages",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(searchText.isEmpty ? "No gRPC messages captured" : "No messages match your search")
            )
            .padding()
        } else {
            SectionCard(title: "Messages (\(filteredEvents.count))", systemImage: "list.bullet") {
                VStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(filteredEvents) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            GRPCMessageRow(event: event)
                        }
                        .foregroundStyle(.primary)
                        .accessibilityHint("Double tap to view message details")

                        if event.id != filteredEvents.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var filteredEvents: [StreamEvent] {
        guard !searchText.isEmpty else { return events }
        return events.filter { event in
            if let binary = event.payload.binary {
                let fields = ProtobufDecoder.decode(binary)
                return fields.contains { $0.value.previewText.localizedCaseInsensitiveContains(searchText) }
            }
            return false
        }
    }

    private func loadEvents() async {
        isLoading = true
        let sessionID = session.id
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? AppGroupStorage.shared.loadStreamEvents(sessionID: sessionID)) ?? []
        }.value
        events = loaded.sorted { $0.sequence < $1.sequence }
        isLoading = false
    }

    private func formattedBytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }
}
