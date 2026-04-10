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

/// Displays real-time network capture statistics in Dynamic Island and on the Lock Screen.
@available(iOS 16.1, *)
struct TraceWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TraceWidgetAttributes.self) { context in
            LiveActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded — touch & hold
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(context: context)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(context: context)
                }

                DynamicIslandExpandedRegion(.center) {
                    if let method = context.state.lastRequestMethod {
                        ExpandedCenter(method: method, status: context.state.lastRequestStatus)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(context: context)
                }
            } compactLeading: {
                // Compact leading — live indicator + icon
                HStack(spacing: 3) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.green)

                    Image(systemName: "network")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.blue)
                }
            } compactTrailing: {
                // Compact trailing — request count + optional error badge
                HStack(spacing: 3) {
                    if context.state.hasErrors {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }

                    Text("\(context.state.requestCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                .contentTransition(.numericText())
            } minimal: {
                // Minimal — count only
                Text("\(context.state.requestCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
                    .contentTransition(.numericText())
            }
            .widgetURL(URL(string: "trace://capture"))
            .keylineTint(.blue)
        }
    }
}

// MARK: - Expanded Region Views

@available(iOS 16.1, *)
private struct ExpandedLeading: View {
    let context: ActivityViewContext<TraceWidgetAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text("Trace")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            Text(context.state.captureStartTime, style: .timer)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }
}

@available(iOS 16.1, *)
private struct ExpandedTrailing: View {
    let context: ActivityViewContext<TraceWidgetAttributes>

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(context.state.requestCount)")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())

            Text("requests")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 4)
    }
}

@available(iOS 16.1, *)
private struct ExpandedCenter: View {
    let method: String
    let status: Int?

    var methodColor: Color {
        switch method {
        case "GET":    .green
        case "POST":   .blue
        case "PUT":    .orange
        case "DELETE": .red
        case "PATCH":  Color(red: 0.6, green: 0.2, blue: 1.0)
        default:       .gray
        }
    }

    var statusColor: Color {
        guard let code = status else { return .gray }
        switch code {
        case 200 ..< 300: return .green
        case 300 ..< 400: return .blue
        case 400 ..< 500: return .orange
        case 500 ..< 600: return .red
        default:          return .gray
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(method)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(methodColor)
                .clipShape(.rect(cornerRadius: 4))

            if let code = status {
                Text("\(code)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor)
            }
        }
    }
}

@available(iOS 16.1, *)
private struct ExpandedBottom: View {
    let context: ActivityViewContext<TraceWidgetAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Label(context.state.dataTransferred, systemImage: "arrow.down.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            if let lastTime = context.state.lastRequestTime {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(lastTime, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

// MARK: - Lock Screen View

/// Lock Screen and notification banner presentation.
/// Uses a Liquid Glass background on iOS 26+, custom tint on earlier versions.
@available(iOS 16.1, *)
struct LiveActivityLockScreenView: View {
    let context: ActivityViewContext<TraceWidgetAttributes>

    var body: some View {
        HStack(spacing: 14) {
            // Left — live indicator column
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 28, height: 28)

                    Image(systemName: "network")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                }

                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                    .tracking(1)
            }
            .frame(width: 36)

            // Center — stats + last request
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    // Request count
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(context.state.requestCount)")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())

                        Text("requests")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Data transferred
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(context.state.dataTransferred)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)

                        Label("data", systemImage: "arrow.down")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                // Last request row
                if let method = context.state.lastRequestMethod {
                    HStack(spacing: 5) {
                        Text(method)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(methodColor(method))
                            .clipShape(.rect(cornerRadius: 4))

                        if let status = context.state.lastRequestStatus {
                            Text("\(status)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(statusColor(status))
                        }

                        if let lastTime = context.state.lastRequestTime {
                            Text(lastTime, style: .relative)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()
                    }
                }
            }

            // Right — timer
            VStack(alignment: .trailing, spacing: 1) {
                Text(context.state.captureStartTime, style: .timer)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .monospacedDigit()

                Text("elapsed")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .activityBackgroundTint(Color(red: 0.05, green: 0.05, blue: 0.12).opacity(0.85))
        .activitySystemActionForegroundColor(.blue)
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET":    .green
        case "POST":   .blue
        case "PUT":    .orange
        case "DELETE": .red
        case "PATCH":  Color(red: 0.6, green: 0.2, blue: 1.0)
        default:       .gray
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200 ..< 300: .green
        case 300 ..< 400: .blue
        case 400 ..< 500: .orange
        case 500 ..< 600: .red
        default:          .gray
        }
    }
}

// MARK: - ContentState Helpers

@available(iOS 16.1, *)
private extension TraceWidgetAttributes.ContentState {
    var hasErrors: Bool {
        guard let status = lastRequestStatus else { return false }
        return status >= 400
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
            requestCount: 127,
            dataTransferred: "4.1 MB",
            captureStartTime: Date().addingTimeInterval(-340),
            lastRequestTime: Date().addingTimeInterval(-3),
            lastRequestMethod: "POST",
            lastRequestHost: "api.stripe.com",
            lastRequestStatus: 201
        )
    }

    static var withErrors: TraceWidgetAttributes.ContentState {
        TraceWidgetAttributes.ContentState(
            requestCount: 42,
            dataTransferred: "1.8 MB",
            captureStartTime: Date().addingTimeInterval(-180),
            lastRequestTime: Date().addingTimeInterval(-8),
            lastRequestMethod: "GET",
            lastRequestHost: "api.example.com",
            lastRequestStatus: 500
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
#Preview("Live Activity — Active", as: .content, using: TraceWidgetAttributes.preview) {
    TraceWidgetLiveActivity()
} contentStates: {
    TraceWidgetAttributes.ContentState.starting
    TraceWidgetAttributes.ContentState.active
    TraceWidgetAttributes.ContentState.withErrors
}
