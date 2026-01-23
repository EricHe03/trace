//
//  ExecutionContext.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public struct ExecutionContext: Sendable {
    public let requestId: UUID
    public var originalRequest: NetworkRequest
    public var currentRequest: NetworkRequest
    public var executionLog: [ExecutionLogEntry]
    public var appliedRules: [UUID]
    public var timings: [String: TimeInterval]
    public var errors: [ExecutionError]

    public init(request: NetworkRequest) {
        self.requestId = request.id
        self.originalRequest = request
        self.currentRequest = request
        self.executionLog = []
        self.appliedRules = []
        self.timings = [:]
        self.errors = []
    }
}

public struct ExecutionLogEntry: Codable, Sendable {
    public let timestamp: Date
    public let phase: ExecutionPhase
    public let ruleId: UUID?
    public let ruleName: String?
    public let outcome: ExecutionOutcome
    public let message: String?
    public let duration: TimeInterval
    public let diffSummary: String?

    public init(
        timestamp: Date = Date(),
        phase: ExecutionPhase,
        ruleId: UUID? = nil,
        ruleName: String? = nil,
        outcome: ExecutionOutcome,
        message: String? = nil,
        duration: TimeInterval = 0,
        diffSummary: String? = nil
    ) {
        self.timestamp = timestamp
        self.phase = phase
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.outcome = outcome
        self.message = message
        self.duration = duration
        self.diffSummary = diffSummary
    }
}

public enum ExecutionOutcome: String, Codable, Sendable {
    case matched
    case notMatched
    case applied
    case skipped
    case error
}

public struct ExecutionError: Codable, Sendable {
    public let ruleId: UUID?
    public let message: String

    public init(ruleId: UUID? = nil, message: String) {
        self.ruleId = ruleId
        self.message = message
    }
}
