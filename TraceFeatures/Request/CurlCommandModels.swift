//
//  CurlCommandModels.swift
//  TraceFeatures
//
//  Created by Codex on 2026/02/07.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

public enum CurlDiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case error

    public var isBlocking: Bool {
        self == .error
    }
}

public struct CurlDiagnostic: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let severity: CurlDiagnosticSeverity
    public let option: String?
    public let message: String

    public init(
        id: UUID = UUID(),
        severity: CurlDiagnosticSeverity,
        option: String? = nil,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.option = option
        self.message = message
    }

    public var asExecutionDiagnostic: CurlExecutionDiagnostic {
        CurlExecutionDiagnostic(severity: severity.rawValue, option: option, message: message)
    }
}

public struct CurlCommandTransferPlan: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case command
        case argv
        case urls
        case effectiveOptions
    }

    public let id: UUID
    public let index: Int
    public let command: String
    /// Tokenized argv payload (without the leading `curl`) used by runtime execution.
    public let argv: [String]
    public let urls: [String]
    public let effectiveOptions: [String: [String]]

    public init(
        id: UUID = UUID(),
        index: Int,
        command: String,
        argv: [String] = [],
        urls: [String],
        effectiveOptions: [String: [String]] = [:]
    ) {
        self.id = id
        self.index = index
        self.command = command
        self.argv = argv
        self.urls = urls
        self.effectiveOptions = effectiveOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        index = try container.decode(Int.self, forKey: .index)
        command = try container.decode(String.self, forKey: .command)
        argv = try container.decodeIfPresent([String].self, forKey: .argv) ?? []
        urls = try container.decode([String].self, forKey: .urls)
        effectiveOptions = try container.decode([String: [String]].self, forKey: .effectiveOptions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(index, forKey: .index)
        try container.encode(command, forKey: .command)
        if !argv.isEmpty {
            try container.encode(argv, forKey: .argv)
        }
        try container.encode(urls, forKey: .urls)
        try container.encode(effectiveOptions, forKey: .effectiveOptions)
    }
}

public struct CurlCommandPlan: Codable, Equatable, Sendable {
    public let originalCommand: String
    public let normalizedCommand: String
    public let argv: [String]
    public let transfers: [CurlCommandTransferPlan]
    public let diagnostics: [CurlDiagnostic]

    public init(
        originalCommand: String,
        normalizedCommand: String,
        argv: [String],
        transfers: [CurlCommandTransferPlan],
        diagnostics: [CurlDiagnostic]
    ) {
        self.originalCommand = originalCommand
        self.normalizedCommand = normalizedCommand
        self.argv = argv
        self.transfers = transfers
        self.diagnostics = diagnostics
    }

    public var blockingDiagnostics: [CurlDiagnostic] {
        diagnostics.filter(\.severity.isBlocking)
    }

    public var hasBlockingDiagnostics: Bool {
        !blockingDiagnostics.isEmpty
    }
}

public struct CurlTransferExecution: Identifiable, Sendable {
    public let id: UUID
    public let transfer: CurlCommandTransferPlan
    public let request: NetworkRequest?
    public let errorMessage: String?
    public let diagnostics: [CurlDiagnostic]

    public init(
        id: UUID = UUID(),
        transfer: CurlCommandTransferPlan,
        request: NetworkRequest?,
        errorMessage: String? = nil,
        diagnostics: [CurlDiagnostic] = []
    ) {
        self.id = id
        self.transfer = transfer
        self.request = request
        self.errorMessage = errorMessage
        self.diagnostics = diagnostics
    }

    public var succeeded: Bool {
        request != nil && errorMessage == nil
    }
}

public struct CurlExecutionResult: Sendable {
    public let plan: CurlCommandPlan
    public let transfers: [CurlTransferExecution]
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        plan: CurlCommandPlan,
        transfers: [CurlTransferExecution],
        startedAt: Date,
        finishedAt: Date
    ) {
        self.plan = plan
        self.transfers = transfers
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var succeededCount: Int {
        transfers.count(where: { $0.succeeded })
    }

    public var failedCount: Int {
        transfers.count - succeededCount
    }

    public var allDiagnostics: [CurlDiagnostic] {
        plan.diagnostics + transfers.flatMap(\.diagnostics)
    }
}
