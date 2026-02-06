//
//  SectionCard.swift
//  TraceUI
//
//  Created by Justin on 2026/02/06.
//

import SwiftUI

/// Presents a consistent card container for section content.
public struct SectionCard<Content: View>: View {
    public let title: String
    public var systemImage: String?
    @ViewBuilder public let content: Content

    public init(
        title: String,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
            .shadow(
                color: DesignSystem.Shadow.sm.color,
                radius: DesignSystem.Shadow.sm.radius,
                x: DesignSystem.Shadow.sm.x,
                y: DesignSystem.Shadow.sm.y
            )
        }
    }
}

