//
//  Components.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI

// MARK: - Filter Chip

/// Represents a filter chip for list scoping with an optional count badge.
/// - Important: The badge renders only when `count > 0` to avoid visual noise.
public struct FilterChip: View {
    public let title: String
    public let icon: String?
    public let isSelected: Bool
    public let count: Int
    public let selectedColor: Color
    public let action: () -> Void

    public init(
        title: String,
        icon: String? = nil,
        isSelected: Bool,
        count: Int = 0,
        selectedColor: Color = DesignSystem.Colors.accent,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.count = count
        self.selectedColor = selectedColor
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                }

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if count != 0 {
                    Text("\(count)")
                        .font(.caption)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(
                            isSelected
                                ? DesignSystem.Colors.surface.opacity(0.2)
                                : DesignSystem.Colors.surface
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(isSelected ? selectedColor : DesignSystem.Colors.surfaceMuted)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.xl))
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.xl))
        }
        .accessibilityLabel("\(title)\(count == 0 ? "" : ", \(count) items")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Info Row

/// Represents a label-value row with selectable value text for copy-friendly metadata.
public struct InfoRow: View {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Section Header

/// Represents an uppercased, lightweight header for grouping related fields.
public struct SectionHeader: View {
    public let title: String

    public var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Stat Item

/// Represents a compact statistic for dashboards and summary views.
public struct StatItem: View {
    public let title: String
    public let value: String
    public let color: Color

    public init(title: String, value: String, color: Color = .primary) {
        self.title = title
        self.value = value
        self.color = color
    }

    public var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Stat Card

/// Represents a card-style statistic with icon and value emphasis.
public struct StatCard: View {
    public let title: String
    public let value: String
    public let icon: String
    public let color: Color

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)

                Spacer()
            }

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Empty State View

/// Represents an empty-state block with an optional primary action.
/// - Important: The action button renders only when both `action` and `actionLabel` are provided.
public struct EmptyStateView: View {
    public let icon: String
    public let title: String
    public let description: String
    public var action: (() -> Void)?
    public var actionLabel: String?

    public init(icon: String, title: String, description: String, action: (() -> Void)? = nil, actionLabel: String? = nil) {
        self.icon = icon
        self.title = title
        self.description = description
        self.action = action
        self.actionLabel = actionLabel
    }

    public var body: some View {
        VStack(spacing: DesignSystem.EmptyState.spacing) {
            Image(systemName: icon)
                .font(.system(size: DesignSystem.EmptyState.iconSize))
                .foregroundStyle(.secondary)

            Text(title)
                .font(DesignSystem.EmptyState.titleFont)
                .fontWeight(DesignSystem.EmptyState.titleWeight)

            Text(description)
                .font(DesignSystem.EmptyState.descriptionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Rule: Render the action only when both the handler and label are provided.
            if let action, let actionLabel {
                Button {
                    action()
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "plus")
                            .imageScale(.medium)
                        Text(actionLabel)
                    }
                    .font(.headline)
                }
                .primaryActionButton(size: .regular)
                .padding(.top, DesignSystem.Spacing.sm)
                .accessibilityLabel(actionLabel)
                .accessibilityHint("Double tap to \(actionLabel.lowercased())")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.EmptyState.verticalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(description)")
    }
}

// MARK: - Quick Actions Bar

/// Represents a row of quick actions for request workflows.
/// - Important: Replay is disabled while `isLoading` to prevent concurrent replays.
public struct QuickActionsBar: View {
    public let onReplay: () -> Void
    public let onCopyURL: () -> Void
    public let onCopyCURL: () -> Void
    public let onShare: () -> Void
    public var isLoading: Bool = false

    public init(
        onReplay: @escaping () -> Void,
        onCopyURL: @escaping () -> Void,
        onCopyCURL: @escaping () -> Void,
        onShare: @escaping () -> Void,
        isLoading: Bool = false
    ) {
        self.onReplay = onReplay
        self.onCopyURL = onCopyURL
        self.onCopyCURL = onCopyCURL
        self.onShare = onShare
        self.isLoading = isLoading
    }

    public var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            QuickActionButton(
                icon: isLoading ? "hourglass" : "arrow.clockwise",
                title: "Replay",
                color: DesignSystem.Colors.accent,
                action: onReplay
            )
            .disabled(isLoading)

            QuickActionButton(
                icon: "doc.on.doc",
                title: "Copy URL",
                color: DesignSystem.Colors.success,
                action: onCopyURL
            )

            QuickActionButton(
                icon: "terminal",
                title: "cURL",
                color: DesignSystem.Colors.warning,
                action: onCopyCURL
            )

            QuickActionButton(
                icon: "square.and.arrow.up",
                title: "Share",
                color: DesignSystem.Colors.accentAlt,
                action: onShare
            )
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
    }
}

private struct QuickActionButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
                    .frame(height: 20)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: max(60, DesignSystem.Accessibility.minimumTapTarget))
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(DesignSystem.Colors.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Double tap to \(title.lowercased())")
    }
}

// MARK: - Bottom Action Bar

/// Represents the primary capture controls anchored to the bottom of the screen.
public struct BottomActionBar: View {
    public let isCapturing: Bool
    public let onToggleCapture: () -> Void
    public let onNewRequest: () -> Void

    public init(isCapturing: Bool, onToggleCapture: @escaping () -> Void, onNewRequest: @escaping () -> Void) {
        self.isCapturing = isCapturing
        self.onToggleCapture = onToggleCapture
        self.onNewRequest = onNewRequest
    }

    public var body: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            Button(action: onToggleCapture) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(isCapturing ? DesignSystem.Colors.success : DesignSystem.Colors.danger)
                        .frame(width: 8, height: 8)

                    Text(isCapturing ? "Capturing" : "Stopped")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Image(systemName: isCapturing ? "stop.fill" : "play.fill")
                        .font(.caption)
                }
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.md)
                .frame(minHeight: DesignSystem.Accessibility.minimumTapTarget)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isCapturing ? DesignSystem.Colors.success.opacity(0.3) : DesignSystem.Colors.danger.opacity(0.3), lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(isCapturing ? "Stop capturing" : "Start capturing")
            .accessibilityHint("Double tap to \(isCapturing ? "stop" : "start") network capture")

            Spacer()

            Button(action: onNewRequest) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "plus")
                        .font(.headline)
                    Text("New Request")
                        .font(.headline)
                }
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.vertical, DesignSystem.Spacing.md)
                .frame(minHeight: DesignSystem.Accessibility.minimumTapTarget)
                .background(DesignSystem.Colors.accent)
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .contentShape(Capsule())
                .shadow(
                    color: DesignSystem.Colors.accent.opacity(0.3),
                    radius: DesignSystem.Shadow.lg.radius,
                    x: DesignSystem.Shadow.lg.x,
                    y: DesignSystem.Shadow.lg.y
                )
            }
            .accessibilityLabel("New Request")
            .accessibilityHint("Double tap to create a new network request")
        }
        .padding(.bottom, DesignSystem.Spacing.sm)
    }
}

// MARK: - Previews

#Preview("FilterChip") {
    HStack {
        FilterChip(title: "All", isSelected: true, count: 10) {}
        FilterChip(title: "Active", isSelected: false, count: 5) {}
    }
}

#Preview("InfoRow") {
    VStack {
        InfoRow(label: "Status", value: "Active")
        InfoRow(label: "Duration", value: "2.5 seconds")
    }
    .padding()
}
