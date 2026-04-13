//
//  GRPCMetadataSection.swift
//  Trace
//

import SwiftUI
import TraceCore
import TraceUI

struct GRPCMetadataSection: View {
    let metadata: GRPCMetadata

    var body: some View {
        SectionCard(title: "gRPC", systemImage: "g.circle") {
            // Status — color-coded badge
            grpcStatusRow
            optionalDivider(metadata.statusMessage != nil)
            if let msg = metadata.statusMessage {
                InfoRow(label: "Status Message", value: msg)
                optionalDivider(metadata.encoding != nil || metadata.acceptEncoding != nil || metadata.timeout != nil || metadata.requestMessageCount != nil || metadata.responseMessageCount != nil || metadata.isGRPCWeb || metadata.statusDetailsBin != nil)
            }
            if let enc = metadata.encoding {
                InfoRow(label: "Encoding", value: enc)
                optionalDivider(metadata.acceptEncoding != nil || metadata.timeout != nil || metadata.requestMessageCount != nil || metadata.responseMessageCount != nil || metadata.isGRPCWeb || metadata.statusDetailsBin != nil)
            }
            if let acceptEnc = metadata.acceptEncoding {
                InfoRow(label: "Accept-Encoding", value: acceptEnc)
                optionalDivider(metadata.timeout != nil || metadata.requestMessageCount != nil || metadata.responseMessageCount != nil || metadata.isGRPCWeb || metadata.statusDetailsBin != nil)
            }
            if let timeout = metadata.timeout {
                InfoRow(label: "Timeout", value: timeout)
                optionalDivider(metadata.requestMessageCount != nil || metadata.responseMessageCount != nil || metadata.isGRPCWeb || metadata.statusDetailsBin != nil)
            }
            if let reqCount = metadata.requestMessageCount {
                InfoRow(label: "Request Messages", value: "\(reqCount)")
                optionalDivider(metadata.responseMessageCount != nil || metadata.isGRPCWeb || metadata.statusDetailsBin != nil)
            }
            if let respCount = metadata.responseMessageCount {
                InfoRow(label: "Response Messages", value: "\(respCount)")
                optionalDivider(metadata.isGRPCWeb || metadata.statusDetailsBin != nil)
            }
            if metadata.isGRPCWeb {
                grpcWebBadgeRow
                optionalDivider(metadata.statusDetailsBin != nil)
            }
            if let detailsBin = metadata.statusDetailsBin {
                statusDetailsBinRow(detailsBin)
            }
        }
    }

    @ViewBuilder
    private var grpcStatusRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if let code = metadata.statusCode {
                        Text("\(code)")
                            .font(.body.monospaced())
                            .fontWeight(.semibold)
                            .foregroundStyle(metadata.isSuccess ? DesignSystem.Colors.success : DesignSystem.Colors.danger)
                    }
                    if let name = metadata.statusName {
                        Text(name)
                            .font(.body)
                            .foregroundStyle(metadata.isSuccess ? DesignSystem.Colors.success : DesignSystem.Colors.danger)
                    }
                    if metadata.statusCode == nil && metadata.statusName == nil {
                        Text("Unknown")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var grpcWebBadgeRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Transport")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("gRPC-Web")
                    .font(.body)
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "globe")
                .foregroundStyle(DesignSystem.Colors.accent)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func statusDetailsBinRow(_ base64Value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Status Details")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(base64Value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func optionalDivider(_ show: Bool) -> some View {
        if show {
            Divider()
        }
    }
}

#Preview {
    var meta = GRPCMetadata()
    meta.statusCode = 0
    meta.statusMessage = nil
    meta.encoding = "gzip"
    meta.acceptEncoding = "gzip, identity"
    meta.timeout = "5S"
    meta.requestMessageCount = 1
    meta.responseMessageCount = 3
    meta.isGRPCWeb = true
    meta.statusDetailsBin = "CAESCmJhZCByZXF1ZXN0"

    return ScrollView {
        GRPCMetadataSection(metadata: meta)
            .padding()
    }
}
