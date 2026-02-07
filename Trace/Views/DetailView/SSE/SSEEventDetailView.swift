//
//  SSEEventDetailView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct SSEEventDetailView: View {
    let event: ServerSentEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    SectionCard(title: "Metadata", systemImage: "info.circle") {
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
                                    Text("\(retry)ms")
                                        .fontWeight(.medium)
                                }
                            }
                        }
                    }

                    SectionCard(title: "Data", systemImage: "text.justify.left") {
                        Text(event.data)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("SSE Event Details")
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
