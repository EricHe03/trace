//
//  BreakpointActionDefinition.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public struct BreakpointActionDefinition: Codable, Sendable {
    public var actionType: BreakpointActionType
    public var parameters: [String: String]

    public init(actionType: BreakpointActionType, parameters: [String: String] = [:]) {
        self.actionType = actionType
        self.parameters = parameters
    }
}

public enum BreakpointActionType: String, Codable, Sendable {
    case pause
    case log
    case alert
    case autoModify
    case repeatRequest
}
