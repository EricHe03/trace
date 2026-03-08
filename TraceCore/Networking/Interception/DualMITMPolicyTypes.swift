//
//  DualMITMPolicyTypes.swift
//  TraceCore
//
//  Created by Justin on 2026/02/24.
//

import Foundation

public struct DualMITMPolicyFeatureFlags: Sendable, Codable, Equatable {
    public var shadowEnabled: Bool
    public var enforceTCPRouting: Bool
    public var enforceProxyRouting: Bool
    public var enforceQUICRouting: Bool
    public var http2MITMEnabled: Bool
    public var strictEnforcementHardFail: Bool

    public init(
        shadowEnabled: Bool,
        enforceTCPRouting: Bool,
        enforceProxyRouting: Bool = false,
        enforceQUICRouting: Bool = false,
        http2MITMEnabled: Bool = false,
        strictEnforcementHardFail: Bool = true
    ) {
        self.shadowEnabled = shadowEnabled
        self.enforceTCPRouting = enforceTCPRouting
        self.enforceProxyRouting = enforceProxyRouting
        self.enforceQUICRouting = enforceQUICRouting
        self.http2MITMEnabled = http2MITMEnabled
        self.strictEnforcementHardFail = strictEnforcementHardFail
    }

    public static var defaults: DualMITMPolicyFeatureFlags {
        DualMITMPolicyFeatureFlags(
            shadowEnabled: true,
            enforceTCPRouting: true,
            enforceProxyRouting: true,
            enforceQUICRouting: true,
            http2MITMEnabled: true,
            strictEnforcementHardFail: true
        )
    }
}

public struct QUICNoProgressConfig: Sendable, Codable, Equatable {
    public var graceMs: Int
    public var idleMs: Int
    public var absoluteMs: Int
    public var minimumClientDatagrams: Int

    public init(
        graceMs: Int = 6000,
        idleMs: Int = 6000,
        absoluteMs: Int = 20000,
        minimumClientDatagrams: Int = 6
    ) {
        self.graceMs = max(0, graceMs)
        self.idleMs = max(0, idleMs)
        self.absoluteMs = max(0, absoluteMs)
        self.minimumClientDatagrams = max(1, minimumClientDatagrams)
    }
}

public struct DualMITMPolicySnapshot: Sendable, Equatable {
    public var tcpTransparentMITMEnabled: Bool
    public var tcpInterceptPorts: Set<UInt16>
    public var mitmProxyHost: String
    public var mitmProxyPort: UInt16
    public var policyMode: DualMITMPolicy
    public var circuitBreakerEnabled: Bool
    public var tcpBypassTTLSeconds: Int
    public var quicHostFailOpenSeconds: Int
    public var quicNoProgress: QUICNoProgressConfig
    public var quicAuthorityRetryAttempts: Int
    public var quicCertMaterialCacheTTLSeconds: Int
    public var allowlist: [String]
    public var mitmEnabled: Bool
    public var quicHandlingMode: QUICHandlingMode
    public var featureFlags: DualMITMPolicyFeatureFlags

    public init(
        tcpTransparentMITMEnabled: Bool,
        tcpInterceptPorts: Set<UInt16>,
        mitmProxyHost: String,
        mitmProxyPort: UInt16,
        policyMode: DualMITMPolicy,
        circuitBreakerEnabled: Bool,
        tcpBypassTTLSeconds: Int = 180,
        quicHostFailOpenSeconds: Int = 1800,
        quicNoProgress: QUICNoProgressConfig = QUICNoProgressConfig(),
        quicAuthorityRetryAttempts: Int = 1,
        quicCertMaterialCacheTTLSeconds: Int = 1800,
        allowlist: [String] = ["*"],
        mitmEnabled: Bool = true,
        quicHandlingMode: QUICHandlingMode = .intercept,
        featureFlags: DualMITMPolicyFeatureFlags = .defaults
    ) {
        self.tcpTransparentMITMEnabled = tcpTransparentMITMEnabled
        self.tcpInterceptPorts = tcpInterceptPorts
        self.mitmProxyHost = mitmProxyHost
        self.mitmProxyPort = mitmProxyPort
        self.policyMode = policyMode
        self.circuitBreakerEnabled = circuitBreakerEnabled
        self.tcpBypassTTLSeconds = max(30, tcpBypassTTLSeconds)
        self.quicHostFailOpenSeconds = max(60, quicHostFailOpenSeconds)
        self.quicNoProgress = quicNoProgress
        self.quicAuthorityRetryAttempts = max(0, quicAuthorityRetryAttempts)
        self.quicCertMaterialCacheTTLSeconds = max(60, quicCertMaterialCacheTTLSeconds)
        self.allowlist = allowlist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        self.mitmEnabled = mitmEnabled
        self.quicHandlingMode = quicHandlingMode
        self.featureFlags = featureFlags
    }

    public var isStrict: Bool {
        policyMode == .strictMITM
    }
}

public struct DualMITMFlowMetadata: Sendable, Equatable {
    public var flowID: UInt64?
    public var sessionID: String?
    public var tunnelGeneration: Int?

    public init(flowID: UInt64? = nil, sessionID: String? = nil, tunnelGeneration: Int? = nil) {
        self.flowID = flowID
        self.sessionID = sessionID
        self.tunnelGeneration = tunnelGeneration
    }
}

public struct FlowPolicyProfile: Sendable, Equatable {
    public var snapshot: DualMITMPolicySnapshot
    public var protocolName: InterceptionProtocol
    public var destination: HostPort
    public var flowID: UInt64?
    public var startedAt: Date
    public var isMITMEligible: Bool

    public init(
        snapshot: DualMITMPolicySnapshot,
        protocolName: InterceptionProtocol,
        destination: HostPort,
        flowID: UInt64? = nil,
        startedAt: Date = Date(),
        isMITMEligible: Bool
    ) {
        self.snapshot = snapshot
        self.protocolName = protocolName
        self.destination = destination
        self.flowID = flowID
        self.startedAt = startedAt
        self.isMITMEligible = isMITMEligible
    }
}

public enum DualMITMRouteAction: Sendable, Equatable {
    case mitm(reason: String = "default")
    case passThrough(reason: String)
    case direct(reason: String)
    case block(reason: String)
}

public struct FlowStartPlan: Sendable, Equatable {
    public var profile: FlowPolicyProfile
    public var action: DualMITMRouteAction
    public var shadowEnabled: Bool
    public var enforced: Bool

    public init(
        profile: FlowPolicyProfile,
        action: DualMITMRouteAction,
        shadowEnabled: Bool,
        enforced: Bool
    ) {
        self.profile = profile
        self.action = action
        self.shadowEnabled = shadowEnabled
        self.enforced = enforced
    }
}

public enum FailureOutcomeAction: Sendable, Equatable {
    case failOpenPassThrough(reason: String)
    case failOpenDirect(reason: String)
    case failClosedBlock(reason: String)
    case retry(reason: String)
    case noop
}

public struct FailurePlan: Sendable, Equatable {
    public var action: FailureOutcomeAction
    public var bypassDomain: HostBypassDomain?
    public var bypassReason: BypassReason?
    public var bypassTTLSeconds: Int?
    public var recordBreakerFailure: Bool
    public var shadowEnabled: Bool
    public var enforced: Bool

    public init(
        action: FailureOutcomeAction,
        bypassDomain: HostBypassDomain? = nil,
        bypassReason: BypassReason? = nil,
        bypassTTLSeconds: Int? = nil,
        recordBreakerFailure: Bool = false,
        shadowEnabled: Bool,
        enforced: Bool
    ) {
        self.action = action
        self.bypassDomain = bypassDomain
        self.bypassReason = bypassReason
        self.bypassTTLSeconds = bypassTTLSeconds
        self.recordBreakerFailure = recordBreakerFailure
        self.shadowEnabled = shadowEnabled
        self.enforced = enforced
    }
}

public struct SuccessDetails: Sendable, Equatable {
    public var establishedMITM: Bool
    public var durationMs: Int?

    public init(establishedMITM: Bool, durationMs: Int? = nil) {
        self.establishedMITM = establishedMITM
        self.durationMs = durationMs
    }
}

public enum DualMITMTCPRouteDecision: Sendable, Equatable {
    case mitm
    case direct(reason: String)
}

public struct DualMITMTCPFlowStartPlan: Sendable, Equatable {
    public let decision: DualMITMTCPRouteDecision
    public let shadowEnabled: Bool
    public let enforceTCPRouting: Bool

    public init(
        decision: DualMITMTCPRouteDecision,
        shadowEnabled: Bool,
        enforceTCPRouting: Bool
    ) {
        self.decision = decision
        self.shadowEnabled = shadowEnabled
        self.enforceTCPRouting = enforceTCPRouting
    }
}

public struct DualMITMTCPBypassLookupResult: Sendable, Equatable {
    public var shouldBypass: Bool
    public var reason: String?

    public init(
        shouldBypass: Bool,
        reason: String?
    ) {
        self.shouldBypass = shouldBypass
        self.reason = reason
    }

    public static let none = DualMITMTCPBypassLookupResult(
        shouldBypass: false,
        reason: nil
    )
}

public enum DualMITMProxyRouteDecision: Sendable, Equatable {
    case mitm
    case passThrough(reason: String)
    case block(reason: String)
}

public struct DualMITMProxyFlowStartPlan: Sendable, Equatable {
    public let decision: DualMITMProxyRouteDecision
    public let shadowEnabled: Bool
    public let enforceProxyRouting: Bool

    public init(
        decision: DualMITMProxyRouteDecision,
        shadowEnabled: Bool,
        enforceProxyRouting: Bool
    ) {
        self.decision = decision
        self.shadowEnabled = shadowEnabled
        self.enforceProxyRouting = enforceProxyRouting
    }
}

public enum DualMITMProxyFailureAction: Sendable, Equatable {
    case failOpenPassThrough(reason: String)
    case failClosedBlock(reason: String)
}

public struct DualMITMProxyFailurePlan: Sendable, Equatable {
    public let action: DualMITMProxyFailureAction
    public let shadowEnabled: Bool
    public let enforceProxyRouting: Bool

    public init(
        action: DualMITMProxyFailureAction,
        shadowEnabled: Bool,
        enforceProxyRouting: Bool
    ) {
        self.action = action
        self.shadowEnabled = shadowEnabled
        self.enforceProxyRouting = enforceProxyRouting
    }
}

public enum DualMITMQUICFailureAction: Sendable, Equatable {
    case passThrough(reason: String)
    case block(reason: String)
}

public struct DualMITMQUICFailurePlan: Sendable, Equatable {
    public let action: DualMITMQUICFailureAction
    public let shadowEnabled: Bool
    public let enforceQUICRouting: Bool

    public init(
        action: DualMITMQUICFailureAction,
        shadowEnabled: Bool,
        enforceQUICRouting: Bool
    ) {
        self.action = action
        self.shadowEnabled = shadowEnabled
        self.enforceQUICRouting = enforceQUICRouting
    }
}

public enum DualMITMQUICRouteDecision: Sendable, Equatable {
    case mitm
    case passThrough(reason: String)
    case block(reason: String)
}

public struct DualMITMQUICFlowStartPlan: Sendable, Equatable {
    public let decision: DualMITMQUICRouteDecision
    public let shadowEnabled: Bool
    public let enforceQUICRouting: Bool

    public init(
        decision: DualMITMQUICRouteDecision,
        shadowEnabled: Bool,
        enforceQUICRouting: Bool
    ) {
        self.decision = decision
        self.shadowEnabled = shadowEnabled
        self.enforceQUICRouting = enforceQUICRouting
    }
}
