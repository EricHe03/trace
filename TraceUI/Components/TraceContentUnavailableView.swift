//
//  TraceContentUnavailableView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/19.
//

import SwiftUI

/// A small compatibility wrapper around SwiftUI's `ContentUnavailableView` (iOS 17+).
///
/// On iOS 16, this renders a lightweight empty state using standard SwiftUI views.
public struct TraceContentUnavailableView: View {
    private let title: String
    private let systemImage: String
    private let description: Text?

    public init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    public var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: description)
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
            }
            .padding()
            .frame(maxWidth: 420)
        }
    }
}
