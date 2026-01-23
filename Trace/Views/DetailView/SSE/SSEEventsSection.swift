//
//  SSEEventsSection.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct SSEEventsSection: View {
    let request: NetworkRequest
    @State private var searchText = ""
    @State private var filterEventType: String?
    @State private var selectedEvent: ServerSentEvent?

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            let events = request.sseEvents

            if events.isEmpty {
                TraceContentUnavailableView(
                    "No SSE Events",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("No Server-Sent Events were parsed from the response")
                )
                .padding()
            } else {
                // Statistics
                InfoCard(title: "SSE Statistics") {
                    HStack {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("TOTAL EVENTS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            Text("\(events.count)")
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

                // Event List
                InfoCard(title: "Events Timeline") {
                    VStack(spacing: DesignSystem.Spacing.md) {
                        ForEach(filteredEvents) { event in
                            Button {
                                selectedEvent = event
                            } label: {
                                SSEEventRow(event: event)
                            }
                            .foregroundStyle(.primary)

                            if event.id != filteredEvents.last?.id {
                                Divider()
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
    }

    private var filteredEvents: [ServerSentEvent] {
        var events = request.sseEvents

        if !searchText.isEmpty {
            events = events.filter { event in
                event.data.localizedCaseInsensitiveContains(searchText) ||
                    event.eventType?.localizedCaseInsensitiveContains(searchText) == true
            }
        }

        if let filterType = filterEventType {
            events = events.filter { $0.eventType == filterType }
        }

        return events
    }

    private var uniqueEventTypes: Set<String> {
        Set(request.sseEvents.compactMap(\.eventType))
    }
}
