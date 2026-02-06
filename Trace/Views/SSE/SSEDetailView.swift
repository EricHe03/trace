//
//  SSEDetailView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct SSEDetailView: View {
    let connection: SSEConnection

    @State private var searchText = ""
    @State private var filterEventType: String?
    @State private var selectedEvent: ServerSentEvent?
    @State private var showingFilters = false

    var body: some View {
        List {
            // Connection Info Section
            Section("Connection") {
                LabeledContent("URL", value: connection.url)
                LabeledContent("Status", value: connection.status.displayName)
                LabeledContent("Started", value: connection.startTime, format: .dateTime)

                if let endTime = connection.endTime {
                    LabeledContent("Ended", value: endTime, format: .dateTime)
                }

                if let duration = connection.duration {
                    LabeledContent("Duration", value: formattedDuration(duration))
                }

                if connection.isTruncated {
                    HStack {
                        Label("Truncated:", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Yes (Limit Reached)")
                            .foregroundStyle(DesignSystem.Colors.warning)
                            .fontWeight(.medium)
                    }
                }
            }

            // Statistics Section
            Section("Statistics") {
                LabeledContent("Total Events", value: String(connection.eventCount))
                LabeledContent("Bytes Received", value: connection.totalBytesString)
                LabeledContent("Event Types", value: String(uniqueEventTypes.count))
            }

            // Events Section
            Section {
                if filteredEvents.isEmpty {
                    eventsEmptyState
                } else {
                    ForEach(filteredEvents) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            SSEConnectionEventRow(event: event)
                        }
                        .foregroundStyle(.primary)
                        .accessibilityHint("Double tap to view event details")
                    }
                }
            } header: {
                HStack {
                    Text("Events")
                    Spacer()
                    if hasActiveFilters {
                        Text("\(filteredEvents.count) of \(connection.events.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("SSE Details")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search events")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Label("Filter", systemImage: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hasActiveFilters ? DesignSystem.Colors.accent : .primary)
                }
            }
        }
        .sheet(item: $selectedEvent) { event in
            SSEEventDetailView(event: event)
        }
        .sheet(isPresented: $showingFilters) {
            SSEEventFiltersView(
                filterEventType: $filterEventType,
                uniqueEventTypes: uniqueEventTypes,
                hasActiveFilters: hasActiveFilters,
                onClear: clearFilters
            )
        }
    }

    private var filteredEvents: [ServerSentEvent] {
        var filtered = connection.events

        // Apply event type filter
        if let type = filterEventType {
            filtered = filtered.filter { $0.eventType == type }
        }

        // Apply search filter
        if !searchText.isEmpty {
            filtered = filtered.filter { event in
                event.data.localizedStandardContains(searchText) ||
                    event.eventType?.localizedStandardContains(searchText) == true ||
                    event.eventId?.localizedStandardContains(searchText) == true
            }
        }

        return filtered
    }

    private var uniqueEventTypes: Set<String> {
        Set(connection.events.compactMap(\.eventType))
    }

    private var hasActiveFilters: Bool {
        filterEventType != nil
    }

    @ViewBuilder
    private var eventsEmptyState: some View {
        if connection.events.isEmpty {
            TraceContentUnavailableView(
                "No Events",
                systemImage: "text.badge.checkmark",
                description: Text("Server-sent events will appear here as they're received")
            )
            .listRowBackground(Color.clear)
        } else {
            // Filters resulted in no events
            TraceContentUnavailableView(
                "No Events Match",
                systemImage: "magnifyingglass",
                description: Text("Try adjusting your search or filters")
            )
            .listRowBackground(Color.clear)
        }
    }

    private func clearFilters() {
        filterEventType = nil
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        DesignSystem.formattedDuration(duration)
    }
}

/// Resolves a live SSE connection snapshot from the shared view model to avoid stale detail data.
struct LiveSSEDetailView: View {
    let connectionID: UUID
    let fallbackConnection: SSEConnection
    @ObservedObject var viewModel: SSEViewModel

    private var resolvedConnection: SSEConnection {
        viewModel.connections.first(where: { $0.id == connectionID }) ?? fallbackConnection
    }

    var body: some View {
        SSEDetailView(connection: resolvedConnection)
    }
}

struct SSEConnectionEventRow: View {
    let event: ServerSentEvent

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.smPlus) {
            HStack {
                // Event type badge
                if let eventType = event.eventType {
                    Text(eventType)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(DesignSystem.Colors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))
                }

                // Event ID
                if let eventId = event.eventId {
                    Text("ID: \(eventId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Size
                Text(event.sizeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Preview
            Text(event.preview)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(.secondary)

            // Timestamp
            Text(event.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }
}

struct SSEEventFiltersView: View {
    @Binding var filterEventType: String?
    let uniqueEventTypes: Set<String>
    let hasActiveFilters: Bool
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Event Type") {
                    Picker("Filter by Type", selection: $filterEventType) {
                        Text("All").tag(String?.none)
                        ForEach(Array(uniqueEventTypes).sorted(), id: \.self) { type in
                            Text(type).tag(String?.some(type))
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
                        onClear()
                    }
                    .disabled(!hasActiveFilters)
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
    NavigationStack {
        SSEDetailView(
            connection: SSEConnection(
                url: "https://example.com/events",
                events: [
                    ServerSentEvent(
                        eventType: "message",
                        data: "Hello from SSE!"
                    ),
                    ServerSentEvent(
                        eventType: "update",
                        data: "Status update received"
                    )
                ],
                status: .closed
            )
        )
    }
}
