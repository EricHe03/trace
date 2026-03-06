//
//  TraceWidgetViews.swift
//  TraceWidget
//
//  Created by AI Assistant on 2026/03/06.
//

import SwiftUI
import TraceCore
import WidgetKit

struct TraceWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.widgetRenderingMode) var renderingMode
    let entry: TraceEntry

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

struct SmallWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.blue)
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
                    .foregroundStyle(.primary)
                    .widgetAccentable()

                Text("Requests")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if configuration.showDataTransfer {
                Text(data.dataTransferred)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(data.isCapturing ? "Capturing..." : "Idle")
                .font(.system(size: 11))
                .foregroundStyle(data.isCapturing ? .green : .gray)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network capture \(data.isCapturing ? "active" : "idle"), \(data.requestCount) requests captured")
        .accessibilityValue(data.dataTransferred)
    }
}

struct MediumWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRequestsToShow: Int {
        max(0, min(configuration.maxRequestsToShow, 3))
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "network")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                        .widgetAccentable()

                    Text("Trace")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(data.requestCount)")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()

                    Text("Requests")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if configuration.showDataTransfer {
                    Text(data.dataTransferred)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(data.isCapturing ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                        .widgetAccentable()

                    Text(data.isCapturing ? "Capturing" : "Idle")
                        .font(.system(size: 11))
                        .foregroundStyle(data.isCapturing ? .green : .gray)
                }
            }
            .frame(width: 100)

            VStack(alignment: .leading, spacing: 4) {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if !configuration.showRequestDetails {
                    Spacer()
                    Text("Request details hidden")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if data.recentRequests.isEmpty || maxRequestsToShow == 0 {
                    Spacer()
                    Text("No requests yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(data.recentRequests.prefix(maxRequestsToShow)) { request in
                        RequestRowCompact(request: request)
                    }

                    if data.recentRequests.count > maxRequestsToShow, maxRequestsToShow > 0 {
                        Text("+\(data.recentRequests.count - maxRequestsToShow) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
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

struct LargeWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRequestsToShow: Int {
        max(0, min(configuration.maxRequestsToShow, 6))
    }

    var successRate: String {
        let successful = data.recentRequests.count {
            guard let code = $0.statusCode else { return false }
            return code >= 200 && code < 300
        }

        guard !data.recentRequests.isEmpty else { return "N/A" }
        let rate = (Double(successful) / Double(data.recentRequests.count)) * 100
        return "\(Int(rate.rounded()))%"
    }

    private var statItems: [(value: String, label: String)] {
        var items = [("\(data.requestCount)", "Requests")]

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
                    .foregroundStyle(.blue)
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
                        .foregroundStyle(data.isCapturing ? .green : .gray)
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
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                if !configuration.showRequestDetails {
                    VStack {
                        Spacer()
                        Text("Request details hidden")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if data.recentRequests.isEmpty || maxRequestsToShow == 0 {
                    VStack {
                        Spacer()
                        Text("No requests captured yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
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

struct ExtraLargeWidgetView: View {
    let data: WidgetData
    let configuration: ConfigurationAppIntent

    private var maxRequestsToShow: Int {
        max(0, min(configuration.maxRequestsToShow, 12))
    }

    var successRate: String {
        let successful = data.recentRequests.count {
            guard let code = $0.statusCode else { return false }
            return code >= 200 && code < 300
        }

        guard !data.recentRequests.isEmpty else { return "N/A" }
        let rate = (Double(successful) / Double(data.recentRequests.count)) * 100
        return "\(Int(rate.rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.blue)
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
                            .foregroundStyle(data.isCapturing ? .green : .gray)
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
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                if !configuration.showRequestDetails {
                    VStack {
                        Spacer()
                        Text("Request details hidden")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if data.recentRequests.isEmpty || maxRequestsToShow == 0 {
                    VStack {
                        Spacer()
                        Text("No requests captured yet")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if data.recentRequests.first != nil {
                Text("Recent network activity")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Network capture \(data.isCapturing ? "active" : "idle"), \(data.requestCount) requests")
    }
}

struct AccessoryInlineView: View {
    let data: WidgetData

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "network")

            Text(data.isCapturing ? "Capturing:" : "Captured:")

            Text("\(data.requestCount)")
                .bold()
        }
        .accessibilityLabel("Network \(data.isCapturing ? "capturing" : "captured"), \(data.requestCount) requests")
    }
}

struct StatBox: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .widgetAccentable()

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.gray.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))
    }
}

struct RequestRowCompact: View {
    let request: WidgetRequest

    var body: some View {
        HStack(spacing: 6) {
            Text(request.method)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(request.methodColor)
                .clipShape(.rect(cornerRadius: 4))
                .widgetAccentable()

            Text(request.redactedHost)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if let code = request.statusCode {
                Text("\(code)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(request.statusColor)
                    .widgetAccentable()
            }
        }
        .padding(.vertical, 2)
    }
}

struct RequestRowDetailed: View {
    let request: WidgetRequest

    var body: some View {
        HStack(spacing: 6) {
            Text(request.method)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(request.methodColor)
                .clipShape(.rect(cornerRadius: 4))
                .widgetAccentable()

            VStack(alignment: .leading, spacing: 2) {
                Text(request.redactedHost)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(request.redactedPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let code = request.statusCode {
                    Text("\(code)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(request.statusColor)
                        .widgetAccentable()
                }

                Text(request.timestamp, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
