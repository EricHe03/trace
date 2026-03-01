//
//  AppGroupStorageModels.swift
//  TraceCore
//

import Foundation

public struct WidgetSharedState: Codable, Equatable, Sendable {
    public var isCapturing: Bool
    public var requestCount: Int
    public var dataTransferred: String
    public var recentRequests: [WidgetRecentRequest]

    public init(
        isCapturing: Bool = false,
        requestCount: Int = 0,
        dataTransferred: String = "0 B",
        recentRequests: [WidgetRecentRequest] = []
    ) {
        self.isCapturing = isCapturing
        self.requestCount = requestCount
        self.dataTransferred = dataTransferred
        self.recentRequests = recentRequests
    }
}

public struct WidgetPendingAction: Codable, Equatable, Sendable {
    public var action: WidgetAction
    public var actionDate: Date
    public var actionView: String?

    public init(action: WidgetAction, actionDate: Date = Date(), actionView: String? = nil) {
        self.action = action
        self.actionDate = actionDate
        self.actionView = actionView
    }
}

public struct MITMAutoBypassStoredEntry: Codable, Equatable, Sendable {
    public var host: String
    public var reason: String
    public var createdAt: Date
    public var expiresAt: Date
    public var isAlias: Bool

    public init(host: String, reason: String, createdAt: Date, expiresAt: Date, isAlias: Bool) {
        self.host = host
        self.reason = reason
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isAlias = isAlias
    }
}

public struct StorageStats {
    public let totalRequests: Int
    public let totalSize: Int64

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

// MARK: - Errors

public enum StorageError: LocalizedError, Equatable {
    case containerNotFound
    case databaseUnavailable
    case encodingFailed
    case decodingFailed
    case fileNotFound

    public var errorDescription: String? {
        switch self {
        case .containerNotFound:
            "App Group container not found. Ensure App Group is configured in entitlements."
        case .databaseUnavailable:
            "Shared GRDB database is unavailable"
        case .encodingFailed:
            "Failed to encode data"
        case .decodingFailed:
            "Failed to decode data"
        case .fileNotFound:
            "File not found"
        }
    }
}
