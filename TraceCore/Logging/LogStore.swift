//
//  LogStore.swift
//  TraceCore
//
//  Created by Cursor on 2026/01/16.
//

import Foundation
import OSLog

// MARK: - LogStore Errors

/// Defines errors that can occur when accessing the log store.
public enum LogStoreError: LocalizedError {
    /// Indicates OSLogStore is not available on this platform.
    case unsupportedPlatform
    /// Indicates the log store could not be opened.
    case storeUnavailable(underlying: Error)
    /// Indicates log entries could not be fetched.
    case fetchFailed(underlying: Error)
    /// Indicates the app group container is not accessible.
    case appGroupUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "OSLogStore is not available on this platform"
        case let .storeUnavailable(error):
            "Failed to open log store: \(error.localizedDescription)"
        case let .fetchFailed(error):
            "Failed to fetch log entries: \(error.localizedDescription)"
        case .appGroupUnavailable:
            "App group container is not accessible"
        }
    }
}

// MARK: - LogStore Actor

/// Provides unified log reading from OSLogStore and VPN extension NDJSON files.
///
/// This actor serves as the single source of truth for reading logs across the app.
/// It queries the system's unified logging via `OSLogStore` and merges logs from
/// the VPN extension's NDJSON file stored in the app group container.
///
/// ## Usage
/// ```swift
/// // Fetch recent logs from all sources.
/// let logs = try await LogStore.shared.fetchLogs(limit: 100)
///
/// // Fetch logs with filters.
/// let errorLogs = try await LogStore.shared.fetchLogs(
///     minimumLevel: .error,
///     limit: 50
/// )
///
/// // Fetch logs since a specific time.
/// let recentLogs = try await LogStore.shared.fetchLogs(
///     since: Date().addingTimeInterval(-3600),
///     limit: 200
/// )
/// ```
///
/// ## Architecture
/// - Uses `OSLogStore(scope: .currentProcessIdentifier)` for main app logs (no entitlement needed)
/// - Reads VPN extension logs from NDJSON file in the shared app group container
/// - Merges and sorts all logs by timestamp for a unified timeline
///
/// ## Console Filtering
/// All Trace logs use the subsystem prefix `com.trace`, enabling easy filtering:
/// ```
/// subsystem:com.trace
/// ```
public actor LogStore {
    /// Shared instance for app-wide log access.
    public static let shared = LogStore()

    /// The app group identifier for reading VPN extension logs.
    private let appGroupID: String?

    /// The filename for VPN extension NDJSON logs.
    private let vpnLogFileName = "vpn_events.ndjson"

    /// Creates a LogStore with optional app group configuration.
    ///
    /// - Parameter appGroupID: The app group identifier for cross-process log access.
    ///   If nil, attempts to read from the default Trace app group.
    public init(appGroupID: String? = nil) {
        // Rationale: Try to infer app group from bundle if not provided.
        if let appGroupID {
            self.appGroupID = appGroupID
        } else {
            // Use the same centralized configuration as the rest of Trace.
            self.appGroupID = AppGroupConfiguration.appGroupIdentifier
        }
    }

    // MARK: - Public API

    /// Fetches logs from all sources, merged and sorted by timestamp.
    ///
    /// - Parameters:
    ///   - since: Only return logs after this date. Defaults to 1 hour ago.
    ///   - categories: Filter by specific categories. Nil returns all categories.
    ///   - minimumLevel: Minimum log level to include. Defaults to `.debug`.
    ///   - limit: Maximum number of logs to return. Defaults to 500.
    ///   - includeVPNLogs: Whether to include VPN extension logs from NDJSON file.
    /// - Returns: Array of `LogEntry` sorted by timestamp (most recent first).
    /// - Throws: `LogStoreError` if log fetching fails.
    public func fetchLogs(
        since: Date? = nil,
        categories: [TraceLog.Category]? = nil,
        minimumLevel: OSLogType = .debug,
        limit: Int = 500,
        includeVPNLogs: Bool = true
    ) async throws -> [LogEntry] {
        let startDate = since ?? Date().addingTimeInterval(-3600) // Default: last hour
        // OSLogStore can behave unexpectedly for future positions; treat it as empty.
        if startDate > Date() { return [] }

        // Fetch from OSLogStore.
        var allLogs = try await fetchFromOSLogStore(
            since: startDate,
            categories: categories,
            minimumLevel: minimumLevel
        )

        // Merge VPN extension logs if requested.
        if includeVPNLogs {
            // Bound work and memory for potentially-large NDJSON files.
            let vpnLogs = await fetchVPNLogs(
                since: startDate,
                minimumLevel: minimumLevel,
                maxEntries: max(1000, limit * 5)
            )
            allLogs.append(contentsOf: vpnLogs)
        }

        // Sort by timestamp (most recent first) and limit.
        let sorted = allLogs.sorted { $0.timestamp > $1.timestamp }
        return Array(sorted.prefix(limit))
    }

    /// Fetches logs filtered by a specific category.
    ///
    /// - Parameters:
    ///   - category: The category to filter by.
    ///   - since: Only return logs after this date.
    ///   - minimumLevel: Minimum log level to include.
    ///   - limit: Maximum number of logs to return.
    /// - Returns: Array of `LogEntry` for the specified category.
    public func fetchLogs(
        category: TraceLog.Category,
        since: Date? = nil,
        minimumLevel: OSLogType = .debug,
        limit: Int = 500
    ) async throws -> [LogEntry] {
        try await fetchLogs(
            since: since,
            categories: [category],
            minimumLevel: minimumLevel,
            limit: limit,
            includeVPNLogs: false
        )
    }

    /// Fetches logs for a specific request ID.
    ///
    /// - Parameters:
    ///   - requestId: The request ID to search for.
    ///   - since: Only return logs after this date.
    /// - Returns: Array of `LogEntry` matching the request ID.
    public func fetchLogs(
        requestId: String,
        since: Date? = nil
    ) async throws -> [LogEntry] {
        let logs = try await fetchLogs(
            since: since,
            minimumLevel: .debug,
            limit: 10000,
            includeVPNLogs: true
        )

        // Filter by request ID in message content.
        // Rationale: Request IDs appear in structured log messages.
        return logs.filter { entry in
            entry.requestId == requestId || entry.message.contains(requestId)
        }
    }

    // MARK: - OSLogStore Integration

    /// Fetches logs from the system's OSLogStore.
    private func fetchFromOSLogStore(
        since startDate: Date,
        categories: [TraceLog.Category]?,
        minimumLevel: OSLogType
    ) async throws -> [LogEntry] {
        // Create OSLogStore for current process.
        let store: OSLogStore
        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            throw LogStoreError.storeUnavailable(underlying: error)
        }

        // Create position from start date.
        let position = store.position(date: startDate)

        // Build predicate for Trace subsystem.
        var predicateFormat = "subsystem BEGINSWITH 'com.trace'"

        // Add category filter if specified.
        if let categories, !categories.isEmpty {
            let categoryStrings = categories.map { "'\($0.rawValue)'" }.joined(separator: ", ")
            predicateFormat += " AND category IN {\(categoryStrings)}"
        }

        let predicate = NSPredicate(format: predicateFormat)

        // Fetch entries.
        let entries: [OSLogEntry]
        do {
            entries = try Array(store.getEntries(at: position, matching: predicate))
        } catch {
            throw LogStoreError.fetchFailed(underlying: error)
        }

        // Convert to LogEntry and filter by level.
        return entries.compactMap { entry -> LogEntry? in
            guard let logEntry = entry as? OSLogEntryLog else { return nil }

            // Filter by minimum level.
            let entryLevel = mapOSLogEntryLevel(logEntry.level)
            guard entryLevel.severity >= minimumLevel.severity else { return nil }

            return convertToLogEntry(logEntry)
        }
    }

    /// Converts an OSLogEntryLog to our LogEntry type.
    private func convertToLogEntry(_ entry: OSLogEntryLog) -> LogEntry {
        // Extract request ID from message if present.
        // Rationale: Structured logs may contain [requestId] patterns.
        let requestId = extractRequestId(from: entry.composedMessage)

        // Extract file info from message if present.
        let (file, line) = extractFileInfo(from: entry.composedMessage)

        return LogEntry(
            timestamp: entry.date,
            level: mapOSLogEntryLevel(entry.level),
            category: entry.category,
            message: entry.composedMessage,
            requestId: requestId,
            file: file,
            function: "", // OSLogStore doesn't preserve function name.
            line: line
        )
    }

    /// Maps OSLogEntryLog.Level to OSLogType.
    private func mapOSLogEntryLevel(_ level: OSLogEntryLog.Level) -> OSLogType {
        switch level {
        case .debug:
            .debug
        case .info:
            .info
        case .notice:
            .default
        case .error:
            .error
        case .fault:
            .fault
        case .undefined:
            .default
        @unknown default:
            .default
        }
    }

    /// Extracts request ID from a log message.
    ///
    /// Looks for patterns like `[abc12345]` in the message.
    private func extractRequestId(from message: String) -> String? {
        // Pattern: [8+ non-bracket characters]
        let pattern = #"\[([^\[\]]{8,})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: message,
                  range: NSRange(message.startIndex..., in: message)
              ),
              let range = Range(match.range(at: 1), in: message)
        else {
            return nil
        }
        return String(message[range])
    }

    /// Extracts file and line info from a log message.
    ///
    /// Looks for patterns like `(FileName.swift:123)` at the end of messages.
    private func extractFileInfo(from message: String) -> (file: String, line: Int) {
        // Pattern: (FileName.swift:123) at end of message
        let pattern = #"\(([^()]+\.swift):(\d+)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: message,
                  range: NSRange(message.startIndex..., in: message)
              ),
              let fileRange = Range(match.range(at: 1), in: message),
              let lineRange = Range(match.range(at: 2), in: message),
              let lineNumber = Int(message[lineRange])
        else {
            return ("", 0)
        }
        return (String(message[fileRange]), lineNumber)
    }

    // MARK: - VPN Extension Logs

    /// Fetches logs from the VPN extension NDJSON file.
    private func fetchVPNLogs(
        since startDate: Date,
        minimumLevel: OSLogType,
        maxEntries: Int
    ) async -> [LogEntry] {
        guard let appGroupID,
              let containerURL = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: appGroupID
              )
        else {
            return []
        }

        let fileURL = containerURL.appendingPathComponent(vpnLogFileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            var entries: [LogEntry] = []
            entries.reserveCapacity(min(maxEntries, 5000))

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            let maxLineBytes = 256 * 1024
            let chunkSize = 64 * 1024
            var buffer = Data()

            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                buffer.append(chunk)

                while true {
                    guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { break }
                    let lineData = buffer.prefix(upTo: newlineIndex)
                    buffer.removeSubrange(...newlineIndex)

                    if lineData.isEmpty { continue }
                    if lineData.count > maxLineBytes { continue }

                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                    guard let jsonData = line.data(using: .utf8) else { continue }
                    guard let event = try? decoder.decode(VPNLogEvent.self, from: jsonData) else { continue }

                    let timestamp = Date(timeIntervalSince1970: event.ts)
                    guard timestamp >= startDate else { continue }

                    let level = mapVPNLogType(event.type)
                    guard level.severity >= minimumLevel.severity else { continue }

                    entries.append(
                        LogEntry(
                            timestamp: timestamp,
                            level: level,
                            category: "VPN.Extension",
                            message: event.msg,
                            requestId: nil,
                            file: "",
                            function: "",
                            line: 0
                        )
                    )

                    if entries.count > maxEntries {
                        // Keep memory bounded; the caller will sort/prefix anyway.
                        entries.removeFirst(entries.count - maxEntries)
                    }
                }
            }

            // Process trailing data without newline.
            if !buffer.isEmpty, buffer.count <= maxLineBytes,
               let line = String(data: buffer, encoding: .utf8),
               !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let jsonData = line.data(using: .utf8),
               let event = try? decoder.decode(VPNLogEvent.self, from: jsonData) {
                let timestamp = Date(timeIntervalSince1970: event.ts)
                if timestamp >= startDate {
                    let level = mapVPNLogType(event.type)
                    if level.severity >= minimumLevel.severity {
                        entries.append(
                            LogEntry(
                                timestamp: timestamp,
                                level: level,
                                category: "VPN.Extension",
                                message: event.msg,
                                requestId: nil,
                                file: "",
                                function: "",
                                line: 0
                            )
                        )
                        if entries.count > maxEntries {
                            entries.removeFirst(entries.count - maxEntries)
                        }
                    }
                }
            }

            return entries
        } catch {
            CoreLog.storage.warning(
                "event=logstore.vpn_log_read outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// Maps VPN log event type string to OSLogType.
    private func mapVPNLogType(_ type: String) -> OSLogType {
        switch type.lowercased() {
        case "debug":
            .debug
        case "info":
            .info
        case "warning", "notice":
            .default
        case "error":
            .error
        case "fault", "critical":
            .fault
        default:
            .info
        }
    }

    // MARK: - VPN Log Clearing

    /// Clears the VPN extension log file.
    ///
    /// Call this when the user requests to clear all logs.
    public func clearVPNLogs() async {
        guard let appGroupID,
              let containerURL = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: appGroupID
              )
        else {
            return
        }

        let fileURL = containerURL.appendingPathComponent(vpnLogFileName)

        do {
            try FileManager.default.removeItem(at: fileURL)
            CoreLog.storage.info("event=logstore.vpn_log_clear outcome=success")
        } catch {
            // File may not exist, which is fine.
            CoreLog.storage.debug(
                "event=logstore.vpn_log_clear outcome=skipped error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

// MARK: - VPN Log Event Model

/// Represents a single VPN extension log event from NDJSON file.
///
/// This matches the format used by `NDJSONLogWriter` in the VPN extension.
private struct VPNLogEvent: Codable {
    let ts: Double
    let msg: String
    let type: String
}
