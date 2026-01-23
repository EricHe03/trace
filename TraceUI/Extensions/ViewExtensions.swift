//
//  ViewExtensions.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI

public extension View {
    /// Applies a transformation to a view when the condition is true.
    /// - Parameters:
    ///   - condition: The condition that controls the transformation.
    ///   - transform: The transformation to apply when the condition is true.
    /// - Returns: The transformed view when the condition is true; otherwise, the original view.
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Applies a pulsing SF Symbol effect on iOS 17+, otherwise no-op.
    @ViewBuilder
    func tracePulseSymbolEffectIfAvailable(speed: Double = 0.5) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.pulse, options: .repeating.speed(speed))
        } else {
            self
        }
    }

    /// Applies a bouncing SF Symbol effect on iOS 18+, otherwise no-op.
    @ViewBuilder
    func traceBounceSymbolEffectIfAvailable() -> some View {
        if #available(iOS 18.0, *) {
            symbolEffect(.bounce, options: .nonRepeating)
        } else {
            self
        }
    }
}
