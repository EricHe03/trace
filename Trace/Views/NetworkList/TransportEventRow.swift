//
//  TransportEventRow.swift
//  Trace
//
//  Created by Justin on 2026/02/24.
//

import Foundation
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

    private var packetSizeText: String {
        formattedByteCount(request.packetBytes ?? request.totalLength)
    }

    private var payloadSizeText: String {
        formattedByteCount(request.payloadBytes)
    }

    private var sizeHintText: String? {
        guard let packetBytes = request.packetBytes,
              packetBytes != request.payloadBytes
        else {
            return nil
        }
        return "payload \(payloadSizeText)"
    }

    private var transportHintText: String? {
        if request.transport == .tcp, let flags = request.tcpFlags {
            var names: [String] = []
            if flags & 0x02 != 0 { names.append("SYN") }
            if flags & 0x10 != 0 { names.append("ACK") }
            if flags & 0x01 != 0 { names.append("FIN") }
            if flags & 0x04 != 0 { names.append("RST") }
            if flags & 0x08 != 0 { names.append("PSH") }
            if flags & 0x20 != 0 { names.append("URG") }
            if names.isEmpty {
                return "FLAGS 0x\(String(format: "%02X", Int(flags)))"
            }
            return names.joined(separator: "|")
        }

        if request.transport == .udp, let udpLength = request.udpDatagramLength {
            return "LEN \(udpLength)"
        }

        return nil
    }

    private var parserBadge: String? {
        switch request.parserOutcome {
        case .parsed:
            nil
        case .fallbackSignatureOnly:
            "Signature Fallback"
        case .fallbackUnknown:
            nil
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
                    if let protocolBadge = request.protocolBadgeText {
                        Text(protocolBadge)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.success.opacity(0.16))
                            .foregroundStyle(DesignSystem.Colors.success)
                            .clipShape(Capsule())
                    }
                    Text(request.transport.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let transportHintText {
                        Text(transportHintText)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.accent.opacity(0.12))
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .clipShape(Capsule())
                    }
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
                Text(packetSizeText)
                    .font(.caption)
                    .fontWeight(.medium)
                if let sizeHintText {
                    Text(sizeHintText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(timestampText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedByteCount(_ bytes: Int) -> String {
        DesignSystem.formattedBytes(bytes)
    }
}

// MARK: - Previews

#Preview {
    List {
        TransportEventRow(request: TransportRequest(
            sourceIP: "192.168.1.10",
            destinationIP: "8.8.8.8",
            sourcePort: 54321,
            destinationPort: 53,
            transport: .udp,
            applicationProtocol: .dns,
            parserOutcome: .parsed,
            payload: .empty,
            payloadBytes: 48,
            ipVersion: 4,
            protocolNumber: 17,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 68,
            fragmentOffset: 0,
            moreFragments: false,
            udpDatagramLength: 28,
            summary: "Query: example.com",
            flowKey: "udp|192.168.1.10:54321|8.8.8.8:53"
        ))
        TransportEventRow(request: TransportRequest(
            sourceIP: "10.0.0.5",
            destinationIP: "93.184.216.34",
            sourcePort: 49152,
            destinationPort: 443,
            transport: .tcp,
            applicationProtocol: .tls,
            parserOutcome: .parsed,
            payload: .empty,
            payloadBytes: 1400,
            packetBytes: 1440,
            ipVersion: 4,
            protocolNumber: 6,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 1460,
            fragmentOffset: 0,
            moreFragments: false,
            tcpFlags: 0x18,
            flowKey: "tcp|10.0.0.5:49152|93.184.216.34:443"
        ))
    }
}
