//
//  RequestTagView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore

public struct RequestTagView: View {
    public let tag: TagType

    public var body: some View {
        Text(tag.displayText)
            .font(DesignSystem.Badge.font)
            .fontWeight(DesignSystem.Badge.fontWeight)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tag.color)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius, style: .continuous))
            .accessibilityLabel(tag.tooltip)
    }
}

public struct DuplicateCounterView: View {
    public let count: Int

    public var body: some View {
        Text("×\(count)")
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .frame(
                minWidth: DesignSystem.Accessibility.absoluteMinimumTapTarget,
                minHeight: DesignSystem.Accessibility.absoluteMinimumTapTarget
            )
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm, style: .continuous))
            .accessibilityLabel("\(count) duplicate requests")
    }
}

public struct OverflowTagView: View {
    public let count: Int
    public let allTags: [TagType]
    @State private var showAllTags = false

    public var body: some View {
        Button {
            showAllTags = true
        } label: {
            Text("+\(count)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
                .padding(.vertical, DesignSystem.Badge.verticalPadding)
                .frame(
                    minWidth: DesignSystem.Accessibility.absoluteMinimumTapTarget,
                    minHeight: DesignSystem.Accessibility.absoluteMinimumTapTarget
                )
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) more tags")
        .popover(isPresented: $showAllTags) {
            AllTagsPopover(tags: allTags)
        }
    }
}

public struct AllTagsPopover: View {
    public let tags: [TagType]

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("All Tags")
                .font(.headline)
                .padding(.bottom, DesignSystem.Spacing.xs)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 80), spacing: DesignSystem.Spacing.sm)
            ], spacing: DesignSystem.Spacing.sm) {
                ForEach(tags, id: \.self) { tag in
                    RequestTagView(tag: tag)
                }
            }
        }
        .padding()
        .frame(maxWidth: 300)
    }
}

#Preview("RequestTagView") {
    HStack {
        RequestTagView(tag: .h2)
        RequestTagView(tag: .failed)
    }
    .padding()
}

#Preview("DuplicateCounterView") {
    DuplicateCounterView(count: 5)
        .padding()
}
