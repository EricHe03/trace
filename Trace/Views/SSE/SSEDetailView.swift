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
                        Text("Truncated:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Yes (Limit Reached)")
                            .foregroundStyle(.orange)
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
                ForEach(filteredEvents) { event in
                    Button {
                        selectedEvent = event
                    } label: {
                        SSEConnectionEventRow(event: event)
                    }
                    .foregroundStyle(.primary)
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
            SSEEventDetailSheet(event: event)
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
                event.data.localizedCaseInsensitiveContains(searchText) ||
                    event.eventType?.localizedCaseInsensitiveContains(searchText) == true ||
                    event.eventId?.localizedCaseInsensitiveContains(searchText) == true
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

    private func clearFilters() {
        filterEventType = nil
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        DesignSystem.formattedDuration(duration)
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

struct SSEEventDetailSheet: View {
    let event: ServerSentEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    // Metadata
                    GroupBox("Metadata") {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            if let eventType = event.eventType {
                                HStack {
                                    Text("Event Type:")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(eventType)
                                        .fontWeight(.medium)
                                }

                                Divider()
                            }

                            if let eventId = event.eventId {
                                HStack {
                                    Text("Event ID:")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(eventId)
                                        .fontWeight(.medium)
                                }

                                Divider()
                            }

                            HStack {
                                Text("Size:")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(event.sizeString)
                                    .fontWeight(.medium)
                            }

                            Divider()

                            HStack {
                                Text("Timestamp:")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(event.timestamp, format: .dateTime)
                                    .fontWeight(.medium)
                            }

                            if let retry = event.retry {
                                Divider()
                                HStack {
                                    Text("Retry:")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(retry) ms")
                                        .fontWeight(.medium)
                                }
                            }
                        }
                    }

                    // Data
                    GroupBox("Data") {
                        Text(event.data)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
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
