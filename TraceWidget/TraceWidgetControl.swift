//
//  TraceWidgetControl.swift
//  TraceWidget
//
//  Created by Justin on 2026/01/10.
//

import AppIntents
import SwiftUI
import TraceCore
import WidgetKit

// MARK: - Control Value Provider

/// Provides the current capture state for the Control Widget.
@available(iOS 18.0, *)
struct CaptureStateProvider: AppIntentControlValueProvider {
    typealias Value = Bool
    typealias Configuration = CaptureControlConfigurationIntent

    func currentValue(configuration: CaptureControlConfigurationIntent) async throws -> Bool {
        let appGroupIdentifier = AppGroupConfiguration.appGroupIdentifier
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return false
        }
        return defaults.bool(forKey: "widget.isCapturing")
    }

    func previewValue(configuration: CaptureControlConfigurationIntent) -> Bool {
        false
    }
}

// MARK: - Control Widget

/// Provides a Control Center widget for quick network capture toggling.
///
/// This control allows users to toggle network capture directly from Control Center,
/// the Lock Screen, or the Action Button without opening the app.
@available(iOS 18.0, *)
struct TraceWidgetControl: ControlWidget {
    static let kind: String = "Justin.Trace.TraceWidgetControl"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: CaptureStateProvider()
        ) { isCapturing in
            ControlWidgetToggle(
                isOn: isCapturing,
                action: SetCaptureStateIntent()
            ) {
                Label {
                    Text(isCapturing ? "Capturing" : "Capture")
                } icon: {
                    Image(systemName: isCapturing ? "record.circle.fill" : "network")
                }
            }
            .tint(.blue)
        }
        .displayName("Network Capture")
        .description("Toggle network traffic capture on or off.")
        .promptsForUserConfiguration()
    }
}
