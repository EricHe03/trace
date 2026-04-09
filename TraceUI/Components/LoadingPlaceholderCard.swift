//
//  LoadingPlaceholderCard.swift
//  TraceUI
//
//  Created by Justin on 2026/02/06.
//

import SwiftUI

/// Presents a lightweight loading placeholder in the shared card style.
public struct LoadingPlaceholderCard: View {
    public let title: String
    public var headerSystemImage: String?
    public var message: String

    public init(title: String, headerSystemImage: String? = "hourglass", message: String) {
        self.title = title
        self.headerSystemImage = headerSystemImage
        self.message = message
    }

    public var body: some View {
        SectionCard(title: title, systemImage: headerSystemImage) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(minHeight: DesignSystem.Accessibility.minimumTapTarget)
        }
    }
}

#Preview {
    ScrollView {
        LoadingPlaceholderCard(
            title: "SSE Events",
            message: "Loading captured stream events..."
        )
        .padding()
    }
}
