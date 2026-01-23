//
//  RequestListRow.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceFeatures

public struct RequestListRow: View {
    public let request: NetworkRequest

    public init(request: NetworkRequest) {
        self.request = request
    }

    private var tagDisplay: (visible: [TagType], overflow: Int) {
        request.getVisibleTags(maxVisible: 3)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(request.method.rawValue)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(methodColor)
                    .cornerRadius(4)
                    .accessibilityLabel("Method: \(request.method.rawValue)")

                Text(request.statusCodeText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(statusColor)
                    .cornerRadius(4)
                    .accessibilityLabel("Status: \(request.statusCodeText)")

                if request.duplicateCount > 1 {
                    DuplicateCounterView(count: request.duplicateCount)
                }

                ForEach(tagDisplay.visible, id: \.self) { tag in
                    RequestTagView(tag: tag)
                }

                if tagDisplay.overflow > 0 {
                    OverflowTagView(count: tagDisplay.overflow, allTags: request.getAllTags())
                }

                if FavoritesManager.shared.isFavorited(requestId: request.id) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.favorite)
                        .accessibilityLabel("Favorited")
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let size = request.responseSize ?? request.requestSize {
                        Text(formatBytes(size))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Size: \(formatBytes(size))")
                    }

                    Text(formatDuration(request.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Duration: \(formatDuration(request.duration))")
                }
            }

            HStack(spacing: 4) {
                Text(request.host)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(request.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("URL: \(request.host)\(request.path)")

            Text(request.timestamp, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var methodColor: Color {
        switch request.method {
        case .get:
            .blue
        case .post:
            .green
        case .put:
            .orange
        case .delete:
            .red
        case .patch:
            .purple
        case .connect:
            .gray
        default:
            .gray
        }
    }

    private var statusColor: Color {
        switch request.statusColor {
        case .success:
            return DesignSystem.Colors.success
        case .redirect:
            return .blue
        case .clientError:
            return DesignSystem.Colors.warning
        case .serverError:
            return DesignSystem.Colors.danger
        case .unknown:
            return .gray
        @unknown default:
            return .gray
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            String(format: "%.0f ms", duration * 1000)
        } else {
            String(format: "%.2f s", duration)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private var accessibilityDescription: String {
        var description = "\(request.method.rawValue) request to \(request.host), status \(request.statusCodeText)"

        // Rationale: Include tag tooltips in the accessibility summary.
        for tag in request.getAllTags() {
            description += ", \(tag.tooltip)"
        }

        if request.duplicateCount > 1 {
            description += ", \(request.duplicateCount) duplicates"
        }

        if FavoritesManager.shared.isFavorited(requestId: request.id) {
            description += ", Favorited"
        }

        return description
    }
}
