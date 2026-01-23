//
//  Profile.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var description: String?
    public var ruleGroups: [UUID]
    public var isActive: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        ruleGroups: [UUID] = [],
        isActive: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.ruleGroups = ruleGroups
        self.isActive = isActive
        self.createdAt = createdAt
    }
}
