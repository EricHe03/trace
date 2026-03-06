//
//  InterceptionMetrics.swift
//  TraceProxy
//
//  Created by OpenAI Codex on 2026/03/06.
//

import Foundation

public struct InterceptionMetrics: Sendable {
    public var totalRequests: Int = 0
    public var totalResponses: Int = 0
    public var blockedCount: Int = 0
    public var redirectedCount: Int = 0
    public var mockedCount: Int = 0
    public var breakpointHits: Int = 0
    public var scriptFailures: Int = 0
    public var redirectLoopsPrevented: Int = 0

    public var blockCheckTimeNs: UInt64 = 0
    public var redirectCheckTimeNs: UInt64 = 0
    public var mockCheckTimeNs: UInt64 = 0
    public var ruleApplicationTimeNs: UInt64 = 0
    public var scriptExecutionTimeNs: UInt64 = 0
    public var breakpointTimeNs: UInt64 = 0

    public var configReloadCount: Int = 0
    public var lastConfigReload: Date?
}
