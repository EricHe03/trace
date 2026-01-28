//
//  AppIntent.swift
//  TraceWidget
//
//  Created by Justin on 2026/01/10.
//

import AppIntents
import TraceCore
import WidgetKit

// MARK: - Widget Configuration Intent

/// Provides configuration options for widget display and behavior.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Trace Widget Configuration" }
    static var description: IntentDescription { "Configure your Trace network monitoring widget." }

    @Parameter(title: "Show Request Details", default: true)
    var showRequestDetails: Bool

    @Parameter(title: "Show Data Transfer", default: true)
    var showDataTransfer: Bool

    @Parameter(title: "Maximum Requests to Display", default: 5)
    var maxRequestsToShow: Int

    @available(iOS 16.0, iOSApplicationExtension 16.0, *)
    func perform() async throws -> some IntentResult {
        .result()
    }
}

// MARK: - Quick Action Intents

/// Starts network traffic capture.
///
/// Opens the app and records a start capture action.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
struct StartCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Network Capture"
    static let description = IntentDescription("Start capturing network traffic")
    static let openAppWhenRun: Bool = true

    @MainActor
    @available(iOS 16.0, iOSApplicationExtension 16.0, *)
    func perform() async throws -> some IntentResult {
        recordWidgetAction(.startCapture)
        return .result()
    }
}

/// Stops network traffic capture.
///
/// Opens the app and records a stop capture action.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
struct StopCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Network Capture"
    static let description = IntentDescription("Stop capturing network traffic")
    static let openAppWhenRun: Bool = true

    @MainActor
    @available(iOS 16.0, iOSApplicationExtension 16.0, *)
    func perform() async throws -> some IntentResult {
        recordWidgetAction(.stopCapture)
        return .result()
    }
}

/// Clears all captured network requests.
///
/// Opens the app and records a clear requests action.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
struct ClearRequestsIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Requests"
    static let description = IntentDescription("Clear all captured network requests")
    static let openAppWhenRun: Bool = true

    @MainActor
    @available(iOS 16.0, iOSApplicationExtension 16.0, *)
    func perform() async throws -> some IntentResult {
        recordWidgetAction(.clearRequests)
        return .result()
    }
}

/// Toggles network traffic capture on or off.
///
/// Opens the app and records a toggle action for the capture state.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
struct ToggleCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Network Capture"
    static let description = IntentDescription("Start or stop network traffic capture")
    static let openAppWhenRun: Bool = true

    @MainActor
    @available(iOS 16.0, iOSApplicationExtension 16.0, *)
    func perform() async throws -> some IntentResult {
        recordWidgetAction(.toggleCapture)
        return .result()
    }
}

/// Configuration intent for the Control Center widget.
@available(iOS 18.0, iOSApplicationExtension 18.0, *)
struct CaptureControlConfigurationIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Capture Control Configuration"
    static let description = IntentDescription("Configure the Trace capture control widget")
}

/// Sets network traffic capture on or off.
///
/// Used by Control Center to drive a toggle-style control.
@available(iOS 18.0, iOSApplicationExtension 18.0, *)
struct SetCaptureStateIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Network Capture"
    static let description = IntentDescription("Set network traffic capture state")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Capture")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        if value {
            recordWidgetAction(.startCapture)
        } else {
            recordWidgetAction(.stopCapture)
        }
        return .result()
    }
}

/// Opens the Trace app to a specific view.
///
/// Optionally navigates directly to a target view within the app.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
struct OpenTraceAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Trace"
    static let description = IntentDescription("Open the Trace app")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "View")
    var targetView: TraceAppView?

    @MainActor
    @available(iOS 16.0, iOSApplicationExtension 16.0, *)
    func perform() async throws -> some IntentResult {
        recordWidgetAction(.openView, view: targetView)
        return .result()
    }
}

/// Defines available Trace app views for deep linking.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
enum TraceAppView: String, AppEnum {
    case capture
    case favorites
    case settings
    case tools

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "View")
    static let caseDisplayRepresentations: [TraceAppView: DisplayRepresentation] = [
        .capture: "Capture",
        .favorites: "Favorites",
        .settings: "Settings",
        .tools: "Tools"
    ]
}

// MARK: - App Shortcuts Provider

/// Registers app intents with Siri and the Shortcuts app for system-wide discoverability.
@available(iOS 16.0, iOSApplicationExtension 16.0, *)
struct TraceAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCaptureIntent(),
            phrases: [
                "Start capture in \(.applicationName)",
                "Begin network capture in \(.applicationName)",
                "Start \(.applicationName) capture"
            ],
            shortTitle: "Start Capture",
            systemImageName: "play.circle"
        )

        AppShortcut(
            intent: StopCaptureIntent(),
            phrases: [
                "Stop capture in \(.applicationName)",
                "End network capture in \(.applicationName)",
                "Stop \(.applicationName) capture"
            ],
            shortTitle: "Stop Capture",
            systemImageName: "stop.circle"
        )

        AppShortcut(
            intent: ToggleCaptureIntent(),
            phrases: [
                "Toggle capture in \(.applicationName)",
                "Toggle network capture in \(.applicationName)"
            ],
            shortTitle: "Toggle Capture",
            systemImageName: "network"
        )

        AppShortcut(
            intent: ClearRequestsIntent(),
            phrases: [
                "Clear requests in \(.applicationName)",
                "Clear captured requests in \(.applicationName)"
            ],
            shortTitle: "Clear Requests",
            systemImageName: "trash"
        )

        AppShortcut(
            intent: OpenTraceAppIntent(),
            phrases: [
                "Open \(.applicationName)"
            ],
            shortTitle: "Open Trace",
            systemImageName: "app"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .blue
    }
}
