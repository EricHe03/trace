import SwiftUI

public extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, _ in
                action()
            }
        } else {
            onChange(of: value) { _ in
                action()
            }
        }
    }

    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (_ newValue: V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            onChange(of: value) { newValue in
                action(newValue)
            }
        }
    }
}

