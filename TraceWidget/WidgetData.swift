//
//  WidgetData.swift
//  TraceWidget
//
//  Created by AI Assistant on 2026/03/06.
//

import SwiftUI
import TraceCore

typealias WidgetData = WidgetSnapshot
typealias WidgetRequest = WidgetSnapshotRequest

extension WidgetSnapshotRequest {
    var statusColor: Color {
        guard let code = statusCode else { return Color.gray }
        switch code {
        case 200 ..< 300:
            return Color.green
        case 300 ..< 400:
            return Color.blue
        case 400 ..< 500:
            return Color.orange
        case 500 ..< 600:
            return Color.red
        default:
            return Color.gray
        }
    }

    var methodColor: Color {
        switch method {
        case "GET":
            Color.green
        case "POST":
            Color.blue
        case "PUT":
            Color.yellow
        case "DELETE":
            Color.red
        case "PATCH":
            Color.orange
        default:
            Color.gray
        }
    }

    var redactedHost: String {
        "Endpoint hidden"
    }

    var redactedPath: String {
        "Path hidden"
    }
}
