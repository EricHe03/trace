//
//  QUICFlowMetadata.swift
//  TraceCore
//
//  Created by Codex on 2026/02/18.
//

import Foundation

public enum QUICHandshakeOutcome: String, Codable, Sendable {
    case negotiated
    case failed
    case passThrough
    case blocked
}

public enum QUICInspectionOutcome: String, Codable, Sendable {
    case intercepted
    case passThroughMarked
    case blocked
    case tunnelForwarded
}

public extension QUICHandshakeOutcome {
    var displayName: String {
        switch self {
        case .negotiated:
            "Negotiated"
        case .failed:
            "Failed"
        case .passThrough:
            "Pass Through"
        case .blocked:
            "Blocked"
        }
    }
}

public extension QUICInspectionOutcome {
    var displayName: String {
        switch self {
        case .intercepted:
            "Intercepted"
        case .passThroughMarked:
            "Pass Through (Marked)"
        case .blocked:
            "Blocked"
        case .tunnelForwarded:
            "Tunnel Forwarded"
        }
    }
}

public struct QUICFlowMetadata: Codable, Equatable, Sendable {
    public let version: String?
    public let alpn: String?
    public let sniHash: String?
    public let sourceConnectionIDLength: Int?
    public let destinationConnectionIDLength: Int?
    public let handshakeOutcome: QUICHandshakeOutcome
    public let failureReason: String?
    public let capturedAt: Date

    public init(
        version: String? = nil,
        alpn: String? = nil,
        sniHash: String? = nil,
        sourceConnectionIDLength: Int? = nil,
        destinationConnectionIDLength: Int? = nil,
        handshakeOutcome: QUICHandshakeOutcome,
        failureReason: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.version = version
        self.alpn = alpn
        self.sniHash = sniHash
        self.sourceConnectionIDLength = sourceConnectionIDLength
        self.destinationConnectionIDLength = destinationConnectionIDLength
        self.handshakeOutcome = handshakeOutcome
        self.failureReason = failureReason
        self.capturedAt = capturedAt
    }
}
