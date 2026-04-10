//
//  TraceWidgetViews.swift
//  TraceWidget
//
//  Created by Justin on 2026/03/06.
//

import SwiftUI
import TraceCore
import WidgetKit

// MARK: - Entry View

struct TraceWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.widgetRenderingMode) var renderingMode
    let entry: TraceEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(data: entry.data)
        case .systemMedium:
            MediumWidgetView(data: entry.data, configuration: entry.configuration)
        case .systemLarge:
            LargeWidgetView(data: entry.data, configuration: entry.configuration)
        case .systemExtraLarge:
            ExtraLargeWidgetView(data: entry.data, configuration: entry.configuration)
        case .accessoryCircular:
            AccessoryCircularView(data: entry.data)
        case .accessoryRectangular:
            AccessoryRectangularView(data: entry.data)
        case .accessoryInline:
            AccessoryInlineView(data: entry.data)
        default:
            SmallWidgetView(data: entry.data)
        }
    }
}

// MARK: - Design Tokens

private enum DS {
    // Padding
    static let outerPad: CGFloat = 16
    static let innerPad: CGFloat = 11

    // Spacing
    static let sectionGap: CGFloat = 12
    static let rowGap: CGFloat = 6
    static let microGap: CGFloat = 3

    // Typography
    static let heroSize: CGFloat = 40
    static let titleSize: CGFloat = 15
    static let labelSize: CGFloat = 13
    static let captionSize: CGFloat = 11

    // Status indicator dot
    static let dotSize: CGFloat = 8

    // Stat card corner
    static let cardCorner: CGFloat = 10

    // Method badge corner
    static let badgeCorner: CGFloat = 5
}

// MARK: - Shared Helpers

private extension WidgetRequest {
    /// Color for the HTTP method badge.
    var methodAccentColor: Color {
        switch method {
        case "GET":    .green
        case "POST":   .blue
        case "PUT":    .orange
        case "DELETE": .red
        case "PATCH":  Color(red: 0.6, green: 0.2, blue: 1.0)
        case "HEAD":   .teal
        default:       .gray
        }
    }

    /// Color for the HTTP status code.
    var statusAccentColor: Color {
        guard let code = statusCode else { return .gray }
        switch code {
        case 200 ..< 300: return .green
        case 300 ..< 400: return .blue
        case 400 ..< 500: return .orange
        case 500 ..< 600: return .red
        default:          return .gray
        }
    }

    var isError: Bool {
        guard let code = statusCode else { return false }
        return code >= 400
    }

    /// Display host — falls back to "-" only if empty string.
    var displayHost: String { host.isEmpty ? "—" : host }

    /// Display path — falls back to "/" only if empty string.
    var displayPath: String { path.isEmpty ? "/" : path }
}

private extension WidgetData {
    /// Percentage of recent requests that are errors (4xx/5xx).
    var errorRate: Double {
        guard !recentRequests.isEmpty else { return 0 }
        let errors = recentRequests.filter { $0.isError }.count
        return Double(errors) / Double(recentRequests.count)
    }

    var errorRateText: String {
        let pct = Int((errorRate * 100).rounded())
        return "\(pct)%"
    }

    var hasErrors: Bool { errorRate > 0 }

    var successRateText: String {
        let pct = Int(((1 - errorRate) * 100).rounded())
        guard !recentRequests.isEmpty else { return "—" }
        return "\(pct)%"
    }
}

// MARK: - Live Status Indicator

private struct LiveDot: View {
    let isLive: Bool
    var size: CGFloat = DS.dotSize

    var body: some View {
        Circle()
            .fill(isLive ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: size, height: size)
            .widgetAccentable()
    }
}

// MARK: - Method Badge

private struct MethodBadge: View {
    let method: String
    let color: Color
    var compact: Bool = false

    var body: some View {
        Text(method)
            .font(.system(size: DS.captionSize, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(color)
            .clipShape(.rect(cornerRadius: DS.badgeCorner))
            .widgetAccentable()
    }
}

// MARK: - Stat Card (iOS 26 Liquid Glass)

private struct StatCard: View {
    let value: String
    let label: String
    var accent: Color = .primary
    var alert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(alert ? .red : accent)
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(label)
                .font(.system(size: DS.captionSize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            if #available(iOS 26, *) {
                RoundedRectangle(cornerRadius: DS.cardCorner)
                    .glassEffect(.regular)
            } else {
                Color.primary.opacity(0.06)
                    .clipShape(.rect(cornerRadius: DS.cardCorner))
            }
        }
    }
}

// MARK: - Request Row

private struct RequestRow: View {
    let request: WidgetRequest
    var detailed: Bool = false

    var body: some View {
        HStack(spacing: DS.rowGap) {
            MethodBadge(method: request.method, color: request.methodAccentColor, compact: !detailed)

            if detailed {
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.displayHost)
                        .font(.system(size: DS.captionSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(request.displayPath)
                        .font(.system(size: DS.captionSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(request.displayHost)
                    .font(.system(size: DS.captionSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let code = request.statusCode {
                Text("\(code)")
                    .font(.system(size: DS.captionSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(request.statusAccentColor)
                    .widgetAccentable()
            }
        }
        .padding(.vertical, DS.microGap)
    }
}

// MARK: - Small Widget
// Goal: instant read — status + count + error alert

struct SmallWidgetView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                    .widgetAccentable()

                Text("Trace")
                    .font(.system(size: DS.labelSize, weight: .semibold))

                Spacer()

                LiveDot(isLive: data.isCapturing)
            }

            Spacer()

            // Hero count
            VStack(alignment: .leading, spacing: 1) {
                Text("\(data.requestCount)")
                    .font(.system(size: DS.heroSize, weight: .heavy))
                    .foregroundStyle(.primary)
                    .widgetAccentable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text("Requests")
                    .font(.system(size: DS.captionSize))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Footer — status + optional error alert
            HStack(spacing: DS.microGap) {
                Text(data.isCapturing ? "Capturing" : "Idle")
                    .font(.system(size: DS.captionSize, weight: .medium))
                    .foregroundStyle(data.isCapturing ? .green : .secondary)

                Spacer()

                if data.hasErrors {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text(data.errorRateText)
                            .font(.system(size: DS.captionSize, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .widgetAccentable()
                } else {
                    Text(data.dataTransferred)
                        .font(.system(size: DS.captionSize))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DS.outerPad)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Trace network \(data.isCapturing ? "capturing" : "idle"), " +
            "\(data.requestCount) requests, " +
            (data.hasErrors ? "\(data.errorRateText) errors" : data.dataTransferred)
        )
    }
}

// MARK: - Medium Widget
// Goal: status + count + error rate + last 3 requests

struct MediumWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRows: Int { min(configuration.maxRequestsToShow, 3) }

    var body: some View {
        HStack(alignment: .top, spacing: DS.sectionGap) {
            // Left — identity + hero count
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "network")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                        .widgetAccentable()

                    Text("Trace")
                        .font(.system(size: DS.labelSize, weight: .semibold))
                }

                Spacer()

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(data.requestCount)")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text("Requests")
                        .font(.system(size: DS.captionSize))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    LiveDot(isLive: data.isCapturing, size: 7)

                    Text(data.isCapturing ? "Capturing" : "Idle")
                        .font(.system(size: DS.captionSize, weight: .medium))
                        .foregroundStyle(data.isCapturing ? .green : .secondary)
                }

                if data.hasErrors {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text(data.errorRateText + " err")
                            .font(.system(size: DS.captionSize, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .widgetAccentable()
                    .padding(.top, 2)
                }
            }
            .frame(width: 104)

            // Right — recent requests
            VStack(alignment: .leading, spacing: DS.microGap) {
                Text("Recent")
                    .font(.system(size: DS.captionSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.none)

                if !configuration.showRequestDetails {
                    Spacer()
                    Text("Details hidden")
                        .font(.system(size: DS.captionSize))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if data.recentRequests.isEmpty {
                    Spacer()
                    Text("No requests yet")
                        .font(.system(size: DS.captionSize))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(data.recentRequests.prefix(maxRows)) { request in
                        RequestRow(request: request)
                    }

                    if data.recentRequests.count > maxRows {
                        Text("+\(data.recentRequests.count - maxRows) more")
                            .font(.system(size: DS.captionSize))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.outerPad)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Trace \(data.isCapturing ? "capturing" : "idle"), " +
            "\(data.requestCount) requests" +
            (data.hasErrors ? ", \(data.errorRateText) error rate" : "")
        )
    }
}

// MARK: - Large Widget
// Goal: full picture — stat cards + request list

struct LargeWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRows: Int { min(configuration.maxRequestsToShow, 6) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sectionGap) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                        .widgetAccentable()

                    Text("Network Monitor")
                        .font(.system(size: DS.titleSize, weight: .semibold))
                }

                Spacer()

                HStack(spacing: 5) {
                    LiveDot(isLive: data.isCapturing)

                    Text(data.isCapturing ? "Capturing" : "Idle")
                        .font(.system(size: DS.captionSize, weight: .medium))
                        .foregroundStyle(data.isCapturing ? .green : .secondary)
                }
            }

            // Stat cards row
            HStack(spacing: 8) {
                StatCard(value: "\(data.requestCount)", label: "Requests")

                if configuration.showDataTransfer {
                    StatCard(value: data.dataTransferred, label: "Data")
                }

                StatCard(
                    value: data.recentRequests.isEmpty ? "—" : data.errorRateText,
                    label: "Errors",
                    accent: .primary,
                    alert: data.hasErrors
                )
            }

            // Divider
            Divider()
                .opacity(0.4)

            // Request list
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent Requests")
                    .font(.system(size: DS.captionSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, DS.rowGap)

                if !configuration.showRequestDetails {
                    detailsHidden
                } else if data.recentRequests.isEmpty {
                    emptyState
                } else {
                    ForEach(data.recentRequests.prefix(maxRows)) { request in
                        RequestRow(request: request, detailed: true)

                        if request.id != data.recentRequests.prefix(maxRows).last?.id {
                            Divider()
                                .opacity(0.3)
                                .padding(.vertical, 1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DS.outerPad)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Network monitor \(data.isCapturing ? "capturing" : "idle"), " +
            "\(data.requestCount) requests, " +
            (data.hasErrors ? "\(data.errorRateText) error rate" : "no errors")
        )
    }

    private var detailsHidden: some View {
        Text("Request details hidden")
            .font(.system(size: DS.labelSize))
            .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        Text("No requests captured yet")
            .font(.system(size: DS.labelSize))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Extra Large Widget
// Goal: maximum context — stats + 2-column request grid

struct ExtraLargeWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRows: Int { min(configuration.maxRequestsToShow, 10) }

    var successRate: String {
        guard !data.recentRequests.isEmpty else { return "—" }
        return data.successRateText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sectionGap) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.blue)
                        .widgetAccentable()

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Network Monitor")
                            .font(.system(size: 17, weight: .semibold))

                        HStack(spacing: 4) {
                            LiveDot(isLive: data.isCapturing, size: 7)

                            Text(data.isCapturing ? "Capturing" : "Idle")
                                .font(.system(size: DS.captionSize, weight: .medium))
                                .foregroundStyle(data.isCapturing ? .green : .secondary)
                        }
                    }
                }

                Spacer()

                // Alert badge
                if data.hasErrors {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text("\(data.errorRateText) errors")
                            .font(.system(size: DS.labelSize, weight: .semibold))
                    }
                    .foregroundStyle(.red)
                    .widgetAccentable()
                }
            }

            // Stat cards
            HStack(spacing: 8) {
                StatCard(value: "\(data.requestCount)", label: "Requests")

                if configuration.showDataTransfer {
                    StatCard(value: data.dataTransferred, label: "Data Transferred")
                }

                StatCard(value: successRate, label: "Success Rate")

                StatCard(
                    value: data.recentRequests.isEmpty ? "—" : data.errorRateText,
                    label: "Error Rate",
                    accent: .primary,
                    alert: data.hasErrors
                )
            }

            Divider()
                .opacity(0.4)

            // 2-column request grid
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent Requests")
                    .font(.system(size: DS.captionSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                if !configuration.showRequestDetails {
                    Text("Request details hidden")
                        .font(.system(size: DS.labelSize))
                        .foregroundStyle(.secondary)
                } else if data.recentRequests.isEmpty {
                    Text("No requests captured yet")
                        .font(.system(size: DS.labelSize))
                        .foregroundStyle(.secondary)
                } else {
                    let columns = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DS.microGap) {
                        ForEach(data.recentRequests.prefix(maxRows)) { request in
                            RequestRow(request: request, detailed: true)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DS.outerPad)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Network monitor \(data.isCapturing ? "capturing" : "idle"), " +
            "\(data.requestCount) requests, " +
            (data.hasErrors ? "\(data.errorRateText) errors" : "no errors")
        )
    }
}

// MARK: - Accessory Circular
// Goal: capture state + count at a glance

struct AccessoryCircularView: View {
    let data: WidgetData

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            VStack(spacing: 1) {
                Image(systemName: data.isCapturing ? "record.circle.fill" : "network")
                    .font(.system(size: 14, weight: .semibold))
                    .widgetAccentable()

                Text("\(data.requestCount)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .widgetAccentable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .accessibilityLabel(
            "Trace \(data.isCapturing ? "capturing" : "idle"), \(data.requestCount) requests"
        )
    }
}

// MARK: - Accessory Rectangular
// Goal: status line + count + last request method

struct AccessoryRectangularView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .widgetAccentable()

                Text(data.isCapturing ? "Capturing" : "Idle")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                if data.isCapturing {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.green)
                        .widgetAccentable()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(data.requestCount)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .widgetAccentable()

                Text("requests")
                    .font(.system(size: DS.captionSize))
                    .foregroundStyle(.secondary)

                Spacer()

                if data.hasErrors {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .widgetAccentable()
                }
            }

            if let last = data.recentRequests.first {
                HStack(spacing: 4) {
                    MethodBadge(method: last.method, color: last.methodAccentColor, compact: true)

                    if let code = last.statusCode {
                        Text("\(code)")
                            .font(.system(size: DS.captionSize, weight: .semibold, design: .monospaced))
                            .foregroundStyle(last.statusAccentColor)
                            .widgetAccentable()
                    }

                    Text(last.timestamp, style: .relative)
                        .font(.system(size: DS.captionSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityLabel(
            "Trace \(data.isCapturing ? "capturing" : "idle"), \(data.requestCount) requests" +
            (data.hasErrors ? ", errors detected" : "")
        )
    }
}

// MARK: - Accessory Inline

struct AccessoryInlineView: View {
    let data: WidgetData

    var body: some View {
        Label {
            Text(data.isCapturing ? "Capturing · \(data.requestCount)" : "Idle · \(data.requestCount)")
        } icon: {
            Image(systemName: data.isCapturing ? "record.circle.fill" : "network")
        }
        .accessibilityLabel(
            "Trace \(data.isCapturing ? "capturing" : "idle"), \(data.requestCount) requests"
        )
    }
}

// MARK: - Previews

@available(iOS 17.0, *)
#Preview("Small — Capturing", as: .systemSmall) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 127,
            dataTransferred: "4.1 MB",
            recentRequests: PreviewData.sampleRequests
        )
    )
}

@available(iOS 17.0, *)
#Preview("Small — Idle with errors", as: .systemSmall) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: false,
            requestCount: 42,
            dataTransferred: "1.8 MB",
            recentRequests: PreviewData.errorRequests
        )
    )
}

@available(iOS 17.0, *)
#Preview("Medium — Capturing", as: .systemMedium) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 248,
            dataTransferred: "12.3 MB",
            recentRequests: PreviewData.sampleRequests
        )
    )
}

@available(iOS 17.0, *)
#Preview("Large — Capturing", as: .systemLarge) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 381,
            dataTransferred: "28.9 MB",
            recentRequests: PreviewData.sampleRequests
        )
    )
}

@available(iOS 17.0, *)
#Preview("Accessory Circular", as: .accessoryCircular) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 64,
            dataTransferred: "2.1 MB",
            recentRequests: []
        )
    )
}

@available(iOS 17.0, *)
#Preview("Accessory Rectangular", as: .accessoryRectangular) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 64,
            dataTransferred: "2.1 MB",
            recentRequests: PreviewData.sampleRequests
        )
    )
}

// MARK: - Preview Data

private enum PreviewData {
    static let sampleRequests: [WidgetRequest] = [
        WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "api.github.com",
            path: "/repos/org/app",
            statusCode: 200,
            timestamp: Date().addingTimeInterval(-4)
        ),
        WidgetRequest(
            id: UUID(),
            method: "POST",
            host: "api.stripe.com",
            path: "/v1/charges",
            statusCode: 201,
            timestamp: Date().addingTimeInterval(-18)
        ),
        WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "cdn.example.com",
            path: "/assets/bundle.js",
            statusCode: 304,
            timestamp: Date().addingTimeInterval(-35)
        ),
        WidgetRequest(
            id: UUID(),
            method: "DELETE",
            host: "api.example.com",
            path: "/sessions/abc",
            statusCode: 500,
            timestamp: Date().addingTimeInterval(-60)
        ),
        WidgetRequest(
            id: UUID(),
            method: "PATCH",
            host: "api.example.com",
            path: "/users/42",
            statusCode: 404,
            timestamp: Date().addingTimeInterval(-90)
        ),
    ]

    static let errorRequests: [WidgetRequest] = [
        WidgetRequest(
            id: UUID(),
            method: "POST",
            host: "api.example.com",
            path: "/auth/token",
            statusCode: 401,
            timestamp: Date().addingTimeInterval(-10)
        ),
        WidgetRequest(
            id: UUID(),
            method: "GET",
            host: "api.example.com",
            path: "/data",
            statusCode: 500,
            timestamp: Date().addingTimeInterval(-45)
        ),
    ]
}
