//
//  TraceWidgetLiveActivity.swift
//  TraceWidget
//
//  Created by Justin on 2026/01/10.
//

import ActivityKit
import SwiftUI
import TraceCore
import WidgetKit

// MARK: - Live Activity Widget

/// Displays real-time network capture statistics in Dynamic Island and on the lock screen.
@available(iOS 16.1, *)
struct TraceWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TraceWidgetAttributes.self) { context in
            LiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color.blue.opacity(0.1))
                .activitySystemActionForegroundColor(Color.blue)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Capturing", systemImage: "network")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.blue)

                        Text(context.state.captureStartTime, style: .timer)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(context.state.requestCount)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)

                        Text("requests")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    if let method = context.state.lastRequestMethod,
                       let host = context.state.lastRequestHost {
                        HStack(spacing: 4) {
                            Text(method)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(methodColor(method))
                                .cornerRadius(3)

                            Text(host)
                                .font(.system(size: 10))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if let status = context.state.lastRequestStatus {
                                Text("\(status)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(statusColor(status))
                            }
                        }
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(context.state.dataTransferred, systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        Group {
                            if let lastTime = context.state.lastRequestTime {
                                Text("Last: ") + Text(lastTime, style: .relative)
                            } else {
                                Text("Last: N/A")
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)

                    Image(systemName: "network")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
            } compactTrailing: {
                Text("\(context.state.requestCount)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)
            } minimal: {
                Text("\(context.state.requestCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.blue)
            }
            // Deep link URL scheme for opening the app to the capture view.
            // The host app should handle the "trace://capture" URL in its scene delegate.
            .widgetURL(URL(string: "trace://capture"))
            .keylineTint(Color.blue)
        }
    }

    /// Returns a color representing the HTTP method.
    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": .green
        case "POST": .blue
        case "PUT": .yellow
        case "DELETE": .red
        case "PATCH": .orange
        default: .gray
        }
    }

    /// Returns a color representing the HTTP status code range.
    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200 ..< 300: .green
        case 300 ..< 400: .blue
        case 400 ..< 500: .orange
        case 500 ..< 600: .red
        default: .gray
        }
    }
}

// MARK: - Lock Screen View

/// Displays the Live Activity on the lock screen and notification banner.
@available(iOS 16.1, *)
struct LiveActivityLockScreenView: View {
    let context: ActivityViewContext<TraceWidgetAttributes>

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)

                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "network")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)

                    Text("Network Capture Active")
                        .font(.system(size: 13, weight: .semibold))
                }

                HStack(spacing: 16) {
                    Label("\(context.state.requestCount) requests", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Label(context.state.dataTransferred, systemImage: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if let method = context.state.lastRequestMethod,
                   let host = context.state.lastRequestHost {
                    HStack(spacing: 4) {
                        Text("Last:")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        Text(method)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(methodColor(method))
                            .cornerRadius(3)

                        Text(host)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(context.state.captureStartTime, style: .timer)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)

                Text("duration")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    /// Returns a color representing the HTTP method.
    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": .green
        case "POST": .blue
        case "PUT": .yellow
        case "DELETE": .red
        case "PATCH": .orange
        default: .gray
        }
    }
}

// MARK: - Previews

@available(iOS 16.1, *)
private extension TraceWidgetAttributes {
    static var preview: TraceWidgetAttributes {
        TraceWidgetAttributes(sessionId: UUID())
    }
}

@available(iOS 16.1, *)
private extension TraceWidgetAttributes.ContentState {
    static var active: TraceWidgetAttributes.ContentState {
        TraceWidgetAttributes.ContentState(
            requestCount: 42,
            dataTransferred: "2.3 MB",
            captureStartTime: Date().addingTimeInterval(-120),
            lastRequestTime: Date().addingTimeInterval(-5),
            lastRequestMethod: "GET",
            lastRequestHost: "api.example.com",
            lastRequestStatus: 200
        )
    }

    static var starting: TraceWidgetAttributes.ContentState {
        TraceWidgetAttributes.ContentState(
            requestCount: 0,
            dataTransferred: "0 B",
            captureStartTime: Date(),
            lastRequestTime: nil,
            lastRequestMethod: nil,
            lastRequestHost: nil,
            lastRequestStatus: nil
        )
    }
}

@available(iOS 17.0, *)
#Preview("Notification", as: .content, using: TraceWidgetAttributes.preview) {
    TraceWidgetLiveActivity()
} contentStates: {
    TraceWidgetAttributes.ContentState.starting
    TraceWidgetAttributes.ContentState.active
}
