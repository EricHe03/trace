//
//  BreakpointPreset.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public struct BreakpointPreset: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var configuration: BreakpointConfiguration

    public init(id: UUID = UUID(), name: String, configuration: BreakpointConfiguration) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }
}
