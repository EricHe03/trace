//
//  DualMITMPolicySnapshotBuilder.swift
//  TraceCore
//
//  Created by Codex on 2026/02/24.
//

import Foundation

public enum DualMITMPolicySnapshotBuilder {
    public struct Inputs: Sendable {
        public var captureConfiguration: CaptureConfiguration
        public var mitmAllowlist: [String]
        public var mitmEnabled: Bool
        public var quicHandlingMode: QUICHandlingMode
        public var featureFlags: DualMITMPolicyFeatureFlags

        public init(
            captureConfiguration: CaptureConfiguration,
            mitmAllowlist: [String],
            mitmEnabled: Bool,
            quicHandlingMode: QUICHandlingMode,
            featureFlags: DualMITMPolicyFeatureFlags
        ) {
            self.captureConfiguration = captureConfiguration
            self.mitmAllowlist = mitmAllowlist
            self.mitmEnabled = mitmEnabled
            self.quicHandlingMode = quicHandlingMode
            self.featureFlags = featureFlags
        }
    }

    public static func build(
        inputs: Inputs,
        tcpTransparentMITMEnabled: Bool,
        tcpInterceptPorts: Set<UInt16>,
        mitmProxyHost: String,
        mitmProxyPort: UInt16
    ) -> DualMITMPolicySnapshot {
        let normalized = inputs.captureConfiguration.normalized()
        return DualMITMPolicySnapshot(
            tcpTransparentMITMEnabled: tcpTransparentMITMEnabled,
            tcpInterceptPorts: tcpInterceptPorts,
            mitmProxyHost: mitmProxyHost,
            mitmProxyPort: mitmProxyPort,
            policyMode: normalized.dualMITMPolicy,
            circuitBreakerEnabled: normalized.dualMITMCircuitBreakerEnabled,
            tcpBypassTTLSeconds: normalized.tcpBypassTTLSeconds,
            quicHostFailOpenSeconds: normalized.quicHostFailOpenSeconds,
            quicNoProgress: QUICNoProgressConfig(
                graceMs: normalized.quicNoProgressGraceMs,
                idleMs: normalized.quicNoProgressIdleMs,
                absoluteMs: normalized.quicNoProgressAbsoluteMs,
                minimumClientDatagrams: normalized.quicNoProgressMinClientDatagrams
            ),
            quicAuthorityRetryAttempts: normalized.quicAuthorityRetryAttempts,
            quicCertMaterialCacheTTLSeconds: normalized.quicCertMaterialCacheTTLSeconds,
            allowlist: inputs.mitmAllowlist,
            mitmEnabled: inputs.mitmEnabled,
            quicHandlingMode: inputs.quicHandlingMode,
            featureFlags: inputs.featureFlags
        )
    }
}
