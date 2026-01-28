//
//  TraceWidgetBundle.swift
//  TraceWidget
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import WidgetKit

/// Aggregates all Trace widgets and Live Activities.
@main
struct TraceWidgetBundle: WidgetBundle {
    var body: some Widget {
        LegacyTraceWidget()
    }
}
