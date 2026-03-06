//
//  WidgetProviders.swift
//  TraceWidget
//
//  Created by AI Assistant on 2026/03/06.
//

import SwiftUI
import TraceCore
import WidgetKit

private func nextUpdateDate(for data: WidgetData, from currentDate: Date) -> Date {
    let updateInterval: TimeInterval = data.isCapturing ? 30 : 300
    return Calendar.current.date(
        byAdding: data.isCapturing ? .second : .minute,
        value: data.isCapturing ? 30 : 5,
        to: currentDate
    ) ?? currentDate.addingTimeInterval(updateInterval)
}

private func fetchWidgetData() -> WidgetData {
    WidgetData(state: AppGroupStorage.shared.loadWidgetState())
}

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

    @available(iOS 17.0, iOSApplicationExtension 17.0, *)
    func recommendations() -> [AppIntentRecommendation<ConfigurationAppIntent>] {
        let data = fetchWidgetData()

        if data.isCapturing {
            return [
                AppIntentRecommendation(
                    intent: ConfigurationAppIntent(),
                    description: "Monitor active network traffic capture"
                )
            ]
        }

        return [
            AppIntentRecommendation(
                intent: ConfigurationAppIntent(),
                description: "View network capture status"
            )
        ]
    }
}

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

struct TraceEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let data: WidgetData
}

struct LegacyProvider: TimelineProvider {
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
