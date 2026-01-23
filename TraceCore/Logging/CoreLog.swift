//
//  CoreLog.swift
//  TraceCore
//
//  Created by Justin on 2026/01/12.
//

import OSLog

// MARK: - Core Module Logging

/// Provides the Core module logging namespace following Trace Logging Standard v1.0.
///
/// **Subsystem:** `com.trace.TraceCore`
///
/// ## Categories
/// | Logger | Category | Use Case |
/// |--------|----------|----------|
/// | `storage` | Storage | File operations, persistence, App Group access |
/// | `lifecycle` | Lifecycle | Initialization, teardown, state transitions |
///
/// ## Usage
/// ```swift
/// // Simple message.
/// CoreLog.storage.info("event=storage.save outcome=success file=\(fileName, privacy: .public)")
///
/// // With a LogEvent builder.
/// let event = LogEvent(domain: "storage", action: "load")
///     .success()
///     .count(items.count)
/// CoreLog.storage.info("\(event)")
///
/// // Error logging.
/// CoreLog.storage.error("event=storage.load outcome=failure error=\(error, privacy: .public)")
/// ```
///
/// ## Privacy Guidelines
/// - Use `.public` for `file` names because configuration file names are safe.
/// - Use `.public` for `count` values because counts are safe.
/// - Use `.public` for `error` because error types are safe.
/// - Use `.private` for `path` because it may contain user directory info.
/// - Use `.private` for `content` because file contents are sensitive.
///
/// ## Console Filtering
/// ```
/// subsystem:com.trace.TraceCore category:Storage
/// ```
public enum CoreLog {
    /// Represents storage operations such as file I/O, persistence, and App Group access.
    ///
    /// Log levels:
    /// - Use `.info` for successful load and save operations.
    /// - Use `.warning` for fallback storage and missing files on first launch.
    /// - Use `.error` for failed operations and container access issues.
    /// - Use `.debug` for detailed file operations and JSON previews.
    public static let storage = TraceLog.make(
        module: .core,
        category: .storage
    )

    /// Represents lifecycle events such as initialization, teardown, and state transitions.
    ///
    /// Log levels:
    /// - Use `.info` for successful initialization.
    /// - Use `.error` for initialization failures.
    /// - Use `.debug` for state transitions.
    public static let lifecycle = TraceLog.make(
        module: .core,
        category: .lifecycle
    )
}

// MARK: - Core Event Domains

/// Provides predefined event builders for common Core operations.
public extension LogEvent {
    /// Creates a storage event.
    /// - Parameter action: The action (e.g., "load", "save", "delete", "clear").
    static func storage(_ action: String) -> LogEvent {
        LogEvent(domain: "storage", action: action)
    }

    /// Creates a lifecycle event.
    /// - Parameter action: The action (e.g., "init", "teardown", "state_change").
    static func lifecycle(_ action: String) -> LogEvent {
        LogEvent(domain: "lifecycle", action: action)
    }
}
