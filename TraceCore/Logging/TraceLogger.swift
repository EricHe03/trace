//
//  TraceLogger.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import OSLog

/// Adds display helpers for OSLogType.
public extension OSLogType {
    /// Returns the severity ranking used for filtering (higher is more severe).
    var severity: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .default: 2
        case .error: 3
        case .fault: 4
        // Rule: Unknown OSLogType values map to the default severity.
        default: 2
        }
    }

    var emoji: String {
        switch self {
        case .debug: "DBG"
        case .info: "INF"
        case .error: "ERR"
        case .fault: "FLT"
        default: "WRN"
        }
    }

    var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .error: "ERROR"
        case .fault: "FAULT"
        default: "DEFAULT"
        }
    }
}

/// Defines legacy log categories for different subsystems.
///
/// - Note: For new code, prefer using `TraceLog.Category` with module-specific logging
///   namespaces (e.g., `CoreLog`, `VPNLog`). This enum is retained for backward
///   compatibility with the in-memory log buffer system.
@available(*, deprecated, message: "Use TraceLog.Category with module-specific loggers (CoreLog, VPNLog, etc.)")
public enum LegacyLogCategory: String, Codable, Sendable {
    case vpn = "VPN"
    case proxy = "Proxy"
    case tls = "TLS"
    case certificate = "Certificate"
    case rewrite = "Rewrite"
    case script = "Script"
    case websocket = "WebSocket"
    case storage = "Storage"
    case network = "Network"
    case ui = "UI"
    case app = "App"
    case general = "General"
    case http2 = "HTTP2"

    public var emoji: String {
        switch self {
        case .vpn: "VPN"
        case .proxy: "PRX"
        case .tls: "TLS"
        case .certificate: "CRT"
        case .rewrite: "RWR"
        case .script: "SCR"
        case .websocket: "WS"
        case .storage: "STO"
        case .network: "NET"
        case .ui: "UI"
        case .app: "APP"
        case .general: "GEN"
        case .http2: "H2"
        }
    }

    /// Maps to the new TraceLog.Category where applicable.
    public var traceLogCategory: TraceLog.Category? {
        switch self {
        case .vpn: .vpnTunnel
        case .proxy: .proxyMITM
        case .tls: .securityTLS
        case .certificate: .securityCertificate
        case .rewrite: .featureRewrite
        case .script: .featureScript
        case .websocket: .networkingWebSocket
        case .storage: .storage
        case .network: .networkingHTTP
        case .ui: .uiNavigation
        case .app: .lifecycle
        case .general: nil
        case .http2: .networkingHTTP2
        }
    }
}

/// Represents a log entry for the in-memory buffer and UI display.
public struct LogEntry: Codable, Sendable {
    public let timestamp: Date
    public let level: OSLogType
    /// Indicates a category string from LegacyLogCategory or TraceLog.Category.
    public let category: String
    public let message: String
    public let requestId: String?
    public let file: String
    public let function: String
    public let line: Int

    public init(
        timestamp: Date,
        level: OSLogType,
        category: String,
        message: String,
        requestId: String?,
        file: String,
        function: String,
        line: Int
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.requestId = requestId
        self.file = file
        self.function = function
        self.line = line
    }

    /// Creates a convenience initializer with LegacyLogCategory.
    @available(*, deprecated, message: "Use init with String category")
    public init(
        timestamp: Date,
        level: OSLogType,
        category: LegacyLogCategory,
        message: String,
        requestId: String?,
        file: String,
        function: String,
        line: Int
    ) {
        self.init(
            timestamp: timestamp,
            level: level,
            category: category.rawValue,
            message: message,
            requestId: requestId,
            file: file,
            function: function,
            line: line
        )
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case levelRawValue = "level"
        case category
        case message
        case requestId
        case file
        case function
        case line
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let rawLevel = try container.decode(UInt8.self, forKey: .levelRawValue)
        level = OSLogType(rawValue: rawLevel)
        category = try container.decode(String.self, forKey: .category)
        message = try container.decode(String.self, forKey: .message)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        file = try container.decode(String.self, forKey: .file)
        function = try container.decode(String.self, forKey: .function)
        line = try container.decode(Int.self, forKey: .line)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(level.rawValue, forKey: .levelRawValue)
        try container.encode(category, forKey: .category)
        try container.encode(message, forKey: .message)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(file, forKey: .file)
        try container.encode(function, forKey: .function)
        try container.encode(line, forKey: .line)
    }

    public var formattedMessage: String {
        let time = LogEntry.timeFormatter.string(from: timestamp)
        let reqId = requestId.map { " [\($0)]" } ?? ""
        return "\(time) [\(level.label)] [\(category)]\(reqId) \(message) (\(file):\(line))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// Provides backward-compatible logging with unified log reading via OSLogStore.
///
/// This actor provides deprecated logging methods for backward compatibility.
/// New code should use module-specific loggers (CoreLog, VPNLog, etc.) directly.
/// Log queries are now delegated to `LogStore` which reads from OSLogStore.
///
/// ## Usage for UI Display
/// ```swift
/// // New way: Use LogStore directly for queries.
/// let logs = try await LogStore.shared.fetchLogs(limit: 100)
///
/// // Legacy way (still works but delegates to LogStore).
/// let logs = try await TraceLogger.shared.getRecentLogs(limit: 100)
/// ```
///
/// ## Migration Guide
/// - Replace `TraceLogger.shared.info(...)` with `CoreLog.lifecycle.info(...)`
/// - Replace `traceInfo(...)` with the appropriate module logger
/// - Replace `getRecentLogs()` with `LogStore.shared.fetchLogs()`
public actor TraceLogger {
    public static let shared = TraceLogger()

    /// Defines the minimum log level for deprecated logging methods.
    public var minimumLevel: OSLogType = .info

    /// Caches os.Logger instances by category.
    private var loggers: [String: Logger] = [:]

    private init() {}

    /// Logs a message with a specified level and category string.
    ///
    /// - Note: For new code, prefer using module-specific loggers directly.
    ///   This method writes to os.Logger which is read by LogStore.
    @available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
    public func log(
        _ message: String,
        level: OSLogType,
        category: String,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        // Rule: Drop logs below the minimum level.
        guard level.severity >= minimumLevel.severity else { return }

        let fileName = (file as NSString).lastPathComponent

        // Build formatted message for os.Logger.
        // Rationale: Include metadata in the message so LogStore can extract it.
        let reqIdPart = requestId.map { " [\($0)]" } ?? ""
        let formattedMessage = "[\(level.label)] [\(category)]\(reqIdPart) \(message) (\(fileName):\(line))"

        let logger = osLogger(for: category)
        logger.log(level: level, "\(formattedMessage, privacy: .public)")
    }

    /// Logs a message with a legacy category for backward compatibility.
    @available(*, deprecated, message: "Use log with String category or module-specific loggers")
    public func log(
        _ message: String,
        level: OSLogType,
        category: LegacyLogCategory,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: level, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    /// Sets the minimum log level.
    public func setMinimumLevel(_ level: OSLogType) {
        minimumLevel = level
    }

    // MARK: - Convenience Methods (Deprecated)

    /// Provides convenience methods for os.Logger log levels.
    @available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
    public func debug(
        _ message: String,
        category: LegacyLogCategory = .general,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .debug, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    @available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
    public func info(
        _ message: String,
        category: LegacyLogCategory = .general,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .info, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    @available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
    public func notice(
        _ message: String,
        category: LegacyLogCategory = .general,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .default, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    @available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
    public func error(
        _ message: String,
        category: LegacyLogCategory = .general,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .error, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    @available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
    public func warning(
        _ message: String,
        category: LegacyLogCategory = .general,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .default, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    @available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
    public func fault(
        _ message: String,
        category: LegacyLogCategory = .general,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .fault, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    @available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
    public func critical(
        _ message: String,
        category: LegacyLogCategory = .general,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .fault, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    /// Logs an error with automatic formatting.
    @available(*, deprecated, message: "Use module-specific loggers with LogEvent builder")
    public func error(
        _ error: Error,
        context: String,
        category: LegacyLogCategory = .general,
        requestId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let message = "\(context): \(error.localizedDescription)"
        log(message, level: .error, category: category.rawValue, requestId: requestId, file: file, function: function, line: line)
    }

    // MARK: - Query Methods (Delegated to LogStore)

    /// Returns recent log entries ordered from most recent to oldest.
    ///
    /// - Note: This method now delegates to `LogStore.shared.fetchLogs()`.
    ///   For new code, use `LogStore` directly.
    /// - Parameter limit: Maximum number of entries to return.
    /// - Returns: Array of log entries, or empty array if fetching fails.
    public func getRecentLogs(limit: Int? = nil) async -> [LogEntry] {
        do {
            return try await LogStore.shared.fetchLogs(
                since: nil,
                categories: nil,
                minimumLevel: minimumLevel,
                limit: limit ?? 500,
                includeVPNLogs: true
            )
        } catch {
            // Rationale: Return empty array on failure to maintain backward compatibility.
            return []
        }
    }

    /// Returns logs filtered by category string.
    ///
    /// - Note: This method now delegates to `LogStore`.
    public func getLogs(category: String, limit: Int? = nil) async -> [LogEntry] {
        do {
            let allLogs = try await LogStore.shared.fetchLogs(
                since: nil,
                minimumLevel: minimumLevel,
                limit: limit ?? 500,
                includeVPNLogs: true
            )
            return allLogs.filter { $0.category == category }
        } catch {
            return []
        }
    }

    /// Returns logs filtered by level.
    ///
    /// - Note: This method now delegates to `LogStore`.
    public func getLogs(level: OSLogType, limit: Int? = nil) async -> [LogEntry] {
        do {
            return try await LogStore.shared.fetchLogs(
                since: nil,
                minimumLevel: level,
                limit: limit ?? 500,
                includeVPNLogs: true
            )
        } catch {
            return []
        }
    }

    /// Returns logs for a specific request.
    ///
    /// - Note: This method now delegates to `LogStore`.
    public func getLogs(requestId: String) async -> [LogEntry] {
        do {
            return try await LogStore.shared.fetchLogs(
                requestId: requestId,
                since: nil
            )
        } catch {
            return []
        }
    }

    /// Clears VPN extension logs.
    ///
    /// - Note: System logs (OSLogStore) cannot be cleared programmatically.
    ///   This only clears the VPN extension NDJSON log file.
    public func clearLogs() async {
        await LogStore.shared.clearVPNLogs()
    }

    // MARK: - Private Helpers

    /// Returns or creates an os.Logger for the given category string.
    private func osLogger(for category: String) -> Logger {
        if let existing = loggers[category] {
            return existing
        }
        // Rationale: Use the TraceLog base subsystem for consistent naming.
        let logger = Logger(subsystem: TraceLog.baseSubsystem, category: category)
        loggers[category] = logger
        return logger
    }
}

// MARK: - Global Convenience Functions (Deprecated)

/// Provides global convenience functions for quick logging.
///
/// - Note: These functions are deprecated. Use module-specific loggers instead:
/// ```swift
/// // Old way (deprecated).
/// traceInfo("Message", category: .storage)
///
/// // New way.
/// CoreLog.storage.info("event=storage.operation outcome=success")
/// ```

@available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
func traceLog(_ message: String, level: OSLogType = .info, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        await TraceLogger.shared.log(message, level: level, category: category.rawValue, requestId: requestId)
    }
}

@available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
public func traceDebug(_ message: String, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        await TraceLogger.shared.log(message, level: .debug, category: category.rawValue, requestId: requestId)
    }
}

@available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
public func traceInfo(_ message: String, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        await TraceLogger.shared.log(message, level: .info, category: category.rawValue, requestId: requestId)
    }
}

@available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
func traceNotice(_ message: String, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        await TraceLogger.shared.log(message, level: .default, category: category.rawValue, requestId: requestId)
    }
}

@available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
public func traceWarning(_ message: String, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        await TraceLogger.shared.log(message, level: .default, category: category.rawValue, requestId: requestId)
    }
}

@available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
public func traceError(_ message: String, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        await TraceLogger.shared.log(message, level: .error, category: category.rawValue, requestId: requestId)
    }
}

@available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
func traceFault(_ message: String, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        await TraceLogger.shared.log(message, level: .fault, category: category.rawValue, requestId: requestId)
    }
}

@available(*, deprecated, message: "Use module-specific loggers (CoreLog, VPNLog, etc.)")
func traceCritical(_ message: String, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        await TraceLogger.shared.log(message, level: .fault, category: category.rawValue, requestId: requestId)
    }
}

@available(*, deprecated, message: "Use module-specific loggers with LogEvent builder")
public func traceError(_ error: Error, context: String, category: LegacyLogCategory = .general, requestId: String? = nil) {
    Task {
        let message = "\(context): \(error.localizedDescription)"
        await TraceLogger.shared.log(message, level: .error, category: category.rawValue, requestId: requestId)
    }
}
