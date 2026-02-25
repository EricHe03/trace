//
//  TransportEventRow.swift
//  Trace
//
//  Created by Codex on 2026/02/24.
//

import SwiftUI
import TraceCore
import TraceUI

struct TransportEventRow: View {
    let request: TransportRequest

    private var eventType: NetworkEventType {
        NetworkEvent.transportRequest(request).type
    }

    private var timestampText: String {
        request.timestamp.formatted(.dateTime.hour().minute().second())
    }

    private var payloadText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(request.payloadBytes))
    }

    private var parserBadge: String? {
        switch request.parserOutcome {
        case .parsed:
            return nil
        case .fallbackSignatureOnly:
            return "Signature Fallback"
        case .fallbackUnknown:
            return "Unknown Fallback"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: eventType.icon)
                .foregroundStyle(DesignSystem.Colors.eventTypeColor(for: eventType))
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(request.applicationProtocol.displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(request.transport.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(request.endpointSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if let summary = request.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let parserBadge {
                    Text(parserBadge)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DesignSystem.Colors.warning.opacity(0.15))
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(payloadText)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(timestampText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
