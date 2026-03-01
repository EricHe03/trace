//
//  CaptureConfiguration.swift
//  TraceCore
//

import Foundation

public enum CaptureMode: String, Codable, Sendable {
    case proxyOnly
    case fullTunnel
    case fullTunnelDualMITM

    public var usesPacketTunnelRouting: Bool {
        switch self {
        case .proxyOnly:
            false
        case .fullTunnel, .fullTunnelDualMITM:
            true
        }
    }

    public var usesSystemHTTPProxy: Bool {
        switch self {
        case .proxyOnly, .fullTunnel:
            true
        case .fullTunnelDualMITM:
            false
        }
    }

    public var supportsCustomSocksServer: Bool {
        self == .fullTunnel
    }

    public var enablesTCPTransparentMITM: Bool {
        self == .fullTunnelDualMITM
    }
}

public enum UDPForwardingMode: String, Codable, Sendable {
    case hevOnly
    case direct
    case split
}

public enum DualMITMPolicy: String, Codable, Sendable {
    case adaptiveFailOpen
    case strictMITM
}

public struct CaptureConfiguration: Codable, Sendable {
    public static let defaultFullTunnelDNSServers = ["1.1.1.1", "8.8.8.8"]

    public var isEnabled: Bool
    public var filterMode: FilterMode
    public var domainFilters: [String] // Domains to include/exclude based on filterMode
    public var captureHeaders: Bool
    public var captureBody: Bool
    public var maxBodySize: Int // Maximum body size to capture in bytes
    public var captureMode: CaptureMode
    public var fullTunnelDNSServers: [String]
    public var fullTunnelSearchDomains: [String]
    public var fullTunnelIPv6Enabled: Bool
    public var fullTunnelSocks5Host: String
    public var fullTunnelSocks5Port: UInt16
    public var fullTunnelUDPForwardingMode: UDPForwardingMode
    public var fullTunnelHybridTCPMITMEnabled: Bool
    public var dualMITMPolicy: DualMITMPolicy
    public var tcpBypassTTLSeconds: Int
    public var quicHostFailOpenSeconds: Int
    public var dualMITMCircuitBreakerEnabled: Bool
    public var quicNoProgressGraceMs: Int
    public var quicNoProgressIdleMs: Int
    public var quicNoProgressAbsoluteMs: Int
    public var quicNoProgressMinClientDatagrams: Int
    public var quicAuthorityRetryAttempts: Int
    public var quicCertMaterialCacheTTLSeconds: Int

    public static let `default` = {
        let captureDefaults = CaptureOptions.default
        return CaptureConfiguration(
            isEnabled: true,
            filterMode: .all,
            domainFilters: [],
            captureHeaders: captureDefaults.captureHeaders,
            captureBody: captureDefaults.captureBody,
            // Default to 10 MB; large bodies are stored on disk and can be increased in Settings.
            maxBodySize: captureDefaults.maxBodySize,
            captureMode: .proxyOnly,
            fullTunnelDNSServers: [],
            fullTunnelSearchDomains: [],
            fullTunnelIPv6Enabled: true,
            fullTunnelSocks5Host: "",
            fullTunnelSocks5Port: 0,
            fullTunnelUDPForwardingMode: .hevOnly,
            fullTunnelHybridTCPMITMEnabled: false,
            dualMITMPolicy: .adaptiveFailOpen,
            tcpBypassTTLSeconds: 180,
            quicHostFailOpenSeconds: 1800,
            dualMITMCircuitBreakerEnabled: true,
            quicNoProgressGraceMs: 6000,
            quicNoProgressIdleMs: 6000,
            quicNoProgressAbsoluteMs: 20000,
            quicNoProgressMinClientDatagrams: 6,
            quicAuthorityRetryAttempts: 1,
            quicCertMaterialCacheTTLSeconds: 1800
        )
    }()

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case filterMode
        case domainFilters
        case captureHeaders
        case captureBody
        case maxBodySize
        case captureMode
        case fullTunnelDNSServers
        case fullTunnelSearchDomains
        case fullTunnelIPv6Enabled
        case fullTunnelSocks5Host
        case fullTunnelSocks5Port
        case fullTunnelUDPForwardingMode
        case fullTunnelHybridTCPMITMEnabled
        case dualMITMPolicy
        case tcpBypassTTLSeconds
        case quicHostFailOpenSeconds
        case dualMITMCircuitBreakerEnabled
        case quicNoProgressGraceMs
        case quicNoProgressIdleMs
        case quicNoProgressAbsoluteMs
        case quicNoProgressMinClientDatagrams
        case quicAuthorityRetryAttempts
        case quicCertMaterialCacheTTLSeconds
    }

    public init(
        isEnabled: Bool,
        filterMode: FilterMode,
        domainFilters: [String],
        captureHeaders: Bool,
        captureBody: Bool,
        maxBodySize: Int,
        captureMode: CaptureMode,
        fullTunnelDNSServers: [String],
        fullTunnelSearchDomains: [String],
        fullTunnelIPv6Enabled: Bool,
        fullTunnelSocks5Host: String,
        fullTunnelSocks5Port: UInt16,
        fullTunnelUDPForwardingMode: UDPForwardingMode,
        fullTunnelHybridTCPMITMEnabled: Bool = false,
        dualMITMPolicy: DualMITMPolicy = .adaptiveFailOpen,
        tcpBypassTTLSeconds: Int = 180,
        quicHostFailOpenSeconds: Int = 1800,
        dualMITMCircuitBreakerEnabled: Bool = true,
        quicNoProgressGraceMs: Int = 6000,
        quicNoProgressIdleMs: Int = 6000,
        quicNoProgressAbsoluteMs: Int = 20000,
        quicNoProgressMinClientDatagrams: Int = 6,
        quicAuthorityRetryAttempts: Int = 1,
        quicCertMaterialCacheTTLSeconds: Int = 1800
    ) {
        self.isEnabled = isEnabled
        self.filterMode = filterMode
        self.domainFilters = domainFilters
        self.captureHeaders = captureHeaders
        self.captureBody = captureBody
        self.maxBodySize = maxBodySize
        self.captureMode = captureMode
        self.fullTunnelDNSServers = fullTunnelDNSServers
        self.fullTunnelSearchDomains = fullTunnelSearchDomains
        self.fullTunnelIPv6Enabled = fullTunnelIPv6Enabled
        self.fullTunnelSocks5Host = fullTunnelSocks5Host
        self.fullTunnelSocks5Port = fullTunnelSocks5Port
        self.fullTunnelUDPForwardingMode = fullTunnelUDPForwardingMode
        self.fullTunnelHybridTCPMITMEnabled = fullTunnelHybridTCPMITMEnabled
        self.dualMITMPolicy = dualMITMPolicy
        self.tcpBypassTTLSeconds = tcpBypassTTLSeconds
        self.quicHostFailOpenSeconds = quicHostFailOpenSeconds
        self.dualMITMCircuitBreakerEnabled = dualMITMCircuitBreakerEnabled
        self.quicNoProgressGraceMs = quicNoProgressGraceMs
        self.quicNoProgressIdleMs = quicNoProgressIdleMs
        self.quicNoProgressAbsoluteMs = quicNoProgressAbsoluteMs
        self.quicNoProgressMinClientDatagrams = quicNoProgressMinClientDatagrams
        self.quicAuthorityRetryAttempts = quicAuthorityRetryAttempts
        self.quicCertMaterialCacheTTLSeconds = quicCertMaterialCacheTTLSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let defaults = CaptureConfiguration.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        filterMode = try container.decodeIfPresent(FilterMode.self, forKey: .filterMode) ?? defaults.filterMode
        domainFilters = try container.decodeIfPresent([String].self, forKey: .domainFilters) ?? defaults.domainFilters
        captureHeaders = try container.decodeIfPresent(Bool.self, forKey: .captureHeaders) ?? defaults.captureHeaders
        captureBody = try container.decodeIfPresent(Bool.self, forKey: .captureBody) ?? defaults.captureBody
        maxBodySize = try container.decodeIfPresent(Int.self, forKey: .maxBodySize) ?? defaults.maxBodySize
        captureMode = try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? defaults.captureMode
        fullTunnelDNSServers = try container.decodeIfPresent([String].self, forKey: .fullTunnelDNSServers)
            ?? defaults.fullTunnelDNSServers
        fullTunnelSearchDomains = try container.decodeIfPresent([String].self, forKey: .fullTunnelSearchDomains)
            ?? defaults.fullTunnelSearchDomains
        fullTunnelIPv6Enabled = try container.decodeIfPresent(Bool.self, forKey: .fullTunnelIPv6Enabled)
            ?? defaults.fullTunnelIPv6Enabled
        fullTunnelSocks5Host = try container.decodeIfPresent(String.self, forKey: .fullTunnelSocks5Host)
            ?? defaults.fullTunnelSocks5Host
        fullTunnelSocks5Port = try container.decodeIfPresent(UInt16.self, forKey: .fullTunnelSocks5Port)
            ?? defaults.fullTunnelSocks5Port
        fullTunnelUDPForwardingMode = try container.decodeIfPresent(UDPForwardingMode.self, forKey: .fullTunnelUDPForwardingMode)
            ?? defaults.fullTunnelUDPForwardingMode
        fullTunnelHybridTCPMITMEnabled = try container.decodeIfPresent(Bool.self, forKey: .fullTunnelHybridTCPMITMEnabled)
            ?? defaults.fullTunnelHybridTCPMITMEnabled
        dualMITMPolicy = try container.decodeIfPresent(DualMITMPolicy.self, forKey: .dualMITMPolicy)
            ?? defaults.dualMITMPolicy
        tcpBypassTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .tcpBypassTTLSeconds)
            ?? defaults.tcpBypassTTLSeconds
        quicHostFailOpenSeconds = try container.decodeIfPresent(Int.self, forKey: .quicHostFailOpenSeconds)
            ?? defaults.quicHostFailOpenSeconds
        dualMITMCircuitBreakerEnabled = try container.decodeIfPresent(Bool.self, forKey: .dualMITMCircuitBreakerEnabled)
            ?? defaults.dualMITMCircuitBreakerEnabled
        quicNoProgressGraceMs = try container.decodeIfPresent(Int.self, forKey: .quicNoProgressGraceMs)
            ?? defaults.quicNoProgressGraceMs
        quicNoProgressIdleMs = try container.decodeIfPresent(Int.self, forKey: .quicNoProgressIdleMs)
            ?? defaults.quicNoProgressIdleMs
        quicNoProgressAbsoluteMs = try container.decodeIfPresent(Int.self, forKey: .quicNoProgressAbsoluteMs)
            ?? defaults.quicNoProgressAbsoluteMs
        quicNoProgressMinClientDatagrams = try container.decodeIfPresent(Int.self, forKey: .quicNoProgressMinClientDatagrams)
            ?? defaults.quicNoProgressMinClientDatagrams
        quicAuthorityRetryAttempts = try container.decodeIfPresent(Int.self, forKey: .quicAuthorityRetryAttempts)
            ?? defaults.quicAuthorityRetryAttempts
        quicCertMaterialCacheTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .quicCertMaterialCacheTTLSeconds)
            ?? defaults.quicCertMaterialCacheTTLSeconds
        self = normalized()
    }

    public func encode(to encoder: Encoder) throws {
        let normalized = normalized()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalized.isEnabled, forKey: .isEnabled)
        try container.encode(normalized.filterMode, forKey: .filterMode)
        try container.encode(normalized.domainFilters, forKey: .domainFilters)
        try container.encode(normalized.captureHeaders, forKey: .captureHeaders)
        try container.encode(normalized.captureBody, forKey: .captureBody)
        try container.encode(normalized.maxBodySize, forKey: .maxBodySize)
        try container.encode(normalized.captureMode, forKey: .captureMode)
        try container.encode(normalized.fullTunnelDNSServers, forKey: .fullTunnelDNSServers)
        try container.encode(normalized.fullTunnelSearchDomains, forKey: .fullTunnelSearchDomains)
        try container.encode(normalized.fullTunnelIPv6Enabled, forKey: .fullTunnelIPv6Enabled)
        try container.encode(normalized.fullTunnelSocks5Host, forKey: .fullTunnelSocks5Host)
        try container.encode(normalized.fullTunnelSocks5Port, forKey: .fullTunnelSocks5Port)
        try container.encode(normalized.fullTunnelUDPForwardingMode, forKey: .fullTunnelUDPForwardingMode)
        try container.encode(normalized.fullTunnelHybridTCPMITMEnabled, forKey: .fullTunnelHybridTCPMITMEnabled)
        try container.encode(normalized.dualMITMPolicy, forKey: .dualMITMPolicy)
        try container.encode(normalized.tcpBypassTTLSeconds, forKey: .tcpBypassTTLSeconds)
        try container.encode(normalized.quicHostFailOpenSeconds, forKey: .quicHostFailOpenSeconds)
        try container.encode(normalized.dualMITMCircuitBreakerEnabled, forKey: .dualMITMCircuitBreakerEnabled)
        try container.encode(normalized.quicNoProgressGraceMs, forKey: .quicNoProgressGraceMs)
        try container.encode(normalized.quicNoProgressIdleMs, forKey: .quicNoProgressIdleMs)
        try container.encode(normalized.quicNoProgressAbsoluteMs, forKey: .quicNoProgressAbsoluteMs)
        try container.encode(normalized.quicNoProgressMinClientDatagrams, forKey: .quicNoProgressMinClientDatagrams)
        try container.encode(normalized.quicAuthorityRetryAttempts, forKey: .quicAuthorityRetryAttempts)
        try container.encode(normalized.quicCertMaterialCacheTTLSeconds, forKey: .quicCertMaterialCacheTTLSeconds)
    }

    public func normalized() -> CaptureConfiguration {
        var normalizedConfig = self
        normalizedConfig.normalizeInPlace()
        return normalizedConfig
    }

    private mutating func normalizeInPlace() {
        fullTunnelSocks5Host = fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        if fullTunnelSocks5Host.isEmpty {
            fullTunnelSocks5Port = 0
        }

        fullTunnelDNSServers = Self.normalizedStringList(fullTunnelDNSServers)
        fullTunnelSearchDomains = Self.normalizedStringList(fullTunnelSearchDomains)
        tcpBypassTTLSeconds = max(30, min(86400, tcpBypassTTLSeconds))
        quicHostFailOpenSeconds = max(60, min(86400, quicHostFailOpenSeconds))
        quicNoProgressGraceMs = max(3000, min(20000, quicNoProgressGraceMs))
        quicNoProgressIdleMs = max(3000, min(20000, quicNoProgressIdleMs))
        quicNoProgressAbsoluteMs = max(8000, min(30000, quicNoProgressAbsoluteMs))
        quicNoProgressMinClientDatagrams = max(1, min(8, quicNoProgressMinClientDatagrams))
        quicAuthorityRetryAttempts = max(0, min(2, quicAuthorityRetryAttempts))
        quicCertMaterialCacheTTLSeconds = max(60, min(86400, quicCertMaterialCacheTTLSeconds))

        if captureMode.usesPacketTunnelRouting, fullTunnelDNSServers.isEmpty {
            fullTunnelDNSServers = Self.defaultFullTunnelDNSServers
        }
    }

    private static func normalizedStringList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                normalized.append(trimmed)
            }
        }
        return normalized
    }
}

public enum FilterMode: String, Codable, Sendable {
    case all // Capture everything
    case whitelist // Only capture specified domains
    case blacklist // Capture everything except specified domains
}
