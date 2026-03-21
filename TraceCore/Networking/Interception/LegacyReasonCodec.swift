//
//  LegacyReasonCodec.swift
//  TraceCore
//
//  Created by Justin on 2026/02/24.
//

import Foundation

/// One-release compatibility layer for legacy string reason tokens.
public enum LegacyReasonCodec {
    public struct DecodedReason: Sendable, Equatable {
        public var failure: InterceptionFailure?
        public var bypassReason: BypassReason?
        public var domain: HostBypassDomain?

        public init(
            failure: InterceptionFailure?,
            bypassReason: BypassReason?,
            domain: HostBypassDomain?
        ) {
            self.failure = failure
            self.bypassReason = bypassReason
            self.domain = domain
        }
    }

    public static func decode(_ token: String) -> DecodedReason {
        let normalized = normalizedToken(token)
        guard !normalized.isEmpty else {
            return DecodedReason(
                failure: .internalError(code: .legacyUnknownToken, context: token),
                bypassReason: .legacyToken(token),
                domain: .tcpMITM
            )
        }

        if normalized == "local_proxy_unreachable" {
            return DecodedReason(
                failure: .localProxyUnreachable,
                bypassReason: .internalError,
                domain: .tcpMITM
            )
        }

        if normalized == "transparent_metadata_invalid" {
            return DecodedReason(
                failure: .transparentMetadataInvalid,
                bypassReason: .internalError,
                domain: .tcpMITM
            )
        }

        if normalized == "resource_exhausted" {
            return DecodedReason(
                failure: .resourceExhausted(kind: .unknown),
                bypassReason: .internalError,
                domain: .tcpMITM
            )
        }

        if normalized == "client_rejected_mitm_or_pinning" ||
            normalized == "possible_pinning_or_strict_trust" {
            return DecodedReason(
                failure: .clientRejectedMITMOrPinning,
                bypassReason: .certificatePinning,
                domain: .tcpMITM
            )
        }

        if normalized == "sni_invalid_or_missing" ||
            normalized == "sni_invalid_or_missing_upstream_hint" {
            return DecodedReason(
                failure: .sniInvalidOrMissing,
                bypassReason: .sniInvalid,
                domain: .tcpMITM
            )
        }

        if normalized == "connection_closed_early" {
            return DecodedReason(
                failure: .connectionClosedEarly(side: .client),
                bypassReason: .transientUpstreamFailure,
                domain: .tcpMITM
            )
        }

        if normalized == "upstream_timeout" {
            return DecodedReason(
                failure: .upstreamTimeout,
                bypassReason: .transientUpstreamFailure,
                domain: .tcpMITM
            )
        }

        if normalized == "upstream_connection_closed" {
            return DecodedReason(
                failure: .upstreamConnectionClosed,
                bypassReason: .transientUpstreamFailure,
                domain: .tcpMITM
            )
        }

        if normalized == "tls_upstream_trust_failed" {
            return DecodedReason(
                failure: .upstreamTLSTrustFailed,
                bypassReason: .upstreamTLSIssue,
                domain: .tcpMITM
            )
        }

        if normalized == "tls_upstream_hostname_mismatch" {
            return DecodedReason(
                failure: .upstreamTLSHostnameMismatch,
                bypassReason: .upstreamTLSIssue,
                domain: .tcpMITM
            )
        }

        if normalized == "mitm_setup_failed" ||
            normalized == "mitm_pipeline_failed" ||
            normalized == "mitm_tls_handler_failed" {
            return DecodedReason(
                failure: .mitmSetupFailed(stage: .pipelineInstall),
                bypassReason: .mitmSetupInstability,
                domain: .tcpMITM
            )
        }

        if normalized == "mitm_non_http_protocol" || normalized == "non_http_protocol" {
            return DecodedReason(
                failure: .nonHTTPProtocol,
                bypassReason: .protocolMismatch,
                domain: .tcpMITM
            )
        }

        if normalized == "protocol_mismatch" {
            return DecodedReason(
                failure: .protocolMismatch(expected: .unknown, observed: nil),
                bypassReason: .protocolMismatch,
                domain: .tcpMITM
            )
        }

        if normalized == "handshakefailed" || normalized == "quic_handshake_failed" {
            return DecodedReason(
                failure: .quicHandshakeFailed(detail: nil),
                bypassReason: .mitmSetupInstability,
                domain: .quicMITM
            )
        }

        if normalized == "engineunavailable" || normalized == "engine_unavailable" {
            return DecodedReason(
                failure: .internalError(code: .quicInternal, context: token),
                bypassReason: .internalError,
                domain: .quicMITM
            )
        }

        if normalized == "certificatepinning" || normalized == "quic_certificate_pinning" {
            return DecodedReason(
                failure: .quicCertificatePinning,
                bypassReason: .certificatePinning,
                domain: .quicMITM
            )
        }

        if normalized == "quic_retry_with_authority_failed" || normalized == "quic_authority_retry_failed" {
            return DecodedReason(
                failure: .quicAuthorityRetryFailed,
                bypassReason: .mitmSetupInstability,
                domain: .quicMITM
            )
        }

        if normalized.hasPrefix("quic_closed_before_http3") {
            return DecodedReason(
                failure: .quicClosedBeforeHTTP3(phase: .beforeHeaders),
                bypassReason: .mitmSetupInstability,
                domain: .quicMITM
            )
        }

        if normalized == "quic_no_progress_fail_open" || normalized == "quic_no_progress" {
            return DecodedReason(
                failure: .quicNoProgress(detail: .absoluteTimeout),
                bypassReason: .mitmSetupInstability,
                domain: .quicMITM
            )
        }

        if normalized == "internal_error" {
            return DecodedReason(
                failure: .internalError(code: .unknown, context: token),
                bypassReason: .internalError,
                domain: .tcpMITM
            )
        }

        return DecodedReason(
            failure: .internalError(code: .legacyUnknownToken, context: token),
            bypassReason: .legacyToken(token),
            domain: normalized.hasPrefix("quic_") ? .quicMITM : .tcpMITM
        )
    }

    public static func encode(_ failure: InterceptionFailure) -> String {
        switch failure {
        case .localProxyUnreachable:
            "local_proxy_unreachable"
        case .transparentMetadataInvalid:
            "transparent_metadata_invalid"
        case .resourceExhausted:
            "resource_exhausted"
        case .clientRejectedMITMOrPinning:
            "client_rejected_mitm_or_pinning"
        case .sniInvalidOrMissing:
            "sni_invalid_or_missing"
        case .connectionClosedEarly:
            "connection_closed_early"
        case .upstreamTimeout:
            "upstream_timeout"
        case .upstreamConnectionClosed:
            "upstream_connection_closed"
        case .upstreamTLSTrustFailed:
            "tls_upstream_trust_failed"
        case .upstreamTLSHostnameMismatch:
            "tls_upstream_hostname_mismatch"
        case .mitmSetupFailed:
            "mitm_setup_failed"
        case .nonHTTPProtocol:
            "mitm_non_http_protocol"
        case .protocolMismatch:
            "protocol_mismatch"
        case .quicHandshakeFailed:
            "quic_handshake_failed"
        case .quicCertificatePinning:
            "quic_certificate_pinning"
        case .quicAuthorityRetryFailed:
            "quic_authority_retry_failed"
        case .quicClosedBeforeHTTP3:
            "quic_closed_before_http3"
        case .quicNoProgress:
            "quic_no_progress_fail_open"
        case .internalError:
            "internal_error"
        }
    }

    public static func encode(_ bypassReason: BypassReason) -> String {
        switch bypassReason {
        case .notAllowlisted:
            "not_allowlisted"
        case .mitmDisabled:
            "mitm_disabled"
        case .quicModePassThrough:
            "quic_mode_pass_through"
        case .quicModeBlock:
            "quic_mode_block"
        case .certificatePinning:
            "certificate_pinning"
        case .clientRejected:
            "client_rejected"
        case .protocolMismatch:
            "protocol_mismatch"
        case .sniInvalid:
            "sni_invalid"
        case .upstreamTLSIssue:
            "upstream_tls_issue"
        case .transientUpstreamFailure:
            "transient_upstream_failure"
        case .mitmSetupInstability:
            "mitm_setup_instability"
        case .internalError:
            "internal_error"
        case let .legacyToken(token):
            normalizedToken(token)
        }
    }

    public static func normalizedToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if let separator = trimmed.firstIndex(of: ":") {
            return String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.replacingOccurrences(of: " ", with: "_")
    }
}
