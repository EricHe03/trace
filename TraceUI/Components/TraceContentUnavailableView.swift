//
//  TraceContentUnavailableView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/19.
//

import SwiftUI

/// A compatibility wrapper around SwiftUI's `ContentUnavailableView` (iOS 17+).
///
/// Follows Apple's Human Interface Guidelines for empty states:
/// - Clear title explaining what's unavailable
/// - Helpful description with context
/// - Optional primary action button
///
/// On iOS 16, this renders a lightweight empty state using standard SwiftUI views.
public struct TraceContentUnavailableView: View {
    private let title: String
    private let systemImage: String
    private let description: Text?
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        _ title: String,
        systemImage: String,
        description: Text? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actionTitle = nil
        self.action = nil
    }

    public init(
        _ title: String,
        systemImage: String,
        description: Text? = nil,
        actionTitle: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        if #available(iOS 17.0, *) {
            if let actionTitle, let action {
                ContentUnavailableView {
                    Label(title, systemImage: systemImage)
                } description: {
                    description
                } actions: {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(title, systemImage: systemImage, description: description)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let description {
                    description
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                }
            }
            .padding()
            .frame(maxWidth: 420)
        }
    }
}

#Preview("No Data") {
    TraceContentUnavailableView(
        "No Requests Yet",
        systemImage: "network.slash",
        description: Text("Start capturing to see network requests here")
    )
}

#Preview("With Action") {
    TraceContentUnavailableView(
        "No Connections",
        systemImage: "antenna.radiowaves.left.and.right.slash",
        description: Text("Enable capture to start monitoring connections"),
        actionTitle: "Start Capture",
        action: {}
    )
}
