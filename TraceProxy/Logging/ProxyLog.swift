//
//  ProxyLog.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/11.
//

import OSLog
import TraceCore

// MARK: - Proxy Module Logging

/// Provides the proxy module logging namespace following Trace Logging Standard v1.0.
///
/// **Subsystem:** `com.trace.TraceProxy`
///
/// ## Categories
/// | Logger | Category | Use Case |
/// |--------|----------|----------|
/// | `mitm` | Proxy.MITM | MITM proxy core operations |
/// | `interceptor` | Proxy.Interceptor | Request interception |
/// | `throttling` | Proxy.Throttling | Network throttling |
/// | `metrics` | Proxy.Metrics | Performance metrics collection |
///
/// ## Usage
/// ```swift
/// // Connection handling
/// ProxyLog.mitm.info("event=proxy.connection_accept outcome=success client_count=\(count)")
/// ProxyLog.mitm.debug("event=proxy.data_forward direction=\(dir, privacy: .public) bytes=\(size)")
///
/// // Interception
/// ProxyLog.interceptor.info("event=intercept.request method=\(method, privacy: .public) host=\(host, privacy: .private(mask: .hash))")
///
/// // Throttling
/// ProxyLog.throttling.debug("event=throttle.delay duration_ms=\(delay) profile=\(profile, privacy: .public)")
/// ```
///
/// ## Privacy Guidelines
/// - Connection counts, bytes transferred: `.public`
/// - Client IPs: `.private` (or don't log at all)
/// - Request hosts: `.private(mask: .hash)` for correlation
/// - HTTP methods, status codes: `.public`
/// - Throttling profiles: `.public`
///
/// ## Console Filtering
/// ```
/// subsystem:com.trace.TraceProxy category:Proxy.MITM
/// ```
public enum ProxyLog {
    /// Provides MITM proxy core operations logging.
    ///
    /// Log levels:
    /// - `.info`: Connection accepted, proxy mode determined
    /// - `.error`: Connection handling failed
    /// - `.debug`: Data forwarding, buffer operations
    public static let mitm = TraceLog.make(
        module: .proxy,
        category: .proxyMITM
    )

    /// Provides request interception event logging.
    ///
    /// Log levels:
    /// - `.info`: Request intercepted, modification applied
    /// - `.warning`: Interception bypassed (allowlist)
    /// - `.debug`: Match evaluation, rule details
    public static let interceptor = TraceLog.make(
        module: .proxy,
        category: .proxyInterceptor
    )

    /// Provides network throttling operation logging.
    ///
    /// Log levels:
    /// - `.info`: Throttling profile applied/changed
    /// - `.debug`: Individual delay events (rate-limit)
    public static let throttling = TraceLog.make(
        module: .proxy,
        category: .proxyThrottling
    )

    /// Provides metrics collection logging.
    ///
    /// Log levels:
    /// - `.info`: Periodic metrics summary
    /// - `.debug`: Individual metric updates
    public static let metrics = TraceLog.make(
        module: .proxy,
        category: .proxyMetrics
    )
}

// MARK: - Proxy Event Domains

/// Provides pre-defined event builders for common proxy operations.
public extension LogEvent {
    /// Creates a proxy connection event.
    /// - Parameter action: The action (e.g., "accept", "close", "forward").
    static func proxy(_ action: String) -> LogEvent {
        LogEvent(domain: "proxy", action: action)
    }

    /// Creates an interception event.
    /// - Parameter action: The action (e.g., "request", "response", "bypass").
    static func intercept(_ action: String) -> LogEvent {
        LogEvent(domain: "intercept", action: action)
    }

    /// Creates a throttling event.
    /// - Parameter action: The action (e.g., "apply", "delay", "profile_change").
    static func throttle(_ action: String) -> LogEvent {
        LogEvent(domain: "throttle", action: action)
    }
}
