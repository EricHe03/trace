//
//  GRPCMessageDetailView.swift
//  Trace
//

import SwiftUI
import TraceCore
import TraceUI

struct GRPCMessageDetailView: View {
    let event: StreamEvent

    @State private var showHex = false

    private var decodedFields: [ProtobufDecoder.Field] {
        let payload = event.payload.binary ?? Data()
        return ProtobufDecoder.decode(payload)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    SectionCard(title: "Message Info") {
                        InfoRow(label: "Sequence", value: "#\(event.sequence)")
                        Divider()
                        InfoRow(label: "Direction", value: event.direction.rawValue.capitalized)
                        Divider()
                        InfoRow(label: "Size", value: formattedBytes(event.payload.byteCount))
                        Divider()
                        InfoRow(label: "Timestamp", value: event.timestamp.formatted(date: .omitted, time: .standard))
                    }

                    SectionCard(title: "Payload") {
                        Picker("View", selection: $showHex) {
                            Text("Decoded").tag(false)
                            Text("Hex").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, DesignSystem.Spacing.xs)

                        if showHex {
                            hexView
                        } else {
                            if decodedFields.isEmpty {
                                Text("No protobuf fields decoded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding()
                            } else {
                                ProtobufMessageView(fields: decodedFields, depth: 0)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("gRPC Message")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var hexView: some View {
        let payload = event.payload.binary ?? Data()
        if payload.isEmpty {
            Text("(empty)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        } else {
            Text(hexString(payload))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hexString(_ data: Data) -> String {
        data.prefix(1024).map { String(format: "%02x", $0) }.joined(separator: " ")
            + (data.count > 1024 ? "\n…(\(data.count - 1024) more bytes)" : "")
    }

    private func formattedBytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }
}
