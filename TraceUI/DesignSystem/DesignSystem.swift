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
        static let verticalPadding: CGFloat = 10
        static let cornerRadius: CGFloat = CornerRadius.md
        public static let bottomPadding: CGFloat = 20
        static let displayDuration: TimeInterval = 2.0
        static let maxWidthPercentage: CGFloat = 0.8
        static let lineLimit: Int = 2
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
            UIAccessibility.isReduceMotionEnabled ? .linear(duration: 0) : .spring(response: 0.3, dampingFraction: 0.95)
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
        public static var preferredStyle: some ListStyle {
            .insetGrouped
        }

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

/// A view modifier that provides unified keyboard dismissal behavior across the app.
/// Keyboards dismiss via:
/// 1. Tapping outside text fields (on the background)
/// 2. Scrolling interactively
/// 3. Natural system events (app switch, lock)
private struct UnifiedKeyboardDismissalModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .background {
                KeyboardDismissalTapRecognizerInstaller(onTap: hideKeyboard)
            }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct KeyboardDismissalTapRecognizerInstaller: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        InstallerView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private final class InstallerView: UIView {
        private let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator.install(on: superview)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let onTap: () -> Void
        private var recognizer: UITapGestureRecognizer?
        private weak var installedOn: UIView?

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap() {
            onTap()
        }

        func install(on view: UIView?) {
            guard let view else { return }
            guard installedOn !== view else { return }

            uninstall()

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self

            view.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
            installedOn = view
        }

        func uninstall() {
            if let recognizer, let installedOn {
                installedOn.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedOn = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let touchedView = touch.view else { return true }

            var current: UIView? = touchedView
            while let view = current {
                if view is UITextField || view is UITextView {
                    return false
                }
                current = view.superview
            }

            return true
        }
    }
}

// MARK: - View Modifiers

public extension View {
    /// Applies unified keyboard dismissal behavior.
    /// Use this on views containing TextField or TextEditor.
    /// The keyboard will dismiss when:
    /// - User taps outside the text field
    /// - User scrolls the view
    /// - System events (app switch, lock)
    func dismissKeyboardOnTapAndScroll() -> some View {
        modifier(UnifiedKeyboardDismissalModifier())
    }

    /// Dismisses the keyboard programmatically when called.
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
            .frame(
                minWidth: DesignSystem.Accessibility.absoluteMinimumTapTarget,
                minHeight: DesignSystem.Accessibility.absoluteMinimumTapTarget
            )
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
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(DesignSystem.Toast.foregroundColor)
                .multilineTextAlignment(.center)
                .lineLimit(DesignSystem.Toast.lineLimit)
                .frame(width: textWidth, alignment: .center)
                .padding(.horizontal, DesignSystem.Toast.horizontalPadding)
                .padding(.vertical, DesignSystem.Toast.verticalPadding)
                .background(DesignSystem.Toast.backgroundColor.opacity(DesignSystem.Toast.backgroundOpacity))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Toast.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message)
        .accessibilityHint("Dismiss notification")
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var maxWidth: CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        return screenWidth * DesignSystem.Toast.maxWidthPercentage
    }

    private var textWidth: CGFloat {
        let textPadding = DesignSystem.Toast.horizontalPadding * 2
        let availableTextWidth = max(maxWidth - textPadding, 1)
        let toastFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let measuredTextWidth = ceil((message as NSString).size(withAttributes: [.font: toastFont]).width)

        return min(measuredTextWidth, availableTextWidth)
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
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, bottomPadding)
                    .animation(DesignSystem.Accessibility.springAnimation, value: message)
                    .onAppear {
                        scheduleAutoDismiss()
                    }
                    .onChangeCompat(of: message) {
                        scheduleAutoDismiss()
                    }
                    .onDisappear {
                        dismissTask?.cancel()
                    }
            }
        }
        .animation(DesignSystem.Accessibility.springAnimation, value: message)
    }

    private func dismiss() {
        withAnimation(DesignSystem.Accessibility.springAnimation) {
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
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

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
        // Use a deterministic formatter instead of `ByteCountFormatter` to avoid
        // OS-version/locale wording differences (e.g. "Zero KB" vs "0 B").
        let value = max(0, bytes)
        if value < 1024 {
            return "\(value) B"
        }

        let kb = Double(value) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", locale: posixLocale, arguments: [kb])
        }

        let mb = kb / 1024.0
        if mb < 1024 {
            return String(format: "%.1f MB", locale: posixLocale, arguments: [mb])
        }

        let gb = mb / 1024.0
        if gb < 1024 {
            return String(format: "%.1f GB", locale: posixLocale, arguments: [gb])
        }

        let tb = gb / 1024.0
        return String(format: "%.1f TB", locale: posixLocale, arguments: [tb])
    }
}
