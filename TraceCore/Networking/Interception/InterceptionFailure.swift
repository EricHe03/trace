//
//  InterceptionFailure.swift
//  TraceCore
//
//  Created by Codex on 2026/02/24.
//

import Foundation

public enum InterceptionProtocol: String, Codable, Sendable {
    case tcpTransparent
    case httpConnect
    case quic
}

public struct HostPort: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public enum FailureOrigin: String, Codable, Sendable {
    case client
    case upstream
    case localProxy
    case policy
    case system
    case internalError
}

public enum ResourceExhaustedKind: String, Codable, Sendable {
    case fileDescriptors
    case memory
    case cpu
    case unknown
}

public enum CloseSide: String, Codable, Sendable {
    case client
    case upstream
    case unknown
}

public enum MITMSetupStage: String, Codable, Sendable {
    case ingressProbe
    case certGeneration
    case clientTLSHandshake
    case upstreamConnect
    case upstreamTLSHandshake
    case pipelineInstall
    case transparentUpgradeTimeout
    case http2Upgrade
    case unknown
}

public enum ExpectedProtocol: String, Codable, Sendable {
    case http1
    case http2
    case http3
    case http1OrHTTP2
    case tls
    case unknown
}

public enum ObservedProtocol: String, Codable, Sendable {
    case http1
    case http2
    case http3
    case tls
    case nonHTTP
    case unknown
}

public enum QUICHandshakeDetail: String, Codable, Sendable {
    case timeout
    case transportError
    case cryptoError
    case certificatePinning
    case unsupportedVersion
    case unknown
}

public enum QUICClosePhase: String, Codable, Sendable {
    case beforeHandshake
    case beforeHeaders
    case beforeSettings
    case beforeResponse
    case unknown
}

public enum QUICNoProgressDetail: String, Codable, Sendable {
    case graceWindowExpired
    case idleTimeout
    case absoluteTimeout
    case insufficientDatagrams
    case unknown
}

public enum InternalErrorCode: String, Codable, Sendable {
    case nioUnhandled
    case parserInvariantViolation
    case policyInvariantViolation
    case quicInternal
    case unknown
    case legacyUnknownToken
}

/// Stable, policy-relevant failure taxonomy for MITM routing decisions.
public enum InterceptionFailure: Sendable, Equatable {
    // Local / orchestration
    case localProxyUnreachable
    case transparentMetadataInvalid
    case resourceExhausted(kind: ResourceExhaustedKind)

    // TLS / handshake
    case clientRejectedMITMOrPinning
    case sniInvalidOrMissing
    case connectionClosedEarly(side: CloseSide)

    // Upstream connectivity
    case upstreamTimeout
    case upstreamConnectionClosed

    // Upstream TLS
    case upstreamTLSTrustFailed
    case upstreamTLSHostnameMismatch

    // Engine setup
    case mitmSetupFailed(stage: MITMSetupStage)

    // Protocol mismatch
    case nonHTTPProtocol
    case protocolMismatch(expected: ExpectedProtocol, observed: ObservedProtocol?)

    // QUIC
    case quicHandshakeFailed(detail: QUICHandshakeDetail?)
    case quicCertificatePinning
    case quicAuthorityRetryFailed
    case quicClosedBeforeHTTP3(phase: QUICClosePhase)
    case quicNoProgress(detail: QUICNoProgressDetail)

    // Catch-all
    case internalError(code: InternalErrorCode, context: String?)
}

extension InterceptionFailure: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case kind
        case side
        case stage
        case expected
        case observed
        case detail
        case phase
        case code
        case context
    }

    private enum Discriminator: String, Codable {
        case localProxyUnreachable
        case transparentMetadataInvalid
        case resourceExhausted
        case clientRejectedMITMOrPinning
        case sniInvalidOrMissing
        case connectionClosedEarly
        case upstreamTimeout
        case upstreamConnectionClosed
        case upstreamTLSTrustFailed
        case upstreamTLSHostnameMismatch
        case mitmSetupFailed
        case nonHTTPProtocol
        case protocolMismatch
        case quicHandshakeFailed
        case quicCertificatePinning
        case quicAuthorityRetryFailed
        case quicClosedBeforeHTTP3
        case quicNoProgress
        case internalError
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .localProxyUnreachable:
            try container.encode(Discriminator.localProxyUnreachable, forKey: .type)
        case .transparentMetadataInvalid:
            try container.encode(Discriminator.transparentMetadataInvalid, forKey: .type)
        case let .resourceExhausted(kind):
            try container.encode(Discriminator.resourceExhausted, forKey: .type)
            try container.encode(kind, forKey: .kind)
        case .clientRejectedMITMOrPinning:
            try container.encode(Discriminator.clientRejectedMITMOrPinning, forKey: .type)
        case .sniInvalidOrMissing:
            try container.encode(Discriminator.sniInvalidOrMissing, forKey: .type)
        case let .connectionClosedEarly(side):
            try container.encode(Discriminator.connectionClosedEarly, forKey: .type)
            try container.encode(side, forKey: .side)
        case .upstreamTimeout:
            try container.encode(Discriminator.upstreamTimeout, forKey: .type)
        case .upstreamConnectionClosed:
            try container.encode(Discriminator.upstreamConnectionClosed, forKey: .type)
        case .upstreamTLSTrustFailed:
            try container.encode(Discriminator.upstreamTLSTrustFailed, forKey: .type)
        case .upstreamTLSHostnameMismatch:
            try container.encode(Discriminator.upstreamTLSHostnameMismatch, forKey: .type)
        case let .mitmSetupFailed(stage):
            try container.encode(Discriminator.mitmSetupFailed, forKey: .type)
            try container.encode(stage, forKey: .stage)
        case .nonHTTPProtocol:
            try container.encode(Discriminator.nonHTTPProtocol, forKey: .type)
        case let .protocolMismatch(expected, observed):
            try container.encode(Discriminator.protocolMismatch, forKey: .type)
            try container.encode(expected, forKey: .expected)
            try container.encodeIfPresent(observed, forKey: .observed)
        case let .quicHandshakeFailed(detail):
            try container.encode(Discriminator.quicHandshakeFailed, forKey: .type)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .quicCertificatePinning:
            try container.encode(Discriminator.quicCertificatePinning, forKey: .type)
        case .quicAuthorityRetryFailed:
            try container.encode(Discriminator.quicAuthorityRetryFailed, forKey: .type)
        case let .quicClosedBeforeHTTP3(phase):
            try container.encode(Discriminator.quicClosedBeforeHTTP3, forKey: .type)
            try container.encode(phase, forKey: .phase)
        case let .quicNoProgress(detail):
            try container.encode(Discriminator.quicNoProgress, forKey: .type)
            try container.encode(detail, forKey: .detail)
        case let .internalError(code, context):
            try container.encode(Discriminator.internalError, forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encodeIfPresent(context, forKey: .context)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Discriminator.self, forKey: .type)

        switch type {
        case .localProxyUnreachable:
            self = .localProxyUnreachable
        case .transparentMetadataInvalid:
            self = .transparentMetadataInvalid
        case .resourceExhausted:
            self = .resourceExhausted(
                kind: try container.decodeIfPresent(ResourceExhaustedKind.self, forKey: .kind) ?? .unknown
            )
        case .clientRejectedMITMOrPinning:
            self = .clientRejectedMITMOrPinning
        case .sniInvalidOrMissing:
            self = .sniInvalidOrMissing
        case .connectionClosedEarly:
            self = .connectionClosedEarly(
                side: try container.decodeIfPresent(CloseSide.self, forKey: .side) ?? .unknown
            )
        case .upstreamTimeout:
            self = .upstreamTimeout
        case .upstreamConnectionClosed:
            self = .upstreamConnectionClosed
        case .upstreamTLSTrustFailed:
            self = .upstreamTLSTrustFailed
        case .upstreamTLSHostnameMismatch:
            self = .upstreamTLSHostnameMismatch
        case .mitmSetupFailed:
            self = .mitmSetupFailed(
                stage: try container.decodeIfPresent(MITMSetupStage.self, forKey: .stage) ?? .unknown
            )
        case .nonHTTPProtocol:
            self = .nonHTTPProtocol
        case .protocolMismatch:
            self = .protocolMismatch(
                expected: try container.decodeIfPresent(ExpectedProtocol.self, forKey: .expected) ?? .unknown,
                observed: try container.decodeIfPresent(ObservedProtocol.self, forKey: .observed)
            )
        case .quicHandshakeFailed:
            self = .quicHandshakeFailed(detail: try container.decodeIfPresent(QUICHandshakeDetail.self, forKey: .detail))
        case .quicCertificatePinning:
            self = .quicCertificatePinning
        case .quicAuthorityRetryFailed:
            self = .quicAuthorityRetryFailed
        case .quicClosedBeforeHTTP3:
            self = .quicClosedBeforeHTTP3(
                phase: try container.decodeIfPresent(QUICClosePhase.self, forKey: .phase) ?? .unknown
            )
        case .quicNoProgress:
            self = .quicNoProgress(
                detail: try container.decodeIfPresent(QUICNoProgressDetail.self, forKey: .detail) ?? .unknown
            )
        case .internalError:
            self = .internalError(
                code: try container.decodeIfPresent(InternalErrorCode.self, forKey: .code) ?? .unknown,
                context: try container.decodeIfPresent(String.self, forKey: .context)
            )
        }
    }
}

public extension InterceptionFailure {
    var stableToken: String {
        switch self {
        case .localProxyUnreachable:
            return "local_proxy_unreachable"
        case .transparentMetadataInvalid:
            return "transparent_metadata_invalid"
        case .resourceExhausted:
            return "resource_exhausted"
        case .clientRejectedMITMOrPinning:
            return "client_rejected_mitm_or_pinning"
        case .sniInvalidOrMissing:
            return "sni_invalid_or_missing"
        case .connectionClosedEarly:
            return "connection_closed_early"
        case .upstreamTimeout:
            return "upstream_timeout"
        case .upstreamConnectionClosed:
            return "upstream_connection_closed"
        case .upstreamTLSTrustFailed:
            return "tls_upstream_trust_failed"
        case .upstreamTLSHostnameMismatch:
            return "tls_upstream_hostname_mismatch"
        case .mitmSetupFailed:
            return "mitm_setup_failed"
        case .nonHTTPProtocol:
            return "non_http_protocol"
        case .protocolMismatch:
            return "protocol_mismatch"
        case .quicHandshakeFailed:
            return "quic_handshake_failed"
        case .quicCertificatePinning:
            return "quic_certificate_pinning"
        case .quicAuthorityRetryFailed:
            return "quic_authority_retry_failed"
        case .quicClosedBeforeHTTP3:
            return "quic_closed_before_http3"
        case .quicNoProgress:
            return "quic_no_progress"
        case .internalError:
            return "internal_error"
        }
    }
}
