//
//  SSEEventRow.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct SSEEventRow: View {
    let event: ServerSentEvent

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.smPlus) {
            HStack {
                if let eventType = event.eventType {
                    Text(eventType)
                        .badgeStyle(backgroundColor: DesignSystem.Colors.accent)
                }

                if let eventId = event.eventId {
                    Text("ID: \(eventId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(event.sizeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(event.preview)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(event.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }
}

#Preview {
    List {
        SSEEventRow(event: ServerSentEvent(
            eventId: "42",
            eventType: "message",
            data: "{\"user\": \"alice\", \"text\": \"Hello world\"}",
            timestamp: Date()
        ))
        SSEEventRow(event: ServerSentEvent(
            eventType: "ping",
            data: "keepalive",
            timestamp: Date().addingTimeInterval(-5)
        ))
        SSEEventRow(event: ServerSentEvent(
            data: "A very long data payload that exceeds the preview limit and should be truncated with an ellipsis at the end of the visible area",
            timestamp: Date().addingTimeInterval(-10)
        ))
    }
}
