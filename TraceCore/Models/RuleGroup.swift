//
//  RuleGroup.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public struct RuleGroup: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var rules: [UUID]
    public var priority: Int
    public var failurePolicy: FailurePolicy
    public var description: String?

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        rules: [UUID] = [],
        priority: Int = 0,
        failurePolicy: FailurePolicy = .failOpen,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.rules = rules
        self.priority = priority
        self.failurePolicy = failurePolicy
        self.description = description
    }
}

public enum FailurePolicy: String, Codable, Sendable {
    case failOpen
    case failClosed
    case failMock
}

extension RuleGroup: Toggleable {}
