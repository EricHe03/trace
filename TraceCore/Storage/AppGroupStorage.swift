//
//  AppGroupStorage.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import GRDB

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

    private static let isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static var allowsFallbackStorage: Bool {
        isSimulator || isRunningTests
    }

    /// Shared App Group identifier (must match entitlements for app + extension)
    private let appGroupIdentifier = AppGroupStorage.appGroupIdentifier

    private let requestsDirectory = "CapturedRequests"
    private let configDirectory = "Configuration"
    private let webSocketDirectory = "WebSocketConnections"
    private let sseDirectory = "SSEConnections"
    private let sessionsDirectory = "CaptureSessions"
    private let transportRequestsDirectory = "TransportRequests"
    private let packetFlowsDirectory = "PacketFlows"
    private let udpFlowsDirectory = "UDPFlows"
    private let throttlingConfigFileName = "throttling.json"
    private let captureOptionsFileName = "capture_options.json"
    private let bodyStorageConfigFileName = "body_storage.json"
    private let samplingConfigFileName = "sampling.json"
    private let configurationFileName = "configuration.json"
    private let mitmAllowlistFileName = "mitm_allowlist.json"
    private static let defaultTransportStoreBudgetBytes = 512 * 1024 * 1024
    private static let transportPruneMinInterval: TimeInterval = 5
    private static let transportPruneWriteThresholdBytes = 8 * 1024 * 1024
    private static let hardCutoverMarkerKey = "storage.grdb_hard_cutover_v1"
    private static let streamPayloadInlineLimitBytes = 256 * 1024
    private static let streamPayloadChunkSizeBytes = 64 * 1024

    enum DefaultsKey {
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

    /// Whether we're using fallback storage (tests/simulator only).
    private(set) var isUsingFallback = false

    /// Whether the app group container/defaults are unavailable on a real device build.
    private(set) var isMisconfigured = false

    /// Cached container URL to prevent repeated app group lookups
    private var _cachedContainerURL: URL?
    private let containerURLLock = NSLock()
    private let transportStoreBudgetLock = NSLock()
    private let transportPruneStateLock = NSLock()
    private var transportStoreBudgetBytes = AppGroupStorage.defaultTransportStoreBudgetBytes
    private var lastTransportPruneAt: Date = .distantPast
    private var transportBytesWrittenSinceLastPrune = 0
    private var didLogMisconfiguration = false
    private let databaseLock = NSLock()
    private var database: TraceDatabase?

    public var containerURL: URL? {
        containerURLLock.lock()
        defer { containerURLLock.unlock() }

        // Return cached value if available
        if let cached = _cachedContainerURL {
            return cached
        }

        if Self.allowsFallbackStorage {
            return fallbackContainerURLLocked()
        }

        // Try to get App Group container first
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            _cachedContainerURL = appGroupURL
            return appGroupURL
        }

        isMisconfigured = true
        if !didLogMisconfiguration {
            didLogMisconfiguration = true
            CoreLog.storage.error("event=storage.app_group_unavailable outcome=failure app_group=\(self.appGroupIdentifier, privacy: .private)")
        }
        return nil
    }

    public init() {
        setupDirectories()
        initializeDatabase()
        performHardCutoverIfNeeded()
        logStorageConfiguration()
    }

    func makeEncoder() -> JSONEncoder {
        JSONCoding.makeEncoder()
    }

    func makeDecoder() -> JSONDecoder {
        JSONCoding.makeDecoder()
    }

    /// Clears DB-backed settings (does not delete captured requests).
    public func resetStoredSettings() {
        executeDBWrite { db in
            try db.execute(sql: "DELETE FROM settings_kv")
            try db.execute(sql: "DELETE FROM config_blobs")
            try db.execute(sql: "DELETE FROM mitm_auto_bypass_entries")
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

        let defaults = sharedUserDefaultsForCleanup()
        for key in DefaultsKey.all {
            defaults.removeObject(forKey: key)
        }
        removeLegacySharedDefaultsKeys(from: defaults)
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
            container.appendingPathComponent(transportRequestsDirectory),
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
        if isMisconfigured {
            CoreLog.storage.error("event=storage.init outcome=failure reason=app_group_unavailable app_group=\(self.appGroupIdentifier, privacy: .private)")
        } else if isUsingFallback {
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

    private func fallbackContainerURLLocked() -> URL? {
        isUsingFallback = true
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let fallbackURL = documentsURL?.appendingPathComponent("AppGroupFallback")
        _cachedContainerURL = fallbackURL
        return fallbackURL
    }

    // MARK: - Database

    enum SettingScope {
        static let capture = "capture_settings"
        static let hardening = "hardening"
        static let widget = "widget"
        static let widgetAction = "widget_action"
        static let mitmAutoBypassMeta = "mitm_auto_bypass_meta"
    }

    private enum LegacyHardeningKey {
        static let all = [
            "hardening.enableRobustReassembly",
            "hardening.enableMetrics",
            "hardening.enableDebugLogging",
            "hardening.rolloutStage",
            "hardening.enableRawCapture",
            "hardening.maxRawCaptureSize",
            "hardening.mitmAllowlist",
            "hardening.quicHandlingMode",
            "hardening.blockQUIC",
            "hardening.enableNIOMITM",
            "hardening.enableNetworkFrameworkMITM",
            "hardening.dualMitmPolicyEngineShadow",
            "hardening.dualMitmPolicyEngineEnforcedTCP",
            "hardening.dualMitmPolicyEngineEnforcedProxy",
            "hardening.dualMitmPolicyEngineEnforcedQUIC",
            "hardening.dualMitmMITMEngineV2",
            "hardening.dualMitmHttp2MITMEnabled",
            "hardening.dualMitmStrictEnforcementHardFail",
            "hardening.enableStreamInterceptionV2"
        ]
    }

    private enum LegacyWidgetKey {
        static let all = [
            "widget.isCapturing",
            "widget.requestCount",
            "widget.dataTransferred",
            "widget.recentRequests",
            WidgetActionKey.action,
            WidgetActionKey.actionDate,
            WidgetActionKey.actionView
        ]
    }

    private enum LegacyMITMAutoBypassKey {
        static let all = [
            "proxy.mitm_auto_bypass.entries.v1",
            "proxy.mitm_auto_bypass.cleanup_legacy_trust_failures.v1",
            "proxy.mitm_auto_bypass.cleanup_legacy_transient_setup_failures.v1",
            "proxy.mitm_auto_bypass.cleanup_legacy_quic_failures.v1"
        ]
    }

    private func initializeDatabase() {
        guard let container = containerURL else {
            CoreLog.storage.error("event=storage.database_init outcome=failure reason=container_not_found")
            return
        }

        let databaseURL = container.appendingPathComponent("trace.sqlite")
        do {
            let db = try TraceDatabase(databaseURL: databaseURL)
            databaseLock.lock()
            database = db
            databaseLock.unlock()
            CoreLog.storage.info("event=storage.database_init outcome=success")
        } catch {
            databaseLock.lock()
            database = nil
            databaseLock.unlock()
            CoreLog.storage.error(
                LogEvent.storage("database_init")
                    .failure()
                    .error(error)
            )
        }
    }

    func withDatabase<T>(_ body: (DatabasePool) throws -> T) throws -> T {
        databaseLock.lock()
        let pool = database?.pool
        databaseLock.unlock()
        guard let pool else {
            throw StorageError.databaseUnavailable
        }
        return try body(pool)
    }

    @discardableResult
    func executeDBWrite(_ body: (Database) throws -> Void) -> Bool {
        do {
            try withDatabase { pool in
                try pool.write { db in
                    try body(db)
                }
            }
            return true
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("db_write")
                    .failure()
                    .error(error)
            )
            return false
        }
    }

    private func performHardCutoverIfNeeded() {
        let shouldCutover: Bool
        do {
            shouldCutover = try withDatabase { pool in
                try pool.read { db in
                    try String.fetchOne(
                        db,
                        sql: "SELECT value FROM storage_metadata WHERE key = ?",
                        arguments: [Self.hardCutoverMarkerKey]
                    ) == nil
                }
            }
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("hard_cutover_check")
                    .failure()
                    .error(error)
            )
            return
        }

        guard shouldCutover else { return }

        clearLegacyStorageArtifacts()

        _ = executeDBWrite { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "DELETE FROM network_requests")
            try db.execute(sql: "DELETE FROM transport_requests")
            try db.execute(sql: "DELETE FROM capture_sessions")
            try db.execute(sql: "DELETE FROM packet_flows")
            try db.execute(sql: "DELETE FROM udp_flows")
            try db.execute(sql: "DELETE FROM websocket_connections")
            try db.execute(sql: "DELETE FROM sse_connections")
            try db.execute(sql: "DELETE FROM stream_payload_chunks")
            try db.execute(sql: "DELETE FROM stream_events")
            try db.execute(sql: "DELETE FROM stream_replays")
            try db.execute(sql: "DELETE FROM stream_sessions")
            try db.execute(sql: "DELETE FROM config_blobs")
            try db.execute(sql: "DELETE FROM settings_kv")
            try db.execute(sql: "DELETE FROM mitm_auto_bypass_entries")
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO storage_metadata (key, value, updated_at)
                VALUES (?, ?, ?)
                """,
                arguments: [Self.hardCutoverMarkerKey, "completed", now]
            )
        }
        CoreLog.storage.info("event=storage.hard_cutover outcome=success")
    }

    private func clearLegacyStorageArtifacts() {
        guard let container = containerURL else { return }

        let directories = [
            requestsDirectory,
            transportRequestsDirectory,
            packetFlowsDirectory,
            udpFlowsDirectory,
            webSocketDirectory,
            sseDirectory,
            sessionsDirectory
        ]
        for directory in directories {
            let url = container.appendingPathComponent(directory)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        if let configURL = configFileURL(for: "")?.deletingLastPathComponent() {
            let knownLegacyFiles = [
                configurationFileName,
                captureOptionsFileName,
                bodyStorageConfigFileName,
                samplingConfigFileName,
                mitmAllowlistFileName,
                throttlingConfigFileName,
                "DNSMessages.json",
                "BreakpointConfiguration.json",
                "rewrite_rules.json",
                "request_maps.json",
                "host_entries.json",
                "scripts.json",
                "breakpoints.json",
                "favorites.json",
                "RewriteRules.json",
                "RequestMaps.json",
                "HostEntries.json",
                "Scripts.json",
                "RuleGroups.json",
                "Profiles.json",
                "BreakpointPresets.json",
                "Favorites.json"
            ]
            for fileName in knownLegacyFiles {
                try? FileManager.default.removeItem(at: configURL.appendingPathComponent(fileName))
            }
        }

        deleteAllBodyFiles()

        let defaults = sharedUserDefaultsForCleanup()
        for key in DefaultsKey.all {
            defaults.removeObject(forKey: key)
        }
        removeLegacySharedDefaultsKeys(from: defaults)
    }

    private func sharedUserDefaultsForCleanup() -> UserDefaults {
        if let defaults = UserDefaults(suiteName: appGroupIdentifier) {
            return defaults
        }
        return UserDefaults.standard
    }

    private func removeLegacySharedDefaultsKeys(from defaults: UserDefaults) {
        for key in LegacyHardeningKey.all {
            defaults.removeObject(forKey: key)
        }
        for key in LegacyWidgetKey.all {
            defaults.removeObject(forKey: key)
        }
        for key in LegacyMITMAutoBypassKey.all {
            defaults.removeObject(forKey: key)
        }
    }

    func settingData(for scope: String, key: String) -> Data? {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    try Data.fetchOne(
                        db,
                        sql: "SELECT value FROM settings_kv WHERE scope = ? AND key = ?",
                        arguments: [scope, key]
                    )
                }
            }
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("setting_read")
                    .failure()
                    .with("scope", value: scope)
                    .with("key", value: key, privacy: .public)
                    .error(error)
            )
            return nil
        }
    }

    func saveSettingData(_ data: Data, scope: String, key: String) throws {
        try withDatabase { pool in
            try pool.write { db in
                let now = Date().timeIntervalSince1970
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO settings_kv (scope, key, value, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [scope, key, data, now]
                )
            }
        }
    }

    func saveSettingValue(_ value: some Encodable, scope: String, key: String) throws {
        let data = try makeEncoder().encode(value)
        try saveSettingData(data, scope: scope, key: key)
    }

    func loadSettingValue<T: Decodable>(_ type: T.Type, scope: String, key: String) -> T? {
        guard let data = settingData(for: scope, key: key) else { return nil }
        return try? makeDecoder().decode(T.self, from: data)
    }

    func removeSetting(scope: String, key: String) throws {
        try withDatabase { pool in
            try pool.write { db in
                try db.execute(
                    sql: "DELETE FROM settings_kv WHERE scope = ? AND key = ?",
                    arguments: [scope, key]
                )
            }
        }
    }

    func mapDatabaseError(_ error: Error) -> StorageError {
        if let storageError = error as? StorageError {
            return storageError
        }
        return .databaseUnavailable
    }

    private var streamInterceptionV2Enabled: Bool {
        loadSettingValue(Bool.self, scope: SettingScope.hardening, key: "hardening.enableStreamInterceptionV2") ?? false
    }

    // MARK: - Request Storage

    /// Saves a captured request to the shared container
    public func saveRequest(_ request: NetworkRequest) throws {
        let payload = try makeEncoder().encode(request)
        let now = Date().timeIntervalSince1970
        let sessionID = request.sessionId?.uuidString
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: """
                INSERT INTO network_requests (id, timestamp, session_id, url, payload, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    timestamp = excluded.timestamp,
                    session_id = excluded.session_id,
                    url = excluded.url,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    request.id.uuidString,
                    request.timestamp.timeIntervalSince1970,
                    sessionID,
                    request.url,
                    payload,
                    now,
                    now
                ]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }

        // Notify main app of new request
        notifyNewRequest()
    }

    /// Loads all captured requests from the shared container
    public func loadAllRequests() throws -> [NetworkRequest] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM network_requests
                        ORDER BY timestamp DESC, id DESC
                        """
                    )

                    var requests: [NetworkRequest] = []
                    requests.reserveCapacity(rows.count)
                    let decoder = makeDecoder()
                    for row in rows {
                        let payload: Data = row["payload"]
                        do {
                            try requests.append(decoder.decode(NetworkRequest.self, from: payload))
                        } catch {
                            CoreLog.storage.error(
                                LogEvent.storage("load_request")
                                    .failure()
                                    .error(error)
                            )
                        }
                    }
                    return requests
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
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

    /// Loads captured requests newer than the given timestamp.
    public func loadRequests(
        newerThan timestamp: Date,
        excludingIDs: Set<UUID> = [],
        limit: Int? = nil
    ) throws -> [NetworkRequest] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, payload
                        FROM network_requests
                        WHERE timestamp >= ?
                        ORDER BY timestamp DESC, id DESC
                        """,
                        arguments: [timestamp.timeIntervalSince1970]
                    )

                    let excluded = Set(excludingIDs.map(\.uuidString))
                    let effectiveLimit = limit.map { max(0, $0) }
                    if let effectiveLimit, effectiveLimit == 0 {
                        return []
                    }

                    let decoder = makeDecoder()
                    var requests: [NetworkRequest] = []
                    requests.reserveCapacity(rows.count)

                    for row in rows {
                        if let effectiveLimit, requests.count >= effectiveLimit {
                            break
                        }

                        let requestID: String = row["id"]
                        if excluded.contains(requestID) {
                            continue
                        }

                        let payload: Data = row["payload"]
                        guard let request = try? decoder.decode(NetworkRequest.self, from: payload),
                              request.timestamp >= timestamp else {
                            continue
                        }
                        requests.append(request)
                    }

                    return requests
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Loads captured requests newer than the given timestamp on a background queue.
    public func loadRequestsAsync(
        newerThan timestamp: Date,
        excludingIDs: Set<UUID> = [],
        limit: Int? = nil
    ) async throws -> [NetworkRequest] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try continuation.resume(returning: self.loadRequests(
                        newerThan: timestamp,
                        excludingIDs: excludingIDs,
                        limit: limit
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Loads a single captured request by identifier.
    public func loadRequest(_ id: UUID) throws -> NetworkRequest? {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    guard let payload = try Data.fetchOne(
                        db,
                        sql: """
                        SELECT payload
                        FROM network_requests
                        WHERE id = ?
                        """,
                        arguments: [id.uuidString]
                    ) else {
                        return nil
                    }

                    do {
                        return try makeDecoder().decode(NetworkRequest.self, from: payload)
                    } catch {
                        CoreLog.storage.error(
                            LogEvent.storage("load_request_by_id")
                                .failure()
                                .with("request_id", value: id.uuidString, privacy: .public)
                                .error(error)
                        )
                        return nil
                    }
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Loads a single captured request by identifier on a background queue.
    public func loadRequestAsync(_ id: UUID) async throws -> NetworkRequest? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try continuation.resume(returning: self.loadRequest(id))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setTransportStoreBudgetBytesForTesting(_ bytes: Int?) {
        transportStoreBudgetLock.lock()
        if let bytes {
            transportStoreBudgetBytes = max(0, bytes)
        } else {
            transportStoreBudgetBytes = AppGroupStorage.defaultTransportStoreBudgetBytes
        }
        transportStoreBudgetLock.unlock()

        transportPruneStateLock.lock()
        lastTransportPruneAt = .distantPast
        transportBytesWrittenSinceLastPrune = 0
        transportPruneStateLock.unlock()
    }

    // MARK: - Transport Request Storage

    /// Saves a captured transport event to the shared container.
    public func saveTransportRequest(_ request: TransportRequest) throws {
        try saveTransportRequests([request])
    }

    /// Saves captured transport events to the shared container in a single batch.
    /// Posts one notification when at least one event is persisted.
    /// Throws when any item in the batch fails, even if some items were persisted.
    public func saveTransportRequests(_ requests: [TransportRequest]) throws {
        guard !requests.isEmpty else { return }
        let encoder = makeEncoder()
        var persistedCount = 0
        var estimatedPersistedBytes = 0
        var lastError: Error?

        for request in requests {
            do {
                let payload = try encoder.encode(request)
                let now = Date().timeIntervalSince1970
                try withDatabase { pool in
                    try pool.write { db in
                        try db.execute(
                            sql: """
                            INSERT INTO transport_requests (
                                id, timestamp, flow_key, payload_bytes, packet_bytes, payload, created_at, updated_at
                            )
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                                timestamp = excluded.timestamp,
                                flow_key = excluded.flow_key,
                                payload_bytes = excluded.payload_bytes,
                                packet_bytes = excluded.packet_bytes,
                                payload = excluded.payload,
                                updated_at = excluded.updated_at
                            """,
                            arguments: [
                                request.id.uuidString,
                                request.timestamp.timeIntervalSince1970,
                                request.flowKey,
                                request.payloadBytes,
                                request.packetBytes,
                                payload,
                                now,
                                now
                            ]
                        )
                    }
                }
                persistedCount += 1
                estimatedPersistedBytes += estimatedTransportStoredBytes(for: request, metadataBytes: payload.count)
            } catch {
                lastError = error
                CoreLog.storage.error(
                    LogEvent.storage("save_transport_request")
                        .failure()
                        .with("request_id", value: request.id.uuidString, privacy: .public)
                        .error(error)
                )
            }
        }

        if persistedCount > 0 {
            let budgetBytes = currentTransportStoreBudgetBytes()
            if shouldPruneTransportRequests(
                afterPersistingBytes: estimatedPersistedBytes,
                budgetBytes: budgetBytes
            ) {
                do {
                    try pruneTransportRequestsIfNeeded()
                    markTransportPruneCompleted()
                } catch {
                    CoreLog.storage.warning(
                        LogEvent.storage("prune_transport_request")
                            .failure()
                            .error(error)
                    )
                }
            }
            notifyNewTransportRequest()
            if let lastError {
                CoreLog.storage.warning(
                    LogEvent.storage("save_transport_request_batch")
                        .failure()
                        .with("persisted_count", value: persistedCount)
                        .with("failed_count", value: max(0, requests.count - persistedCount))
                        .error(lastError)
                )
                throw lastError
            }
            return
        }

        if let lastError {
            throw lastError
        }
    }

    /// Loads all captured transport events from the shared container.
    public func loadAllTransportRequests() throws -> [TransportRequest] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM transport_requests
                        ORDER BY timestamp DESC, id DESC
                        """
                    )
                    var requests: [TransportRequest] = []
                    requests.reserveCapacity(rows.count)
                    let decoder = makeDecoder()
                    for row in rows {
                        let payload: Data = row["payload"]
                        do {
                            try requests.append(decoder.decode(TransportRequest.self, from: payload))
                        } catch {
                            CoreLog.storage.error(
                                LogEvent.storage("load_transport_request")
                                    .failure()
                                    .error(error)
                            )
                        }
                    }
                    return requests
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Loads captured transport events newer than the provided timestamp.
    /// Optimized for incremental UI updates where most stored files are already known.
    public func loadTransportRequests(
        newerThan timestamp: Date,
        excludingIDs: Set<UUID> = [],
        limit: Int? = nil
    ) throws -> [TransportRequest] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, payload
                        FROM transport_requests
                        WHERE timestamp >= ?
                        ORDER BY timestamp DESC, id DESC
                        """,
                        arguments: [timestamp.timeIntervalSince1970]
                    )

                    let excluded = Set(excludingIDs.map(\.uuidString))
                    let effectiveLimit = limit.map { max(0, $0) }
                    if let effectiveLimit, effectiveLimit == 0 {
                        return []
                    }
                    let decoder = makeDecoder()
                    var requests: [TransportRequest] = []
                    requests.reserveCapacity(rows.count)

                    for row in rows {
                        if let effectiveLimit, requests.count >= effectiveLimit {
                            break
                        }

                        let requestID: String = row["id"]
                        if excluded.contains(requestID) {
                            continue
                        }

                        let payload: Data = row["payload"]
                        guard let request = try? decoder.decode(TransportRequest.self, from: payload),
                              request.timestamp >= timestamp else {
                            continue
                        }
                        requests.append(request)
                    }

                    return requests
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Loads all captured transport events from the shared container on a background queue.
    public func loadAllTransportRequestsAsync() async throws -> [TransportRequest] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try continuation.resume(returning: self.loadAllTransportRequests())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Loads captured transport events newer than the given timestamp on a background queue.
    public func loadTransportRequestsAsync(
        newerThan timestamp: Date,
        excludingIDs: Set<UUID> = [],
        limit: Int? = nil
    ) async throws -> [TransportRequest] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try continuation.resume(returning: self.loadTransportRequests(
                        newerThan: timestamp,
                        excludingIDs: excludingIDs,
                        limit: limit
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Deletes all captured transport events.
    public func clearAllTransportRequests() throws {
        do {
            try withDatabase { pool in
                try pool.write { db in
                    let rows = try Row.fetchAll(db, sql: "SELECT payload FROM transport_requests")
                    let decoder = makeDecoder()
                    for row in rows {
                        let payload: Data = row["payload"]
                        if let request = try? decoder.decode(TransportRequest.self, from: payload) {
                            request.payload.deleteFile()
                            request.packet?.deleteFile()
                        }
                    }
                    try db.execute(sql: "DELETE FROM transport_requests")
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }

        transportPruneStateLock.lock()
        lastTransportPruneAt = Date()
        transportBytesWrittenSinceLastPrune = 0
        transportPruneStateLock.unlock()
    }

    private struct TransportStorageEntry {
        let id: String
        let timestamp: Date
        let request: TransportRequest?
        let totalBytes: Int
    }

    private func currentTransportStoreBudgetBytes() -> Int {
        transportStoreBudgetLock.lock()
        defer { transportStoreBudgetLock.unlock() }
        return transportStoreBudgetBytes
    }

    private func estimatedTransportStoredBytes(for request: TransportRequest, metadataBytes: Int) -> Int {
        max(0, metadataBytes + request.payloadBytes + (request.packetBytes ?? 0))
    }

    private func shouldPruneTransportRequests(afterPersistingBytes bytes: Int, budgetBytes: Int) -> Bool {
        transportPruneStateLock.lock()
        transportBytesWrittenSinceLastPrune += max(0, bytes)

        // Oversized batches should prune immediately to keep budget bounded.
        let shouldPrune =
            budgetBytes <= 0 ||
            bytes >= budgetBytes ||
            transportBytesWrittenSinceLastPrune >= AppGroupStorage.transportPruneWriteThresholdBytes ||
            Date().timeIntervalSince(lastTransportPruneAt) >= AppGroupStorage.transportPruneMinInterval

        transportPruneStateLock.unlock()
        return shouldPrune
    }

    private func markTransportPruneCompleted() {
        transportPruneStateLock.lock()
        lastTransportPruneAt = Date()
        transportBytesWrittenSinceLastPrune = 0
        transportPruneStateLock.unlock()
    }

    private func pruneTransportRequestsIfNeeded() throws {
        let budgetBytes = currentTransportStoreBudgetBytes()
        guard budgetBytes > 0 else {
            try clearAllTransportRequests()
            return
        }

        do {
            try withDatabase { pool in
                try pool.write { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, timestamp, payload
                        FROM transport_requests
                        ORDER BY timestamp ASC, id ASC
                        """
                    )
                    guard !rows.isEmpty else { return }

                    let decoder = makeDecoder()
                    var totalBytes = 0
                    var entries: [TransportStorageEntry] = []
                    entries.reserveCapacity(rows.count)

                    for row in rows {
                        let id: String = row["id"]
                        let timestampValue: Double = row["timestamp"]
                        let payload: Data = row["payload"]
                        let request = try? decoder.decode(TransportRequest.self, from: payload)
                        var entryBytes = payload.count
                        var filePaths: Set<String> = []
                        if let request,
                           let payloadURL = bodyFileURL(for: request.payload),
                           filePaths.insert(payloadURL.path).inserted {
                            entryBytes += fileSize(at: payloadURL)
                        }
                        if let request,
                           let packetURL = bodyFileURL(for: request.packet),
                           filePaths.insert(packetURL.path).inserted {
                            entryBytes += fileSize(at: packetURL)
                        }

                        totalBytes += entryBytes
                        entries.append(
                            TransportStorageEntry(
                                id: id,
                                timestamp: Date(timeIntervalSince1970: timestampValue),
                                request: request,
                                totalBytes: entryBytes
                            )
                        )
                    }

                    guard totalBytes > budgetBytes else { return }

                    var remainingEntries = entries.count
                    var remainingBytes = totalBytes
                    var prunedCount = 0

                    for entry in entries where remainingBytes > budgetBytes {
                        // Keep at least the newest event, even if oversized.
                        guard remainingEntries > 1 else { break }

                        entry.request?.payload.deleteFile()
                        entry.request?.packet?.deleteFile()

                        try db.execute(
                            sql: "DELETE FROM transport_requests WHERE id = ?",
                            arguments: [entry.id]
                        )

                        remainingEntries -= 1
                        remainingBytes = max(0, remainingBytes - entry.totalBytes)
                        prunedCount += 1
                    }

                    if prunedCount > 0 {
                        CoreLog.storage.info(
                            "event=storage.transport_prune outcome=success pruned=\(prunedCount) total_bytes_before=\(totalBytes) total_bytes_after=\(remainingBytes) budget_bytes=\(budgetBytes)"
                        )
                    }
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    private func fileSize(at url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private func bodyFileURL(for body: BodyStorage?) -> URL? {
        guard let body else { return nil }
        switch body {
        case let .file(url, _, _):
            return url
        case let .truncatedFile(url, _, _, _):
            return url
        default:
            return nil
        }
    }

    // MARK: - Packet Flow Storage

    /// Saves a packet flow record to the shared container.
    public func savePacketFlowRecord(_ record: PacketFlowRecord) throws {
        let payload = try makeEncoder().encode(record)
        let now = Date().timeIntervalSince1970
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: """
                INSERT INTO packet_flows (id, last_seen, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    last_seen = excluded.last_seen,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [record.id.uuidString, record.lastSeen.timeIntervalSince1970, payload, now]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    /// Loads all packet flow records from the shared container.
    public func loadAllPacketFlowRecords() throws -> [PacketFlowRecord] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM packet_flows
                        ORDER BY last_seen DESC, id DESC
                        """
                    )
                    let decoder = makeDecoder()
                    var records: [PacketFlowRecord] = []
                    records.reserveCapacity(rows.count)
                    for row in rows {
                        let payload: Data = row["payload"]
                        do {
                            try records.append(decoder.decode(PacketFlowRecord.self, from: payload))
                        } catch {
                            CoreLog.storage.error(
                                LogEvent.storage("load_packet_flow")
                                    .failure()
                                    .error(error)
                            )
                        }
                    }
                    return records
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Deletes a packet flow record from the shared container.
    public func deletePacketFlowRecord(_ record: PacketFlowRecord) throws {
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: "DELETE FROM packet_flows WHERE id = ?",
                arguments: [record.id.uuidString]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    /// Removes all packet flow records.
    public func clearAllPacketFlowRecords() throws {
        let didWrite = executeDBWrite { db in
            try db.execute(sql: "DELETE FROM packet_flows")
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    // MARK: - UDP Flow Storage

    /// Saves UDP flow metadata to the shared container.
    public func saveUDPFlowMetadata(_ flow: UDPFlowMetadata) throws {
        let payload = try makeEncoder().encode(flow)
        let now = Date().timeIntervalSince1970
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: """
                INSERT INTO udp_flows (id, last_activity, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    last_activity = excluded.last_activity,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [flow.id.uuidString, flow.lastActivity.timeIntervalSince1970, payload, now]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }

        notifyNewUDPFlow()
    }

    /// Loads all UDP flow metadata from the shared container.
    public func loadAllUDPFlowMetadata() throws -> [UDPFlowMetadata] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM udp_flows
                        ORDER BY last_activity DESC, id DESC
                        """
                    )
                    let decoder = makeDecoder()
                    var flows: [UDPFlowMetadata] = []
                    flows.reserveCapacity(rows.count)
                    for row in rows {
                        let payload: Data = row["payload"]
                        do {
                            try flows.append(decoder.decode(UDPFlowMetadata.self, from: payload))
                        } catch {
                            CoreLog.storage.error(
                                LogEvent.storage("load_udp_flow")
                                    .failure()
                                    .error(error)
                            )
                        }
                    }
                    return flows
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Deletes a UDP flow metadata record from the shared container.
    public func deleteUDPFlowMetadata(_ id: UUID) throws {
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: "DELETE FROM udp_flows WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    /// Removes all UDP flow metadata records.
    public func clearAllUDPFlowMetadata() throws {
        let didWrite = executeDBWrite { db in
            try db.execute(sql: "DELETE FROM udp_flows")
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    /// Loads all captured requests for a specific session
    public func loadRequestsForSession(_ sessionId: UUID) throws -> [NetworkRequest] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM network_requests
                        WHERE session_id = ?
                        ORDER BY timestamp DESC, id DESC
                        """,
                        arguments: [sessionId.uuidString]
                    )
                    let decoder = makeDecoder()
                    var requests: [NetworkRequest] = []
                    requests.reserveCapacity(rows.count)
                    for row in rows {
                        let payload: Data = row["payload"]
                        if let request = try? decoder.decode(NetworkRequest.self, from: payload) {
                            requests.append(request)
                        }
                    }
                    return requests
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
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
        do {
            try withDatabase { pool in
                try pool.write { db in
                    let payload = try Data.fetchOne(
                        db,
                        sql: "SELECT payload FROM network_requests WHERE id = ?",
                        arguments: [requestID.uuidString]
                    )
                    if let payload {
                        let decoder = makeDecoder()
                        if let request = try? decoder.decode(NetworkRequest.self, from: payload) {
                            request.requestBody.deleteFile()
                            request.responseBody.deleteFile()
                        }
                    }
                    try db.execute(
                        sql: "DELETE FROM network_requests WHERE id = ?",
                        arguments: [requestID.uuidString]
                    )
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Deletes a specific request (convenience overload)
    public func deleteRequest(_ request: NetworkRequest) throws {
        try deleteRequest(request.id)
    }

    /// Deletes all captured requests
    public func clearAllRequests() throws {
        do {
            try withDatabase { pool in
                try pool.write { db in
                    let rows = try Row.fetchAll(db, sql: "SELECT payload FROM network_requests")
                    let decoder = makeDecoder()
                    for row in rows {
                        let payload: Data = row["payload"]
                        if let request = try? decoder.decode(NetworkRequest.self, from: payload) {
                            request.requestBody.deleteFile()
                            request.responseBody.deleteFile()
                        }
                    }
                    try db.execute(sql: "DELETE FROM network_requests")
                }
            }
            deleteAllBodyFiles()
        } catch {
            throw mapDatabaseError(error)
        }
    }

    // MARK: - WebSocket Storage

    /// Saves a WebSocket connection to the shared container
    public func saveWebSocketConnection(_ connection: WebSocketConnection) throws {
        let payload = try makeEncoder().encode(connection)
        let now = Date().timeIntervalSince1970
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: """
                INSERT INTO websocket_connections (id, start_time, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    start_time = excluded.start_time,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [connection.id.uuidString, connection.startTime.timeIntervalSince1970, payload, now]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }

        // Notify main app of new/updated WebSocket connection
        notifyNewWebSocket()
    }

    /// Loads all WebSocket connections from the shared container
    public func loadAllWebSocketConnections() throws -> [WebSocketConnection] {
        if streamInterceptionV2Enabled {
            let projected = try loadProjectedWebSocketConnections()
            if !projected.isEmpty {
                return projected
            }
        }

        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM websocket_connections
                        ORDER BY start_time DESC, id DESC
                        """
                    )
                    let decoder = makeDecoder()
                    var connections: [WebSocketConnection] = []
                    connections.reserveCapacity(rows.count)
                    for row in rows {
                        let payload: Data = row["payload"]
                        if let connection = try? decoder.decode(WebSocketConnection.self, from: payload) {
                            connections.append(connection)
                        }
                    }
                    return connections
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Deletes a specific WebSocket connection
    public func deleteWebSocketConnection(_ connectionID: UUID) throws {
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: "DELETE FROM websocket_connections WHERE id = ?",
                arguments: [connectionID.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM stream_sessions WHERE id = ? AND protocol_type = ?",
                arguments: [connectionID.uuidString, StreamProtocolType.websocket.rawValue]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    /// Deletes all WebSocket connections
    public func clearAllWebSocketConnections() throws {
        let didWrite = executeDBWrite { db in
            try db.execute(sql: "DELETE FROM websocket_connections")
            try db.execute(
                sql: "DELETE FROM stream_sessions WHERE protocol_type = ?",
                arguments: [StreamProtocolType.websocket.rawValue]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    // MARK: - SSE Storage

    /// Saves an SSE connection to the shared container
    public func saveSSEConnection(_ connection: SSEConnection) throws {
        let payload = try makeEncoder().encode(connection)
        let now = Date().timeIntervalSince1970
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: """
                INSERT INTO sse_connections (id, start_time, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    start_time = excluded.start_time,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [connection.id.uuidString, connection.startTime.timeIntervalSince1970, payload, now]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }

        // Notify main app of new/updated SSE connection
        notifyNewSSE()
    }

    /// Loads all SSE connections from the shared container
    public func loadAllSSEConnections() throws -> [SSEConnection] {
        if streamInterceptionV2Enabled {
            let projected = try loadProjectedSSEConnections()
            if !projected.isEmpty {
                return projected
            }
        }

        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM sse_connections
                        ORDER BY start_time DESC, id DESC
                        """
                    )

                    let decoder = makeDecoder()
                    var connections: [SSEConnection] = []
                    connections.reserveCapacity(rows.count)

                    for row in rows {
                        let payload: Data = row["payload"]
                        if let connection = try? decoder.decode(SSEConnection.self, from: payload) {
                            connections.append(connection)
                        }
                    }

                    CoreLog.storage.info("event=storage.load_sse outcome=success count=\(connections.count, privacy: .public)")
                    return connections
                }
            }
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("load_sse")
                    .failure()
                    .error(error)
            )
            throw mapDatabaseError(error)
        }
    }

    /// Deletes a specific SSE connection
    public func deleteSSEConnection(_ connectionID: UUID) throws {
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: "DELETE FROM sse_connections WHERE id = ?",
                arguments: [connectionID.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM stream_sessions WHERE id = ? AND protocol_type = ?",
                arguments: [connectionID.uuidString, StreamProtocolType.sse.rawValue]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    /// Deletes all SSE connections
    public func clearAllSSEConnections() throws {
        let didWrite = executeDBWrite { db in
            try db.execute(sql: "DELETE FROM sse_connections")
            try db.execute(
                sql: "DELETE FROM stream_sessions WHERE protocol_type = ?",
                arguments: [StreamProtocolType.sse.rawValue]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    // MARK: - Stream Session/Event Storage

    public func upsertStreamSession(_ session: StreamSession) throws {
        do {
            try withDatabase { pool in
                try pool.write { db in
                    let encoder = makeEncoder()
                    let now = Date().timeIntervalSince1970
                    let sessionID = session.id.uuidString

                    let mergedSession: StreamSession = if let row = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT id, protocol_type, url, start_time, end_time, status,
                               request_headers, response_headers, metadata,
                               event_count, bytes_in, bytes_out
                        FROM stream_sessions
                        WHERE id = ?
                        """,
                        arguments: [sessionID]
                    ), let existing = decodeStreamSession(row) {
                        mergeStreamSession(existing: existing, incoming: session)
                    } else {
                        session
                    }

                    let requestHeadersData = try encoder.encode(mergedSession.requestHeaders)
                    let responseHeadersData = try encoder.encode(mergedSession.responseHeaders)
                    let metadataData = try encoder.encode(mergedSession.metadata)
                    try db.execute(
                        sql: """
                        INSERT INTO stream_sessions (
                            id, protocol_type, url, start_time, end_time, status,
                            request_headers, response_headers, metadata,
                            event_count, bytes_in, bytes_out, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            protocol_type = excluded.protocol_type,
                            url = excluded.url,
                            start_time = excluded.start_time,
                            end_time = excluded.end_time,
                            status = excluded.status,
                            request_headers = excluded.request_headers,
                            response_headers = excluded.response_headers,
                            metadata = excluded.metadata,
                            event_count = excluded.event_count,
                            bytes_in = excluded.bytes_in,
                            bytes_out = excluded.bytes_out,
                            updated_at = excluded.updated_at
                        """,
                        arguments: [
                            sessionID,
                            mergedSession.protocolType.rawValue,
                            mergedSession.url,
                            mergedSession.startTime.timeIntervalSince1970,
                            mergedSession.endTime?.timeIntervalSince1970,
                            mergedSession.status.rawValue,
                            requestHeadersData,
                            responseHeadersData,
                            metadataData,
                            mergedSession.eventCount,
                            mergedSession.bytesIn,
                            mergedSession.bytesOut,
                            now,
                            now
                        ]
                    )
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }

        notifyStreamUpdated()
        switch session.protocolType {
        case .sse:
            notifyNewSSE()
        case .websocket:
            notifyNewWebSocket()
        }
    }

    private func mergeStreamSession(existing: StreamSession, incoming: StreamSession) -> StreamSession {
        guard existing.id == incoming.id else { return incoming }

        let mergedProtocolType = existing.protocolType == incoming.protocolType
            ? incoming.protocolType
            : existing.protocolType
        let mergedURL = incoming.url.isEmpty ? existing.url : incoming.url

        let startTime = min(existing.startTime, incoming.startTime)
        let endTime: Date? = switch (existing.endTime, incoming.endTime) {
        case let (lhs?, rhs?):
            max(lhs, rhs)
        case let (lhs?, nil):
            lhs
        case let (nil, rhs?):
            rhs
        case (nil, nil):
            nil
        }

        let statusOrder: [StreamSessionStatus: Int] = [
            .connecting: 0,
            .open: 1,
            .streaming: 2,
            .replaying: 3,
            .closing: 4,
            .closed: 5,
            .failed: 6
        ]
        let existingOrder = statusOrder[existing.status] ?? 0
        let incomingOrder = statusOrder[incoming.status] ?? 0
        let mergedStatus = existingOrder >= incomingOrder ? existing.status : incoming.status

        var merged = incoming
        merged.protocolType = mergedProtocolType
        merged.url = mergedURL
        merged.startTime = startTime
        merged.endTime = endTime
        merged.status = mergedStatus
        if merged.requestHeaders.isEmpty {
            merged.requestHeaders = existing.requestHeaders
        }
        if merged.responseHeaders.isEmpty {
            merged.responseHeaders = existing.responseHeaders
        }
        merged.metadata = existing.metadata.merging(incoming.metadata) { _, new in new }
        merged.eventCount = max(existing.eventCount, incoming.eventCount)
        merged.bytesIn = max(existing.bytesIn, incoming.bytesIn)
        merged.bytesOut = max(existing.bytesOut, incoming.bytesOut)
        return merged
    }

    public func appendStreamEvent(_ event: StreamEvent) throws {
        let encoder = makeEncoder()
        var protocolType: StreamProtocolType?
        var didInsert = false

        do {
            try withDatabase { pool in
                try pool.write { db in
                    guard let protocolRaw = try String.fetchOne(
                        db,
                        sql: "SELECT protocol_type FROM stream_sessions WHERE id = ?",
                        arguments: [event.sessionID.uuidString]
                    ), let resolvedProtocol = StreamProtocolType(rawValue: protocolRaw)
                    else {
                        throw StorageError.fileNotFound
                    }
                    protocolType = resolvedProtocol

                    let sequence: Int64
                    if event.sequence > 0 {
                        sequence = event.sequence
                    } else {
                        let nextSequence = try Int64.fetchOne(
                            db,
                            sql: """
                            SELECT COALESCE(MAX(sequence), 0) + 1
                            FROM stream_events
                            WHERE session_id = ?
                            """,
                            arguments: [event.sessionID.uuidString]
                        )
                        sequence = nextSequence ?? 1
                    }

                    let payloadText = event.payload.text
                    var payloadInline = event.payload.binary
                    var payloadChunked = 0
                    let payloadSize = event.payload.byteCount
                    if let binaryPayload = payloadInline, binaryPayload.count > Self.streamPayloadInlineLimitBytes {
                        payloadChunked = 1
                        payloadInline = nil
                    }

                    let metadataData = try encoder.encode(event.metadata)
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO stream_events (
                            id, session_id, sequence, timestamp, direction, kind,
                            payload_text, payload_inline, payload_chunked,
                            payload_content_type, payload_encoding, payload_size,
                            was_modified, was_blocked, metadata, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            event.id.uuidString,
                            event.sessionID.uuidString,
                            sequence,
                            event.timestamp.timeIntervalSince1970,
                            event.direction.rawValue,
                            event.kind.rawValue,
                            payloadText,
                            payloadInline,
                            payloadChunked,
                            event.payload.contentType,
                            event.payload.encoding,
                            payloadSize,
                            event.wasModified ? 1 : 0,
                            event.wasBlocked ? 1 : 0,
                            metadataData,
                            Date().timeIntervalSince1970
                        ]
                    )
                    didInsert = db.changesCount > 0
                    guard didInsert else { return }

                    try db.execute(
                        sql: "DELETE FROM stream_payload_chunks WHERE event_id = ?",
                        arguments: [event.id.uuidString]
                    )
                    if payloadChunked == 1, let binaryPayload = event.payload.binary {
                        var chunkIndex = 0
                        var cursor = 0
                        while cursor < binaryPayload.count {
                            let upperBound = min(cursor + Self.streamPayloadChunkSizeBytes, binaryPayload.count)
                            let chunk = binaryPayload.subdata(in: cursor ..< upperBound)
                            try db.execute(
                                sql: """
                                INSERT INTO stream_payload_chunks (event_id, chunk_index, chunk, created_at)
                                VALUES (?, ?, ?, ?)
                                """,
                                arguments: [
                                    event.id.uuidString,
                                    chunkIndex,
                                    chunk,
                                    Date().timeIntervalSince1970
                                ]
                            )
                            chunkIndex += 1
                            cursor = upperBound
                        }
                    }

                    let now = Date().timeIntervalSince1970
                    let bytesIn = event.direction == .received ? payloadSize : 0
                    let bytesOut = event.direction == .sent ? payloadSize : 0
                    try db.execute(
                        sql: """
                        UPDATE stream_sessions
                        SET event_count = COALESCE(event_count, 0) + 1,
                            bytes_in = COALESCE(bytes_in, 0) + ?,
                            bytes_out = COALESCE(bytes_out, 0) + ?,
                            status = CASE
                                WHEN status IN ('closed', 'failed') THEN status
                                ELSE ?
                            END,
                            updated_at = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            bytesIn,
                            bytesOut,
                            StreamSessionStatus.streaming.rawValue,
                            now,
                            event.sessionID.uuidString
                        ]
                    )
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }

        guard didInsert else { return }

        notifyStreamUpdated()
        switch protocolType {
        case .sse:
            notifyNewSSE()
        case .websocket:
            notifyNewWebSocket()
        case .none:
            break
        }
    }

    public func loadStreamSession(_ sessionID: UUID) throws -> StreamSession? {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    guard let row = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT id, protocol_type, url, start_time, end_time, status,
                               request_headers, response_headers, metadata,
                               event_count, bytes_in, bytes_out
                        FROM stream_sessions
                        WHERE id = ?
                        """,
                        arguments: [sessionID.uuidString]
                    ) else {
                        return nil
                    }

                    return decodeStreamSession(row)
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    public func loadStreamSessions(
        protocolType: StreamProtocolType? = nil,
        limit: Int? = nil
    ) throws -> [StreamSession] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows: [Row] = if let protocolType, let limit, limit > 0 {
                        try Row.fetchAll(
                            db,
                            sql: """
                            SELECT id, protocol_type, url, start_time, end_time, status,
                                   request_headers, response_headers, metadata,
                                   event_count, bytes_in, bytes_out
                            FROM stream_sessions
                            WHERE protocol_type = ?
                            ORDER BY start_time DESC, id DESC
                            LIMIT ?
                            """,
                            arguments: [protocolType.rawValue, limit]
                        )
                    } else if let protocolType {
                        try Row.fetchAll(
                            db,
                            sql: """
                            SELECT id, protocol_type, url, start_time, end_time, status,
                                   request_headers, response_headers, metadata,
                                   event_count, bytes_in, bytes_out
                            FROM stream_sessions
                            WHERE protocol_type = ?
                            ORDER BY start_time DESC, id DESC
                            """,
                            arguments: [protocolType.rawValue]
                        )
                    } else if let limit, limit > 0 {
                        try Row.fetchAll(
                            db,
                            sql: """
                            SELECT id, protocol_type, url, start_time, end_time, status,
                                   request_headers, response_headers, metadata,
                                   event_count, bytes_in, bytes_out
                            FROM stream_sessions
                            ORDER BY start_time DESC, id DESC
                            LIMIT ?
                            """,
                            arguments: [limit]
                        )
                    } else {
                        try Row.fetchAll(
                            db,
                            sql: """
                            SELECT id, protocol_type, url, start_time, end_time, status,
                                   request_headers, response_headers, metadata,
                                   event_count, bytes_in, bytes_out
                            FROM stream_sessions
                            ORDER BY start_time DESC, id DESC
                            """
                        )
                    }

                    return rows.compactMap(decodeStreamSession)
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    public func loadStreamEvents(
        sessionID: UUID,
        limit: Int? = nil
    ) throws -> [StreamEvent] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows: [Row] = if let limit, limit > 0 {
                        try Row.fetchAll(
                            db,
                            sql: """
                            SELECT id, session_id, sequence, timestamp, direction, kind,
                                   payload_text, payload_inline, payload_chunked,
                                   payload_content_type, payload_encoding, payload_size,
                                   was_modified, was_blocked, metadata
                            FROM stream_events
                            WHERE session_id = ?
                            ORDER BY sequence ASC, id ASC
                            LIMIT ?
                            """,
                            arguments: [sessionID.uuidString, limit]
                        )
                    } else {
                        try Row.fetchAll(
                            db,
                            sql: """
                            SELECT id, session_id, sequence, timestamp, direction, kind,
                                   payload_text, payload_inline, payload_chunked,
                                   payload_content_type, payload_encoding, payload_size,
                                   was_modified, was_blocked, metadata
                            FROM stream_events
                            WHERE session_id = ?
                            ORDER BY sequence ASC, id ASC
                            """,
                            arguments: [sessionID.uuidString]
                        )
                    }

                    return rows.compactMap { decodeStreamEvent($0, db: db) }
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    public func startStreamReplay(_ spec: StreamReplaySpec) throws -> UUID {
        let replayID = UUID()
        let encoder = makeEncoder()
        let specData = try encoder.encode(spec)
        let now = Date().timeIntervalSince1970

        do {
            try withDatabase { pool in
                try pool.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO stream_replays (
                            id, session_id, spec, result, status,
                            started_at, ended_at, created_at, updated_at
                        ) VALUES (?, ?, ?, NULL, ?, ?, NULL, ?, ?)
                        """,
                        arguments: [
                            replayID.uuidString,
                            spec.sessionID.uuidString,
                            specData,
                            StreamReplayStatus.running.rawValue,
                            spec.startedAt.timeIntervalSince1970,
                            now,
                            now
                        ]
                    )
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }

        notifyStreamUpdated()
        return replayID
    }

    public func completeStreamReplay(_ result: StreamReplayResult) throws {
        let encoder = makeEncoder()
        let resultData = try encoder.encode(result)
        let now = Date().timeIntervalSince1970
        let status: StreamReplayStatus = result.succeeded ? .succeeded : .failed
        let endedAt = (result.endedAt ?? Date()).timeIntervalSince1970

        do {
            try withDatabase { pool in
                try pool.write { db in
                    try db.execute(
                        sql: """
                        UPDATE stream_replays
                        SET result = ?,
                            status = ?,
                            ended_at = ?,
                            updated_at = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            resultData,
                            status.rawValue,
                            endedAt,
                            now,
                            result.replayID.uuidString
                        ]
                    )
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }

        notifyStreamUpdated()
    }

    public func loadStreamReplayRecords(
        sessionID: UUID,
        limit: Int? = nil
    ) throws -> [StreamReplayRecord] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows: [Row] = if let limit, limit > 0 {
                        try Row.fetchAll(
                            db,
                            sql: """
                            SELECT id, session_id, spec, result, status, started_at, ended_at
                            FROM stream_replays
                            WHERE session_id = ?
                            ORDER BY started_at DESC, id DESC
                            LIMIT ?
                            """,
                            arguments: [sessionID.uuidString, limit]
                        )
                    } else {
                        try Row.fetchAll(
                            db,
                            sql: """
                            SELECT id, session_id, spec, result, status, started_at, ended_at
                            FROM stream_replays
                            WHERE session_id = ?
                            ORDER BY started_at DESC, id DESC
                            """,
                            arguments: [sessionID.uuidString]
                        )
                    }
                    let decoder = makeDecoder()
                    return rows.compactMap { row in
                        guard let replayID = UUID(uuidString: row["id"]),
                              let loadedSessionID = UUID(uuidString: row["session_id"]),
                              let status = StreamReplayStatus(rawValue: row["status"])
                        else {
                            return nil
                        }
                        let specData: Data = row["spec"]
                        guard let spec = try? decoder.decode(StreamReplaySpec.self, from: specData) else {
                            return nil
                        }
                        let resultData: Data? = row["result"]
                        let result = resultData.flatMap { try? decoder.decode(StreamReplayResult.self, from: $0) }
                        let startedAtSeconds: Double = row["started_at"]
                        let endedAtSeconds: Double? = row["ended_at"]

                        return StreamReplayRecord(
                            replayID: replayID,
                            sessionID: loadedSessionID,
                            status: status,
                            spec: spec,
                            result: result,
                            startedAt: Date(timeIntervalSince1970: startedAtSeconds),
                            endedAt: endedAtSeconds.map(Date.init(timeIntervalSince1970:))
                        )
                    }
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Deletes stream sessions that ended before a cutoff (or started before cutoff if still open).
    /// - Returns: Number of deleted sessions.
    public func deleteStreamSessions(olderThan cutoffDate: Date) throws -> Int {
        do {
            var deleted = 0
            try withDatabase { pool in
                try pool.write { db in
                    try db.execute(
                        sql: """
                        DELETE FROM stream_sessions
                        WHERE COALESCE(end_time, start_time) < ?
                        """,
                        arguments: [cutoffDate.timeIntervalSince1970]
                    )
                    deleted = db.changesCount
                }
            }
            return deleted
        } catch {
            throw mapDatabaseError(error)
        }
    }

    private func decodeStreamSession(_ row: Row) -> StreamSession? {
        guard let id = UUID(uuidString: row["id"]),
              let protocolType = StreamProtocolType(rawValue: row["protocol_type"]),
              let status = StreamSessionStatus(rawValue: row["status"])
        else {
            return nil
        }

        let requestHeadersData: Data = row["request_headers"]
        let responseHeadersData: Data = row["response_headers"]
        let metadataData: Data = row["metadata"]
        let decoder = makeDecoder()

        let requestHeaders = (try? decoder.decode([TraceHTTPHeader].self, from: requestHeadersData)) ?? []
        let responseHeaders = (try? decoder.decode([TraceHTTPHeader].self, from: responseHeadersData)) ?? []
        let metadata = (try? decoder.decode([String: String].self, from: metadataData)) ?? [:]

        return StreamSession(
            id: id,
            protocolType: protocolType,
            url: row["url"],
            startTime: Date(timeIntervalSince1970: row["start_time"]),
            endTime: {
                let value: Double? = row["end_time"]
                return value.map(Date.init(timeIntervalSince1970:))
            }(),
            status: status,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            metadata: metadata,
            eventCount: row["event_count"],
            bytesIn: row["bytes_in"],
            bytesOut: row["bytes_out"]
        )
    }

    private func decodeStreamEvent(_ row: Row, db: Database) -> StreamEvent? {
        guard let id = UUID(uuidString: row["id"]),
              let sessionID = UUID(uuidString: row["session_id"]),
              let direction = StreamEventDirection(rawValue: row["direction"]),
              let kind = StreamEventKind(rawValue: row["kind"])
        else {
            return nil
        }

        let payloadText: String? = row["payload_text"]
        var payloadBinary: Data? = row["payload_inline"]
        let payloadChunked: Int = row["payload_chunked"]
        if payloadChunked != 0 {
            let chunkRows = (try? Row.fetchAll(
                db,
                sql: """
                SELECT chunk
                FROM stream_payload_chunks
                WHERE event_id = ?
                ORDER BY chunk_index ASC
                """,
                arguments: [id.uuidString]
            )) ?? []
            if !chunkRows.isEmpty {
                var data = Data()
                for chunkRow in chunkRows {
                    let chunk: Data = chunkRow["chunk"]
                    data.append(chunk)
                }
                payloadBinary = data
            }
        }

        let metadataData: Data = row["metadata"]
        let metadata = (try? makeDecoder().decode([String: String].self, from: metadataData)) ?? [:]
        let timestamp: Double = row["timestamp"]
        let wasModified: Int = row["was_modified"]
        let wasBlocked: Int = row["was_blocked"]

        return StreamEvent(
            id: id,
            sessionID: sessionID,
            sequence: row["sequence"],
            timestamp: Date(timeIntervalSince1970: timestamp),
            direction: direction,
            kind: kind,
            payload: StreamEventPayload(
                text: payloadText,
                binary: payloadBinary,
                contentType: row["payload_content_type"],
                encoding: row["payload_encoding"]
            ),
            wasModified: wasModified != 0,
            wasBlocked: wasBlocked != 0,
            metadata: metadata
        )
    }

    private func loadProjectedWebSocketConnections() throws -> [WebSocketConnection] {
        let sessions = try loadStreamSessions(protocolType: .websocket)
        guard !sessions.isEmpty else { return [] }

        var connections: [WebSocketConnection] = []
        connections.reserveCapacity(sessions.count)
        for session in sessions {
            let events = try loadStreamEvents(sessionID: session.id)
            var messages: [WebSocketMessage] = []
            messages.reserveCapacity(events.count)
            var closeCode: Int?
            var closeReason: String?

            for event in events {
                guard let messageType = websocketMessageType(for: event) else { continue }
                let direction: WebSocketDirection = event.direction == .sent ? .sent : .received
                let payloadData = event.payload.binary
                    ?? event.payload.text?.data(using: .utf8)
                    ?? Data()
                let payloadLength = Int(event.metadata["payload_length"] ?? "") ?? payloadData.count
                let isFinal = event.metadata["is_final"] != "false"
                let isMasked = event.metadata["is_masked"] == "true"
                let message = WebSocketMessage(
                    id: event.id,
                    direction: direction,
                    timestamp: event.timestamp,
                    payload: payloadData,
                    messageType: messageType,
                    isFinal: isFinal,
                    isMasked: isMasked,
                    payloadLength: payloadLength
                )
                messages.append(message)

                if messageType == .close, closeCode == nil {
                    closeCode = extractWebSocketCloseCode(from: payloadData)
                    closeReason = extractWebSocketCloseReason(from: payloadData)
                }
            }

            connections.append(
                WebSocketConnection(
                    id: session.id,
                    url: session.url,
                    startTime: session.startTime,
                    endTime: session.endTime,
                    messages: messages,
                    status: webSocketConnectionStatus(for: session.status),
                    requestHeaders: session.requestHeaders,
                    responseHeaders: session.responseHeaders,
                    closeCode: closeCode,
                    closeReason: closeReason
                )
            )
        }
        return connections.sorted { $0.startTime > $1.startTime }
    }

    private func loadProjectedSSEConnections() throws -> [SSEConnection] {
        let sessions = try loadStreamSessions(protocolType: .sse)
        guard !sessions.isEmpty else { return [] }

        var connections: [SSEConnection] = []
        connections.reserveCapacity(sessions.count)
        for session in sessions {
            let events = try loadStreamEvents(sessionID: session.id)
            let sseEvents = events.compactMap { event -> ServerSentEvent? in
                guard event.kind == .sseEvent || event.kind == .message else { return nil }
                let data = event.payload.text
                    ?? event.payload.binary.flatMap { String(data: $0, encoding: .utf8) }
                    ?? ""
                guard !data.isEmpty else { return nil }

                let eventID = event.metadata["event_id"]
                let eventType = event.metadata["event_type"]
                let retry = Int(event.metadata["retry"] ?? "")
                return ServerSentEvent(
                    id: event.id,
                    eventId: eventID?.isEmpty == true ? nil : eventID,
                    eventType: eventType?.isEmpty == true ? nil : eventType,
                    data: data,
                    retry: retry,
                    timestamp: event.timestamp
                )
            }

            connections.append(
                SSEConnection(
                    id: session.id,
                    url: session.url,
                    startTime: session.startTime,
                    endTime: session.endTime,
                    events: sseEvents,
                    status: sseConnectionStatus(for: session.status),
                    requestHeaders: session.requestHeaders,
                    responseHeaders: session.responseHeaders,
                    totalBytesReceived: session.bytesIn,
                    isTruncated: session.metadata["is_truncated"] == "true"
                )
            )
        }
        return connections.sorted { $0.startTime > $1.startTime }
    }

    private func webSocketConnectionStatus(for status: StreamSessionStatus) -> WebSocketConnectionStatus {
        switch status {
        case .connecting:
            .connecting
        case .open, .streaming:
            .open
        case .replaying, .closing:
            .closing
        case .closed:
            .closed
        case .failed:
            .failed
        }
    }

    private func sseConnectionStatus(for status: StreamSessionStatus) -> SSEConnectionStatus {
        switch status {
        case .connecting:
            .connecting
        case .open, .streaming, .replaying:
            .streaming
        case .closing, .closed:
            .closed
        case .failed:
            .failed
        }
    }

    private func websocketMessageType(for event: StreamEvent) -> WebSocketMessageType? {
        if let rawType = event.metadata["message_type"],
           let parsed = WebSocketMessageType(rawValue: rawType) {
            return parsed
        }

        switch event.kind {
        case .ping:
            return .ping
        case .pong:
            return .pong
        case .close:
            return .close
        case .message:
            if event.payload.text != nil {
                return .text
            }
            return .binary
        default:
            return nil
        }
    }

    private func extractWebSocketCloseCode(from payload: Data) -> Int? {
        guard payload.count >= 2 else { return nil }
        return Int(payload[0]) << 8 | Int(payload[1])
    }

    private func extractWebSocketCloseReason(from payload: Data) -> String? {
        guard payload.count > 2 else { return nil }
        return String(data: payload.subdata(in: 2 ..< payload.count), encoding: .utf8)
    }

    // MARK: - Inter-Process Communication

    // Observers for notifications
    private let notificationObserversLock = NSLock()
    private var requestObservers: [UUID: NotificationObserver] = [:]
    private var transportRequestObservers: [UUID: NotificationObserver] = [:]
    private var webSocketObservers: [UUID: NotificationObserver] = [:]
    private var sseObservers: [UUID: NotificationObserver] = [:]
    private var streamObservers: [UUID: NotificationObserver] = [:]
    private var udpFlowObservers: [UUID: NotificationObserver] = [:]

    /// Notifies the main app that a new request was captured
    private func notifyNewRequest() {
        // Use CFNotificationCenter for cross-process notifications
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notificationName = "com.trace.newRequest" as CFString

        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName), nil, nil, true)
    }

    /// Notifies the main app that a new transport event was captured.
    private func notifyNewTransportRequest() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notificationName = "com.trace.newTransportRequest" as CFString
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

    private func notifyStreamUpdated() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let notificationName = "com.trace.streamUpdated" as CFString
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

    /// Sets up listener for new transport request notifications (call from main app).
    /// - Important: Retain the returned token; it auto-cancels observation on deinit.
    public func observeNewTransportRequests(handler: @escaping @Sendable () -> Void) -> AppGroupStorageObserverToken {
        let id = UUID()
        let observer = NotificationObserver()
        observer.observe(notificationName: "com.trace.newTransportRequest", handler: handler)
        notificationObserversLock.lock()
        transportRequestObservers[id] = observer
        notificationObserversLock.unlock()

        return AppGroupStorageObserverToken { [weak self] in
            guard let self else { return }
            self.notificationObserversLock.lock()
            let observer = self.transportRequestObservers.removeValue(forKey: id)
            self.notificationObserversLock.unlock()
            observer?.stop()
        }
    }

    public func stopObservingNewTransportRequests() {
        notificationObserversLock.lock()
        let observers = Array(transportRequestObservers.values)
        transportRequestObservers.removeAll()
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
        CoreLog.storage.info("event=storage.observe_new_sse outcome=start observer_id=\(id.uuidString, privacy: .public)")
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

    /// Sets up listener for stream session/event updates.
    /// - Important: Retain the returned token; it auto-cancels observation on deinit.
    public func observeStreamUpdates(handler: @escaping @Sendable () -> Void) -> AppGroupStorageObserverToken {
        let id = UUID()
        let observer = NotificationObserver()
        observer.observe(notificationName: "com.trace.streamUpdated", handler: handler)
        notificationObserversLock.lock()
        streamObservers[id] = observer
        notificationObserversLock.unlock()

        return AppGroupStorageObserverToken { [weak self] in
            guard let self else { return }
            self.notificationObserversLock.lock()
            let observer = self.streamObservers.removeValue(forKey: id)
            self.notificationObserversLock.unlock()
            observer?.stop()
        }
    }

    public func stopObservingStreamUpdates() {
        notificationObserversLock.lock()
        let observers = Array(streamObservers.values)
        streamObservers.removeAll()
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
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) AS count, COALESCE(SUM(length(payload)), 0) AS total_bytes
                        FROM network_requests
                        """
                    )
                    let count = row?["count"] as Int? ?? 0
                    let bytes = row?["total_bytes"] as Int64? ?? 0
                    return StorageStats(totalRequests: count, totalSize: bytes)
                }
            }
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("storage_stats")
                    .failure()
                    .error(error)
            )
            return StorageStats(totalRequests: 0, totalSize: 0)
        }
    }

    /// Triggers SQLite compaction and returns reclaimed bytes on disk.
    /// Includes `trace.sqlite`, `trace.sqlite-wal`, and `trace.sqlite-shm` files.
    public func reclaimDatabaseSpace() -> Int64 {
        guard let container = containerURL else { return 0 }
        let databaseURL = container.appendingPathComponent("trace.sqlite")
        let sizeBefore = sqliteFootprintBytes(at: databaseURL)

        do {
            try withDatabase { pool in
                try pool.writeWithoutTransaction { db in
                    _ = try db.checkpoint(.truncate)
                }
                try pool.vacuum()
                try pool.writeWithoutTransaction { db in
                    _ = try db.checkpoint(.truncate)
                }
            }
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("reclaim_database_space")
                    .failure()
                    .error(error)
            )
            return 0
        }

        let sizeAfter = sqliteFootprintBytes(at: databaseURL)
        return max(0, sizeBefore - sizeAfter)
    }

    // MARK: - Request Helpers

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

    private func sqliteFootprintBytes(at databaseURL: URL) -> Int64 {
        let sqliteFiles = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        return sqliteFiles.reduce(into: Int64(0)) { partialResult, url in
            let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            partialResult += Int64(fileSize ?? 0)
        }
    }

    func sanitizeDomainList(_ list: [String]) -> [String] {
        let cleaned = list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? ["*"] : cleaned
    }

}
