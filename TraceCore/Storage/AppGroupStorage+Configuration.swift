//
//  AppGroupStorage+Configuration.swift
//  TraceCore
//
//  Created by OpenAI Codex on 2026/03/06.
//

import Foundation
import GRDB

private let configurationDirectoryName = "Configuration"

public extension AppGroupStorage {
    func loadData(from fileName: String) throws -> Data {
        let key = canonicalConfigBlobName(for: fileName)
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    guard let data = try Data.fetchOne(
                        db,
                        sql: "SELECT data FROM config_blobs WHERE name = ?",
                        arguments: [key]
                    ) else {
                        throw StorageError.fileNotFound
                    }
                    return data
                }
            }
        } catch let error as StorageError {
            throw error
        } catch {
            throw mapDatabaseError(error)
        }
    }

    func saveData(_ data: Data, to fileName: String) throws {
        let key = canonicalConfigBlobName(for: fileName)
        let now = Date().timeIntervalSince1970
        do {
            try withDatabase { pool in
                try pool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO config_blobs (name, data, updated_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(name) DO UPDATE SET
                            data = excluded.data,
                            updated_at = excluded.updated_at
                        """,
                        arguments: [key, data, now]
                    )
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    func configFileURL(for fileName: String) -> URL? {
        guard let container = containerURL else {
            return nil
        }

        return container
            .appendingPathComponent(configurationDirectoryName)
            .appendingPathComponent(fileName)
    }

    func appGroupFileURL(for fileName: String) -> URL? {
        guard let container = containerURL else {
            return nil
        }
        return container.appendingPathComponent(fileName)
    }

    func packetCaptureFiles(prefixes: [String] = ["capture_raw_packets", "capture_http2_proxy", "packet_capture", "capture"]) -> [URL] {
        guard let container = containerURL else { return [] }
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let matching = fileURLs.filter { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".pcap") else { return false }
            return prefixes.contains { name.hasPrefix($0) }
        }

        return matching.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return left > right
        }
    }

    func configFileModificationDate(for fileName: String) -> Date? {
        let key = canonicalConfigBlobName(for: fileName)
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    guard let updatedAt = try Double.fetchOne(
                        db,
                        sql: "SELECT updated_at FROM config_blobs WHERE name = ?",
                        arguments: [key]
                    ) else {
                        return nil
                    }
                    return Date(timeIntervalSince1970: updatedAt)
                }
            }
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("config_blob_modification_date")
                    .failure()
                    .with("file", value: fileName, privacy: .public)
                    .error(error)
            )
            return nil
        }
    }

    func saveConfiguration(_ config: CaptureConfiguration) throws {
        let normalized = config.normalized()
        try saveSettingValue(normalized, scope: SettingScope.capture, key: DefaultsKey.captureConfiguration)
    }

    func loadConfiguration() -> CaptureConfiguration {
        if let config = loadSettingValue(
            CaptureConfiguration.self,
            scope: SettingScope.capture,
            key: DefaultsKey.captureConfiguration
        ) {
            return config.normalized()
        }
        return CaptureConfiguration.default.normalized()
    }

    func saveCaptureOptions(_ options: CaptureOptions) throws {
        let normalized = options.normalized()
        try saveSettingValue(normalized, scope: SettingScope.capture, key: DefaultsKey.captureOptions)
    }

    func loadCaptureOptions() -> CaptureOptions {
        if let options = loadSettingValue(
            CaptureOptions.self,
            scope: SettingScope.capture,
            key: DefaultsKey.captureOptions
        ) {
            return options.normalized()
        }

        try? saveCaptureOptions(.default)
        return CaptureOptions.default
    }

    func saveBodyStorageConfig(_ config: BodyStorageConfig) throws {
        let normalized = config.normalized()
        try saveSettingValue(normalized, scope: SettingScope.capture, key: DefaultsKey.bodyStorageConfig)
    }

    func loadBodyStorageConfig() -> BodyStorageConfig {
        if let config = loadSettingValue(
            BodyStorageConfig.self,
            scope: SettingScope.capture,
            key: DefaultsKey.bodyStorageConfig
        ) {
            return config.normalized()
        }

        try? saveBodyStorageConfig(.default)
        return BodyStorageConfig.default
    }

    func saveSamplingConfig(_ config: SamplingConfig) throws {
        let normalized = config.normalized()
        try saveSettingValue(normalized, scope: SettingScope.capture, key: DefaultsKey.samplingConfig)
    }

    func loadSamplingConfig() -> SamplingConfig {
        if let config = loadSettingValue(
            SamplingConfig.self,
            scope: SettingScope.capture,
            key: DefaultsKey.samplingConfig
        ) {
            return config.normalized()
        }

        try? saveSamplingConfig(.default)
        return SamplingConfig.default
    }

    func saveMITMAllowlist(_ allowlist: [String]) throws {
        let sanitized = sanitizeDomainList(allowlist)
        try saveSettingValue(sanitized, scope: SettingScope.capture, key: DefaultsKey.mitmAllowlist)
    }

    func loadMITMAllowlist() -> [String] {
        if let list = loadSettingValue(
            [String].self,
            scope: SettingScope.capture,
            key: DefaultsKey.mitmAllowlist
        ) {
            return sanitizeDomainList(list)
        }

        try? saveMITMAllowlist(["*"])
        return ["*"]
    }

    func saveRewriteRules(_ rules: [RewriteRule]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(rules)
        try saveData(data, to: "rewrite_rules.json")
    }

    func loadRewriteRules() async throws -> [RewriteRule] {
        do {
            let data = try loadData(from: "rewrite_rules.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RewriteRule].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    func saveRequestMaps(_ maps: [RequestMap]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(maps)
        try saveData(data, to: "request_maps.json")
    }

    func loadRequestMaps() async throws -> [RequestMap] {
        do {
            let data = try loadData(from: "request_maps.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RequestMap].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    func saveHostEntries(_ entries: [HostEntry]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try saveData(data, to: "host_entries.json")
    }

    func loadHostEntries() async throws -> [HostEntry] {
        do {
            let data = try loadData(from: "host_entries.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([HostEntry].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    func saveScripts(_ scripts: [Script]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(scripts)
        try saveData(data, to: "scripts.json")
    }

    func loadScripts() async throws -> [Script] {
        do {
            let data = try loadData(from: "scripts.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Script].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    func saveBreakpoints(_ breakpoints: [Breakpoint]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(breakpoints)
        try saveData(data, to: "breakpoints.json")
    }

    func loadBreakpoints() async throws -> [Breakpoint] {
        do {
            let data = try loadData(from: "breakpoints.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Breakpoint].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    func saveFavorites(_ favorites: [Favorite]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(favorites)
        try saveData(data, to: "favorites.json")
    }

    func loadFavorites() async throws -> [Favorite] {
        do {
            let data = try loadData(from: "favorites.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Favorite].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    func saveThrottlingState(_ state: NetworkThrottlingState) throws {
        try saveSettingValue(state, scope: SettingScope.capture, key: DefaultsKey.throttlingState)
    }

    func loadThrottlingState() -> NetworkThrottlingState {
        if let state = loadSettingValue(
            NetworkThrottlingState.self,
            scope: SettingScope.capture,
            key: DefaultsKey.throttlingState
        ) {
            return state
        }

        return .disabled
    }
}

private extension AppGroupStorage {
    func canonicalConfigBlobName(for fileName: String) -> String {
        switch fileName.lowercased() {
        case "rewrite_rules.json", "rewriterules.json":
            "RewriteRules.json"
        case "request_maps.json", "requestmaps.json":
            "RequestMaps.json"
        case "host_entries.json", "hostentries.json":
            "HostEntries.json"
        case "scripts.json":
            "Scripts.json"
        case "favorites.json":
            "Favorites.json"
        case "rulegroups.json":
            "RuleGroups.json"
        case "profiles.json":
            "Profiles.json"
        default:
            fileName
        }
    }
}
