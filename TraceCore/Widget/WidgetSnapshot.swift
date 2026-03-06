//
//  WidgetSnapshot.swift
//  TraceCore
//
//  Created by AI Assistant on 2026/03/06.
//

import Foundation

public struct WidgetSnapshot: Equatable, Sendable {
    public let isCapturing: Bool
    public let requestCount: Int
    public let dataTransferred: String
    public let recentRequests: [WidgetSnapshotRequest]

    public init(
        isCapturing: Bool,
        requestCount: Int,
        dataTransferred: String,
        recentRequests: [WidgetSnapshotRequest]
    ) {
        self.isCapturing = isCapturing
        self.requestCount = requestCount
        self.dataTransferred = dataTransferred
        self.recentRequests = recentRequests
    }

    public init(state: WidgetSharedState) {
        self.init(
            isCapturing: state.isCapturing,
            requestCount: state.requestCount,
            dataTransferred: state.dataTransferred,
            recentRequests: state.recentRequests.map(WidgetSnapshotRequest.init)
        )
    }

    public static var placeholder: WidgetSnapshot {
        WidgetSnapshot(
            isCapturing: false,
            requestCount: 88,
            dataTransferred: "1.2 MB",
            recentRequests: [
                WidgetSnapshotRequest(
                    id: UUID(),
                    method: "GET",
                    host: "api.example.com",
                    path: "/users",
                    statusCode: 200,
                    timestamp: Date()
                ),
                WidgetSnapshotRequest(
                    id: UUID(),
                    method: "POST",
                    host: "api.example.com",
                    path: "/data",
                    statusCode: 201,
                    timestamp: Date()
                )
            ]
        )
    }
}

public struct WidgetSnapshotRequest: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let method: String
    public let host: String
    public let path: String
    public let statusCode: Int?
    public let timestamp: Date

    public init(
        id: UUID,
        method: String,
        host: String,
        path: String,
        statusCode: Int?,
        timestamp: Date
    ) {
        self.id = id
        self.method = method
        self.host = host
        self.path = path
        self.statusCode = statusCode
        self.timestamp = timestamp
    }

    public init(_ request: WidgetRecentRequest) {
        let url = URL(string: request.url)
        self.init(
            id: request.id,
            method: request.method,
            host: url?.host ?? request.url,
            path: url?.path ?? "/",
            statusCode: request.statusCode,
            timestamp: request.timestamp
        )
    }
}
