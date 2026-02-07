//
//  SSEEventsSection.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Combine
import SwiftUI
import TraceCore
import TraceUI

struct SSEEventsSection: View {
    let request: NetworkRequest

    @State private var searchText = ""
    @State private var filterEventType: String?
    @State private var selectedEvent: ServerSentEvent?
    @State private var fallbackEvents: [ServerSentEvent] = []
    @State private var shouldPollFallback = true
    @State private var isLoadingFallback = false

    private let fallbackRefreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            if isLoadingFallback, displayedEvents.isEmpty {
                LoadingPlaceholderCard(
                    title: "SSE Events",
                    message: "Loading captured stream events..."
                )
            } else if displayedEvents.isEmpty {
                TraceContentUnavailableView(
                    "No SSE Events",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("No Server-Sent Events were parsed from the response")
                )
                .padding()
            } else {
                SSEEventsFilterBar(
                    searchText: $searchText,
                    filterEventType: $filterEventType,
                    uniqueEventTypes: uniqueEventTypes
                )

                SectionCard(title: "SSE Statistics", systemImage: "chart.bar") {
                    HStack {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("TOTAL EVENTS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            Text("\(displayedEvents.count)")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }

                        Spacer()

                        if !uniqueEventTypes.isEmpty {
                            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                                Text("EVENT TYPES")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                Text("\(uniqueEventTypes.count)")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }

                SectionCard(title: "Events Timeline", systemImage: "timeline.selection") {
                    if filteredEvents.isEmpty {
                        TraceContentUnavailableView(
                            "No Events Match",
                            systemImage: "magnifyingglass",
                            description: Text("Try adjusting your search or filter")
                        )
                    } else {
                        VStack(spacing: DesignSystem.Spacing.md) {
                            ForEach(filteredEvents) { event in
                                Button {
                                    selectedEvent = event
                                } label: {
                                    SSEEventRow(event: event)
                                }
                                .foregroundStyle(.primary)
                                .accessibilityHint("Double tap to view event details")

                                if event.id != filteredEvents.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .sheet(item: $selectedEvent) { event in
            SSEEventDetailView(event: event)
        }
        .task(id: request.id) {
            fallbackEvents = []
            shouldPollFallback = true
            await loadFallbackEventsIfNeeded()
        }
        .onReceive(fallbackRefreshTimer) { _ in
            guard shouldPollFallback, request.isSSE, request.sseEvents.isEmpty else { return }
            Task {
                await loadFallbackEventsIfNeeded()
            }
        }
    }

    private var filteredEvents: [ServerSentEvent] {
        var events = displayedEvents

        if let filterType = filterEventType {
            events = events.filter { $0.eventType == filterType }
        }

        if !searchText.isEmpty {
            events = events.filter { event in
                event.data.localizedStandardContains(searchText) ||
                    event.eventType?.localizedStandardContains(searchText) == true ||
                    event.eventId?.localizedStandardContains(searchText) == true
            }
        }

        return events
    }

    private var uniqueEventTypes: Set<String> {
        Set(displayedEvents.compactMap(\.eventType))
    }

    private var displayedEvents: [ServerSentEvent] {
        let parsedEvents = request.sseEvents
        return parsedEvents.isEmpty ? fallbackEvents : parsedEvents
    }

    private func loadFallbackEventsIfNeeded() async {
        let isAlreadyLoading = await MainActor.run { () -> Bool in
            if isLoadingFallback {
                return true
            }
            isLoadingFallback = true
            return false
        }
        guard !isAlreadyLoading else { return }

        defer {
            Task { @MainActor in
                isLoadingFallback = false
            }
        }

        guard request.isSSE else {
            await MainActor.run {
                fallbackEvents = []
                shouldPollFallback = false
            }
            return
        }

        guard request.sseEvents.isEmpty else {
            await MainActor.run {
                fallbackEvents = []
                shouldPollFallback = false
            }
            return
        }

        let requestURL = request.url
        let requestTimestamp = request.timestamp
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<FallbackLoadResult, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.loadFallbackEvents(
                    requestURL: requestURL,
                    requestTimestamp: requestTimestamp
                ))
            }
        }

        await MainActor.run {
            fallbackEvents = result.events
            shouldPollFallback = result.shouldContinuePolling
        }
    }

    private static func loadFallbackEvents(
        requestURL: String,
        requestTimestamp: Date
    ) -> FallbackLoadResult {
        do {
            let connections = try AppGroupStorage.shared.loadAllSSEConnections()
            let matchingConnections = connections.filter { canonicalURL($0.url) == canonicalURL(requestURL) }
            guard !matchingConnections.isEmpty else {
                return FallbackLoadResult(events: [], shouldContinuePolling: true)
            }

            let preferredConnections = matchingConnections.filter { !$0.events.isEmpty }
            let candidates = preferredConnections.isEmpty ? matchingConnections : preferredConnections
            guard let nearest = candidates.min(by: {
                abs($0.startTime.timeIntervalSince(requestTimestamp)) <
                    abs($1.startTime.timeIntervalSince(requestTimestamp))
            }) else {
                return FallbackLoadResult(events: [], shouldContinuePolling: false)
            }

            return FallbackLoadResult(
                events: nearest.events,
                shouldContinuePolling: nearest.isActive
            )
        } catch {
            return FallbackLoadResult(events: [], shouldContinuePolling: true)
        }
    }

    private static func canonicalURL(_ urlString: String) -> String {
        if urlString.hasSuffix("/") {
            return String(urlString.dropLast())
        }
        return urlString
    }
}

private struct FallbackLoadResult {
    let events: [ServerSentEvent]
    let shouldContinuePolling: Bool
}
