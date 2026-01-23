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
        TraceWidget()
        if #available(iOS 18.0, *) {
            TraceWidgetControl()
        }

        if #available(iOS 16.1, *) {
            TraceWidgetLiveActivity()
        }
    }
}
