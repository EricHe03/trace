//
//  TraceWidgetPreviews.swift
//  TraceWidget
//
//  Created by AI Assistant on 2026/03/06.
//

import SwiftUI
import TraceCore
import WidgetKit

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
