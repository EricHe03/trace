//
//  TraceLog.swift
//  TraceCore
//
//  Created by Justin on 2026/01/11.
//

import CryptoKit
import Foundation
import OSLog

// MARK: - Logger Factory

/// Provides a centralized logger factory following Trace Logging Standard v1.0.
///
/// ## Quick Start
/// ```swift
/// // In each module, create a logging namespace:
/// public enum NetworkLog {
///     public static let http = TraceLog.make(module: .networking, category: .networkingHTTP)
///     public static let http2 = TraceLog.make(module: .networking, category: .networkingHTTP2)
/// }
///
/// // Usage with structured format:
/// NetworkLog.http.info("event=http.request_send outcome=success method=\(method, privacy: .public) status=\(status)")
/// ```
///
/// ## Subsystem Naming
/// All loggers use `com.trace.<ModuleName>` as the subsystem.
/// - App subsystem: `com.trace.Trace`.
/// - VPN Extension subsystem: `com.trace.TraceVPN`.
/// - Networking subsystem: `com.trace.TraceNetworking`.
///
/// ## Console Filtering
/// Filter by subsystem: `subsystem:com.trace`
/// Filter by category: `category:VPN.Tunnel`
/// Combined: `subsystem:com.trace.TraceVPN category:VPN.Tunnel`
public enum TraceLog {
    /// Defines the base subsystem for all Trace modules (reverse-DNS notation).
    public static let baseSubsystem = "com.trace"

    /// Creates a Logger with consistent subsystem naming using type-safe identifiers.
    ///
    /// - Parameters:
    ///   - module: The module identifier enum.
    ///   - category: The category identifier enum.
    /// - Returns: A configured `Logger` instance.
    ///
    /// Example:
    /// ```swift
    /// let tunnelLog = TraceLog.make(module: .vpn, category: .vpnTunnel)
    /// tunnelLog.info("event=vpn.tunnel_start outcome=success")
    /// ```
    public static func make(module: Module, category: Category) -> Logger {
        Logger(subsystem: "\(baseSubsystem).\(module.rawValue)", category: category.rawValue)
    }

    /// Creates a Logger with string-based module and category (for dynamic cases).
    ///
    /// Prefer the enum-based `make(module:category:)` for compile-time safety.
    ///
    /// - Parameters:
    ///   - module: The module name string (e.g., "TraceVPN").
    ///   - category: The category string (e.g., "VPN.Tunnel").
    /// - Returns: A configured `Logger` instance.
    public static func make(module: String, category: String) -> Logger {
        Logger(subsystem: "\(baseSubsystem).\(module)", category: category)
    }
}

// MARK: - Module Identifiers

public extension TraceLog {
    /// Defines module names for type-safe logger creation.
    ///
    /// Each module in the project should have a corresponding entry here.
    /// The raw value matches the module/target name for consistent subsystem naming.
    enum Module: String, CaseIterable, Sendable {
        case core = "TraceCore"
        case vpn = "TraceVPN"
        case networking = "TraceNetworking"
        case security = "TraceSecurity"
        case features = "TraceFeatures"
        case proxy = "TraceProxy"
        case compression = "TraceCompression"
        case ui = "TraceUI"
        case app = "Trace"
        case widget = "TraceWidget"

        /// Returns the full subsystem string for this module.
        public var subsystem: String {
            "\(TraceLog.baseSubsystem).\(rawValue)"
        }
    }
}

// MARK: - Category Identifiers

public extension TraceLog {
    /// Defines category strings for common logging contexts.
    ///
    /// Categories follow a hierarchical naming convention: `Domain.Subdomain`
    /// This enables granular filtering in Console.app and log analysis tools.
    ///
    /// ## Naming Convention
    /// - Use PascalCase for domain and subdomain.
    /// - Keep names stable because changes break log filtering.
    /// - Group related functionality under the same domain prefix.
    enum Category: String, CaseIterable, Sendable {
        // MARK: VPN Module

        /// Describes tunnel lifecycle events, including start, stop, state transitions, and heartbeat.
        case vpnTunnel = "VPN.Tunnel"
        /// Describes proxy server lifecycle and configuration events.
        case vpnProxy = "VPN.Proxy"
        /// Describes certificate loading and trust checks.
        case vpnCertificate = "VPN.Certificate"
        /// Describes network settings and hardening configuration events.
        case vpnConfig = "VPN.Config"

        // MARK: Networking Module

        /// Describes HTTP/1.x request and response handling.
        case networkingHTTP = "Networking.HTTP"
        /// Describes HTTP/2 multiplexed stream handling.
        case networkingHTTP2 = "Networking.HTTP2"
        /// Describes Server-Sent Events streaming.
        case networkingSSE = "Networking.SSE"
        /// Describes WebSocket connection handling.
        case networkingWebSocket = "Networking.WebSocket"
        /// Describes DNS resolution events.
        case networkingDNS = "Networking.DNS"

        // MARK: Security Module

        /// Describes TLS handshake and connection events.
        case securityTLS = "Security.TLS"
        /// Describes Keychain operations.
        case securityKeychain = "Security.Keychain"
        /// Describes cryptographic operations.
        case securityCrypto = "Security.Crypto"
        /// Describes certificate generation and validation.
        case securityCertificate = "Security.Certificate"

        // MARK: Proxy Module

        /// Describes MITM proxy core operations.
        case proxyMITM = "Proxy.MITM"
        /// Describes request interception.
        case proxyInterceptor = "Proxy.Interceptor"
        /// Describes network throttling.
        case proxyThrottling = "Proxy.Throttling"
        /// Describes metrics collection.
        case proxyMetrics = "Proxy.Metrics"

        // MARK: Features Module

        /// Describes request capture events.
        case featureCapture = "Feature.Capture"
        /// Describes request rewriting events.
        case featureRewrite = "Feature.Rewrite"
        /// Describes JavaScript scripting events.
        case featureScript = "Feature.Script"
        /// Describes breakpoint debugging events.
        case featureBreakpoint = "Feature.Breakpoint"
        /// Describes hosts file management events.
        case featureHosts = "Feature.Hosts"
        /// Describes data export events (HAR, cURL, etc.).
        case featureExport = "Feature.Export"
        /// Describes VPN management events.
        case featureVPN = "Feature.VPN"
        /// Describes request mapping and mocking events.
        case featureRequestMap = "Feature.RequestMap"
        /// Describes notification events.
        case featureNotification = "Feature.Notification"
        /// Describes data cleanup and storage management events.
        case featureStorage = "Feature.Storage"
        /// Describes profile management events.
        case featureProfile = "Feature.Profile"
        /// Describes rule pack import/export events.
        case featureRulePack = "Feature.RulePack"

        // MARK: UI Module

        /// Describes view navigation events.
        case uiNavigation = "UI.Navigation"
        /// Describes ViewModel state changes.
        case uiViewModel = "UI.ViewModel"
        /// Describes user interaction events.
        case uiInteraction = "UI.Interaction"

        // MARK: General

        /// Describes storage operations.
        case storage = "Storage"
        /// Describes app lifecycle events.
        case lifecycle = "Lifecycle"
        /// Describes widget-specific events.
        case widget = "Widget"
    }
}

// MARK: - LogCategory Protocol (for custom categories)

/// Defines a protocol for custom log categories with type safety.
///
/// Implement this protocol to create domain-specific category enums:
/// ```swift
/// enum MyCustomCategory: String, LogCategory {
///     case operationA = "Custom.OperationA"
///     case operationB = "Custom.OperationB"
/// }
/// ```
public protocol LogCategory: RawRepresentable where RawValue == String {}

extension TraceLog.Category: LogCategory {}

// MARK: - Event Formatting

/// Builds structured log events for consistent message formatting.
///
/// Creates messages in the standard format:
/// `event=<domain.action> outcome=<success|failure> [key=value...]`
///
/// ## Usage
/// ```swift
/// let event = LogEvent(domain: "vpn", action: "tunnel_start")
///     .success()
///     .with("duration_ms", value: 150)
///     .with("id", value: tunnelID, privacy: .hash)
///
/// VPNLog.tunnel.info("\(event)")
/// ```
///
/// ## Privacy
/// By default, values are logged as public. Use `.private` or `.hash` for sensitive data.
public struct LogEvent: CustomStringConvertible {
    /// Defines outcome values for structured logging.
    public enum Outcome: String {
        case success
        case failure
        case skipped
        case pending
    }

    /// Defines privacy levels for interpolated values.
    public enum Privacy {
        /// Indicates a value that is safe to log (enum cases, error codes, counts).
        case `public`
        /// Indicates a value that is redacted in production logs.
        case `private`
        /// Indicates a value that is hashed for correlation without exposing raw data.
        case hash
    }

    private var domain: String
    private var action: String
    private var outcome: Outcome?
    private var pairs: [(key: String, value: String, privacy: Privacy)]

    /// Creates a new log event.
    ///
    /// - Parameters:
    ///   - domain: The event domain (e.g., "vpn", "http", "tls").
    ///   - action: The action being logged (e.g., "tunnel_start", "request_send").
    public init(domain: String, action: String) {
        self.domain = domain
        self.action = action
        self.outcome = nil
        self.pairs = []
    }

    /// Marks the event as successful.
    public func success() -> LogEvent {
        var copy = self
        copy.outcome = .success
        return copy
    }

    /// Marks the event as failed.
    public func failure() -> LogEvent {
        var copy = self
        copy.outcome = .failure
        return copy
    }

    /// Sets a specific outcome.
    public func outcome(_ outcome: Outcome) -> LogEvent {
        var copy = self
        copy.outcome = outcome
        return copy
    }

    /// Adds a key-value pair to the event.
    ///
    /// - Parameters:
    ///   - key: The key name (use lower_snake_case).
    ///   - value: The value to log.
    ///   - privacy: The privacy level (default: .public).
    /// - Returns: The updated event for chaining.
    public func with(
        _ key: String,
        value: some CustomStringConvertible,
        privacy: Privacy = .public
    ) -> LogEvent {
        var copy = self
        copy.pairs.append((key: key, value: String(describing: value), privacy: privacy))
        return copy
    }

    /// Adds an optional key-value pair and skips it when the value is nil.
    public func with(
        _ key: String,
        value: (some CustomStringConvertible)?,
        privacy: Privacy = .public
    ) -> LogEvent {
        guard let value else { return self }
        return with(key, value: value, privacy: privacy)
    }

    /// Adds an error description.
    public func error(_ error: Error) -> LogEvent {
        with("error", value: String(describing: error))
    }

    /// Adds an error code.
    public func errorCode(_ code: Int) -> LogEvent {
        with("error_code", value: code)
    }

    /// Adds a duration in milliseconds.
    public func duration(ms: Int) -> LogEvent {
        with("duration_ms", value: ms)
    }

    /// Adds a duration calculated from a start date.
    public func duration(since start: Date) -> LogEvent {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return duration(ms: ms)
    }

    /// Adds an attempt number for retry tracking.
    public func attempt(_ number: Int) -> LogEvent {
        with("attempt", value: number)
    }

    /// Adds a count value.
    public func count(_ value: Int) -> LogEvent {
        with("count", value: value)
    }

    /// Builds the formatted log message string.
    ///
    /// - Note: This produces a plain string. Privacy annotations should be applied
    ///   at the Logger call site using OSLogPrivacy.
    public var description: String {
        var parts = ["event=\(domain).\(action)"]

        if let outcome {
            parts.append("outcome=\(outcome.rawValue)")
        }

        for pair in pairs {
            let value: String = switch pair.privacy {
            case .public:
                pair.value
            case .private:
                "<redacted>"
            case .hash:
                Self.hashValue(pair.value)
            }
            parts.append("\(pair.key)=\(value)")
        }

        return parts.joined(separator: " ")
    }

    private static func hashValue(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}

// MARK: - Rate-Limited Logging Helper

/// Provides a helper for rate-limiting logs in streaming and retry scenarios.
///
/// ## Policy
/// - Log the first failure at warning or error level.
/// - Log intermediate retries at debug level.
/// - Log the final failure at error level.
///
/// ## Usage
/// ```swift
/// let rateLimiter = LogRateLimiter(maxRetries: 3)
///
/// for attempt in 1...maxRetries {
///     do {
///         try await operation()
///         break
///     } catch {
///         let level = rateLimiter.levelForAttempt(attempt, isFinal: attempt == maxRetries)
///         logger.log(level: level, "event=operation outcome=failure attempt=\(attempt)")
///     }
/// }
/// ```
public struct LogRateLimiter: Sendable {
    public let maxRetries: Int

    public init(maxRetries: Int) {
        self.maxRetries = maxRetries
    }

    /// Determines the appropriate log level for a retry attempt.
    ///
    /// - Parameters:
    ///   - attempt: The current attempt number (1-based).
    ///   - isFinal: Whether this is the final attempt.
    /// - Returns: The recommended OSLogType.
    public func levelForAttempt(_ attempt: Int, isFinal: Bool) -> OSLogType {
        if attempt == 1 {
            // Rule: The first failure uses the warning-level default.
            .default
        } else if isFinal {
            // Rule: The final failure uses error level.
            .error
        } else {
            // Rule: Intermediate retries use debug level.
            .debug
        }
    }
}

// MARK: - Sampling Helper

/// Provides a lightweight sampler for high-volume logs.
///
/// Policy: log the first N events for a key, then every Kth event thereafter.
public final class LogSampler: @unchecked Sendable {
    private var counters: [String: Int] = [:]
    private let lock = NSLock()

    public static let shared = LogSampler()

    public init() {}

    /// Returns true when the event should be logged.
    ///
    /// - Parameters:
    ///   - key: A stable key (e.g., "http2_frame:<connId>").
    ///   - first: Number of initial events to log per key.
    ///   - every: Log every Kth event after the initial burst.
    public func shouldLog(key: String, first: Int = 3, every: Int = 100) -> Bool {
        guard first > 0 || every > 0 else {
            return false
        }

        lock.lock()
        let nextCount = (counters[key] ?? 0) + 1
        counters[key] = nextCount
        lock.unlock()

        if first > 0, nextCount <= first {
            return true
        }

        guard every > 0 else {
            return false
        }

        return (nextCount - first) % every == 0
    }

    /// Namespaces a key under a logical event group.
    public func shouldLog(event: String, key: String, first: Int = 3, every: Int = 100) -> Bool {
        shouldLog(key: "\(event).\(key)", first: first, every: every)
    }
}

// MARK: - Convenience Extensions

public extension Logger {
    /// Logs a structured event at info level.
    @inlinable
    func info(_ event: LogEvent) {
        info("\(event.description)")
    }

    /// Logs a structured event at debug level.
    @inlinable
    func debug(_ event: LogEvent) {
        debug("\(event.description)")
    }

    /// Logs a structured event at warning level (OSLog .default).
    @inlinable
    func warning(_ event: LogEvent) {
        warning("\(event.description)")
    }

    /// Logs a structured event at error level.
    @inlinable
    func error(_ event: LogEvent) {
        error("\(event.description)")
    }

    /// Logs a structured event at fault level.
    @inlinable
    func fault(_ event: LogEvent) {
        fault("\(event.description)")
    }
}
