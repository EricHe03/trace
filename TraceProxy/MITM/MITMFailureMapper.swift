//
//  MITMFailureMapper.swift
//  TraceProxy
//
//  Created by Codex on 2026/02/24.
//

import Foundation
import TraceCore

enum MITMFailureMapper {
    static func mapTransparentFailure(_ kind: TransparentMITMFailureKind) -> InterceptionFailure {
        switch kind {
        case .clientRejectedMITMOrPinning:
            return .clientRejectedMITMOrPinning
        case .connectionClosedEarly:
            return .connectionClosedEarly(side: .client)
        case .upstreamTimeout:
            return .upstreamTimeout
        case .upstreamConnectionClosed:
            return .upstreamConnectionClosed
        case .tlsUpstreamTrustFailed:
            return .upstreamTLSTrustFailed
        case .tlsUpstreamHostnameMismatch:
            return .upstreamTLSHostnameMismatch
        case .mitmSetupFailed:
            return .mitmSetupFailed(stage: .pipelineInstall)
        }
    }

    static func mapLegacyReason(_ reason: String) -> InterceptionFailure {
        let decoded = LegacyReasonCodec.decode(reason)
        return decoded.failure ??
            .internalError(code: .legacyUnknownToken, context: reason)
    }

    static func bypassReason(forLegacyReason reason: String) -> BypassReason? {
        LegacyReasonCodec.decode(reason).bypassReason
    }

    static func legacyToken(for failure: InterceptionFailure) -> String {
        LegacyReasonCodec.encode(failure)
    }
}
