//
//  DataCleanupManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import SwiftUI
#if canImport(TraceCore)
import TraceCore
#endif

/// Manages automatic cleanup of stored capture data.
public actor DataCleanupManager {
    public static let shared = DataCleanupManager()

    private var cleanupTask: Task<Void, Never>?
    private static var isRunningUnitTests: Bool {
        #if canImport(TraceCore)
        return RuntimeEnvironment.isRunningUnitTests
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #endif
    }

    private let defaults: UserDefaults

    private enum DefaultsKey {
        static let cleanupConfiguration = "trace.settings.storage.cleanupConfiguration"
        static let cleanupStats = "trace.settings.storage.cleanupStats"
    }

    private enum DirectoryName {
        static let requests = "CapturedRequests"
        static let bodies = "Bodies"
        static let logs = "Logs"
        static let packetFlows = "PacketFlows"
    }

    private var config = CleanupConfiguration()

    public struct CleanupConfiguration: Codable, Equatable {
        public var enabled: Bool = true
        public var requestRetentionDays: Int = 7
        public var bodyFileRetentionDays: Int = 7
        public var logRetentionDays: Int = 7
        public var maxStorageMB: Int = 500
        public var cleanupInterval: TimeInterval = 3600

        public init() {}
    }

    public struct CleanupStats: Codable {
        public var lastCleanup: Date?
        public var requestsDeleted: Int = 0
        public var bodyFilesDeleted: Int = 0
        public var logsDeleted: Int = 0
        public var bytesFreed: Int64 = 0

        public init() {}
    }

    private var stats = CleanupStats()

    private init() {
        // Unit tests should not depend on developer/user persisted app settings.
        // Use an isolated suite so default configuration tests are deterministic.
        if Self.isRunningUnitTests {
            defaults = UserDefaults(suiteName: "com.trace.TraceTests") ?? .standard
            // Keep tests deterministic and isolated from any persisted host-app settings.
            // Unit tests can still mutate configuration in-memory via `updateConfiguration`.
            config = CleanupConfiguration()
            stats = CleanupStats()
        } else {
            defaults = .standard
            config = Self.loadPersistedConfiguration(from: defaults) ?? CleanupConfiguration()
            stats = Self.loadPersistedStats(from: defaults) ?? CleanupStats()
        }
        if config.enabled {
            Task { await self.startAutoCleanup() }
        }
    }

    // MARK: - Configuration

    public func updateConfiguration(_ newConfig: CleanupConfiguration) async {
        config = newConfig

        cleanupTask?.cancel()
        if config.enabled {
            startAutoCleanup()
        }

        persistConfiguration()
        FeatureLog.storage.info("event=storage.config_update outcome=success")
    }

    public func getConfiguration() -> CleanupConfiguration {
        config
    }

    public func getStats() -> CleanupStats {
        stats
    }

    // MARK: - Automatic Cleanup

    private func startAutoCleanup() {
        cleanupTask = Task {
            while !Task.isCancelled {
                if config.enabled {
                    await performCleanup()
                }

                try? await Task.sleep(nanoseconds: UInt64(config.cleanupInterval * 1_000_000_000))
            }
        }
    }

    public func performManualCleanup() async {
        await performCleanup()
    }

    private func performCleanup() async {
        FeatureLog.storage.info("event=storage.cleanup_start outcome=pending")

        var deletedRequests = 0
        var deletedBodies = 0
        var deletedLogs = 0
        var deletedStreamSessions = 0
        var bytesFreed: Int64 = 0

        let requestResult = await cleanupOldRequests()
        deletedRequests = requestResult.count
        bytesFreed += requestResult.bytes

        deletedStreamSessions = await cleanupOldStreamSessions()

        let bodyResult = await cleanupOldBodyFiles()
        deletedBodies = bodyResult.count
        bytesFreed += bodyResult.bytes

        let logResult = await cleanupOldLogs()
        deletedLogs = logResult.count
        bytesFreed += logResult.bytes

        let flowResult = await cleanupOldPacketFlows()
        bytesFreed += flowResult.bytes

        let packetResult = await cleanupOldPacketCaptures()
        bytesFreed += packetResult.bytes

        await enforceStorageLimit()

        stats.lastCleanup = Date()
        stats.requestsDeleted += deletedRequests
        stats.bodyFilesDeleted += deletedBodies
        stats.logsDeleted += deletedLogs
        stats.bytesFreed += bytesFreed
        persistStats()

        FeatureLog.storage.info("event=storage.cleanup_complete outcome=success requests_deleted=\(deletedRequests) stream_sessions_deleted=\(deletedStreamSessions) bodies_deleted=\(deletedBodies) logs_deleted=\(deletedLogs) bytes_freed=\(bytesFreed)")
    }

    private func cleanupOldPacketFlows() async -> (count: Int, bytes: Int64) {
        let retentionDate = Date().addingTimeInterval(-Double(config.requestRetentionDays * 24 * 3600))

        do {
            let flows = try AppGroupStorage.shared.loadAllPacketFlowRecords()
            let encoder = JSONCoding.makeEncoder()
            var deletedCount = 0
            var bytesFreed: Int64 = 0

            for flow in flows where flow.lastSeen < retentionDate {
                if let bytes = try? encoder.encode(flow).count {
                    bytesFreed += Int64(bytes)
                }
                do {
                    try AppGroupStorage.shared.deletePacketFlowRecord(flow)
                    deletedCount += 1
                } catch {
                    FeatureLog.storage.error("event=storage.cleanup_flows outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
            }

            return (deletedCount, bytesFreed)
        } catch {
            FeatureLog.storage.error("event=storage.cleanup_flows outcome=failure error=\(error.localizedDescription, privacy: .public)")
            return (0, 0)
        }
    }

    private func cleanupOldPacketCaptures() async -> (count: Int, bytes: Int64) {
        let retentionDate = Date().addingTimeInterval(-Double(config.requestRetentionDays * 24 * 3600))
        let files = AppGroupStorage.shared.packetCaptureFiles()
        guard !files.isEmpty else { return (0, 0) }

        var deletedCount = 0
        var bytesFreed: Int64 = 0

        for fileURL in files {
            if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let modDate = attrs.contentModificationDate,
               modDate < retentionDate {
                if let fileSize = attrs.fileSize {
                    bytesFreed += Int64(fileSize)
                }
                try? FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            FeatureLog.storage.info("event=storage.cleanup_pcap outcome=success count=\(deletedCount)")
        }

        return (deletedCount, bytesFreed)
    }

    // MARK: - Request Cleanup

    private func cleanupOldRequests() async -> (count: Int, bytes: Int64) {
        let cutoffDate = Date().addingTimeInterval(-Double(config.requestRetentionDays) * 24 * 60 * 60)

        var deletedCount = 0
        var bytesFreed: Int64 = 0

        do {
            let requests = try AppGroupStorage.shared.loadAllRequests()
            for request in requests where request.timestamp < cutoffDate {
                bytesFreed += estimateStoredBytes(for: request)
                do {
                    try AppGroupStorage.shared.deleteRequest(request)
                    deletedCount += 1
                } catch {
                    FeatureLog.storage.error("event=storage.delete_request outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            FeatureLog.storage.error("event=storage.cleanup_requests outcome=failure error=\(error.localizedDescription, privacy: .public)")
        }

        return (deletedCount, bytesFreed)
    }

    private func cleanupOldStreamSessions() async -> Int {
        let cutoffDate = Date().addingTimeInterval(-Double(config.requestRetentionDays) * 24 * 60 * 60)
        do {
            return try AppGroupStorage.shared.deleteStreamSessions(olderThan: cutoffDate)
        } catch {
            FeatureLog.storage.error("event=storage.cleanup_stream_sessions outcome=failure error=\(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    // MARK: - Body File Cleanup

    private func cleanupOldBodyFiles() async -> (count: Int, bytes: Int64) {
        guard let containerURL = storageContainerURL() else {
            return (0, 0)
        }

        let bodiesDir = containerURL.appendingPathComponent(DirectoryName.bodies)
        return await cleanupOldFiles(
            in: bodiesDir,
            retentionDays: config.bodyFileRetentionDays,
            label: "body file"
        )
    }

    // MARK: - Log Cleanup

    private func cleanupOldLogs() async -> (count: Int, bytes: Int64) {
        guard let containerURL = storageContainerURL() else {
            return (0, 0)
        }

        let logsDir = containerURL.appendingPathComponent(DirectoryName.logs)
        return await cleanupOldFiles(
            in: logsDir,
            retentionDays: config.logRetentionDays,
            label: "log file"
        )
    }

    // MARK: - Storage Limit Enforcement

    private func enforceStorageLimit() async {
        guard let containerURL = storageContainerURL() else {
            return
        }

        var totalSize = calculateDirectorySize(containerURL)
        let maxBytes = Int64(config.maxStorageMB) * 1024 * 1024

        if totalSize > maxBytes {
            FeatureLog.storage.warning("event=storage.limit_exceeded total_bytes=\(totalSize) max_bytes=\(maxBytes)")

            // Rule: Remove oldest requests first to preserve recent captures.
            while totalSize > maxBytes {
                let requiredBytes = totalSize - maxBytes
                let requestCleanup = await deleteOldestRequests(toFree: requiredBytes)
                guard requestCleanup.deletedCount > 0 else {
                    break
                }
                let reclaimedDatabaseBytes = AppGroupStorage.shared.reclaimDatabaseSpace()
                if reclaimedDatabaseBytes > 0 {
                    FeatureLog.storage.info(
                        "event=storage.enforce_limit_db_compaction outcome=success bytes_freed=\(reclaimedDatabaseBytes)"
                    )
                }
                totalSize = calculateDirectorySize(containerURL)
            }

            if totalSize > maxBytes {
                let reclaimedDatabaseBytes = AppGroupStorage.shared.reclaimDatabaseSpace()
                if reclaimedDatabaseBytes > 0 {
                    FeatureLog.storage.info(
                        "event=storage.enforce_limit_db_compaction outcome=success bytes_freed=\(reclaimedDatabaseBytes)"
                    )
                }
                totalSize = calculateDirectorySize(containerURL)
            }

            if totalSize > maxBytes {
                _ = await deleteOldestFiles(
                    in: containerURL.appendingPathComponent(DirectoryName.bodies),
                    toFree: totalSize - maxBytes,
                    label: "body files"
                )
                totalSize = calculateDirectorySize(containerURL)
            }

            if totalSize > maxBytes {
                _ = await deleteOldestFiles(
                    in: containerURL.appendingPathComponent(DirectoryName.logs),
                    toFree: totalSize - maxBytes,
                    label: "log files"
                )
                totalSize = calculateDirectorySize(containerURL)
            }

            if totalSize > maxBytes {
                FeatureLog.storage.warning("event=storage.limit_exceeded_after_cleanup total_bytes=\(totalSize) max_bytes=\(maxBytes)")
            }
        }
    }

    private func calculateDirectorySize(_ directory: URL) -> Int64 {
        var totalSize: Int64 = 0

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }

        return totalSize
    }

    private func deleteOldestRequests(toFree bytesToFree: Int64) async -> (deletedCount: Int, estimatedFreedBytes: Int64) {
        var estimatedFreedBytes: Int64 = 0
        var deletedCount = 0

        do {
            let sortedRequests = try AppGroupStorage.shared.loadAllRequests().sorted { $0.timestamp < $1.timestamp }
            for request in sortedRequests {
                if estimatedFreedBytes >= bytesToFree {
                    break
                }

                let estimated = estimateStoredBytes(for: request)
                do {
                    try AppGroupStorage.shared.deleteRequest(request)
                    estimatedFreedBytes += estimated
                    deletedCount += 1
                } catch {
                    FeatureLog.storage.error("event=storage.enforce_limit outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            FeatureLog.storage.error("event=storage.enforce_limit outcome=failure error=\(error.localizedDescription, privacy: .public)")
        }

        FeatureLog.storage.info(
            "event=storage.enforce_limit outcome=success deleted_count=\(deletedCount) bytes_freed_estimate=\(estimatedFreedBytes)"
        )
        return (deletedCount, estimatedFreedBytes)
    }

    // MARK: - Manual Operations

    public func deleteAllRequests() async -> Int {
        do {
            let deletedCount = try AppGroupStorage.shared.loadAllRequests().count
            try AppGroupStorage.shared.clearAllRequests()
            FeatureLog.storage.info("event=storage.delete_all outcome=success deleted_count=\(deletedCount)")
            return deletedCount
        } catch {
            FeatureLog.storage.error("event=storage.delete_all outcome=failure error=\(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    public func getStorageUsage() async -> (total: Int64, requests: Int64, bodies: Int64, logs: Int64) {
        guard let containerURL = storageContainerURL() else {
            return (0, 0, 0, 0)
        }

        let requestsSize = AppGroupStorage.shared.getStorageStats().totalSize
        let bodiesSize = calculateDirectorySize(containerURL.appendingPathComponent(DirectoryName.bodies))
        let logsSize = calculateDirectorySize(containerURL.appendingPathComponent(DirectoryName.logs))
        let totalSize = requestsSize + bodiesSize + logsSize

        return (totalSize, requestsSize, bodiesSize, logsSize)
    }

    private func storageContainerURL() -> URL? {
        AppGroupStorage.shared.containerURL
    }

    private func cleanupOldFiles(
        in directory: URL,
        retentionDays: Int,
        label: String
    ) async -> (count: Int, bytes: Int64) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        ) else {
            return (0, 0)
        }

        let cutoffDate = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        var deletedCount = 0
        var bytesFreed: Int64 = 0

        for file in files {
            guard let attributes = try? file.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]),
                  let creationDate = attributes.creationDate,
                  let fileSize = attributes.fileSize else {
                continue
            }

            if creationDate < cutoffDate {
                do {
                    try FileManager.default.removeItem(at: file)
                    deletedCount += 1
                    bytesFreed += Int64(fileSize)
                } catch {
                    FeatureLog.storage.error("event=storage.delete_file outcome=failure type=\(label, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return (deletedCount, bytesFreed)
    }

    private func bodyFileSize(_ storage: BodyStorage) -> Int64 {
        let url: URL
        switch storage {
        case let .file(fileURL, _, _):
            url = fileURL
        case let .truncatedFile(fileURL, _, _, _):
            url = fileURL
        default:
            return 0
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(fileSize)
    }

    private func estimateStoredBytes(for request: NetworkRequest) -> Int64 {
        let metadataBytes = (try? JSONCoding.makeEncoder().encode(request).count) ?? 0
        let requestBodyBytes = bodyFileSize(request.requestBody)
        let responseBodyBytes = bodyFileSize(request.responseBody)
        return Int64(metadataBytes) + requestBodyBytes + responseBodyBytes
    }

    private func deleteOldestFiles(in directory: URL, toFree bytesToFree: Int64, label: String) async -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        ) else {
            return 0
        }

        let sortedFiles = files.sorted { file1, file2 in
            let date1 = try? file1.resourceValues(forKeys: [.creationDateKey]).creationDate
            let date2 = try? file2.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (date1 ?? Date()) < (date2 ?? Date())
        }

        var freedBytes: Int64 = 0
        var deletedCount = 0

        for file in sortedFiles {
            if freedBytes >= bytesToFree {
                break
            }

            if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                do {
                    try FileManager.default.removeItem(at: file)
                    freedBytes += Int64(fileSize)
                    deletedCount += 1
                } catch {
                    FeatureLog.storage.error("event=storage.delete_file outcome=failure type=\(label, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if deletedCount > 0 {
            FeatureLog.storage.info("event=storage.delete_files outcome=success type=\(label, privacy: .public) deleted_count=\(deletedCount) bytes_freed=\(freedBytes)")
        }

        return freedBytes
    }
}

// MARK: - Persistence

extension DataCleanupManager {
    private static func loadPersistedConfiguration(from defaults: UserDefaults) -> CleanupConfiguration? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = defaults.data(forKey: DefaultsKey.cleanupConfiguration) else { return nil }
        return try? decoder.decode(CleanupConfiguration.self, from: data)
    }

    private static func loadPersistedStats(from defaults: UserDefaults) -> CleanupStats? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = defaults.data(forKey: DefaultsKey.cleanupStats) else { return nil }
        return try? decoder.decode(CleanupStats.self, from: data)
    }

    private func persistConfiguration() {
        guard !Self.isRunningUnitTests else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(config) {
            defaults.set(data, forKey: DefaultsKey.cleanupConfiguration)
        }
    }

    private func persistStats() {
        guard !Self.isRunningUnitTests else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(stats) {
            defaults.set(data, forKey: DefaultsKey.cleanupStats)
        }
    }
}
