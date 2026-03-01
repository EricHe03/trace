//
//  BypassReason.swift
//  TraceCore
//
//  Created by Justin on 2026/02/24.
//

import Foundation

public enum HostBypassDomain: String, Codable, Sendable {
    case tcpMITM
    case quicMITM
}

public enum BypassReason: Sendable, Equatable {
    // Explicit policy
    case notAllowlisted
    case mitmDisabled
    case quicModePassThrough
    case quicModeBlock

    // Failure-driven
    case certificatePinning
    case clientRejected
    case protocolMismatch
    case sniInvalid
    case upstreamTLSIssue
    case transientUpstreamFailure
    case mitmSetupInstability
    case internalError

    /// One-release compatibility
    case legacyToken(String)
}

extension BypassReason: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case token
    }

    private enum Discriminator: String, Codable {
        case notAllowlisted
        case mitmDisabled
        case quicModePassThrough
        case quicModeBlock
        case certificatePinning
        case clientRejected
        case protocolMismatch
        case sniInvalid
        case upstreamTLSIssue
        case transientUpstreamFailure
        case mitmSetupInstability
        case internalError
        case legacyToken
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notAllowlisted:
            try container.encode(Discriminator.notAllowlisted, forKey: .type)
        case .mitmDisabled:
            try container.encode(Discriminator.mitmDisabled, forKey: .type)
        case .quicModePassThrough:
            try container.encode(Discriminator.quicModePassThrough, forKey: .type)
        case .quicModeBlock:
            try container.encode(Discriminator.quicModeBlock, forKey: .type)
        case .certificatePinning:
            try container.encode(Discriminator.certificatePinning, forKey: .type)
        case .clientRejected:
            try container.encode(Discriminator.clientRejected, forKey: .type)
        case .protocolMismatch:
            try container.encode(Discriminator.protocolMismatch, forKey: .type)
        case .sniInvalid:
            try container.encode(Discriminator.sniInvalid, forKey: .type)
        case .upstreamTLSIssue:
            try container.encode(Discriminator.upstreamTLSIssue, forKey: .type)
        case .transientUpstreamFailure:
            try container.encode(Discriminator.transientUpstreamFailure, forKey: .type)
        case .mitmSetupInstability:
            try container.encode(Discriminator.mitmSetupInstability, forKey: .type)
        case .internalError:
            try container.encode(Discriminator.internalError, forKey: .type)
        case let .legacyToken(token):
            try container.encode(Discriminator.legacyToken, forKey: .type)
            try container.encode(token, forKey: .token)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Discriminator.self, forKey: .type)
        switch type {
        case .notAllowlisted:
            self = .notAllowlisted
        case .mitmDisabled:
            self = .mitmDisabled
        case .quicModePassThrough:
            self = .quicModePassThrough
        case .quicModeBlock:
            self = .quicModeBlock
        case .certificatePinning:
            self = .certificatePinning
        case .clientRejected:
            self = .clientRejected
        case .protocolMismatch:
            self = .protocolMismatch
        case .sniInvalid:
            self = .sniInvalid
        case .upstreamTLSIssue:
            self = .upstreamTLSIssue
        case .transientUpstreamFailure:
            self = .transientUpstreamFailure
        case .mitmSetupInstability:
            self = .mitmSetupInstability
        case .internalError:
            self = .internalError
        case .legacyToken:
            self = try .legacyToken(container.decodeIfPresent(String.self, forKey: .token) ?? "")
        }
    }
}

public extension BypassReason {
    var stableToken: String {
        switch self {
        case .notAllowlisted:
            return "not_allowlisted"
        case .mitmDisabled:
            return "mitm_disabled"
        case .quicModePassThrough:
            return "quic_mode_pass_through"
        case .quicModeBlock:
            return "quic_mode_block"
        case .certificatePinning:
            return "certificate_pinning"
        case .clientRejected:
            return "client_rejected"
        case .protocolMismatch:
            return "protocol_mismatch"
        case .sniInvalid:
            return "sni_invalid"
        case .upstreamTLSIssue:
            return "upstream_tls_issue"
        case .transientUpstreamFailure:
            return "transient_upstream_failure"
        case .mitmSetupInstability:
            return "mitm_setup_instability"
        case .internalError:
            return "internal_error"
        case let .legacyToken(token):
            let normalized = token
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized.isEmpty ? "legacy_token" : normalized
        }
    }
}
