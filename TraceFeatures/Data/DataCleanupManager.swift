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
actor DataCleanupManager {
    static let shared = DataCleanupManager()

    private var cleanupTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

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

    struct CleanupConfiguration: Codable, Equatable {
        var enabled: Bool = true
        var requestRetentionDays: Int = 7
        var bodyFileRetentionDays: Int = 7
        var logRetentionDays: Int = 7
        var maxStorageMB: Int = 500
        var cleanupInterval: TimeInterval = 3600
    }

    struct CleanupStats: Codable {
        var lastCleanup: Date?
        var requestsDeleted: Int = 0
        var bodyFilesDeleted: Int = 0
        var logsDeleted: Int = 0
        var bytesFreed: Int64 = 0
    }

    private var stats = CleanupStats()

    private init() {
        config = Self.loadPersistedConfiguration(from: defaults) ?? CleanupConfiguration()
        stats = Self.loadPersistedStats(from: defaults) ?? CleanupStats()
        if config.enabled {
            Task { await self.startAutoCleanup() }
        }
    }

    // MARK: - Configuration

    func updateConfiguration(_ newConfig: CleanupConfiguration) async {
        config = newConfig

        cleanupTask?.cancel()
        if config.enabled {
            startAutoCleanup()
        }

        persistConfiguration()
        FeatureLog.storage.info("event=storage.config_update outcome=success")
    }

    func getConfiguration() -> CleanupConfiguration {
        config
    }

    func getStats() -> CleanupStats {
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

    func performManualCleanup() async {
        await performCleanup()
    }

    private func performCleanup() async {
        FeatureLog.storage.info("event=storage.cleanup_start outcome=pending")

        var deletedRequests = 0
        var deletedBodies = 0
        var deletedLogs = 0
        var bytesFreed: Int64 = 0

        let requestResult = await cleanupOldRequests()
        deletedRequests = requestResult.count
        bytesFreed += requestResult.bytes

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

        FeatureLog.storage.info("event=storage.cleanup_complete outcome=success requests_deleted=\(deletedRequests) bodies_deleted=\(deletedBodies) logs_deleted=\(deletedLogs) bytes_freed=\(bytesFreed)")
    }

    private func cleanupOldPacketFlows() async -> (count: Int, bytes: Int64) {
        guard let containerURL = AppGroupStorage.shared.containerURL else {
            return (0, 0)
        }

        let flowsDir = containerURL.appendingPathComponent(DirectoryName.packetFlows)
        let retentionDate = Date().addingTimeInterval(-Double(config.requestRetentionDays * 24 * 3600))

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: flowsDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            var deletedCount = 0
            var bytesFreed: Int64 = 0

            for fileURL in fileURLs {
                if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                   let modDate = attrs.contentModificationDate {
                    if modDate < retentionDate {
                        if let fileSize = attrs.fileSize {
                            bytesFreed += Int64(fileSize)
                        }
                        try? FileManager.default.removeItem(at: fileURL)
                        deletedCount += 1
                    }
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

        guard let containerURL = storageContainerURL() else {
            return (0, 0)
        }

        let requestsDir = containerURL.appendingPathComponent(DirectoryName.requests)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: requestsDir,
            includingPropertiesForKeys: [.creationDateKey]
        ) else {
            return (0, 0)
        }

        var deletedCount = 0
        var bytesFreed: Int64 = 0

        for file in files {
            guard let resourceValues = try? file.resourceValues(forKeys: [.creationDateKey]),
                  let creationDate = resourceValues.creationDate else {
                continue
            }

            if creationDate < cutoffDate {
                do {
                    let freed = try deleteRequestFileAndBodies(at: file)
                    deletedCount += 1
                    bytesFreed += freed
                } catch {
                    FeatureLog.storage.error("event=storage.delete_request outcome=failure error=\(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return (deletedCount, bytesFreed)
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

        let totalSize = calculateDirectorySize(containerURL)
        let maxBytes = Int64(config.maxStorageMB) * 1024 * 1024

        if totalSize > maxBytes {
            FeatureLog.storage.warning("event=storage.limit_exceeded total_bytes=\(totalSize) max_bytes=\(maxBytes)")

            // Rule: Remove oldest requests first to preserve recent captures.
            var remainingToFree = totalSize - maxBytes
            let freedFromRequests = await deleteOldestRequests(toFree: remainingToFree)
            remainingToFree -= freedFromRequests

            if remainingToFree > 0 {
                let freedFromBodies = await deleteOldestFiles(
                    in: containerURL.appendingPathComponent(DirectoryName.bodies),
                    toFree: remainingToFree,
                    label: "body files"
                )
                remainingToFree -= freedFromBodies
            }

            if remainingToFree > 0 {
                _ = await deleteOldestFiles(
                    in: containerURL.appendingPathComponent(DirectoryName.logs),
                    toFree: remainingToFree,
                    label: "log files"
                )
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

    private func deleteOldestRequests(toFree bytesToFree: Int64) async -> Int64 {
        guard let containerURL = storageContainerURL() else {
            return 0
        }

        let requestsDir = containerURL.appendingPathComponent(DirectoryName.requests)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: requestsDir,
            includingPropertiesForKeys: [.creationDateKey]
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

            do {
                let freed = try deleteRequestFileAndBodies(at: file)
                freedBytes += freed
                deletedCount += 1
            } catch {
                FeatureLog.storage.error("event=storage.enforce_limit outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
        }

        FeatureLog.storage.info("event=storage.enforce_limit outcome=success deleted_count=\(deletedCount) bytes_freed=\(freedBytes)")
        return freedBytes
    }

    // MARK: - Manual Operations

    func deleteAllRequests() async -> Int {
        guard let containerURL = storageContainerURL() else {
            return 0
        }

        let requestsDir = containerURL.appendingPathComponent("CapturedRequests")

        guard let files = try? FileManager.default.contentsOfDirectory(at: requestsDir, includingPropertiesForKeys: nil) else {
            return 0
        }

        var deletedCount = 0

        for file in files {
            do {
                _ = try deleteRequestFileAndBodies(at: file)
                deletedCount += 1
            } catch {
                FeatureLog.storage.error("event=storage.delete_request outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
        }

        FeatureLog.storage.info("event=storage.delete_all outcome=success deleted_count=\(deletedCount)")

        return deletedCount
    }

    func getStorageUsage() async -> (total: Int64, requests: Int64, bodies: Int64, logs: Int64) {
        guard let containerURL = storageContainerURL() else {
            return (0, 0, 0, 0)
        }

        let requestsSize = calculateDirectorySize(containerURL.appendingPathComponent(DirectoryName.requests))
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

    private func deleteRequestFileAndBodies(at fileURL: URL) throws -> Int64 {
        var freedBytes: Int64 = 0

        if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            freedBytes += Int64(fileSize)
        }

        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let request = try? decoder.decode(NetworkRequest.self, from: data) {
                freedBytes += deleteBodyFile(request.requestBody)
                freedBytes += deleteBodyFile(request.responseBody)
            }
        }

        try FileManager.default.removeItem(at: fileURL)
        return freedBytes
    }

    private func deleteBodyFile(_ storage: BodyStorage) -> Int64 {
        guard case let .file(url, _, _) = storage else { return 0 }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try? FileManager.default.removeItem(at: url)
        return Int64(fileSize)
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

// MARK: - Storage Settings View

/// Displays storage usage and cleanup controls.
public struct StorageSettingsView: View {
    @State private var config = DataCleanupManager.CleanupConfiguration()
    @State private var stats = DataCleanupManager.CleanupStats()
    @State private var storageUsage: (total: Int64, requests: Int64, bodies: Int64, logs: Int64) = (0, 0, 0, 0)
    @State private var isCleaningUp = false

    public init() {}

    public var body: some View {
        Form {
            Section("Storage Usage") {
                storageUsageRow(label: "Total", bytes: storageUsage.total)
                storageUsageRow(label: "Requests", bytes: storageUsage.requests)
                storageUsageRow(label: "Body Files", bytes: storageUsage.bodies)
                storageUsageRow(label: "Logs", bytes: storageUsage.logs)
            }

            Section("Automatic Cleanup") {
                Toggle("Enable Auto Cleanup", isOn: $config.enabled)

                Stepper("Keep Requests: \(config.requestRetentionDays) days", value: $config.requestRetentionDays, in: 1 ... 30)
                Stepper("Keep Body Files: \(config.bodyFileRetentionDays) days", value: $config.bodyFileRetentionDays, in: 1 ... 30)
                Stepper("Keep Logs: \(config.logRetentionDays) days", value: $config.logRetentionDays, in: 1 ... 30)
                Stepper("Max Storage: \(config.maxStorageMB) MB", value: $config.maxStorageMB, in: 100 ... 2000, step: 100)
            }

            Section("Statistics") {
                if let lastCleanup = stats.lastCleanup {
                    HStack {
                        Text("Last Cleanup")
                        Spacer()
                        Text(lastCleanup, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Requests Deleted")
                    Spacer()
                    Text("\(stats.requestsDeleted)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Space Freed")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: stats.bytesFreed, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task {
                        isCleaningUp = true
                        await DataCleanupManager.shared.performManualCleanup()
                        await loadData()
                        isCleaningUp = false
                    }
                } label: {
                    if isCleaningUp {
                        HStack {
                            ProgressView()
                            Text("Cleaning Up...")
                        }
                    } else {
                        Label("Clean Up Now", systemImage: "trash")
                    }
                }
                .disabled(isCleaningUp)

                Button(role: .destructive) {
                    Task {
                        _ = await DataCleanupManager.shared.deleteAllRequests()
                        await loadData()
                    }
                } label: {
                    Label("Delete All Requests", systemImage: "trash.fill")
                }
            }
        }
        .navigationTitle("Storage")
        .task {
            await loadData()
        }
        .onChange(of: config) { newConfig in
            Task {
                await DataCleanupManager.shared.updateConfiguration(newConfig)
            }
        }
    }

    private func storageUsageRow(label: String, bytes: Int64) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .foregroundStyle(.secondary)
        }
    }

    private func loadData() async {
        config = await DataCleanupManager.shared.getConfiguration()
        stats = await DataCleanupManager.shared.getStats()
        storageUsage = await DataCleanupManager.shared.getStorageUsage()
    }
}

#Preview {
    NavigationStack {
        StorageSettingsView()
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(config) {
            defaults.set(data, forKey: DefaultsKey.cleanupConfiguration)
        }
    }

    private func persistStats() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(stats) {
            defaults.set(data, forKey: DefaultsKey.cleanupStats)
        }
    }
}
