//
//  QuickActionHandler.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import os
import SwiftUI
import TraceCore
import TraceFeatures
import TraceSecurity
import UIKit

/// Handles Home Screen Quick Action interactions.
class QuickActionHandler {
    static let shared = QuickActionHandler()

    private init() {}

    /// Processes a Quick Action shortcut item.
    /// - Parameters:
    ///   - shortcutItem: The Quick Action to handle.
    ///   - viewModel: The capture view model to update.
    /// - Returns: `true` when the action was handled.
    @MainActor
    func handleShortcutItem(
        _ shortcutItem: UIApplicationShortcutItem,
        viewModel: CaptureViewModel
    ) async -> Bool {
        switch shortcutItem.type {
        case "com.trace.startCapture":
            await startCapture()
            return true

        case "com.trace.stopCapture":
            stopCapture()
            return true

        case "com.trace.viewLastSession":
            viewLastSession(viewModel: viewModel)
            return true

        case "com.trace.exportData":
            await exportData(viewModel: viewModel)
            return true

        default:
            return false
        }
    }

    // MARK: - Action Handlers

    @MainActor
    private func startCapture() async {
        let vpnManager = VPNManager.shared

        guard !vpnManager.isConnected else {
            FeatureLog.vpn.info("event=vpn.start outcome=skipped reason=already_connected source=quick_action")
            return
        }

        do {
            try await vpnManager.start()
            FeatureLog.vpn.info("event=vpn.start outcome=success source=quick_action")
        } catch {
            FeatureLog.vpn.error(
                "event=vpn.start outcome=failure source=quick_action error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func stopCapture() {
        let vpnManager = VPNManager.shared

        guard vpnManager.isConnected else {
            FeatureLog.vpn.info("event=vpn.stop outcome=skipped reason=already_disconnected source=quick_action")
            return
        }

        vpnManager.stop()
        FeatureLog.vpn.info("event=vpn.stop outcome=success source=quick_action")
    }

    private func viewLastSession(viewModel: CaptureViewModel) {
        guard let lastSession = viewModel.sessions.first else {
            CoreLog.lifecycle.warning("event=app.quick_action outcome=skipped action=view_last_session reason=no_sessions")
            return
        }

        viewModel.selectedSession = lastSession
        CoreLog.lifecycle.info(
            "event=app.quick_action outcome=success action=view_last_session session_id=\(lastSession.id.uuidString, privacy: .public)"
        )
    }

    @MainActor
    private func exportData(viewModel: CaptureViewModel) async {
        guard let lastSession = viewModel.sessions.first else {
            CoreLog.lifecycle.warning("event=app.quick_action outcome=skipped action=export_har reason=no_sessions")
            await sendNotification(
                title: "Export Failed",
                body: "No sessions available to export"
            )
            return
        }

        do {
            let requests = try AppGroupStorage.shared.loadRequestsForSession(lastSession.id)

            let fileName = "trace-export-\(lastSession.id.uuidString).har"
            let fileURL = try HARExporter.exportToFile(requests: requests, filename: fileName)

            await sendNotification(
                title: "Export Complete",
                body: "Exported \(requests.count) request\(requests.count == 1 ? "" : "s") from session. Open the app to share."
            )

            // Note: Assumes the app reads this key to surface the export after launch.
            UserDefaults.standard.set(fileURL.path, forKey: "lastExportedHARPath")

            CoreLog.lifecycle.info(
                "event=app.quick_action outcome=success action=export_har session_id=\(lastSession.id.uuidString, privacy: .public) request_count=\(requests.count)"
            )
        } catch {
            CoreLog.lifecycle.error(
                "event=app.quick_action outcome=failure action=export_har error=\(error.localizedDescription, privacy: .public)"
            )
            await sendNotification(
                title: "Export Failed",
                body: "Error: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String) async {
        do {
            try await NotificationManager.shared.sendNotification(
                title: title,
                body: body,
                identifier: "quick-action-export"
            )
        } catch {
            CoreLog.lifecycle.error(
                "event=app.notification_send outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
