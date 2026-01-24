//
//  NotificationSettingsView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceFeatures

struct NotificationSettingsView: View {
    @ObservedObject private var settings = NotificationSettings.shared
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
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
                    if notificationStatus == .denied {
                        Button("Open Settings") {
                            NotificationManager.shared.openNotificationSettings()
                        }
                        .font(.caption)
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
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        case .ephemeral:
            return .blue
        @unknown default:
            return .gray
        }
    }

    private var statusText: String {
        switch notificationStatus {
        case .authorized:
            return "Notifications Enabled"
        case .denied:
            return "Notifications Disabled"
        case .notDetermined:
            return "Permission Not Requested"
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
            return "Permission will be requested when the app launches."
        case .provisional:
            return "Notifications are delivered quietly. You can manage them in Settings."
        case .ephemeral:
            return "Temporary notification access granted."
        @unknown default:
            return ""
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
