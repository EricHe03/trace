//
//  ThresholdStepper.swift
//  TraceUI
//
//  Created by Justin on 2026/01/24.
//

import SwiftUI

public struct ThresholdStepper: View {
    public let title: String
    @Binding public var value: Int
    public let range: ClosedRange<Int>
    public let step: Int

    public init(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
    }

    public var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(DesignSystem.formattedBytes(value))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

