//
//  RequestListRow.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore

public struct RequestListRow: View {
    public let request: NetworkRequest
    public let isFavorited: Bool

    public init(request: NetworkRequest, isFavorited: Bool = false) {
        self.request = request
        self.isFavorited = isFavorited
    }

    private var tagDisplay: (visible: [TagType], overflow: Int) {
        request.getVisibleTags(maxVisible: 3)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.smPlus) {
                badge(
                    text: request.method.rawValue,
                    background: methodColor,
                    accessibilityLabel: "Method: \(request.method.rawValue)"
                )

                badge(
                    text: request.statusCodeText,
                    background: statusColor,
                    accessibilityLabel: "Status: \(request.statusCodeText)"
                )

                if request.duplicateCount > 1 {
                    DuplicateCounterView(count: request.duplicateCount)
                }

                ForEach(tagDisplay.visible, id: \.self) { tag in
                    RequestTagView(tag: tag)
                }

                if tagDisplay.overflow > 0 {
                    OverflowTagView(count: tagDisplay.overflow, allTags: request.getAllTags())
                }

                if isFavorited {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.favorite)
                        .accessibilityLabel("Favorited")
                }

                Spacer()

                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xxs) {
                    if let size = request.responseSize ?? request.requestSize {
                        let formattedBytes = DesignSystem.formattedBytes(size)
                        Text(formattedBytes)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Size: \(formattedBytes)")
                    }

                    let formattedDuration = DesignSystem.formattedDuration(request.duration)
                    Text(formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Duration: \(formattedDuration)")
                }
            }

            HStack(spacing: DesignSystem.Spacing.xs) {
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
        .padding(.vertical, DesignSystem.Spacing.rowVertical)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var methodColor: Color {
        DesignSystem.Colors.methodColor(for: request.method)
    }

    private var statusColor: Color {
        DesignSystem.Colors.statusColor(for: request.statusColor)
    }

    private func badge(text: String, background: Color, accessibilityLabel: String) -> some View {
        Text(text)
            .font(DesignSystem.Badge.font)
            .fontWeight(DesignSystem.Badge.fontWeight)
            .foregroundStyle(.white)
            .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
            .padding(.vertical, DesignSystem.Badge.verticalPadding)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius, style: .continuous))
            .accessibilityLabel(accessibilityLabel)
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

        if isFavorited {
            description += ", Favorited"
        }

        return description
    }
}
