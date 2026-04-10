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

/// Reads the current capture state from the shared App Group storage.
@available(iOS 18.0, *)
struct CaptureStateProvider: AppIntentControlValueProvider {
    typealias Value = Bool
    typealias Configuration = CaptureControlConfigurationIntent

    func currentValue(configuration: CaptureControlConfigurationIntent) async throws -> Bool {
        AppGroupStorage.shared.loadWidgetState().isCapturing
    }

    func previewValue(configuration: CaptureControlConfigurationIntent) -> Bool {
        false
    }
}

// MARK: - Control Widget

/// Control Center, Lock Screen, and Action Button widget for toggling network capture.
///
/// The system applies Liquid Glass automatically in iOS 26.
/// Tint (.blue) drives the Liquid Glass colored variant when active.
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
                    // SF Symbol transitions with .replace effect on state change
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
