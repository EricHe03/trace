//
//  TraceWidget.swift
//  TraceWidget
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import WidgetKit

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
