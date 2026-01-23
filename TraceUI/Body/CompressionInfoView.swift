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
                    .foregroundStyle(compressionInfo.decompressionSuccess ? .green : .orange)
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
                            Text(formatBytes(compressionInfo.compressedSize))
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
                            Text(formatBytes(compressionInfo.decompressedSize))
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
                            .foregroundStyle(.green)
                    }

                    HStack {
                        Label("Space Saved", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", compressionInfo.savingsPercentage))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.green)
                    }

                    if let decompressionTime = compressionInfo.decompressionTime {
                        HStack {
                            Label("Decompression Time", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatDuration(decompressionTime))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Decompression Failed")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                    }

                    Text("The body data could not be decompressed. Displaying raw compressed data.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    @ViewBuilder
    private var algorithmBadge: some View {
        // Rule: Split comma-separated algorithms into individual badges.
        let algorithms = compressionInfo.algorithm.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(algorithms, id: \.self) { algorithm in
                Text(algorithm.uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.bold)
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(algorithmColor(for: algorithm))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func algorithmColor(for algorithm: String) -> Color {
        switch algorithm.lowercased() {
        case "gzip", "x-gzip":
            .blue
        case "br", "brotli":
            .purple
        case "deflate":
            .indigo
        default:
            .gray
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            String(format: "%.2f μs", duration * 1_000_000)
        } else if duration < 1 {
            String(format: "%.2f ms", duration * 1000)
        } else {
            String(format: "%.3f s", duration)
        }
    }
}
