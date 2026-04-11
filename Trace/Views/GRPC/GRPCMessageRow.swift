//
//  GRPCMessageRow.swift
//  Trace
//

import SwiftUI
import TraceCore
import TraceUI

struct GRPCMessageRow: View {
    let event: StreamEvent

    private var directionColor: Color {
        event.direction == .sent ? DesignSystem.Colors.accent : DesignSystem.Colors.success
    }

    private var directionLabel: String {
        switch event.direction {
        case .sent: return "Sent"
        case .received: return "Received"
        case .system: return "System"
        }
    }

    private var decodedPreview: String {
        let payload = event.payload.binary ?? Data()
        if payload.isEmpty { return "(empty)" }
        let fields = ProtobufDecoder.decode(payload)
        if fields.isEmpty { return "\(payload.count) bytes" }
        let preview = fields.prefix(2).map { "\($0.displayName): \($0.value.previewText)" }.joined(separator: ", ")
        return fields.count > 2 ? preview + "…" : preview
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            VStack(spacing: 2) {
                Text(directionLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(directionColor)
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(directionColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))

                Text("#\(event.sequence)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(decodedPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack {
                    Text(formattedBytes(event.payload.byteCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(event.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(directionLabel) gRPC message, \(formattedBytes(event.payload.byteCount))")
    }

    private func formattedBytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }
}
