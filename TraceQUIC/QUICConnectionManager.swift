//
//  QUICConnectionManager.swift
//  TraceQUIC
//
//  Created by Justin on 2026/02/18.
//

import Foundation

public struct QUICConnectionState: Sendable {
    public let activeConnections: Int
    public let totalInterceptAttempts: UInt64
    public let totalPassThroughFallbacks: UInt64
    public let totalFailures: UInt64
    public let quicFlowsSeenTotal: UInt64
    public let quicFlowsInterceptedTotal: UInt64
    public let quicFlowsPassThroughTotal: UInt64
    public let quicFlowsBlockedTotal: UInt64
    public let quicFlowsTunnelForwardedTotal: UInt64
    public let quicMitmFailuresTotal: UInt64
    public let quicMitmFailuresByReason: [String: UInt64]
    public let http3RequestsCapturedTotal: UInt64
    public let http3SSEStreamsCapturedTotal: UInt64
    public let recentFallbackReasons: [String]

    public init(
        activeConnections: Int,
        totalInterceptAttempts: UInt64,
        totalPassThroughFallbacks: UInt64,
        totalFailures: UInt64,
        quicFlowsSeenTotal: UInt64,
        quicFlowsInterceptedTotal: UInt64,
        quicFlowsPassThroughTotal: UInt64,
        quicFlowsBlockedTotal: UInt64,
        quicFlowsTunnelForwardedTotal: UInt64,
        quicMitmFailuresTotal: UInt64,
        quicMitmFailuresByReason: [String: UInt64],
        http3RequestsCapturedTotal: UInt64,
        http3SSEStreamsCapturedTotal: UInt64,
        recentFallbackReasons: [String]
    ) {
        self.activeConnections = activeConnections
        self.totalInterceptAttempts = totalInterceptAttempts
        self.totalPassThroughFallbacks = totalPassThroughFallbacks
        self.totalFailures = totalFailures
        self.quicFlowsSeenTotal = quicFlowsSeenTotal
        self.quicFlowsInterceptedTotal = quicFlowsInterceptedTotal
        self.quicFlowsPassThroughTotal = quicFlowsPassThroughTotal
        self.quicFlowsBlockedTotal = quicFlowsBlockedTotal
        self.quicFlowsTunnelForwardedTotal = quicFlowsTunnelForwardedTotal
        self.quicMitmFailuresTotal = quicMitmFailuresTotal
        self.quicMitmFailuresByReason = quicMitmFailuresByReason
        self.http3RequestsCapturedTotal = http3RequestsCapturedTotal
        self.http3SSEStreamsCapturedTotal = http3SSEStreamsCapturedTotal
        self.recentFallbackReasons = recentFallbackReasons
    }
}

public actor QUICConnectionManager {
    public static let shared = QUICConnectionManager()

    private var activeConnectionIDs: Set<UUID> = []
    private var totalInterceptAttempts: UInt64 = 0
    private var totalPassThroughFallbacks: UInt64 = 0
    private var totalFailures: UInt64 = 0
    private var quicFlowsSeenTotal: UInt64 = 0
    private var quicFlowsInterceptedTotal: UInt64 = 0
    private var quicFlowsPassThroughTotal: UInt64 = 0
    private var quicFlowsBlockedTotal: UInt64 = 0
    private var quicFlowsTunnelForwardedTotal: UInt64 = 0
    private var quicMitmFailuresTotal: UInt64 = 0
    private var quicMitmFailuresByReason: [String: UInt64] = [:]
    private var http3RequestsCapturedTotal: UInt64 = 0
    private var http3SSEStreamsCapturedTotal: UInt64 = 0
    private var recentFallbackReasons: [String] = []
    private let maxRecentFallbackReasons = 10

    public init() {}

    @discardableResult
    public func openConnectionAttempt() -> UUID {
        let id = UUID()
        activeConnectionIDs.insert(id)
        totalInterceptAttempts &+= 1
        return id
    }

    public func closeConnection(_ id: UUID) {
        activeConnectionIDs.remove(id)
    }

    public func recordFlowSeen() {
        quicFlowsSeenTotal &+= 1
    }

    public func recordIntercepted() {
        quicFlowsInterceptedTotal &+= 1
    }

    public func recordBlocked() {
        quicFlowsBlockedTotal &+= 1
    }

    public func recordTunnelForwarded() {
        quicFlowsTunnelForwardedTotal &+= 1
    }

    public func recordPolicyPassThrough(reason _: String = "unknown") {
        quicFlowsPassThroughTotal &+= 1
    }

    public func recordBatch(
        flowSeen: UInt64 = 0,
        blocked: UInt64 = 0,
        tunnelForwarded: UInt64 = 0,
        policyPassThrough: UInt64 = 0
    ) {
        if flowSeen > 0 {
            quicFlowsSeenTotal &+= flowSeen
        }
        if blocked > 0 {
            quicFlowsBlockedTotal &+= blocked
        }
        if tunnelForwarded > 0 {
            quicFlowsTunnelForwardedTotal &+= tunnelForwarded
        }
        if policyPassThrough > 0 {
            quicFlowsPassThroughTotal &+= policyPassThrough
        }
    }

    public func recordPassThroughFallback(reason: String = "unknown") {
        totalPassThroughFallbacks &+= 1
        quicFlowsPassThroughTotal &+= 1
        quicMitmFailuresTotal &+= 1
        recordFailureReason(reason)
    }

    public func recordFailure(reason: String? = nil) {
        totalFailures &+= 1
        quicMitmFailuresTotal &+= 1
        if let reason {
            recordFailureReason(reason)
        }
    }

    public func recordHTTP3RequestCaptured(isSSE: Bool) {
        http3RequestsCapturedTotal &+= 1
        if isSSE {
            http3SSEStreamsCapturedTotal &+= 1
        }
    }

    public func snapshot() -> QUICConnectionState {
        QUICConnectionState(
            activeConnections: activeConnectionIDs.count,
            totalInterceptAttempts: totalInterceptAttempts,
            totalPassThroughFallbacks: totalPassThroughFallbacks,
            totalFailures: totalFailures,
            quicFlowsSeenTotal: quicFlowsSeenTotal,
            quicFlowsInterceptedTotal: quicFlowsInterceptedTotal,
            quicFlowsPassThroughTotal: quicFlowsPassThroughTotal,
            quicFlowsBlockedTotal: quicFlowsBlockedTotal,
            quicFlowsTunnelForwardedTotal: quicFlowsTunnelForwardedTotal,
            quicMitmFailuresTotal: quicMitmFailuresTotal,
            quicMitmFailuresByReason: quicMitmFailuresByReason,
            http3RequestsCapturedTotal: http3RequestsCapturedTotal,
            http3SSEStreamsCapturedTotal: http3SSEStreamsCapturedTotal,
            recentFallbackReasons: recentFallbackReasons
        )
    }

    private func recordFailureReason(_ reason: String) {
        quicMitmFailuresByReason[reason, default: 0] &+= 1
        recentFallbackReasons.append(reason)
        if recentFallbackReasons.count > maxRecentFallbackReasons {
            recentFallbackReasons.removeFirst(recentFallbackReasons.count - maxRecentFallbackReasons)
        }
    }
}
