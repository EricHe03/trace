//
//  RulePack.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public struct RulePack: Codable, Sendable {
    public var metadata: RulePackMetadata
    public var rules: [RewriteRule]
    public var groups: [RuleGroup]

    public init(metadata: RulePackMetadata, rules: [RewriteRule], groups: [RuleGroup]) {
        self.metadata = metadata
        self.rules = rules
        self.groups = groups
    }
}

public struct RulePackMetadata: Codable, Sendable {
    public var name: String
    public var version: String
    public var author: String
    public var description: String
    public var createdAt: Date

    public init(
        name: String,
        version: String,
        author: String,
        description: String,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.createdAt = createdAt
    }
}

public enum MergeStrategy: String, Codable, Sendable {
    case replace
    case merge
    case ask
}
