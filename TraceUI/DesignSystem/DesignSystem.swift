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
        public static let rowVertical: CGFloat = 8

        /// Defines horizontal padding for sections — matches system `.insetGrouped` insets.
        public static let sectionHorizontal: CGFloat = 20

        /// Defines indentation for tree-like layouts.
        public static let indent: CGFloat = lgPlus
    }

    // MARK: - Corner Radius

    /// Defines standard corner radius values.
    /// Always pair with `RoundedRectangle(cornerRadius:, style: .continuous)` for Apple's
    /// superellipse (squircle) appearance used by native iOS components.
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
        // Monospaced variants — use `.monospacedDigit()` for numeric-only content
        public static let monospacedFont: Font = .system(.body, design: .monospaced)
        public static let monospacedCaptionFont: Font = .system(.caption, design: .monospaced)
        public static let monospacedCaption2Font: Font = .system(.caption2, design: .monospaced)

        // Dynamic Type text styles
        public static let largeTitle: Font = .largeTitle
        public static let title: Font = .title
        public static let title2: Font = .title2
        public static let title3: Font = .title3
        public static let headline: Font = .headline
        public static let subheadline: Font = .subheadline
        public static let body: Font = .body
        public static let callout: Font = .callout
        public static let footnote: Font = .footnote
        public static let caption: Font = .caption
        public static let caption2: Font = .caption2
    }

    // MARK: - Colors

    /// Defines semantic color mappings.
    /// All colors use `Color(UIColor)` system variants for automatic light/dark,
    /// Increased Contrast, and accessibility adaptation — no manual fallbacks needed.
    public enum Colors {
        // Semantic tints
        public static let accent: Color = Color(.systemBlue)
        public static let accentAlt: Color = Color(.systemPurple)
        public static let success: Color = Color(.systemGreen)
        public static let warning: Color = Color(.systemOrange)
        public static let danger: Color = Color(.systemRed)
        public static let info: Color = Color(.systemCyan)
        public static let favorite: Color = Color(.systemYellow)
        public static let muted: Color = Color(.systemGray)

        // Surface hierarchy
        public static let surface: Color = Color(.systemBackground)
        public static let surfaceSubtle: Color = Color(.systemGray5)
        public static let surfaceMuted: Color = Color(.systemGray6)
        public static let groupedBackground: Color = Color(.systemGroupedBackground)
        public static let secondaryGroupedBackground: Color = Color(.secondarySystemGroupedBackground)
        public static let tertiaryGroupedBackground: Color = Color(.tertiarySystemGroupedBackground)

        // Label hierarchy
        public static let label: Color = Color(.label)
        public static let secondaryLabel: Color = Color(.secondaryLabel)
        public static let tertiaryLabel: Color = Color(.tertiaryLabel)
        public static let quaternaryLabel: Color = Color(.quaternaryLabel)
        public static let placeholderText: Color = Color(.placeholderText)

        // Separators
        public static let separator: Color = Color(.separator)
        public static let opaqueSeparator: Color = Color(.opaqueSeparator)
    }

    // MARK: - Effects

    /// Defines standard shadow configurations.
    /// Prefer `Material` backgrounds (`.ultraThinMaterial`, `.regularMaterial`, etc.) over
    /// custom shadows in Liquid Glass / layered surface contexts.
    public enum Shadow {
        public static let sm = (color: Color.black.opacity(0.05), radius: CGFloat(2), x: CGFloat(0), y: CGFloat(1))
        public static let md = (color: Color.black.opacity(0.1), radius: CGFloat(4), x: CGFloat(0), y: CGFloat(2))
        public static let lg = (color: Color.black.opacity(0.15), radius: CGFloat(8), x: CGFloat(0), y: CGFloat(4))
    }

    // MARK: - Toast

    /// Defines standard toast configuration.
    public enum Toast {
        static let horizontalPadding: CGFloat = Spacing.lg
        static let verticalPadding: CGFloat = 10
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
        /// Badges use pill shape to match Apple's native badge appearance.
        public static let cornerRadius: CGFloat = CornerRadius.pill
        public static let font: Font = .caption
        public static let fontWeight: Font.Weight = .semibold
    }

    // MARK: - Empty States

    /// Defines standard empty state configuration.
    /// On iOS 17+ targets, prefer the native `ContentUnavailableView` — its typography
    /// and layout match these tokens exactly and it is automatically localized/accessible.
    public enum EmptyState {
        public static let iconSize: CGFloat = 60
        public static let spacing: CGFloat = Spacing.lg
        public static let titleFont: Font = .title2
        public static let titleWeight: Font.Weight = .semibold
        public static let descriptionFont: Font = .subheadline
        public static let verticalPadding: CGFloat = 40
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
        /// Uses a short cross-fade instead of instant snap, per HIG guidance.
        public static var preferredAnimation: SwiftUI.Animation {
            UIAccessibility.isReduceMotionEnabled ? .linear(duration: 0.15) : .easeInOut
        }

        /// Returns a spring animation that respects the Reduce Motion setting.
        public static var springAnimation: SwiftUI.Animation {
            UIAccessibility.isReduceMotionEnabled ? .linear(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.95)
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

        /// Defines the minimum tappable size for iOS (44×44 pt).
        public static let minimumTapTarget: CGFloat = 44

        /// Defines the absolute minimum tappable size for non-primary interactive elements (28×28 pt).
        public static let absoluteMinimumTapTarget: CGFloat = 28
    }

    // MARK: - Haptics

    /// Defines standard haptic feedback patterns.
    public enum Haptics {
        /// Plays light impact feedback — subtle, for minor UI interactions.
        public static func light() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }

        /// Plays medium impact feedback — standard, for most interactions.
        public static func medium() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }

        /// Plays heavy impact feedback — pronounced, for significant actions.
        public static func heavy() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
        }

        /// Plays rigid impact feedback — sharp, precise, for snapping/locking interactions.
        public static func rigid() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred()
        }

        /// Plays soft impact feedback — gentle, for floating or elastic interactions.
        public static func soft() {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .soft)
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
        /// Uses `secondarySystemGroupedBackground` for correct vibrancy inside grouped forms.
        public static let textEditorBackground: Color = Color(.secondarySystemGroupedBackground)
        public static let textEditorPadding: CGFloat = Spacing.sm
        public static let textEditorCornerRadius: CGFloat = CornerRadius.md
    }

    // MARK: - Lists

    /// Defines list style guidelines for common screens.
    /// - `.insetGrouped`: Primary data lists (Requests, WebSockets, Favorites, Tests)
    /// - `.plain`: Management/configuration screens with custom styling (Rules, Scripts, Maps, Hosts)
    /// - `Form` (auto `.insetGrouped`): Settings and configuration forms
    public enum List {
        public static var preferredStyle: some ListStyle {
            .insetGrouped
        }

        public static let rowVerticalPadding: CGFloat = Spacing.rowVertical
        /// Leading/trailing 20 pt matches the system `.insetGrouped` list insets.
        public static let rowInsets = EdgeInsets(
            top: Spacing.sm,
            leading: Spacing.lgPlus,
            bottom: Spacing.sm,
            trailing: Spacing.lgPlus
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

    /// Applies standard badge styling with pill shape matching native iOS badges.
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
            .clipShape(Capsule())
    }

    /// Applies standard card styling with continuous corner radius.
    func cardStyle() -> some View {
        self
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md, style: .continuous))
            .shadow(
                color: DesignSystem.Shadow.sm.color,
                radius: DesignSystem.Shadow.sm.radius,
                x: DesignSystem.Shadow.sm.x,
                y: DesignSystem.Shadow.sm.y
            )
    }

    /// Applies standard form text editor styling with continuous corner radius.
    func formTextEditorStyle() -> some View {
        self
            .padding(DesignSystem.Form.textEditorPadding)
            .background(DesignSystem.Form.textEditorBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Form.textEditorCornerRadius, style: .continuous))
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

/// Presents a standard toast notification view using a system material background
/// for automatic light/dark mode and vibrancy adaptation.
struct ToastView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(DesignSystem.Toast.lineLimit)
                .frame(width: textWidth, alignment: .center)
                .padding(.horizontal, DesignSystem.Toast.horizontalPadding)
                .padding(.vertical, DesignSystem.Toast.verticalPadding)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(DesignSystem.Colors.separator, lineWidth: 0.5))
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
                    .padding(.bottom, effectiveBottomPadding)
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

    /// Computes bottom padding that clears the home indicator safe area.
    private var effectiveBottomPadding: CGFloat {
        let safeAreaBottom = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
        return max(bottomPadding, safeAreaBottom + 8)
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
        let normalized = max(0, duration)
        if normalized < 1 {
            let milliseconds = normalized * 1000
            if normalized > 0, milliseconds < 1 {
                return "<1 ms"
            }
            return String(format: "%.0f ms", milliseconds)
        } else if normalized < 60 {
            return String(format: "%.2f s", normalized)
        } else {
            let minutes = Int(normalized / 60)
            let seconds = Int(normalized.truncatingRemainder(dividingBy: 60))
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
