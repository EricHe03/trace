//
//  WidgetModels.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

public enum WidgetActionKey {
    public static let action = "widget.action"
    public static let actionDate = "widget.actionDate"
    public static let actionView = "widget.actionView"
}

public enum WidgetAction: String, Codable, Equatable, Sendable {
    case toggleCapture
    case startCapture
    case stopCapture
    case clearRequests
    case openView
}

public struct WidgetRecentRequest: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let method: String
    public let url: String
    public let statusCode: Int?
    public let timestamp: Date

    public init(from request: NetworkRequest) {
        self.id = request.id
        self.method = request.method.rawValue
        self.url = request.url
        self.statusCode = request.statusCode
        self.timestamp = request.timestamp
    }
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
public struct TraceWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var requestCount: Int
        public var dataTransferred: String
        public var captureStartTime: Date
        public var lastRequestTime: Date?
        public var lastRequestMethod: String?
        public var lastRequestHost: String?
        public var lastRequestStatus: Int?

        public init(
            requestCount: Int,
            dataTransferred: String,
            captureStartTime: Date,
            lastRequestTime: Date?,
            lastRequestMethod: String?,
            lastRequestHost: String?,
            lastRequestStatus: Int?
        ) {
            self.requestCount = requestCount
            self.dataTransferred = dataTransferred
            self.captureStartTime = captureStartTime
            self.lastRequestTime = lastRequestTime
            self.lastRequestMethod = lastRequestMethod
            self.lastRequestHost = lastRequestHost
            self.lastRequestStatus = lastRequestStatus
        }
    }

    public var sessionId: UUID

    public init(sessionId: UUID) {
        self.sessionId = sessionId
    }
}
#endif
