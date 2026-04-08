//
//  SSEEventsFilterBar.swift
//  Trace
//
//  Created by Justin on 2026/02/06.
//

import SwiftUI
import TraceUI

struct SSEEventsFilterBar: View {
    @Binding var searchText: String
    @Binding var filterEventType: String?
    let uniqueEventTypes: Set<String>

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || filterEventType != nil
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            TextField("Search events", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.webSearch)
                .submitLabel(.search)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Menu {
                    Button("All Event Types") {
                        filterEventType = nil
                    }
                    ForEach(Array(uniqueEventTypes).sorted(), id: \.self) { type in
                        Button(type) {
                            filterEventType = type
                        }
                    }
                } label: {
                    Label(
                        filterEventType ?? "All Event Types",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Spacer()

                if hasActiveFilters {
                    Button("Clear") {
                        searchText = ""
                        filterEventType = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SSE filters")
    }
}

private struct SSEEventsFilterBarPreview: View {
    @State private var searchText = ""
    @State private var filterType: String?

    var body: some View {
        SSEEventsFilterBar(
            searchText: $searchText,
            filterEventType: $filterType,
            uniqueEventTypes: ["message", "update", "ping"]
        )
        .padding()
    }
}

#Preview {
    SSEEventsFilterBarPreview()
}
