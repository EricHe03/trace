//
//  DesignSystem.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import UIKit

/// Defines the central design system for UI constants and standards.
public enum DesignSystem {
    // MARK: - Spacing

    /// Defines standard spacing values for consistent layout.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let smPlus: CGFloat = 6
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let lgPlus: CGFloat = 20
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 40

        /// Defines vertical spacing for list rows.
        public static let rowVertical: CGFloat = 4

        /// Defines horizontal padding for sections.
        public static let sectionHorizontal: CGFloat = 16

        /// Defines indentation for tree-like layouts.
        public static let indent: CGFloat = lgPlus
    }

    // MARK: - Corner Radius

    /// Defines standard corner radius values.
    public enum CornerRadius {
        public static let sm: CGFloat = 4
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let pill: CGFloat = 999
    }

    // MARK: - Typography

    /// Defines standard font configurations.
    public enum Typography {
        public static let monospacedFont: Font = .system(.body, design: .monospaced)
        public static let monospacedCaptionFont: Font = .system(.caption, design: .monospaced)
        public static let monospacedCaption2Font: Font = .system(.caption2, design: .monospaced)
    }

    // MARK: - Colors

    /// Defines semantic color mappings.
    public enum Colors {
        private static var isHighContrast: Bool {
            UIAccessibility.isDarkerSystemColorsEnabled ||
                UIAccessibility.isInvertColorsEnabled
        }

        public static var accent: Color {
            isHighContrast ? Color(red: 0.0, green: 0.45, blue: 1.0) : .blue
        }

        public static var accentAlt: Color {
            isHighContrast ? Color(red: 0.6, green: 0.0, blue: 0.8) : .purple
        }

        public static var success: Color {
            isHighContrast ? Color(red: 0.0, green: 0.7, blue: 0.0) : .green
        }

        public static var warning: Color {
            isHighContrast ? Color(red: 1.0, green: 0.6, blue: 0.0) : .orange
        }

        public static var danger: Color {
            isHighContrast ? Color(red: 0.9, green: 0.0, blue: 0.0) : .red
        }

        public static var info: Color {
            isHighContrast ? Color(red: 0.0, green: 0.7, blue: 0.8) : .cyan
        }

        public static var favorite: Color {
            isHighContrast ? Color(red: 1.0, green: 0.8, blue: 0.0) : .yellow
        }

        public static let muted: Color = .gray

        public static let surface: Color = .init(.systemBackground)
        public static let surfaceSubtle: Color = .init(.systemGray5)
        public static let surfaceMuted: Color = .init(.systemGray6)
        public static let groupedBackground: Color = .init(.systemGroupedBackground)
    }

    // MARK: - Effects

    /// Defines standard shadow configurations.
    public enum Shadow {
        public static let sm = (color: Color.black.opacity(0.05), radius: CGFloat(2), x: CGFloat(0), y: CGFloat(1))
        public static let md = (color: Color.black.opacity(0.1), radius: CGFloat(4), x: CGFloat(0), y: CGFloat(2))
        public static let lg = (color: Color.black.opacity(0.15), radius: CGFloat(8), x: CGFloat(0), y: CGFloat(4))
    }

    // MARK: - Toast

    /// Defines standard toast configuration.
    public enum Toast {
        static let backgroundColor: Color = .black
        static let backgroundOpacity: Double = 0.8
        static let foregroundColor: Color = .white
        static let horizontalPadding: CGFloat = Spacing.lg
        static let verticalPadding: CGFloat = Spacing.md
        static let cornerRadius: CGFloat = CornerRadius.md
        public static let bottomPadding: CGFloat = 20
        static let displayDuration: TimeInterval = 2.0
    }

    // MARK: - Badges & Pills

    /// Defines standard badge configuration.
    public enum Badge {
        public static let horizontalPadding: CGFloat = 8
        public static let verticalPadding: CGFloat = 4
        public static let cornerRadius: CGFloat = CornerRadius.sm
        public static let font: Font = .caption
        public static let fontWeight: Font.Weight = .semibold
    }

    // MARK: - Empty States

    /// Defines standard empty state configuration.
    enum EmptyState {
        static let iconSize: CGFloat = 60
        static let spacing: CGFloat = Spacing.lg
        static let titleFont: Font = .title2
        static let titleWeight: Font.Weight = .semibold
        static let descriptionFont: Font = .subheadline
        static let verticalPadding: CGFloat = 40
    }

    // MARK: - Icon Sizes

    /// Defines standard icon sizes that scale with Dynamic Type.
    public enum IconSize {
        public static var hero: CGFloat {
            UIFontMetrics.default.scaledValue(for: 80)
        }

        public static var section: CGFloat {
            UIFontMetrics.default.scaledValue(for: 40)
        }
    }

    // MARK: - Accessibility

    /// Defines accessibility-aware animations and transitions.
    public enum Accessibility {
        /// Returns an animation that respects the Reduce Motion setting.
        public static var preferredAnimation: SwiftUI.Animation {
            UIAccessibility.isReduceMotionEnabled ? .linear(duration: 0) : .easeInOut
        }

        /// Returns a spring animation that respects the Reduce Motion setting.
        public static var springAnimation: SwiftUI.Animation {
            UIAccessibility.isReduceMotionEnabled ? .linear(duration: 0) : .spring(response: 0.3, dampingFraction: 0.7)
        }

        /// Returns a transition that respects the Reduce Motion setting.
        public static func transition(standard: AnyTransition) -> AnyTransition {
            UIAccessibility.isReduceMotionEnabled ? .opacity : standard
        }

        /// Returns whether the user prefers reduced motion.
        public static var isReduceMotionEnabled: Bool {
            UIAccessibility.isReduceMotionEnabled
        }

        /// Returns whether high contrast mode is enabled.
        public static var isHighContrast: Bool {
            UIAccessibility.isDarkerSystemColorsEnabled ||
                UIAccessibility.isInvertColorsEnabled
        }

        /// Defines the minimum tappable size for iOS (44x44 pt).
        public static let minimumTapTarget: CGFloat = 44

        /// Defines the absolute minimum tappable size (28x28 pt).
        public static let absoluteMinimumTapTarget: CGFloat = 28
    }

    // MARK: - Haptics

    /// Defines standard haptic feedback patterns.
    public enum Haptics {
        /// Plays light impact feedback.
        public static func light() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }

        /// Plays medium impact feedback.
        public static func medium() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }

        /// Plays heavy impact feedback.
        public static func heavy() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
        }

        /// Plays success notification feedback.
        public static func success() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }

        /// Plays warning notification feedback.
        public static func warning() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }

        /// Plays error notification feedback.
        public static func error() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }

        /// Plays selection-changed feedback.
        public static func selection() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
        }
    }

    // MARK: - Forms

    /// Defines standard form field configuration.
    public enum Form {
        public static let textEditorMinHeight: CGFloat = 100
        public static let textEditorMinHeightSmall: CGFloat = 100
        public static let textEditorMinHeightMedium: CGFloat = 120
        public static let textEditorMinHeightLarge: CGFloat = 150
        public static let outputMaxHeight: CGFloat = 200
        public static let outputMaxHeightLarge: CGFloat = 300
        public static let textEditorBackground: Color = .init(.systemGray6)
        public static let textEditorPadding: CGFloat = Spacing.sm
        public static let textEditorCornerRadius: CGFloat = CornerRadius.md
    }

    // MARK: - Lists

    /// Defines list style guidelines for common screens.
    /// - .insetGrouped: Primary data lists (Requests, WebSockets, Favorites, Tests)
    /// - .plain: Management/configuration screens with custom styling (Rules, Scripts, Maps, Hosts)
    /// - Form (auto .insetGrouped): Settings and configuration forms
    ///
    /// Defines standard list configuration.
    public enum List {
        public static var preferredStyle: some ListStyle { .insetGrouped }
        public static let rowVerticalPadding: CGFloat = Spacing.rowVertical
        public static let rowInsets = EdgeInsets(
            top: Spacing.sm,
            leading: Spacing.lg,
            bottom: Spacing.sm,
            trailing: Spacing.lg
        )
    }
}

// MARK: - Keyboard Dismissal

/// A view modifier that adds a keyboard toolbar with a Done button for dismissing the keyboard.
private struct KeyboardDismissToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        hideKeyboard()
                    }
                }
            }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - View Modifiers

public extension View {
    /// Adds a keyboard toolbar with a Done button for dismissing the keyboard.
    /// Use this on views containing TextField or TextEditor to allow users to dismiss the keyboard.
    func keyboardDismissToolbar() -> some View {
        modifier(KeyboardDismissToolbarModifier())
    }

    /// Dismisses the keyboard when called.
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Applies standard badge styling.
    func badgeStyle(backgroundColor: Color, foregroundColor: Color = .white) -> some View {
        self
            .font(DesignSystem.Badge.font)
            .fontWeight(DesignSystem.Badge.fontWeight)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, DesignSystem.Badge.horizontalPadding)
            .padding(.vertical, DesignSystem.Badge.verticalPadding)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Badge.cornerRadius))
    }

    /// Applies standard card styling.
    func cardStyle() -> some View {
        self
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
            .shadow(
                color: DesignSystem.Shadow.sm.color,
                radius: DesignSystem.Shadow.sm.radius,
                x: DesignSystem.Shadow.sm.x,
                y: DesignSystem.Shadow.sm.y
            )
    }

    /// Applies standard form text editor styling.
    func formTextEditorStyle() -> some View {
        self
            .padding(DesignSystem.Form.textEditorPadding)
            .background(DesignSystem.Form.textEditorBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Form.textEditorCornerRadius))
    }

    /// Applies the standard toast notification overlay.
    func toast(message: Binding<String?>, bottomPadding: CGFloat = DesignSystem.Toast.bottomPadding) -> some View {
        self.modifier(ToastModifier(message: message, bottomPadding: bottomPadding))
    }

    /// Applies standard primary action button styling.
    /// - Parameters:
    ///   - tint: The button's tint color. Defaults to accent.
    ///   - size: The control size. Defaults to `.large` for prominent CTAs, use `.regular` for inline actions.
    func primaryActionButton(tint: Color = DesignSystem.Colors.accent, size: ControlSize = .large) -> some View {
        self
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(size)
    }
}

// MARK: - Toast View

/// Presents a standard toast notification view.
struct ToastView: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(DesignSystem.Toast.foregroundColor)
                .fixedSize(horizontal: false, vertical: true)

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignSystem.Toast.foregroundColor)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
        }
        .padding(.horizontal, DesignSystem.Toast.horizontalPadding)
        .padding(.vertical, DesignSystem.Toast.verticalPadding)
        .background(DesignSystem.Toast.backgroundColor.opacity(DesignSystem.Toast.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Toast.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Toast.cornerRadius))
        .onTapGesture {
            onDismiss?()
        }
        .padding(.bottom, DesignSystem.Toast.bottomPadding)
    }
}

// MARK: - Toast Modifier

private struct ToastModifier: ViewModifier {
    @Binding var message: String?
    let bottomPadding: CGFloat
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                ToastView(message: message, onDismiss: dismiss)
                    .transition(
                        DesignSystem.Accessibility.transition(
                            standard: AnyTransition.move(edge: Edge.bottom)
                                .combined(with: AnyTransition.opacity)
                        )
                    )
                    .padding(.bottom, bottomPadding)
                    .onAppear {
                        scheduleAutoDismiss()
                    }
                    .onChange(of: message) { _ in
                        scheduleAutoDismiss()
                    }
                    .onDisappear {
                        dismissTask?.cancel()
                    }
            }
        }
    }

    private func dismiss() {
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            message = nil
        }
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        let duration: TimeInterval = UIAccessibility.isVoiceOverRunning ? 6.0 : DesignSystem.Toast.displayDuration
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dismiss()
            }
        }
    }
}

// MARK: - Helper Functions

public extension DesignSystem {
    /// Formats a duration consistently for UI display.
    static func formattedDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.2f s", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }

    /// Formats byte counts consistently for UI display.
    static func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
