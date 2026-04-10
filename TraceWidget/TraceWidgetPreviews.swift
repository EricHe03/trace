//
//  TraceWidgetPreviews.swift
//  TraceWidget
//
//  Created by Justin on 2026/03/06.
//

import SwiftUI
import TraceCore
import WidgetKit

// Additional preview states. Primary previews are in TraceWidgetViews.swift.

@available(iOS 17.0, *)
#Preview("Extra Large — Capturing", as: .systemExtraLarge) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(
            isCapturing: true,
            requestCount: 512,
            dataTransferred: "34.7 MB",
            recentRequests: [
                WidgetRequest(id: UUID(), method: "GET",    host: "api.github.com",    path: "/repos/org/app",      statusCode: 200, timestamp: Date().addingTimeInterval(-3)),
                WidgetRequest(id: UUID(), method: "POST",   host: "api.stripe.com",    path: "/v1/charges",          statusCode: 201, timestamp: Date().addingTimeInterval(-10)),
                WidgetRequest(id: UUID(), method: "GET",    host: "cdn.fastly.com",    path: "/assets/bundle.js",    statusCode: 304, timestamp: Date().addingTimeInterval(-22)),
                WidgetRequest(id: UUID(), method: "PUT",    host: "api.example.com",   path: "/users/42",            statusCode: 200, timestamp: Date().addingTimeInterval(-38)),
                WidgetRequest(id: UUID(), method: "DELETE", host: "api.example.com",   path: "/sessions/abc",        statusCode: 500, timestamp: Date().addingTimeInterval(-55)),
                WidgetRequest(id: UUID(), method: "PATCH",  host: "api.example.com",   path: "/profile/settings",    statusCode: 404, timestamp: Date().addingTimeInterval(-80)),
                WidgetRequest(id: UUID(), method: "GET",    host: "fonts.googleapis.com", path: "/css2?family=Inter", statusCode: 200, timestamp: Date().addingTimeInterval(-95)),
                WidgetRequest(id: UUID(), method: "POST",   host: "analytics.example.com", path: "/events",          statusCode: 201, timestamp: Date().addingTimeInterval(-110)),
            ]
        )
    )
}

@available(iOS 17.0, *)
#Preview("Accessory Inline — Idle", as: .accessoryInline) {
    TraceWidget()
} timeline: {
    TraceEntry(
        date: .now,
        configuration: ConfigurationAppIntent(),
        data: WidgetData(isCapturing: false, requestCount: 88, dataTransferred: "3.2 MB", recentRequests: [])
    )
}
