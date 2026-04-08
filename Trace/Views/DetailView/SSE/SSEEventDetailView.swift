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
    @State private var viewMode: ViewMode = .text

    enum ViewMode: String, CaseIterable {
        case text = "Text"
        case hex = "Hex"
        case raw = "Raw"
    }

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
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                            Picker("View Mode", selection: $viewMode) {
                                ForEach(ViewMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Group {
                                switch viewMode {
                                case .text:
                                    Text(event.data)
                                        .font(.system(.body, design: .monospaced))
                                case .hex:
                                    Text(eventDataHex)
                                        .font(.system(.caption, design: .monospaced))
                                case .raw:
                                    Text(String(bytes: eventData, encoding: .utf8) ?? "")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
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

    private var eventData: Data {
        Data(event.data.utf8)
    }

    private var eventDataHex: String {
        eventData.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

#Preview {
    SSEEventDetailView(event: ServerSentEvent(
        eventId: "42",
        eventType: "message",
        data: "{\"user\": \"alice\", \"message\": \"Hello from SSE!\", \"timestamp\": 1712345678}",
        retry: 3000,
        timestamp: Date()
    ))
}
