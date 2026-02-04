//
//  AppGroupStorage.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Manages storage in the shared App Group container
/// This allows the main app and Network Extension to share captured request data
public class AppGroupStorage: @unchecked Sendable {
    public static let shared = AppGroupStorage()

    /// Shared App Group identifier (must match entitlements for app + extension).
    ///
    /// Exposed for tooling/tests that need to create `FileManager`/`UserDefaults` suites directly.
    public static var appGroupIdentifier: String {
        AppGroupConfiguration.appGroupIdentifier
    }

    private static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    /// Shared App Group identifier (must match entitlements for app + extension)
    private let appGroupIdentifier = AppGroupStorage.appGroupIdentifier

    private let requestsDirectory = "CapturedRequests"
    private let configDirectory = "Configuration"
    private let webSocketDirectory = "WebSocketConnections"
    private let sseDirectory = "SSEConnections"
    private let sessionsDirectory = "CaptureSessions"
    private let packetFlowsDirectory = "PacketFlows"
    private let udpFlowsDirectory = "UDPFlows"
    private let throttlingConfigFileName = "throttling.json"
    private let captureOptionsFileName = "capture_options.json"
    private let bodyStorageConfigFileName = "body_storage.json"
    private let samplingConfigFileName = "sampling.json"
    private let configurationFileName = "configuration.json"
    private let mitmAllowlistFileName = "mitm_allowlist.json"

    private enum DefaultsKey {
        static let captureConfiguration = "trace.settings.captureConfiguration"
        static let captureOptions = "trace.settings.captureOptions"
        static let bodyStorageConfig = "trace.settings.bodyStorageConfig"
        static let samplingConfig = "trace.settings.samplingConfig"
        static let mitmAllowlist = "trace.settings.mitmAllowlist"
        static let throttlingState = "trace.settings.throttlingState"

        static let all: [String] = [
            captureConfiguration,
            captureOptions,
            bodyStorageConfig,
            samplingConfig,
            mitmAllowlist,
            throttlingState
        ]
    }

    /// Whether we're using fallback storage (local instead of App Group)
    private(set) var isUsingFallback = false

    /// Cached container URL to prevent repeated app group lookups
    private var _cachedContainerURL: URL?

    public var containerURL: URL? {
        // Return cached value if available
        if let cached = _cachedContainerURL {
            return cached
        }

        if Self.isSimulator {
            return fallbackContainerURL()
        }

        // Try to get App Group container first
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            _cachedContainerURL = appGroupURL
            return appGroupURL
        }

        return fallbackContainerURL()
    }

    public init() {
        setupDirectories()
        logStorageConfiguration()
    }

    // MARK: - Shared Defaults

    private var sharedUserDefaults: UserDefaults {
        if let defaults = UserDefaults(suiteName: appGroupIdentifier) {
            return defaults
        }
        CoreLog.storage.warning("event=storage.userdefaults outcome=fallback reason=suite_unavailable")
        return UserDefaults.standard
    }

    private func makeEncoder() -> JSONEncoder {
        JSONCoding.makeEncoder()
    }

    private func makeDecoder() -> JSONDecoder {
        JSONCoding.makeDecoder()
    }

    /// Clears UserDefaults-backed settings (does not delete captured requests).
    public func resetStoredSettings() {
        let defaults = sharedUserDefaults
        for key in DefaultsKey.all {
            defaults.removeObject(forKey: key)
        }

        // Best-effort cleanup of legacy, file-based settings.
        let legacyFiles = [
            configurationFileName,
            captureOptionsFileName,
            bodyStorageConfigFileName,
            samplingConfigFileName,
            mitmAllowlistFileName,
            throttlingConfigFileName
        ]
        for fileName in legacyFiles {
            if let url = configFileURL(for: fileName) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Setup

    private func setupDirectories() {
        guard let container = containerURL else {
            CoreLog.storage.error("event=storage.setup outcome=failure error=container_not_found")
            return
        }

        let directories = [
            container.appendingPathComponent(requestsDirectory),
            container.appendingPathComponent(configDirectory),
            container.appendingPathComponent(webSocketDirectory),
            container.appendingPathComponent(sseDirectory),
            container.appendingPathComponent(sessionsDirectory),
            container.appendingPathComponent(packetFlowsDirectory),
            container.appendingPathComponent(udpFlowsDirectory)
        ]

        for directory in directories {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                CoreLog.storage.error(
                    LogEvent.storage("create_directory")
                        .failure()
                        .with("directory", value: directory.lastPathComponent)
                        .error(error)
                )
            }
        }
    }

    private func logStorageConfiguration() {
        if isUsingFallback {
            CoreLog.storage.warning("event=storage.init outcome=fallback reason=app_group_unavailable")
            if Self.isSimulator {
                CoreLog.storage.info("event=storage.init_note reason=simulator_expected")
                CoreLog.storage.info("event=storage.init_note message=test_on_real_device_for_production")
            } else {
                CoreLog.storage.warning("event=storage.init_note reason=check_entitlements_and_provisioning")
            }
        } else {
            CoreLog.storage.info("event=storage.init outcome=success storage_type=app_group")
        }

        if let url = containerURL {
            CoreLog.storage.info("event=storage.location path=\(url.path, privacy: .private)")
        }

        // Note: In the simulator, you may see "container_create_or_lookup_app_group_path_by_app_group_identifier"
        // errors in the Xcode console when App Groups are not available. This is expected and handled by the
        // fallback storage mechanism. The containerURL is cached to minimize these lookups.
    }

    private func fallbackContainerURL() -> URL? {
        isUsingFallback = true
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let fallbackURL = documentsURL?.appendingPathComponent("AppGroupFallback")
        _cachedContainerURL = fallbackURL
        return fallbackURL
    }

    // MARK: - Request Storage

    /// Saves a captured request to the shared container
    public func saveRequest(_ request: NetworkRequest) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let requestsURL = container.appendingPathComponent(requestsDirectory)
        let fileName = "\(request.id.uuidString).json"
        let fileURL = requestsURL.appendingPathComponent(fileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)

        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Fallback: allow captures to persist even when the device is locked.
            CoreLog.storage.warning(
                LogEvent.storage("save_request")
                    .outcome(.failure)
                    .with("reason", value: "file_protection_retry")
                    .error(error)
            )
            try data.write(to: fileURL, options: [.atomic, .noFileProtection])
        }

        // Notify main app of new request
        notifyNewRequest()
    }

    /// Loads all captured requests from the shared container
    public func loadAllRequests() throws -> [NetworkRequest] {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let requestsURL = container.appendingPathComponent(requestsDirectory)

        guard FileManager.default.fileExists(atPath: requestsURL.path) else {
            return []
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: requestsURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var requests: [NetworkRequest] = []

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
                let request = try decoder.decode(NetworkRequest.self, from: data)
                requests.append(request)
            } catch {
                CoreLog.storage.error(
                    LogEvent.storage("load_request")
                        .failure()
                        .with("file", value: fileURL.lastPathComponent)
                        .error(error)
                )

                if let decodingError = error as? DecodingError {
                    let detail = switch decodingError {
                    case let .keyNotFound(key, context):
                        "Missing key '\(key.stringValue)' at: \(context.codingPath.map(\.stringValue).joined(separator: "."))"
                    case let .typeMismatch(type, context):
                        "Type mismatch for \(type) at: \(context.codingPath.map(\.stringValue).joined(separator: ".")) | \(context.debugDescription)"
                    case let .valueNotFound(type, context):
                        "Value not found for \(type) at: \(context.codingPath.map(\.stringValue).joined(separator: "."))"
                    case let .dataCorrupted(context):
                        "Data corrupted at: \(context.codingPath.map(\.stringValue).joined(separator: ".")) | \(context.debugDescription)"
                    @unknown default:
                        "Unknown decoding error for file \(fileURL.lastPathComponent)"
                    }
                    CoreLog.storage.debug("event=storage.decode_detail detail=\(detail, privacy: .public)")
                }

                if let data = try? Data(contentsOf: fileURL),
                   let jsonString = String(data: data, encoding: .utf8) {
                    let previewBytes = min(500, jsonString.utf8.count)
                    CoreLog.storage.debug(
                        "event=storage.json_preview bytes=\(data.count) preview_bytes=\(previewBytes)"
                    )
                }
            }
        }

        // Sort by timestamp, most recent first
        return requests.sorted { $0.timestamp > $1.timestamp }
    }

    /// Loads all captured requests from the shared container on a background queue
    public func loadAllRequestsAsync() async throws -> [NetworkRequest] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try continuation.resume(returning: self.loadAllRequests())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Async wrapper for loading requests (alias for loadAllRequestsAsync)
    public func loadRequests() async throws -> [NetworkRequest] {
        try await loadAllRequestsAsync()
    }

    // MARK: - Packet Flow Storage

    /// Saves a packet flow record to the shared container.
    public func savePacketFlowRecord(_ record: PacketFlowRecord) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let flowsURL = container.appendingPathComponent(packetFlowsDirectory)
        let fileName = "\(record.id.uuidString).json"
        let fileURL = flowsURL.appendingPathComponent(fileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        try data.write(to: fileURL, options: [.atomic])
    }

    /// Loads all packet flow records from the shared container.
    public func loadAllPacketFlowRecords() throws -> [PacketFlowRecord] {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let flowsURL = container.appendingPathComponent(packetFlowsDirectory)

        guard FileManager.default.fileExists(atPath: flowsURL.path) else {
            return []
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: flowsURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [PacketFlowRecord] = []

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let record = try decoder.decode(PacketFlowRecord.self, from: data)
                records.append(record)
            } catch {
                CoreLog.storage.error(
                    LogEvent.storage("load_packet_flow")
                        .failure()
                        .with("file", value: fileURL.lastPathComponent)
                        .error(error)
                )
            }
        }

        return records.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Deletes a packet flow record from the shared container.
    public func deletePacketFlowRecord(_ record: PacketFlowRecord) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let flowsURL = container.appendingPathComponent(packetFlowsDirectory)
        let fileURL = flowsURL.appendingPathComponent("\(record.id.uuidString).json")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Removes all packet flow records.
    public func clearAllPacketFlowRecords() throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let flowsURL = container.appendingPathComponent(packetFlowsDirectory)
        guard FileManager.default.fileExists(atPath: flowsURL.path) else { return }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: flowsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - UDP Flow Storage

    /// Saves UDP flow metadata to the shared container.
    public func saveUDPFlowMetadata(_ flow: UDPFlowMetadata) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let flowsURL = container.appendingPathComponent(udpFlowsDirectory)
        let fileName = "\(flow.id.uuidString).json"
        let fileURL = flowsURL.appendingPathComponent(fileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(flow)

        try data.write(to: fileURL, options: [.atomic])

        notifyNewUDPFlow()
    }

    /// Loads all UDP flow metadata from the shared container.
    public func loadAllUDPFlowMetadata() throws -> [UDPFlowMetadata] {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let flowsURL = container.appendingPathComponent(udpFlowsDirectory)
        guard FileManager.default.fileExists(atPath: flowsURL.path) else {
            return []
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: flowsURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var flows: [UDPFlowMetadata] = []
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let flow = try decoder.decode(UDPFlowMetadata.self, from: data)
                flows.append(flow)
            } catch {
                CoreLog.storage.error(
                    LogEvent.storage("load_udp_flow")
                        .failure()
                        .with("file", value: fileURL.lastPathComponent)
                        .error(error)
                )
            }
        }

        return flows.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Deletes a UDP flow metadata record from the shared container.
    public func deleteUDPFlowMetadata(_ id: UUID) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let flowsURL = container.appendingPathComponent(udpFlowsDirectory)
        let fileURL = flowsURL.appendingPathComponent("\(id.uuidString).json")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Removes all UDP flow metadata records.
    public func clearAllUDPFlowMetadata() throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let flowsURL = container.appendingPathComponent(udpFlowsDirectory)
        guard FileManager.default.fileExists(atPath: flowsURL.path) else { return }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: flowsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Loads all captured requests for a specific session
    public func loadRequestsForSession(_ sessionId: UUID) throws -> [NetworkRequest] {
        try loadAllRequests().filter { $0.sessionId == sessionId }
    }

    /// Saves multiple requests to the shared container
    public func saveRequests(_ requests: [NetworkRequest]) async throws {
        // Clear existing requests first
        try clearAllRequests()

        // Save all new requests
        for request in requests {
            try saveRequest(request)
        }
    }

    /// Deletes a specific request
    public func deleteRequest(_ requestID: UUID) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let requestsURL = container.appendingPathComponent(requestsDirectory)
        let fileName = "\(requestID.uuidString).json"
        let fileURL = requestsURL.appendingPathComponent(fileName)

        try deleteRequestFileAndBodies(at: fileURL)
    }

    /// Deletes a specific request (convenience overload)
    public func deleteRequest(_ request: NetworkRequest) throws {
        try deleteRequest(request.id)
    }

    /// Deletes all captured requests
    public func clearAllRequests() throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let requestsURL = container.appendingPathComponent(requestsDirectory)

        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: requestsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            try? deleteRequestFileAndBodies(at: fileURL)
        }

        deleteAllBodyFiles()
    }

    // MARK: - Generic Storage

    /// Load data from a file in the config directory
    public func loadData(from fileName: String) throws -> Data {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let fileURL = container
            .appendingPathComponent(configDirectory)
            .appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw StorageError.fileNotFound
        }

        return try Data(contentsOf: fileURL)
    }

    /// Save data to a file in the config directory
    public func saveData(_ data: Data, to fileName: String) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let fileURL = container
            .appendingPathComponent(configDirectory)
            .appendingPathComponent(fileName)

        try data.write(to: fileURL, options: [.atomic])
    }

    /// Get the URL for a config file in the shared container.
    public func configFileURL(for fileName: String) -> URL? {
        guard let container = containerURL else {
            return nil
        }

        return container
            .appendingPathComponent(configDirectory)
            .appendingPathComponent(fileName)
    }

    /// Get a direct file URL in the app group container root.
    public func appGroupFileURL(for fileName: String) -> URL? {
        guard let container = containerURL else {
            return nil
        }
        return container.appendingPathComponent(fileName)
    }

    /// Returns packet capture files in the app group container.
    public func packetCaptureFiles(prefixes: [String] = ["capture_raw_packets", "capture_http2_proxy", "packet_capture", "capture"]) -> [URL] {
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

    /// Get the last modification date for a config file, if it exists.
    public func configFileModificationDate(for fileName: String) -> Date? {
        guard let fileURL = configFileURL(for: fileName) else {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attributes?[.modificationDate] as? Date
    }

    // MARK: - Configuration Storage

    /// Saves capture configuration (filters, settings, etc.)
    public func saveConfiguration(_ config: CaptureConfiguration) throws {
        let data = try makeEncoder().encode(config)
        sharedUserDefaults.set(data, forKey: DefaultsKey.captureConfiguration)
    }

    /// Loads capture configuration
    public func loadConfiguration() -> CaptureConfiguration {
        if let data = sharedUserDefaults.data(forKey: DefaultsKey.captureConfiguration),
           let config = try? makeDecoder().decode(CaptureConfiguration.self, from: data) {
            return config
        }

        // Legacy migration: JSON file in App Group container.
        if let legacyData = try? loadData(from: configurationFileName),
           let legacyConfig = try? makeDecoder().decode(CaptureConfiguration.self, from: legacyData) {
            sharedUserDefaults.set(legacyData, forKey: DefaultsKey.captureConfiguration)
            return legacyConfig
        }

        return CaptureConfiguration.default
    }

    // MARK: - Capture Options

    public func saveCaptureOptions(_ options: CaptureOptions) throws {
        let normalized = options.normalized()
        let data = try makeEncoder().encode(normalized)
        sharedUserDefaults.set(data, forKey: DefaultsKey.captureOptions)
    }

    public func loadCaptureOptions() -> CaptureOptions {
        if let data = sharedUserDefaults.data(forKey: DefaultsKey.captureOptions),
           let options = try? makeDecoder().decode(CaptureOptions.self, from: data) {
            return options.normalized()
        }

        // Legacy migration: JSON file in App Group container.
        if let legacyData = try? loadData(from: captureOptionsFileName),
           let legacy = try? makeDecoder().decode(CaptureOptions.self, from: legacyData) {
            sharedUserDefaults.set(legacyData, forKey: DefaultsKey.captureOptions)
            return legacy.normalized()
        }

        try? saveCaptureOptions(.default)
        return CaptureOptions.default
    }

    // MARK: - Body Storage Configuration

    public func saveBodyStorageConfig(_ config: BodyStorageConfig) throws {
        let normalized = config.normalized()
        let data = try makeEncoder().encode(normalized)
        sharedUserDefaults.set(data, forKey: DefaultsKey.bodyStorageConfig)
    }

    public func loadBodyStorageConfig() -> BodyStorageConfig {
        if let data = sharedUserDefaults.data(forKey: DefaultsKey.bodyStorageConfig),
           let config = try? makeDecoder().decode(BodyStorageConfig.self, from: data) {
            return config.normalized()
        }

        // Legacy migration: JSON file in App Group container.
        if let legacyData = try? loadData(from: bodyStorageConfigFileName),
           let legacy = try? makeDecoder().decode(BodyStorageConfig.self, from: legacyData) {
            sharedUserDefaults.set(legacyData, forKey: DefaultsKey.bodyStorageConfig)
            return legacy.normalized()
        }

        try? saveBodyStorageConfig(.default)
        return BodyStorageConfig.default
    }

    // MARK: - Sampling Configuration

    public func saveSamplingConfig(_ config: SamplingConfig) throws {
        let normalized = config.normalized()
        let data = try makeEncoder().encode(normalized)
        sharedUserDefaults.set(data, forKey: DefaultsKey.samplingConfig)
    }

    public func loadSamplingConfig() -> SamplingConfig {
        if let data = sharedUserDefaults.data(forKey: DefaultsKey.samplingConfig),
           let config = try? makeDecoder().decode(SamplingConfig.self, from: data) {
            return config.normalized()
        }

        // Legacy migration: JSON file in App Group container.
        if let legacyData = try? loadData(from: samplingConfigFileName),
           let legacy = try? makeDecoder().decode(SamplingConfig.self, from: legacyData) {
            sharedUserDefaults.set(legacyData, forKey: DefaultsKey.samplingConfig)
            return legacy.normalized()
        }

        try? saveSamplingConfig(.default)
        return SamplingConfig.default
    }

    // MARK: - MITM Allowlist

    public func saveMITMAllowlist(_ allowlist: [String]) throws {
        let sanitized = sanitizeDomainList(allowlist)
        let data = try makeEncoder().encode(sanitized)
        sharedUserDefaults.set(data, forKey: DefaultsKey.mitmAllowlist)
    }

    public func loadMITMAllowlist() -> [String] {
        if let data = sharedUserDefaults.data(forKey: DefaultsKey.mitmAllowlist),
           let list = try? makeDecoder().decode([String].self, from: data) {
            return sanitizeDomainList(list)
        }

        // Legacy migration: JSON file in App Group container.
        if let legacyData = try? loadData(from: mitmAllowlistFileName),
           let legacy = try? makeDecoder().decode([String].self, from: legacyData) {
            sharedUserDefaults.set(legacyData, forKey: DefaultsKey.mitmAllowlist)
            return sanitizeDomainList(legacy)
        }

        try? saveMITMAllowlist(["*"])
        return ["*"]
    }

    // MARK: - Rewrite Rules Storage

    /// Saves rewrite rules to the shared container
    public func saveRewriteRules(_ rules: [RewriteRule]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(rules)
        try saveData(data, to: "rewrite_rules.json")
    }

    /// Loads rewrite rules from the shared container
    public func loadRewriteRules() async throws -> [RewriteRule] {
        do {
            let data = try loadData(from: "rewrite_rules.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RewriteRule].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    // MARK: - Request Maps Storage

    /// Saves request maps to the shared container
    public func saveRequestMaps(_ maps: [RequestMap]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(maps)
        try saveData(data, to: "request_maps.json")
    }

    /// Loads request maps from the shared container
    public func loadRequestMaps() async throws -> [RequestMap] {
        do {
            let data = try loadData(from: "request_maps.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RequestMap].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    // MARK: - Host Entries Storage

    /// Saves host entries to the shared container
    public func saveHostEntries(_ entries: [HostEntry]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try saveData(data, to: "host_entries.json")
    }

    /// Loads host entries from the shared container
    public func loadHostEntries() async throws -> [HostEntry] {
        do {
            let data = try loadData(from: "host_entries.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([HostEntry].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    // MARK: - Scripts Storage

    /// Saves scripts to the shared container
    public func saveScripts(_ scripts: [Script]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(scripts)
        try saveData(data, to: "scripts.json")
    }

    /// Loads scripts from the shared container
    public func loadScripts() async throws -> [Script] {
        do {
            let data = try loadData(from: "scripts.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Script].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    // MARK: - Breakpoints Storage

    /// Saves breakpoints to the shared container
    public func saveBreakpoints(_ breakpoints: [Breakpoint]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(breakpoints)
        try saveData(data, to: "breakpoints.json")
    }

    /// Loads breakpoints from the shared container
    public func loadBreakpoints() async throws -> [Breakpoint] {
        do {
            let data = try loadData(from: "breakpoints.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Breakpoint].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    // MARK: - Favorites Storage

    /// Saves favorites to the shared container
    public func saveFavorites(_ favorites: [Favorite]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(favorites)
        try saveData(data, to: "favorites.json")
    }

    /// Loads favorites from the shared container
    public func loadFavorites() async throws -> [Favorite] {
        do {
            let data = try loadData(from: "favorites.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Favorite].self, from: data)
        } catch StorageError.fileNotFound {
            return []
        }
    }

    // MARK: - Throttling Configuration

    /// Saves network throttling state for the tunnel provider.
    public func saveThrottlingState(_ state: NetworkThrottlingState) throws {
        let data = try makeEncoder().encode(state)
        sharedUserDefaults.set(data, forKey: DefaultsKey.throttlingState)
    }

    /// Loads network throttling state.
    public func loadThrottlingState() -> NetworkThrottlingState {
        if let data = sharedUserDefaults.data(forKey: DefaultsKey.throttlingState),
           let state = try? makeDecoder().decode(NetworkThrottlingState.self, from: data) {
            return state
        }

        // Legacy migration: JSON file in App Group container.
        if let legacyData = try? loadData(from: throttlingConfigFileName),
           let legacy = try? makeDecoder().decode(NetworkThrottlingState.self, from: legacyData) {
            sharedUserDefaults.set(legacyData, forKey: DefaultsKey.throttlingState)
            return legacy
        }

        return .disabled
    }

    // MARK: - WebSocket Storage

    /// Saves a WebSocket connection to the shared container
    public func saveWebSocketConnection(_ connection: WebSocketConnection) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let wsURL = container.appendingPathComponent(webSocketDirectory)
        let fileName = "\(connection.id.uuidString).json"
        let fileURL = wsURL.appendingPathComponent(fileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(connection)

        try data.write(to: fileURL)

        // Notify main app of new/updated WebSocket connection
        notifyNewWebSocket()
    }

    /// Loads all WebSocket connections from the shared container
    public func loadAllWebSocketConnections() throws -> [WebSocketConnection] {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let wsURL = container.appendingPathComponent(webSocketDirectory)

        guard FileManager.default.fileExists(atPath: wsURL.path) else {
            return []
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: wsURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var connections: [WebSocketConnection] = []

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            if let data = try? Data(contentsOf: fileURL),
               let connection = try? decoder.decode(WebSocketConnection.self, from: data) {
                connections.append(connection)
            }
        }

        // Sort by start time, most recent first
        return connections.sorted { $0.startTime > $1.startTime }
    }

    /// Deletes a specific WebSocket connection
    public func deleteWebSocketConnection(_ connectionID: UUID) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let wsURL = container.appendingPathComponent(webSocketDirectory)
        let fileName = "\(connectionID.uuidString).json"
        let fileURL = wsURL.appendingPathComponent(fileName)

        try FileManager.default.removeItem(at: fileURL)
    }

    /// Deletes all WebSocket connections
    public func clearAllWebSocketConnections() throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let wsURL = container.appendingPathComponent(webSocketDirectory)

        // Remove and recreate the directory
        try FileManager.default.removeItem(at: wsURL)
        try FileManager.default.createDirectory(at: wsURL, withIntermediateDirectories: true)
    }

    // MARK: - SSE Storage

    /// Saves an SSE connection to the shared container
    public func saveSSEConnection(_ connection: SSEConnection) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let sseURL = container.appendingPathComponent(sseDirectory)
        let fileName = "\(connection.id.uuidString).json"
        let fileURL = sseURL.appendingPathComponent(fileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(connection)

        try data.write(to: fileURL)

        // Notify main app of new/updated SSE connection
        notifyNewSSE()
    }

    /// Loads all SSE connections from the shared container
    public func loadAllSSEConnections() throws -> [SSEConnection] {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let sseURL = container.appendingPathComponent(sseDirectory)

        guard FileManager.default.fileExists(atPath: sseURL.path) else {
            return []
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: sseURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var connections: [SSEConnection] = []

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            if let data = try? Data(contentsOf: fileURL),
               let connection = try? decoder.decode(SSEConnection.self, from: data) {
                connections.append(connection)
            }
        }

        // Sort by start time, most recent first
        return connections.sorted { $0.startTime > $1.startTime }
    }

    /// Deletes a specific SSE connection
    public func deleteSSEConnection(_ connectionID: UUID) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let sseURL = container.appendingPathComponent(sseDirectory)
        let fileName = "\(connectionID.uuidString).json"
        let fileURL = sseURL.appendingPathComponent(fileName)

        try FileManager.default.removeItem(at: fileURL)
    }

    /// Deletes all SSE connections
    public func clearAllSSEConnections() throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let sseURL = container.appendingPathComponent(sseDirectory)

        // Remove and recreate the directory
        try FileManager.default.removeItem(at: sseURL)
        try FileManager.default.createDirectory(at: sseURL, withIntermediateDirectories: true)
    }

    // MARK: - Inter-Process Communication

    // Observers for notifications
    private let notificationObserversLock = NSLock()
    private var requestObservers: [UUID: NotificationObserver] = [:]
    private var webSocketObservers: [UUID: NotificationObserver] = [:]
    private var sseObservers: [UUID: NotificationObserver] = [:]
    private var udpFlowObservers: [UUID: NotificationObserver] = [:]

    /// Notifies the main app that a new request was captured
    private func notifyNewRequest() {
        // Use CFNotificationCenter for cross-process notifications
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notificationName = "com.trace.newRequest" as CFString

        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName), nil, nil, true)
    }

    /// Notifies the main app that a new WebSocket connection was created/updated
    private func notifyNewWebSocket() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notificationName = "com.trace.newWebSocket" as CFString

        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName), nil, nil, true)
    }

    /// Notifies the main app that a new SSE connection was created/updated
    private func notifyNewSSE() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notificationName = "com.trace.newSSE" as CFString

        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName), nil, nil, true)
    }

    /// Notifies the main app that a new UDP flow was recorded
    private func notifyNewUDPFlow() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notificationName = "com.trace.newUDPFlow" as CFString

        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName), nil, nil, true)
    }

    /// Sets up listener for new request notifications (call from main app).
    /// - Important: Retain the returned token; it auto-cancels observation on deinit.
    public func observeNewRequests(handler: @escaping @Sendable () -> Void) -> AppGroupStorageObserverToken {
        let id = UUID()
        let observer = NotificationObserver()
        observer.observe(notificationName: "com.trace.newRequest", handler: handler)
        notificationObserversLock.lock()
        requestObservers[id] = observer
        notificationObserversLock.unlock()

        return AppGroupStorageObserverToken { [weak self] in
            guard let self else { return }
            self.notificationObserversLock.lock()
            let observer = self.requestObservers.removeValue(forKey: id)
            self.notificationObserversLock.unlock()
            observer?.stop()
        }
    }

    public func stopObservingNewRequests() {
        notificationObserversLock.lock()
        let observers = Array(requestObservers.values)
        requestObservers.removeAll()
        notificationObserversLock.unlock()
        observers.forEach { $0.stop() }
    }

    /// Sets up listener for new WebSocket connection notifications (call from main app)
    /// - Important: Retain the returned token; it auto-cancels observation on deinit.
    public func observeNewWebSockets(handler: @escaping @Sendable () -> Void) -> AppGroupStorageObserverToken {
        let id = UUID()
        let observer = NotificationObserver()
        observer.observe(notificationName: "com.trace.newWebSocket", handler: handler)
        notificationObserversLock.lock()
        webSocketObservers[id] = observer
        notificationObserversLock.unlock()

        return AppGroupStorageObserverToken { [weak self] in
            guard let self else { return }
            self.notificationObserversLock.lock()
            let observer = self.webSocketObservers.removeValue(forKey: id)
            self.notificationObserversLock.unlock()
            observer?.stop()
        }
    }

    public func stopObservingNewWebSockets() {
        notificationObserversLock.lock()
        let observers = Array(webSocketObservers.values)
        webSocketObservers.removeAll()
        notificationObserversLock.unlock()
        observers.forEach { $0.stop() }
    }

    /// Sets up listener for new SSE connection notifications (call from main app)
    /// - Important: Retain the returned token; it auto-cancels observation on deinit.
    public func observeNewSSE(handler: @escaping @Sendable () -> Void) -> AppGroupStorageObserverToken {
        let id = UUID()
        let observer = NotificationObserver()
        observer.observe(notificationName: "com.trace.newSSE", handler: handler)
        notificationObserversLock.lock()
        sseObservers[id] = observer
        notificationObserversLock.unlock()

        return AppGroupStorageObserverToken { [weak self] in
            guard let self else { return }
            self.notificationObserversLock.lock()
            let observer = self.sseObservers.removeValue(forKey: id)
            self.notificationObserversLock.unlock()
            observer?.stop()
        }
    }

    public func stopObservingNewSSE() {
        notificationObserversLock.lock()
        let observers = Array(sseObservers.values)
        sseObservers.removeAll()
        notificationObserversLock.unlock()
        observers.forEach { $0.stop() }
    }

    /// Sets up listener for new UDP flow notifications (call from main app)
    /// - Important: Retain the returned token; it auto-cancels observation on deinit.
    public func observeNewUDPFlows(handler: @escaping @Sendable () -> Void) -> AppGroupStorageObserverToken {
        let id = UUID()
        let observer = NotificationObserver()
        observer.observe(notificationName: "com.trace.newUDPFlow", handler: handler)
        notificationObserversLock.lock()
        udpFlowObservers[id] = observer
        notificationObserversLock.unlock()

        return AppGroupStorageObserverToken { [weak self] in
            guard let self else { return }
            self.notificationObserversLock.lock()
            let observer = self.udpFlowObservers.removeValue(forKey: id)
            self.notificationObserversLock.unlock()
            observer?.stop()
        }
    }

    public func stopObservingNewUDPFlows() {
        notificationObserversLock.lock()
        let observers = Array(udpFlowObservers.values)
        udpFlowObservers.removeAll()
        notificationObserversLock.unlock()
        observers.forEach { $0.stop() }
    }

    // MARK: - Statistics

    /// Returns storage statistics
    public func getStorageStats() -> StorageStats {
        guard let container = containerURL else {
            return StorageStats(totalRequests: 0, totalSize: 0)
        }

        let requestsURL = container.appendingPathComponent(requestsDirectory)

        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: requestsURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StorageStats(totalRequests: 0, totalSize: 0)
        }

        let totalSize = fileURLs.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + size
        }

        return StorageStats(
            totalRequests: fileURLs.count(where: { $0.pathExtension == "json" }),
            totalSize: Int64(totalSize)
        )
    }

    // MARK: - Request Helpers

    private func deleteRequestFileAndBodies(at fileURL: URL) throws {
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let request = try? decoder.decode(NetworkRequest.self, from: data) {
                request.requestBody.deleteFile()
                request.responseBody.deleteFile()
            }
        }

        try FileManager.default.removeItem(at: fileURL)
    }

    private func deleteAllBodyFiles() {
        guard let container = containerURL else { return }

        let bodiesURL = container.appendingPathComponent("Bodies")
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: bodiesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func sanitizeDomainList(_ list: [String]) -> [String] {
        let cleaned = list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? ["*"] : cleaned
    }

    // MARK: - Session Storage

    /// Saves multiple sessions to the shared container (async)
    public func saveSessions(_ sessions: [CaptureSession]) async throws {
        for session in sessions {
            try saveSession(session)
        }
    }

    /// Loads all sessions from storage (async)
    public func loadSessions() async throws -> [CaptureSession] {
        try loadAllSessions()
    }

    /// Saves a capture session to the shared container
    public func saveSession(_ session: CaptureSession) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let sessionsURL = container.appendingPathComponent(sessionsDirectory)
        let fileURL = sessionsURL.appendingPathComponent("\(session.id.uuidString).json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(session) else {
            throw StorageError.encodingFailed
        }

        try data.write(to: fileURL, options: [.atomic])
        CoreLog.storage.debug("event=storage.session_save outcome=success session_id=\(session.id.uuidString, privacy: .public)")
    }

    /// Loads all capture sessions from storage
    public func loadAllSessions() throws -> [CaptureSession] {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let sessionsURL = container.appendingPathComponent(sessionsDirectory)

        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var sessions: [CaptureSession] = []
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let session = try? decoder.decode(CaptureSession.self, from: data) else {
                continue
            }
            sessions.append(session)
        }

        return sessions.sorted { $0.startTime > $1.startTime }
    }

    /// Deletes a specific session from storage
    public func deleteSession(_ sessionID: UUID) throws {
        guard let container = containerURL else {
            throw StorageError.containerNotFound
        }

        let sessionsURL = container.appendingPathComponent(sessionsDirectory)
        let fileURL = sessionsURL.appendingPathComponent("\(sessionID.uuidString).json")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
            CoreLog.storage.debug("event=storage.session_delete outcome=success session_id=\(sessionID.uuidString, privacy: .public)")
        }
    }

    /// Updates an existing session (same as save, but with explicit semantics)
    public func updateSession(_ session: CaptureSession) throws {
        try saveSession(session)
    }
}

// MARK: - App Group Configuration

public enum AppGroupConfiguration {
    /// Centralized App Group identifier to keep the main app and extension in sync.
    public static let appGroupIdentifier: String = {
        // Allow overriding via Info.plist so release builds can set the correct group without code changes.
        if let infoIdentifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           let sanitized = sanitizeIdentifier(infoIdentifier) {
            return sanitized
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            return "group.\(bundleIdentifier)"
        }

        return "group.unknown"
    }()

    private static func sanitizeIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
        return trimmed
    }
}

// MARK: - Configuration Model

public enum CaptureMode: String, Codable, Sendable {
    case proxyOnly
    case fullTunnel
}

public enum UDPForwardingMode: String, Codable, Sendable {
    case hevOnly
    case direct
    case split
}

public struct CaptureConfiguration: Codable, Sendable {
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
            fullTunnelUDPForwardingMode: .hevOnly
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
        fullTunnelUDPForwardingMode: UDPForwardingMode
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(filterMode, forKey: .filterMode)
        try container.encode(domainFilters, forKey: .domainFilters)
        try container.encode(captureHeaders, forKey: .captureHeaders)
        try container.encode(captureBody, forKey: .captureBody)
        try container.encode(maxBodySize, forKey: .maxBodySize)
        try container.encode(captureMode, forKey: .captureMode)
        try container.encode(fullTunnelDNSServers, forKey: .fullTunnelDNSServers)
        try container.encode(fullTunnelSearchDomains, forKey: .fullTunnelSearchDomains)
        try container.encode(fullTunnelIPv6Enabled, forKey: .fullTunnelIPv6Enabled)
        try container.encode(fullTunnelSocks5Host, forKey: .fullTunnelSocks5Host)
        try container.encode(fullTunnelSocks5Port, forKey: .fullTunnelSocks5Port)
        try container.encode(fullTunnelUDPForwardingMode, forKey: .fullTunnelUDPForwardingMode)
    }
}

public enum FilterMode: String, Codable, Sendable {
    case all // Capture everything
    case whitelist // Only capture specified domains
    case blacklist // Capture everything except specified domains
}

// MARK: - Storage Stats

public struct StorageStats {
    public let totalRequests: Int
    public let totalSize: Int64

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

// MARK: - Errors

public enum StorageError: LocalizedError, Equatable {
    case containerNotFound
    case encodingFailed
    case decodingFailed
    case fileNotFound

    public var errorDescription: String? {
        switch self {
        case .containerNotFound:
            "App Group container not found. Ensure App Group is configured in entitlements."
        case .encodingFailed:
            "Failed to encode data"
        case .decodingFailed:
            "Failed to decode data"
        case .fileNotFound:
            "File not found"
        }
    }
}

// MARK: - NetworkRequest Codable Extension

extension NetworkRequest: Codable {
    enum CodingKeys: String, CodingKey {
        case id, url, method, statusCode, statusMessage, timestamp, duration
        case requestHeaders, responseHeaders, requestBody, responseBody, protocolVersion, sessionId
        case timingPhases, tlsInfo
        case wasThrottled, throttlingProfile
        case isDuplicate, duplicateOfRequestId
        case isManual
        case wasBlocked, wasCancelled, wasRewritten, isMocked, isReplayed
        case appliedScriptName, hitBreakpoint, retryAttempts
        case executionLog, executionErrors, appliedRuleIds
        case contentType, contentEncoding, userAgent, cacheControl
        case requestCookies, responseCookies
        case queryParameters, authorization, tlsAlerts
        case http2Streams, http2ConnectionInfo
        case redirectChain
    }

    private struct QueryItemStorage: Codable {
        let name: String
        let value: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.url = try container.decode(String.self, forKey: .url)
        self.method = try container.decode(HTTPMethod.self, forKey: .method)
        self.statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.duration = try container.decode(TimeInterval.self, forKey: .duration)
        self.requestHeaders = try container.decode([TraceHTTPHeader].self, forKey: .requestHeaders)
        self.responseHeaders = try container.decode([TraceHTTPHeader].self, forKey: .responseHeaders)

        // Support legacy String? format for backward compatibility
        // Use try? to handle type mismatches (when it's actually a BodyStorage dictionary)
        if let bodyString = try? container.decode(String.self, forKey: .requestBody) {
            self.requestBody = BodyStorage.fromLegacyString(bodyString)
        } else {
            self.requestBody = try container.decodeIfPresent(BodyStorage.self, forKey: .requestBody) ?? .empty
        }

        if let bodyString = try? container.decode(String.self, forKey: .responseBody) {
            self.responseBody = BodyStorage.fromLegacyString(bodyString)
        } else {
            self.responseBody = try container.decodeIfPresent(BodyStorage.self, forKey: .responseBody) ?? .empty
        }

        self.protocolVersion = try container.decodeIfPresent(HTTPProtocolVersion.self, forKey: .protocolVersion)
        self.sessionId = try container.decodeIfPresent(UUID.self, forKey: .sessionId)

        self.timingPhases = try container.decodeIfPresent(NetworkTimingPhases.self, forKey: .timingPhases)
        self.tlsInfo = try container.decodeIfPresent(TLSConnectionInfo.self, forKey: .tlsInfo)
        self.wasThrottled = try container.decodeIfPresent(Bool.self, forKey: .wasThrottled) ?? false
        self.throttlingProfile = try container.decodeIfPresent(String.self, forKey: .throttlingProfile)
        self.isDuplicate = try container.decodeIfPresent(Bool.self, forKey: .isDuplicate) ?? false
        self.duplicateOfRequestId = try container.decodeIfPresent(UUID.self, forKey: .duplicateOfRequestId)
        self.isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        self.wasBlocked = try container.decodeIfPresent(Bool.self, forKey: .wasBlocked) ?? false
        self.wasCancelled = try container.decodeIfPresent(Bool.self, forKey: .wasCancelled) ?? false
        self.wasRewritten = try container.decodeIfPresent(Bool.self, forKey: .wasRewritten) ?? false
        self.isMocked = try container.decodeIfPresent(Bool.self, forKey: .isMocked) ?? false
        self.isReplayed = try container.decodeIfPresent(Bool.self, forKey: .isReplayed) ?? false
        self.appliedScriptName = try container.decodeIfPresent(String.self, forKey: .appliedScriptName)
        self.hitBreakpoint = try container.decodeIfPresent(Bool.self, forKey: .hitBreakpoint) ?? false
        self.retryAttempts = try container.decodeIfPresent(Int.self, forKey: .retryAttempts) ?? 0
        self.executionLog = try container.decodeIfPresent([ExecutionLogEntry].self, forKey: .executionLog) ?? []
        self.executionErrors = try container.decodeIfPresent([ExecutionError].self, forKey: .executionErrors) ?? []
        self.appliedRuleIds = try container.decodeIfPresent([UUID].self, forKey: .appliedRuleIds) ?? []
        self.contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        self.contentEncoding = try container.decodeIfPresent(String.self, forKey: .contentEncoding)
        self.userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        self.cacheControl = try container.decodeIfPresent(String.self, forKey: .cacheControl)
        self.requestCookies = try container.decodeIfPresent([HTTPCookie].self, forKey: .requestCookies)
        self.responseCookies = try container.decodeIfPresent([HTTPCookie].self, forKey: .responseCookies)
        if let storedQueryItems = try container.decodeIfPresent([QueryItemStorage].self, forKey: .queryParameters) {
            self.queryParameters = storedQueryItems.map { URLQueryItem(name: $0.name, value: $0.value) }
        } else {
            self.queryParameters = nil
        }
        self.authorization = try container.decodeIfPresent(String.self, forKey: .authorization)
        self.tlsAlerts = try container.decodeIfPresent([TLSAlertMessage].self, forKey: .tlsAlerts)
        self.http2Streams = try container.decodeIfPresent([HTTP2StreamInfo].self, forKey: .http2Streams)
        self.http2ConnectionInfo = try container.decodeIfPresent(HTTP2ConnectionInfo.self, forKey: .http2ConnectionInfo)
        self.redirectChain = try container.decodeIfPresent([RedirectInfo].self, forKey: .redirectChain) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(duration, forKey: .duration)
        try container.encode(requestHeaders, forKey: .requestHeaders)
        try container.encode(responseHeaders, forKey: .responseHeaders)
        try container.encode(requestBody, forKey: .requestBody)
        try container.encode(responseBody, forKey: .responseBody)
        try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(timingPhases, forKey: .timingPhases)
        try container.encodeIfPresent(tlsInfo, forKey: .tlsInfo)
        try container.encode(wasThrottled, forKey: .wasThrottled)
        try container.encodeIfPresent(throttlingProfile, forKey: .throttlingProfile)
        try container.encode(isDuplicate, forKey: .isDuplicate)
        try container.encodeIfPresent(duplicateOfRequestId, forKey: .duplicateOfRequestId)
        try container.encode(isManual, forKey: .isManual)
        try container.encode(wasBlocked, forKey: .wasBlocked)
        try container.encode(wasCancelled, forKey: .wasCancelled)
        try container.encode(wasRewritten, forKey: .wasRewritten)
        try container.encode(isMocked, forKey: .isMocked)
        try container.encode(isReplayed, forKey: .isReplayed)
        try container.encodeIfPresent(appliedScriptName, forKey: .appliedScriptName)
        try container.encode(hitBreakpoint, forKey: .hitBreakpoint)
        try container.encode(retryAttempts, forKey: .retryAttempts)
        try container.encode(executionLog, forKey: .executionLog)
        try container.encode(executionErrors, forKey: .executionErrors)
        try container.encode(appliedRuleIds, forKey: .appliedRuleIds)
        try container.encodeIfPresent(contentType, forKey: .contentType)
        try container.encodeIfPresent(contentEncoding, forKey: .contentEncoding)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encodeIfPresent(cacheControl, forKey: .cacheControl)
        try container.encodeIfPresent(requestCookies, forKey: .requestCookies)
        try container.encodeIfPresent(responseCookies, forKey: .responseCookies)
        let storedQueryItems = queryParameters?.map { QueryItemStorage(name: $0.name, value: $0.value) }
        try container.encodeIfPresent(storedQueryItems, forKey: .queryParameters)
        try container.encodeIfPresent(authorization, forKey: .authorization)
        try container.encodeIfPresent(tlsAlerts, forKey: .tlsAlerts)
        try container.encodeIfPresent(http2Streams, forKey: .http2Streams)
        try container.encodeIfPresent(http2ConnectionInfo, forKey: .http2ConnectionInfo)
        try container.encode(redirectChain, forKey: .redirectChain)
    }
}

extension HTTPMethod: Codable {}

// MARK: - Notification Observer Helper

/// Helper class to properly manage CFNotificationCenter observer lifecycle
public class NotificationObserver {
    private let lock = NSLock()
    private var observer: UnsafeMutableRawPointer?
    private var handler: (@Sendable () -> Void)?
    private var notificationName: CFString?

    public func stop() {
        lock.lock()
        let observer = observer
        let notificationName = notificationName
        self.observer = nil
        self.notificationName = nil
        handler = nil
        lock.unlock()

        guard let observer, let notificationName else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            CFNotificationName(notificationName),
            nil
        )
        Unmanaged<NotificationObserver>.fromOpaque(observer).release()
    }

    public func observe(notificationName: String, handler: @escaping @Sendable () -> Void) {
        stop()

        lock.lock()
        self.handler = handler
        self.notificationName = notificationName as CFString
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        lock.unlock()

        // Use a weak reference pattern
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let instance = Unmanaged<NotificationObserver>.fromOpaque(observer).takeUnretainedValue()
            let handler = instance.handler
            DispatchQueue.main.async {
                handler?()
            }
        }

        lock.lock()
        self.observer = Unmanaged.passRetained(self).toOpaque()
        let observer = self.observer
        let name = self.notificationName
        lock.unlock()
        CFNotificationCenterAddObserver(
            center,
            observer,
            callback,
            name,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        stop()
    }
}

public final class AppGroupStorageObserverToken: @unchecked Sendable {
    private var cancelHandler: (() -> Void)?
    private let cancelLock = NSLock()

    public init(_ cancelHandler: @escaping () -> Void) {
        self.cancelHandler = cancelHandler
    }

    public func cancel() {
        cancelLock.lock()
        let handler = cancelHandler
        cancelHandler = nil
        cancelLock.unlock()
        handler?()
    }

    deinit {
        cancel()
    }
}
