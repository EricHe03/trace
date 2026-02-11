//
//  TraceWidget.swift
//  TraceWidget
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import WidgetKit

// MARK: - Widget Data Models

/// Represents a snapshot of network capture data for widget display.
struct WidgetData {
    let isCapturing: Bool
    let requestCount: Int
    let dataTransferred: String
    let recentRequests: [WidgetRequest]

    /// Provides preview data when the shared store is unavailable.
    static var placeholder: WidgetData {
        WidgetData(
            isCapturing: false,
            requestCount: 88,
            dataTransferred: "1.2 MB",
            recentRequests: [
                WidgetRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/users", statusCode: 200, timestamp: Date()),
                WidgetRequest(id: UUID(), method: "POST", host: "api.example.com", path: "/data", statusCode: 201, timestamp: Date())
            ]
        )
    }
}

/// Represents a captured HTTP request for widget display.
struct WidgetRequest: Identifiable, Codable {
    let id: UUID
    let method: String
    let host: String
    let path: String
    let statusCode: Int?
    let timestamp: Date

    /// Returns a color representing the HTTP status code range.
    var statusColor: Color {
        guard let code = statusCode else { return .gray }
        // Rationale: Coarse buckets scan faster in constrained widget sizes.
        switch code {
        case 200 ..< 300: return .green
        case 300 ..< 400: return .blue
        case 400 ..< 500: return .orange
        case 500 ..< 600: return .red
        default: return .gray
        }
    }

    /// Returns a color representing the HTTP method.
    var methodColor: Color {
        // Rule: Method colors MUST stay aligned with the in-app legend to avoid mismatched semantics.
        switch method {
        case "GET": .green
        case "POST": .blue
        case "PUT": .yellow
        case "DELETE": .red
        case "PATCH": .orange
        default: .gray
        }
    }

    /// Returns a privacy-safe host label suitable for glanceable surfaces.
    var redactedHost: String {
        "Endpoint hidden"
    }

    /// Returns a privacy-safe path label suitable for glanceable surfaces.
    var redactedPath: String {
        "Path hidden"
    }
}

// MARK: - Timeline Provider

private func nextUpdateDate(for data: WidgetData, from currentDate: Date) -> Date {
    // Rationale: Refresh quickly while capturing and back off when idle to reduce battery impact.
    let updateInterval: TimeInterval = data.isCapturing ? 30 : 300
    return Calendar.current.date(
        byAdding: data.isCapturing ? .second : .minute,
        value: data.isCapturing ? 30 : 5,
        to: currentDate
    ) ?? currentDate.addingTimeInterval(updateInterval)
}

/// Fetches current network capture data from shared App Group storage.
private func fetchWidgetData() -> WidgetData {
    let appGroupIdentifier = AppGroupConfiguration.appGroupIdentifier
    // Rule: Shared defaults keys MUST stay aligned with the host app's writer contract.
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
        return .placeholder
    }

    let isCapturing = defaults.bool(forKey: "widget.isCapturing")
    let requestCount = defaults.integer(forKey: "widget.requestCount")
    let dataTransferred = defaults.string(forKey: "widget.dataTransferred") ?? "0 B"

    var recentRequests: [WidgetRequest] = []
    // Rationale: Render widgets even when shared data is missing or stale.
    if let requestsData = defaults.data(forKey: "widget.recentRequests"),
       let decoded = try? JSONDecoder().decode([WidgetRecentRequest].self, from: requestsData) {
        recentRequests = decoded.map { req in
            let url = URL(string: req.url)
            return WidgetRequest(
                id: req.id,
                method: req.method,
                host: url?.host ?? req.url,
                path: url?.path ?? "/",
                statusCode: req.statusCode,
                timestamp: req.timestamp
            )
        }
    }

    return WidgetData(
        isCapturing: isCapturing,
        requestCount: requestCount,
        dataTransferred: dataTransferred,
        recentRequests: recentRequests
    )
}

/// Provides timeline entries for the network monitor widget.
struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TraceEntry {
        TraceEntry(date: Date(), configuration: ConfigurationAppIntent(), data: .placeholder)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> TraceEntry {
        TraceEntry(date: Date(), configuration: configuration, data: fetchWidgetData())
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<TraceEntry> {
        let currentDate = Date()
        let data = fetchWidgetData()
        let entry = TraceEntry(date: currentDate, configuration: configuration, data: data)
        let nextUpdate = nextUpdateDate(for: data, from: currentDate)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    /// Provides recommendations for Smart Stack to determine when to show this widget.
    @available(iOS 17.0, iOSApplicationExtension 17.0, *)
    func recommendations() -> [AppIntentRecommendation<ConfigurationAppIntent>] {
        let data = fetchWidgetData()

        // Recommend showing widget when actively capturing
        if data.isCapturing {
            return [
                AppIntentRecommendation(
                    intent: ConfigurationAppIntent(),
                    description: "Monitor active network traffic capture"
                )
            ]
        }

        // Default recommendation
        return [
            AppIntentRecommendation(
                intent: ConfigurationAppIntent(),
                description: "View network capture status"
            )
        ]
    }
}

// MARK: - Widget Background Helper

extension View {
    @ViewBuilder
    func traceWidgetContainerBackground(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 17.0, iOSApplicationExtension 17.0, *) {
            self.containerBackground(for: .widget, content: content)
        } else {
            self.background(content())
        }
    }
}

/// Represents a timeline entry containing network capture data and configuration.
struct TraceEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let data: WidgetData
}

// MARK: - Legacy Provider (iOS 16)

private struct LegacyProvider: TimelineProvider {
    private let defaultConfiguration = ConfigurationAppIntent()

    func placeholder(in context: Context) -> TraceEntry {
        TraceEntry(date: Date(), configuration: defaultConfiguration, data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TraceEntry) -> Void) {
        let entry = TraceEntry(date: Date(), configuration: defaultConfiguration, data: fetchWidgetData())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TraceEntry>) -> Void) {
        let currentDate = Date()
        let data = fetchWidgetData()
        let entry = TraceEntry(date: currentDate, configuration: defaultConfiguration, data: data)
        let nextUpdate = nextUpdateDate(for: data, from: currentDate)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Widget Views

/// Renders the Trace widget root view for the current widget family.
struct TraceWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.widgetRenderingMode) var renderingMode
    var entry: TraceEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallWidgetView(data: entry.data, configuration: entry.configuration)
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
                SmallWidgetView(data: entry.data, configuration: entry.configuration)
            }
        }
    }
}

// MARK: - Small Widget View

/// Renders a compact widget view with capture status and request count.
struct SmallWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.blue)
                    .widgetAccentable()

                Text("Trace")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                Circle()
                    .fill(data.isCapturing ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                    .widgetAccentable()
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("\(data.requestCount)")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.primary)
                    .widgetAccentable()

                Text("Requests")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if configuration.showDataTransfer {
                Text(data.dataTransferred)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Text(data.isCapturing ? "Capturing..." : "Idle")
                .font(.system(size: 11))
                .foregroundColor(data.isCapturing ? .green : .gray)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network capture \(data.isCapturing ? "active" : "idle"), \(data.requestCount) requests captured")
        .accessibilityValue(data.dataTransferred)
    }
}

// MARK: - Medium Widget View

/// Renders a medium widget view with stats and recent requests.
struct MediumWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRequestsToShow: Int {
        // Rationale: Clamp values to keep layout stable across user configuration extremes.
        max(0, min(configuration.maxRequestsToShow, 3))
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "network")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.blue)
                        .widgetAccentable()

                    Text("Trace")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(data.requestCount)")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.primary)
                        .widgetAccentable()

                    Text("Requests")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if configuration.showDataTransfer {
                    Text(data.dataTransferred)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(data.isCapturing ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                        .widgetAccentable()

                    Text(data.isCapturing ? "Capturing" : "Idle")
                        .font(.system(size: 11))
                        .foregroundColor(data.isCapturing ? .green : .gray)
                }
            }
            .frame(width: 100)

            VStack(alignment: .leading, spacing: 4) {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                if !configuration.showRequestDetails {
                    Spacer()
                    Text("Request details hidden")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                } else if data.recentRequests.isEmpty || maxRequestsToShow == 0 {
                    Spacer()
                    Text("No requests yet")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    ForEach(data.recentRequests.prefix(maxRequestsToShow)) { request in
                        RequestRowCompact(request: request)
                    }

                    if data.recentRequests.count > maxRequestsToShow, maxRequestsToShow > 0 {
                        Text("+\(data.recentRequests.count - maxRequestsToShow) more")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network capture \(data.isCapturing ? "active" : "idle"), \(data.requestCount) requests, recent activity")
    }
}

// MARK: - Large Widget View

/// Renders a large widget view with detailed stats and recent requests.
struct LargeWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRequestsToShow: Int {
        // Rationale: Clamp values to keep layout stable across user configuration extremes.
        max(0, min(configuration.maxRequestsToShow, 6))
    }

    /// Calculates the percentage of successful (2xx) responses.
    var successRate: String {
        // Rationale: Use recent requests instead of totals to reflect current health.
        let successful = data.recentRequests.count(where: {
            if let code = $0.statusCode {
                return code >= 200 && code < 300
            }
            return false
        })

        guard !data.recentRequests.isEmpty else { return "N/A" }
        let rate = (Double(successful) / Double(data.recentRequests.count)) * 100
        return String(format: "%.0f%%", rate)
    }

    private var statItems: [(value: String, label: String)] {
        var items = [
            ("\(data.requestCount)", "Requests")
        ]

        if configuration.showDataTransfer {
            items.append((data.dataTransferred, "Data"))
        }

        items.append((successRate, "Success"))
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.blue)
                    .widgetAccentable()

                Text("Network Monitor")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(data.isCapturing ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                        .widgetAccentable()

                    Text(data.isCapturing ? "Capturing" : "Idle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(data.isCapturing ? .green : .gray)
                }
            }

            HStack(spacing: 16) {
                ForEach(Array(statItems.enumerated()), id: \.offset) { _, item in
                    StatBox(value: item.value, label: item.label)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Recent Requests")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                if !configuration.showRequestDetails {
                    VStack {
                        Spacer()
                        Text("Request details hidden")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else if data.recentRequests.isEmpty || maxRequestsToShow == 0 {
                    VStack {
                        Spacer()
                        Text("No requests captured yet")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    ForEach(data.recentRequests.prefix(maxRequestsToShow)) { request in
                        RequestRowDetailed(request: request)
                    }
                }
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network monitor, \(data.isCapturing ? "capturing" : "idle"), \(data.requestCount) total requests")
    }
}

// MARK: - Extra Large Widget View

/// Renders an extra large widget view optimized for large displays.
struct ExtraLargeWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRequestsToShow: Int {
        // Rationale: Clamp values to keep layout stable across user configuration extremes.
        max(0, min(configuration.maxRequestsToShow, 12))
    }

    /// Calculates the percentage of successful (2xx) responses.
    var successRate: String {
        // Rationale: Use recent requests instead of totals to reflect current health.
        let successful = data.recentRequests.count(where: {
            if let code = $0.statusCode {
                return code >= 200 && code < 300
            }
            return false
        })

        guard !data.recentRequests.isEmpty else { return "N/A" }
        let rate = (Double(successful) / Double(data.recentRequests.count)) * 100
        return String(format: "%.0f%%", rate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.blue)
                    .widgetAccentable()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Network Monitor")
                        .font(.system(size: 18, weight: .semibold))

                    HStack(spacing: 4) {
                        Circle()
                            .fill(data.isCapturing ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                            .widgetAccentable()

                        Text(data.isCapturing ? "Capturing" : "Idle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(data.isCapturing ? .green : .gray)
                    }
                }

                Spacer()
            }

            HStack(spacing: 12) {
                StatBox(value: "\(data.requestCount)", label: "Requests")

                if configuration.showDataTransfer {
                    StatBox(value: data.dataTransferred, label: "Data Transferred")
                }

                StatBox(value: successRate, label: "Success Rate")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Recent Requests")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                if !configuration.showRequestDetails {
                    VStack {
                        Spacer()
                        Text("Request details hidden")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else if data.recentRequests.isEmpty || maxRequestsToShow == 0 {
                    VStack {
                        Spacer()
                        Text("No requests captured yet")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    let columns = [GridItem(.flexible()), GridItem(.flexible())]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(data.recentRequests.prefix(maxRequestsToShow)) { request in
                            RequestRowDetailed(request: request)
                        }
                    }
                }
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network monitor, \(data.isCapturing ? "capturing" : "idle"), \(data.requestCount) total requests")
    }
}

// MARK: - Accessory Widgets

/// Renders a circular accessory widget for lock screen, Apple Watch, and StandBy mode.
struct AccessoryCircularView: View {
    let data: WidgetData

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "network")
                .font(.system(size: 16, weight: .semibold))
                .widgetAccentable()

            Text("\(data.requestCount)")
                .font(.system(size: 18, weight: .bold))
                .widgetAccentable()
        }
        .traceWidgetContainerBackground {
            Color.clear
        }
        .accessibilityLabel("Network capture, \(data.requestCount) requests")
    }
}

/// Renders a rectangular accessory widget for lock screen and StandBy mode.
struct AccessoryRectangularView: View {
    let data: WidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 12, weight: .semibold))

                Text(data.isCapturing ? "Capturing" : "Idle")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                if data.isCapturing {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .widgetAccentable()
                }
            }

            HStack {
                Text("\(data.requestCount)")
                    .font(.system(size: 20, weight: .bold))
                    .widgetAccentable()

                Text("requests")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Spacer()
            }

            if data.recentRequests.first != nil {
                Text("Recent network activity")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Network capture \(data.isCapturing ? "active" : "idle"), \(data.requestCount) requests")
    }
}

/// Renders an inline accessory widget for lock screen.
struct AccessoryInlineView: View {
    let data: WidgetData

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "network")

            Text(data.isCapturing ? "Capturing:" : "Captured:")

            Text("\(data.requestCount)")
                .fontWeight(.bold)
        }
        .accessibilityLabel("Network \(data.isCapturing ? "capturing" : "captured"), \(data.requestCount) requests")
    }
}

// MARK: - Subviews

/// Displays a statistics box with a value and label.
struct StatBox: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
                .widgetAccentable()

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

/// Displays a compact request row with method, host, and status code.
struct RequestRowCompact: View {
    let request: WidgetRequest

    var body: some View {
        HStack(spacing: 6) {
            Text(request.method)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(request.methodColor)
                .cornerRadius(4)
                .widgetAccentable()

            Text(request.redactedHost)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            if let code = request.statusCode {
                Text("\(code)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(request.statusColor)
                    .widgetAccentable()
            }
        }
        .padding(.vertical, 2)
    }
}

/// Displays a detailed request row with method, host, path, status, and time.
struct RequestRowDetailed: View {
    let request: WidgetRequest

    var body: some View {
        HStack(spacing: 6) {
            Text(request.method)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(request.methodColor)
                .cornerRadius(4)
                .widgetAccentable()

            VStack(alignment: .leading, spacing: 2) {
                Text(request.redactedHost)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(request.redactedPath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let code = request.statusCode {
                    Text("\(code)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(request.statusColor)
                        .widgetAccentable()
                }

                Text(request.timestamp, style: .relative)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Widget Configuration

/// Defines the main network monitor widget with multiple families and configurations.
struct TraceWidget: Widget {
    let kind: String = "TraceWidget"

    private var supportedFamilies: [WidgetFamily] {
        [
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ]
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: LegacyProvider()
        ) { entry in
            TraceWidgetEntryView(entry: entry)
                .traceWidgetContainerBackgroundIfAvailable()
        }
        .configurationDisplayName("Network Monitor")
        .description("View captured network requests and monitor traffic activity.")
        .supportedFamilies(supportedFamilies)
    }
}

private extension View {
    @ViewBuilder
    func traceWidgetContainerBackgroundIfAvailable() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(.fill.tertiary, for: .widget)
        } else {
            self
        }
    }
}

// MARK: - Previews

@available(iOS 17.0, *)
#Preview(as: .systemSmall) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 42,
            dataTransferred: "2.3 MB",
            recentRequests: []
        )
    )
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: false,
            requestCount: 0,
            dataTransferred: "0 B",
            recentRequests: []
        )
    )
}

@available(iOS 17.0, *)
#Preview(as: .systemMedium) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 156,
            dataTransferred: "5.7 MB",
            recentRequests: [
                WidgetRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/users", statusCode: 200, timestamp: Date().addingTimeInterval(-5)),
                WidgetRequest(id: UUID(), method: "POST", host: "api.example.com", path: "/auth", statusCode: 201, timestamp: Date().addingTimeInterval(-12)),
                WidgetRequest(id: UUID(), method: "GET", host: "cdn.example.com", path: "/image.png", statusCode: 304, timestamp: Date().addingTimeInterval(-30))
            ]
        )
    )
}

@available(iOS 17.0, *)
#Preview(as: .systemLarge) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 234,
            dataTransferred: "12.4 MB",
            recentRequests: [
                WidgetRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/users/profile", statusCode: 200, timestamp: Date().addingTimeInterval(-5)),
                WidgetRequest(id: UUID(), method: "POST", host: "api.example.com", path: "/auth/login", statusCode: 201, timestamp: Date().addingTimeInterval(-12)),
                WidgetRequest(id: UUID(), method: "GET", host: "cdn.example.com", path: "/assets/logo.png", statusCode: 304, timestamp: Date().addingTimeInterval(-30)),
                WidgetRequest(id: UUID(), method: "PUT", host: "api.example.com", path: "/settings", statusCode: 200, timestamp: Date().addingTimeInterval(-45)),
                WidgetRequest(id: UUID(), method: "DELETE", host: "api.example.com", path: "/cache", statusCode: 204, timestamp: Date().addingTimeInterval(-60)),
                WidgetRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/data", statusCode: 500, timestamp: Date().addingTimeInterval(-90))
            ]
        )
    )
}

@available(iOS 17.0, *)
#Preview(as: .systemExtraLarge) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 345,
            dataTransferred: "18.2 MB",
            recentRequests: [
                WidgetRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/users/profile", statusCode: 200, timestamp: Date().addingTimeInterval(-5)),
                WidgetRequest(id: UUID(), method: "POST", host: "api.example.com", path: "/auth/login", statusCode: 201, timestamp: Date().addingTimeInterval(-12)),
                WidgetRequest(id: UUID(), method: "GET", host: "cdn.example.com", path: "/assets/logo.png", statusCode: 304, timestamp: Date().addingTimeInterval(-30)),
                WidgetRequest(id: UUID(), method: "PUT", host: "api.example.com", path: "/settings", statusCode: 200, timestamp: Date().addingTimeInterval(-45)),
                WidgetRequest(id: UUID(), method: "DELETE", host: "api.example.com", path: "/cache", statusCode: 204, timestamp: Date().addingTimeInterval(-60)),
                WidgetRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/data", statusCode: 500, timestamp: Date().addingTimeInterval(-90)),
                WidgetRequest(id: UUID(), method: "PATCH", host: "api.example.com", path: "/profile", statusCode: 200, timestamp: Date().addingTimeInterval(-120)),
                WidgetRequest(id: UUID(), method: "GET", host: "cdn.example.com", path: "/image2.png", statusCode: 200, timestamp: Date().addingTimeInterval(-150))
            ]
        )
    )
}

@available(iOS 17.0, *)
#Preview(as: .accessoryCircular) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 42,
            dataTransferred: "2.3 MB",
            recentRequests: []
        )
    )
}

@available(iOS 17.0, *)
#Preview(as: .accessoryRectangular) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 156,
            dataTransferred: "5.7 MB",
            recentRequests: [
                WidgetRequest(id: UUID(), method: "GET", host: "api.example.com", path: "/users", statusCode: 200, timestamp: Date().addingTimeInterval(-5))
            ]
        )
    )
}

@available(iOS 17.0, *)
#Preview(as: .accessoryInline) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 42,
            dataTransferred: "2.3 MB",
            recentRequests: []
        )
    )
}
