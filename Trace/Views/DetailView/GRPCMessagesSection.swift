//
//  GRPCMessagesSection.swift
//  Trace
//

import Combine
import SwiftUI
import TraceCore
import TraceUI

struct GRPCMessagesSection: View {
    let request: NetworkRequest

    @State private var events: [StreamEvent] = []
    @State private var selectedEvent: StreamEvent?
    @State private var isLoading = true
    @State private var shouldPoll = true

    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            if isLoading && events.isEmpty {
                LoadingPlaceholderCard(
                    title: "gRPC Stream",
                    message: "Loading stream messages..."
                )
            } else if events.isEmpty {
                TraceContentUnavailableView(
                    "No gRPC Messages",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("No gRPC stream messages were captured for this request")
                )
                .padding()
            } else {
                statisticsCard
                messagesCard
            }
        }
        .padding()
        .sheet(item: $selectedEvent) { event in
            GRPCMessageDetailView(event: event)
        }
        .task(id: request.id) {
            events = []
            shouldPoll = true
            await loadEvents()
        }
        .onReceive(pollTimer) { _ in
            guard shouldPoll else { return }
            Task { await loadEvents() }
        }
    }

    @ViewBuilder
    private var statisticsCard: some View {
        SectionCard(title: "gRPC Stream", systemImage: "g.circle") {
            HStack {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(events.count)")
                        .font(.title2.weight(.semibold))
                }

                Spacer()

                let receivedCount = events.filter { $0.direction == .received }.count
                let sentCount = events.filter { $0.direction == .sent }.count

                if receivedCount > 0 {
                    VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                        Text("Received")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(receivedCount)")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.success)
                    }
                }

                if sentCount > 0 {
                    VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                        Text("Sent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(sentCount)")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var messagesCard: some View {
        SectionCard(title: "Messages Timeline", systemImage: "timeline.selection") {
            VStack(spacing: DesignSystem.Spacing.md) {
                ForEach(events) { event in
                    Button {
                        selectedEvent = event
                    } label: {
                        GRPCMessageRow(event: event)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Double tap to view message details")

                    if event.id != events.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func loadEvents() async {
        let isAlreadyLoading = await MainActor.run { () -> Bool in
            if isLoading && !events.isEmpty { return true }
            isLoading = events.isEmpty
            return false
        }
        guard !isAlreadyLoading else { return }

        let requestURL = request.url
        let requestTimestamp = request.timestamp

        let result = await Task.detached(priority: .userInitiated) {
            Self.loadStreamEvents(requestURL: requestURL, requestTimestamp: requestTimestamp)
        }.value

        await MainActor.run {
            if let newEvents = result.events {
                events = newEvents.filter { $0.kind == .message }.sorted { $0.sequence < $1.sequence }
            }
            shouldPoll = result.shouldContinuePolling
            isLoading = false
        }
    }

    private static func loadStreamEvents(
        requestURL: String,
        requestTimestamp: Date
    ) -> (events: [StreamEvent]?, shouldContinuePolling: Bool) {
        do {
            let sessions = try AppGroupStorage.shared.loadStreamSessions(protocolType: .grpc)
            let matching = sessions.filter { canonicalURL($0.url) == canonicalURL(requestURL) }
            guard !matching.isEmpty else {
                return (nil, true)
            }
            guard let nearest = matching.min(by: {
                abs($0.startTime.timeIntervalSince(requestTimestamp)) <
                    abs($1.startTime.timeIntervalSince(requestTimestamp))
            }) else {
                return (nil, false)
            }
            let events = try AppGroupStorage.shared.loadStreamEvents(sessionID: nearest.id)
            let stillActive = nearest.status == .open || nearest.status == .streaming || nearest.status == .connecting
            return (events, stillActive)
        } catch {
            return (nil, true)
        }
    }

    private static func canonicalURL(_ urlString: String) -> String {
        urlString.hasSuffix("/") ? String(urlString.dropLast()) : urlString
    }
}
