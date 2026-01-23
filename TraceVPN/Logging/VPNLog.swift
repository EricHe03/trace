//
//  VPNLog.swift
//  TraceVPN
//
//  Created by Justin on 2026/01/11.
//

import OSLog
import TraceCore

// MARK: - VPN Module Logging

/// Provides VPN module loggers following Trace Logging Standard v1.0.
///
/// Discussion: This namespace provides structured logging for VPN tunnel operations, proxy server lifecycle,
/// certificate management, and network configuration. All loggers use the
/// `com.trace.TraceVPN` subsystem and are optimized for Console.app filtering.
///
/// - Note: Subsystem is `com.trace.TraceVPN`.
/// - Note: Categories map to `VPN.Tunnel`, `VPN.Proxy`, `VPN.Certificate`, and `VPN.Config`.
///
/// Usage:
/// ```swift
/// // Simple structured message
/// VPNLog.tunnel.info("event=vpn.tunnel_start outcome=success id=\(id, privacy: .public)")
///
/// // With LogEvent builder (preferred for complex events)
/// let event = LogEvent(domain: "vpn", action: "tunnel_start")
///     .success()
///     .duration(since: startTime)
///     .with("id", value: tunnelId, privacy: .public)
/// VPNLog.tunnel.info("\(event)")
///
/// // Error logging
/// VPNLog.proxy.error("event=vpn.proxy_start outcome=failure error=\(error, privacy: .public)")
/// ```
///
/// Privacy guidelines:
/// - `id` (invocation ID): `.public` — safe identifier with no PII
/// - `fingerprint`: `.private(mask: .hash)` — sensitive but correlatable
/// - `error`: `.public` — error types contain no user data
/// - `host`/`port`: `.public` for localhost, `.private` for external addresses
///
/// Console filtering:
/// ```
/// subsystem:com.trace.TraceVPN category:VPN.Tunnel
/// ```
public enum VPNLog {
    /// Logs tunnel lifecycle events (start, stop, state transitions, heartbeat).
    ///
    /// Use this logger for all `PacketTunnelProvider` lifecycle operations.
    /// Tracks tunnel state changes, invocation IDs for debugging concurrent starts,
    /// and periodic heartbeats when debug logging is enabled.
    ///
    /// **Log Levels:**
    /// - `.info`: Tunnel started/stopped successfully
    /// - `.warning`: Duplicate start ignored, non-fatal issues
    /// - `.error`: Tunnel start/stop failed
    /// - `.debug`: Heartbeat, internal state changes
    public static let tunnel = TraceLog.make(
        module: .vpn,
        category: .vpnTunnel
    )

    /// Logs proxy server events (start, stop, configuration changes).
    ///
    /// Tracks the local MITM proxy server (`MITMProxyServer`) lifecycle and
    /// dynamic configuration updates. Critical for diagnosing proxy startup failures.
    ///
    /// **Log Levels:**
    /// - `.info`: Proxy started/stopped
    /// - `.error`: Proxy failed to start
    /// - `.debug`: Configuration updates, internal state
    public static let proxy = TraceLog.make(
        module: .vpn,
        category: .vpnProxy
    )

    /// Logs certificate events (CA loading, trust checks, MITM status).
    ///
    /// Tracks root CA certificate operations and system trust validation.
    /// If the CA is not trusted, HTTPS MITM will be disabled and only
    /// HTTP traffic will be captured.
    ///
    /// **Log Levels:**
    /// - `.info`: CA loaded successfully, trust verified
    /// - `.warning`: CA not trusted (MITM will be disabled)
    /// - `.error`: CA failed to load
    /// - `.debug`: Fingerprint details, cache operations
    public static let certificate = TraceLog.make(
        module: .vpn,
        category: .vpnCertificate
    )

    /// Logs configuration events (network settings, hardening config updates).
    ///
    /// Logs VPN network settings (DNS, proxy, routes) and hardening configuration
    /// changes (MITM allowlist, QUIC blocking, raw packet capture).
    ///
    /// **Log Levels:**
    /// - `.info`: Settings applied successfully
    /// - `.error`: Settings failed to apply
    /// - `.debug`: Detailed configuration values
    public static let config = TraceLog.make(
        module: .vpn,
        category: .vpnConfig
    )
}

// MARK: - VPN Event Domains

/// Provides predefined event builders for common VPN operations.
///
/// These factory methods provide consistent event naming across the VPN module.
/// Use them instead of constructing `LogEvent` manually to ensure event names
/// follow the standard `domain.action` pattern.
public extension LogEvent {
    /// Creates a tunnel lifecycle event.
    ///
    /// - Parameter action: The action name (e.g., "start", "stop", "heartbeat")
    /// - Returns: A `LogEvent` with domain "vpn" and action "tunnel_\(action)"
    static func vpnTunnel(_ action: String) -> LogEvent {
        LogEvent(domain: "vpn", action: "tunnel_\(action)")
    }

    /// Creates a proxy server event.
    ///
    /// - Parameter action: The action name (e.g., "start", "stop", "config_update")
    /// - Returns: A `LogEvent` with domain "vpn" and action "proxy_\(action)"
    static func vpnProxy(_ action: String) -> LogEvent {
        LogEvent(domain: "vpn", action: "proxy_\(action)")
    }

    /// Creates a certificate event.
    ///
    /// - Parameter action: The action name (e.g., "load", "trust_check", "cleanup")
    /// - Returns: A `LogEvent` with domain "vpn" and action "ca_\(action)"
    static func vpnCertificate(_ action: String) -> LogEvent {
        LogEvent(domain: "vpn", action: "ca_\(action)")
    }

    /// Creates a network settings event.
    ///
    /// - Parameter action: The action name (e.g., "apply", "configure")
    /// - Returns: A `LogEvent` with domain "vpn" and action "network_\(action)"
    static func vpnConfig(_ action: String) -> LogEvent {
        LogEvent(domain: "vpn", action: "network_\(action)")
    }
}
