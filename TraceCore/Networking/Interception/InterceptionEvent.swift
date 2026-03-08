//
//  InterceptionEvent.swift
//  TraceCore
//
//  Created by Justin on 2026/02/24.
//

import Foundation

public enum InterceptionEventType: String, Codable, Sendable {
    case flowStart = "flow_start"
    case flowRouteDecision = "flow_route_decision"
    case mitmAttemptStart = "mitm_attempt_start"
    case mitmEstablished = "mitm_established"
    case mitmFailure = "mitm_failure"
    case failoverDecision = "failover_decision"
    case bypassRecorded = "bypass_recorded"
    case breakerTrip = "breaker_trip"
    case breakerRecover = "breaker_recover"
    case quicFailOpenActivated = "quic_fail_open_activated"
    case quicFailOpenExpired = "quic_fail_open_expired"
    case reconfigBegin = "reconfig_begin"
    case reconfigCommit = "reconfig_commit"
    case reconfigRollback = "reconfig_rollback"
    case strictViolationDetected = "strict_violation_detected"
    case policyMismatch = "policy_mismatch"
}

public enum InterceptionAction: String, Codable, Sendable {
    case mitm
    case passThrough
    case direct
    case block
    case retry
    case noop
}

public struct InterceptionFailurePayload: Codable, Sendable, Equatable {
    public var token: String
    public var failure: InterceptionFailure

    public init(token: String, failure: InterceptionFailure) {
        self.token = token
        self.failure = failure
    }
}

public struct BreakerStatePayload: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var isDegraded: Bool
    public var reason: String?
    public var degradedUntilMs: Int64?

    public init(
        enabled: Bool,
        isDegraded: Bool,
        reason: String? = nil,
        degradedUntilMs: Int64? = nil
    ) {
        self.enabled = enabled
        self.isDegraded = isDegraded
        self.reason = reason
        self.degradedUntilMs = degradedUntilMs
    }
}

public struct BypassPayload: Codable, Sendable, Equatable {
    public var domain: HostBypassDomain
    public var reason: BypassReason
    public var ttlSeconds: Int?

    public init(domain: HostBypassDomain, reason: BypassReason, ttlSeconds: Int? = nil) {
        self.domain = domain
        self.reason = reason
        self.ttlSeconds = ttlSeconds
    }
}

public struct QuicFailOpenPayload: Codable, Sendable, Equatable {
    public var hostHash: String?
    public var ttlSeconds: Int?
    public var reason: String?

    public init(hostHash: String? = nil, ttlSeconds: Int? = nil, reason: String? = nil) {
        self.hostHash = hostHash
        self.ttlSeconds = ttlSeconds
        self.reason = reason
    }
}

public struct BuildInfoPayload: Codable, Sendable, Equatable {
    public var appVersion: String
    public var buildNumber: String
    public var platform: String

    public init(
        appVersion: String = "unknown",
        buildNumber: String = "unknown",
        platform: String = "ios"
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.platform = platform
    }
}

public struct InterceptionEvent: Codable, Sendable {
    public var type: InterceptionEventType
    public var timestampMs: Int64
    public var sessionID: String
    public var tunnelGeneration: Int
    public var flowID: UInt64?

    public var captureMode: String
    public var dualMITMPolicy: String
    public var protocolName: String

    public var destinationHost: String?
    public var destinationHostHash: String?
    public var destinationPort: Int?

    public var action: InterceptionAction?
    public var decisionReason: String?
    public var failure: InterceptionFailurePayload?

    public var breakerState: BreakerStatePayload?
    public var bypass: BypassPayload?
    public var quicFailOpen: QuicFailOpenPayload?

    public var durationsMs: [String: Int]?
    public var counters: [String: Int]?

    public var legacyToken: String?
    public var build: BuildInfoPayload

    public init(
        type: InterceptionEventType,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        sessionID: String,
        tunnelGeneration: Int,
        flowID: UInt64? = nil,
        captureMode: String,
        dualMITMPolicy: String,
        protocolName: String,
        destinationHost: String? = nil,
        destinationHostHash: String? = nil,
        destinationPort: Int? = nil,
        action: InterceptionAction? = nil,
        decisionReason: String? = nil,
        failure: InterceptionFailurePayload? = nil,
        breakerState: BreakerStatePayload? = nil,
        bypass: BypassPayload? = nil,
        quicFailOpen: QuicFailOpenPayload? = nil,
        durationsMs: [String: Int]? = nil,
        counters: [String: Int]? = nil,
        legacyToken: String? = nil,
        build: BuildInfoPayload = BuildInfoPayload()
    ) {
        self.type = type
        self.timestampMs = timestampMs
        self.sessionID = sessionID
        self.tunnelGeneration = tunnelGeneration
        self.flowID = flowID
        self.captureMode = captureMode
        self.dualMITMPolicy = dualMITMPolicy
        self.protocolName = protocolName
        self.destinationHost = destinationHost
        self.destinationHostHash = destinationHostHash
        self.destinationPort = destinationPort
        self.action = action
        self.decisionReason = decisionReason
        self.failure = failure
        self.breakerState = breakerState
        self.bypass = bypass
        self.quicFailOpen = quicFailOpen
        self.durationsMs = durationsMs
        self.counters = counters
        self.legacyToken = legacyToken
        self.build = build
    }
}
