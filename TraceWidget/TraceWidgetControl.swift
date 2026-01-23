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

/// Provides a Control Center widget for quick network capture toggling.
@available(iOS 18.0, *)
struct TraceWidgetControl: ControlWidget {
    static let kind: String = "Justin.Trace.TraceWidgetControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleCaptureIntent()) {
                Label {
                    Text("Capture")
                } icon: {
                    Image(systemName: "network")
                }
            }
        }
        .displayName("Network Capture")
        .description("Quickly toggle network traffic capture on or off.")
    }
}

/// Toggles network traffic capture on or off.
///
/// This intent opens the app and records a toggle action for the capture state.
struct ToggleCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Network Capture"
    static let description = IntentDescription("Start or stop network traffic capture")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        recordWidgetAction(.toggleCapture)
        return .result()
    }
}
