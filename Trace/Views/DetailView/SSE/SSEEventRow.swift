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
