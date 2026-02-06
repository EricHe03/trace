//
//  NotificationSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceFeatures
import TraceUI

struct NotificationSettingsView: View {
    @ObservedObject private var settings = NotificationSettings.shared
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isRequestingPermission = false

    var body: some View {
        Form {
            // Permission Status Section
            Section {
                HStack {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(statusText)
                        .font(.subheadline)
                    Spacer()
                    if notificationStatus == .notDetermined {
                        Button {
                            requestNotificationPermission()
                        } label: {
                            if isRequestingPermission {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Enable")
                            }
                        }
                        .font(.caption)
                        .disabled(isRequestingPermission)
                        .accessibilityLabel("Enable notifications")
                        .accessibilityHint("Shows the system permission alert for notifications")
                    } else if notificationStatus == .denied {
                        Button("Open Settings") {
                            NotificationManager.shared.openNotificationSettings()
                        }
                        .font(.caption)
                        .accessibilityLabel("Open system settings")
                        .accessibilityHint("Opens the iOS Settings app for notification permissions")
                    }
                }
            } header: {
                Text("Permission Status")
            } footer: {
                Text(statusFooter)
            }

            // Notification Types Section
            Section {
                Toggle(isOn: $settings.enableErrorNotifications) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HTTP Errors")
                            .font(.body)
                        Text("4xx and 5xx status codes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $settings.enableSlowRequestNotifications) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Slow Requests")
                            .font(.body)
                        Text("Requests exceeding threshold")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.enableSlowRequestNotifications {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Threshold")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.1fs", settings.slowRequestThreshold))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.slowRequestThreshold,
                            in: 0.5 ... 10.0,
                            step: 0.5
                        )
                        .accessibilityLabel("Slow request threshold")
                        .accessibilityValue(String(format: "%.1f seconds", settings.slowRequestThreshold))
                    }
                    .padding(.vertical, 4)
                }

                Toggle(isOn: $settings.enableLargeDataNotifications) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Large Data Transfers")
                            .font(.body)
                        Text("Requests with large payloads")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.enableLargeDataNotifications {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Threshold")
                                .font(.subheadline)
                            Spacer()
                            Text(formatBytes(settings.largeDataThreshold))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.largeDataThreshold) },
                                set: { settings.largeDataThreshold = Int64($0) }
                            ),
                            in: 1_000_000 ... 50_000_000,
                            step: 1_000_000
                        )
                        .accessibilityLabel("Large data threshold")
                        .accessibilityValue(formatBytes(settings.largeDataThreshold))
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Notification Types")
            } footer: {
                Text("Choose which network events should trigger notifications")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await checkNotificationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                await checkNotificationStatus()
            }
        }
    }

    // MARK: - Helpers

    private func checkNotificationStatus() async {
        notificationStatus = await NotificationManager.shared.checkAuthorizationStatus()
    }

    private func requestNotificationPermission() {
        isRequestingPermission = true

        Task {
            do {
                try await NotificationManager.shared.requestAuthorization()
            } catch {
                // If the request fails or is interrupted, status refresh reflects current state.
            }

            await checkNotificationStatus()
            await MainActor.run {
                isRequestingPermission = false
            }
        }
    }

    private var statusIcon: String {
        switch notificationStatus {
        case .authorized, .provisional:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.circle.fill"
        case .notDetermined:
            return "questionmark.circle.fill"
        case .ephemeral:
            return "clock.circle.fill"
        @unknown default:
            return "questionmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch notificationStatus {
        case .authorized, .provisional:
            return DesignSystem.Colors.success
        case .denied:
            return DesignSystem.Colors.danger
        case .notDetermined:
            return DesignSystem.Colors.warning
        case .ephemeral:
            return DesignSystem.Colors.info
        @unknown default:
            return DesignSystem.Colors.muted
        }
    }

    private var statusText: String {
        switch notificationStatus {
        case .authorized:
            return "Notifications Enabled"
        case .denied:
            return "Notifications Disabled"
        case .notDetermined:
            return "Notifications Not Enabled"
        case .provisional:
            return "Provisional Authorization"
        case .ephemeral:
            return "Ephemeral Authorization"
        @unknown default:
            return "Unknown Status"
        }
    }

    private var statusFooter: String {
        switch notificationStatus {
        case .authorized:
            return "You will receive notifications for network events based on your preferences below."
        case .denied:
            return "Notifications are disabled. Open Settings to enable them."
        case .notDetermined:
            return "Trace requests notification permission only after you tap Enable."
        case .provisional:
            return "Notifications are delivered quietly (provisional authorization). You can change delivery style in Settings."
        case .ephemeral:
            return "Temporary notification access granted."
        @unknown default:
            return ""
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        DesignSystem.formattedBytes(Int(bytes))
    }
}
