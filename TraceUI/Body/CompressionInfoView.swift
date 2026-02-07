//
//  CompressionInfoView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore

/// Presents compression statistics for body content.
public struct CompressionInfoView: View {
    public let compressionInfo: CompressionInfo

    public init(compressionInfo: CompressionInfo) {
        self.compressionInfo = compressionInfo
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Image(systemName: compressionInfo.decompressionSuccess ? "archivebox.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(compressionInfo.decompressionSuccess ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                Text("Compression")
                    .font(.headline)
                Spacer()
                algorithmBadge
            }

            if compressionInfo.decompressionSuccess {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("Compressed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(DesignSystem.formattedBytes(compressionInfo.compressedSize))
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                        }

                        Spacer()

                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)

                        Spacer()

                        VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                            Text("Decompressed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(DesignSystem.formattedBytes(compressionInfo.decompressedSize))
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                        }
                    }

                    Divider()

                    HStack {
                        Label("Compression Ratio", systemImage: "percent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1fx", 1.0 / compressionInfo.ratio))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DesignSystem.Colors.success)
                    }

                    HStack {
                        Label("Space Saved", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", compressionInfo.savingsPercentage))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DesignSystem.Colors.success)
                    }

                    if let decompressionTime = compressionInfo.decompressionTime {
                        HStack {
                            Label("Decompression Time", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(DesignSystem.formattedDuration(decompressionTime))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DesignSystem.Colors.warning)
                        Text("Decompression Failed")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.warning)
                    }

                    Text("The body data could not be decompressed. Displaying raw compressed data.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.warning.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))
            }
        }
        .padding()
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg))
        .shadow(
            color: DesignSystem.Shadow.sm.color,
            radius: DesignSystem.Shadow.sm.radius,
            x: DesignSystem.Shadow.sm.x,
            y: DesignSystem.Shadow.sm.y
        )
    }

    @ViewBuilder
    private var algorithmBadge: some View {
        // Rule: Split comma-separated algorithms into individual badges.
        let algorithms = compressionInfo.algorithm.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(algorithms, id: \.self) { algorithm in
                Text(algorithm.uppercased())
                    .font(DesignSystem.Typography.monospacedCaption2Font)
                    .fontWeight(.bold)
                    .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                    .padding(.vertical, DesignSystem.Badge.verticalPadding)
                    .frame(minHeight: DesignSystem.Accessibility.absoluteMinimumTapTarget)
                    .background(algorithmColor(for: algorithm))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius, style: .continuous))
            }
        }
    }

    private func algorithmColor(for algorithm: String) -> Color {
        switch algorithm.lowercased() {
        case "gzip", "x-gzip":
            DesignSystem.Colors.accent
        case "br", "brotli":
            DesignSystem.Colors.accentAlt
        case "deflate":
            DesignSystem.Colors.info
        default:
            DesignSystem.Colors.muted
        }
    }
}
