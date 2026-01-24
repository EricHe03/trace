//
//  ByteSizeSlider.swift
//  TraceUI
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI

public struct ByteSizeSlider: View {
    public let title: String
    @Binding public var value: Int
    public let range: ClosedRange<Int>
    public let step: Int
    public let showBounds: Bool

    public init(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        showBounds: Bool = true
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.showBounds = showBounds
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(DesignSystem.formattedBytes(value))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )

            if showBounds {
                HStack {
                    Text(DesignSystem.formattedBytes(range.lowerBound))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(DesignSystem.formattedBytes(range.upperBound))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(DesignSystem.formattedBytes(value))")
    }
}
