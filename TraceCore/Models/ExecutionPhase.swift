//
//  ExecutionPhase.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public enum ExecutionPhase: Int, Codable, CaseIterable, Sendable {
    case block = 1
    case redirect = 2
    case mock = 3
    case breakpointRequest = 4
    case scriptRequest = 5
    case rewriteRequest = 6
    case sendRequest = 7
    case scriptResponse = 8
    case rewriteResponse = 9
    case breakpointResponse = 10
}
