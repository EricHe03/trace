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
