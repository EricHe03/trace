//
//  AppGroupStorage.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import GRDB

public struct WidgetSharedState: Codable, Equatable, Sendable {
    public var isCapturing: Bool
    public var requestCount: Int
    public var dataTransferred: String
    public var recentRequests: [WidgetRecentRequest]

    public init(
        isCapturing: Bool = false,
        requestCount: Int = 0,
        dataTransferred: String = "0 B",
        recentRequests: [WidgetRecentRequest] = []
    ) {
        self.isCapturing = isCapturing
        self.requestCount = requestCount
        self.dataTransferred = dataTransferred
        self.recentRequests = recentRequests
    }
}

public struct WidgetPendingAction: Codable, Equatable, Sendable {
    public var action: WidgetAction
    public var actionDate: Date
    public var actionView: String?

    public init(action: WidgetAction, actionDate: Date = Date(), actionView: String? = nil) {
        self.action = action
        self.actionDate = actionDate
        self.actionView = actionView
    }
}

public struct MITMAutoBypassStoredEntry: Codable, Equatable, Sendable {
    public var host: String
    public var reason: String
    public var createdAt: Date
    public var expiresAt: Date
    public var isAlias: Bool

    public init(host: String, reason: String, createdAt: Date, expiresAt: Date, isAlias: Bool) {
        self.host = host
        self.reason = reason
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isAlias = isAlias
    }
}

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

    private func makeEncoder() -> JSONEncoder {
        JSONCoding.makeEncoder()
    }

    private func makeDecoder() -> JSONDecoder {
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

    private enum SettingScope {
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
            "hardening.dualMitmStrictEnforcementHardFail"
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

    private func withDatabase<T>(_ body: (DatabasePool) throws -> T) throws -> T {
        databaseLock.lock()
        let pool = database?.pool
        databaseLock.unlock()
        guard let pool else {
            throw StorageError.databaseUnavailable
        }
        return try body(pool)
    }

    @discardableResult
    private func executeDBWrite(_ body: (Database) throws -> Void) -> Bool {
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

    private func settingData(for scope: String, key: String) -> Data? {
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

    private func saveSettingData(_ data: Data, scope: String, key: String) throws {
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

    private func saveSettingValue<T: Encodable>(_ value: T, scope: String, key: String) throws {
        let data = try makeEncoder().encode(value)
        try saveSettingData(data, scope: scope, key: key)
    }

    private func loadSettingValue<T: Decodable>(_ type: T.Type, scope: String, key: String) -> T? {
        guard let data = settingData(for: scope, key: key) else { return nil }
        return try? makeDecoder().decode(T.self, from: data)
    }

    private func removeSetting(scope: String, key: String) throws {
        try withDatabase { pool in
            try pool.write { db in
                try db.execute(
                    sql: "DELETE FROM settings_kv WHERE scope = ? AND key = ?",
                    arguments: [scope, key]
                )
            }
        }
    }

    private func mapDatabaseError(_ error: Error) -> StorageError {
        if let storageError = error as? StorageError {
            return storageError
        }
        return .databaseUnavailable
    }

    // MARK: - Typed Shared State

    public func saveHardeningSetting<T: Encodable>(_ value: T, forKey key: String) throws {
        try saveSettingValue(value, scope: SettingScope.hardening, key: key)
    }

    public func loadHardeningSetting<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        loadSettingValue(type, scope: SettingScope.hardening, key: key)
    }

    public func saveWidgetState(_ state: WidgetSharedState) throws {
        try saveSettingValue(state, scope: SettingScope.widget, key: "state")
    }

    public func loadWidgetState() -> WidgetSharedState {
        loadSettingValue(WidgetSharedState.self, scope: SettingScope.widget, key: "state") ?? WidgetSharedState()
    }

    public func saveWidgetPendingAction(_ action: WidgetPendingAction) throws {
        try saveSettingValue(action, scope: SettingScope.widgetAction, key: "pending_action")
    }

    public func loadWidgetPendingAction() -> WidgetPendingAction? {
        loadSettingValue(WidgetPendingAction.self, scope: SettingScope.widgetAction, key: "pending_action")
    }

    public func clearWidgetPendingAction() throws {
        try removeSetting(scope: SettingScope.widgetAction, key: "pending_action")
    }

    public func consumeWidgetPendingAction(maxAge: TimeInterval) -> WidgetPendingAction? {
        guard let action = loadWidgetPendingAction() else { return nil }
        if Date().timeIntervalSince(action.actionDate) > maxAge {
            try? clearWidgetPendingAction()
            return nil
        }
        try? clearWidgetPendingAction()
        return action
    }

    public func saveMITMAutoBypassMetadataFlag(_ value: Bool, forKey key: String) throws {
        try saveSettingValue(value, scope: SettingScope.mitmAutoBypassMeta, key: key)
    }

    public func loadMITMAutoBypassMetadataFlag(forKey key: String) -> Bool {
        loadSettingValue(Bool.self, scope: SettingScope.mitmAutoBypassMeta, key: key) ?? false
    }

    public func replaceMITMAutoBypassEntries(_ entries: [MITMAutoBypassStoredEntry]) throws {
        try withDatabase { pool in
            try pool.write { db in
                try db.execute(sql: "DELETE FROM mitm_auto_bypass_entries")
                for entry in entries {
                    try db.execute(
                        sql: """
                        INSERT INTO mitm_auto_bypass_entries (host, reason, created_at, expires_at, is_alias)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            entry.host,
                            entry.reason,
                            entry.createdAt.timeIntervalSince1970,
                            entry.expiresAt.timeIntervalSince1970,
                            entry.isAlias ? 1 : 0
                        ]
                    )
                }
            }
        }
    }

    public func loadMITMAutoBypassEntries() -> [MITMAutoBypassStoredEntry] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT host, reason, created_at, expires_at, is_alias
                        FROM mitm_auto_bypass_entries
                        ORDER BY created_at DESC, host ASC
                        """
                    )
                    return rows.map { row in
                        let isAliasInt: Int = row["is_alias"]
                        return MITMAutoBypassStoredEntry(
                            host: row["host"],
                            reason: row["reason"],
                            createdAt: Date(timeIntervalSince1970: row["created_at"]),
                            expiresAt: Date(timeIntervalSince1970: row["expires_at"]),
                            isAlias: isAliasInt != 0
                        )
                    }
                }
            }
        } catch {
            CoreLog.storage.error(
                LogEvent.storage("mitm_auto_bypass_entries_load")
                    .failure()
                    .error(error)
            )
            return []
        }
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
                            requests.append(try decoder.decode(NetworkRequest.self, from: payload))
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
                            requests.append(try decoder.decode(TransportRequest.self, from: payload))
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
                            records.append(try decoder.decode(PacketFlowRecord.self, from: payload))
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
                            flows.append(try decoder.decode(UDPFlowMetadata.self, from: payload))
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

    // MARK: - Generic Storage

    private func canonicalConfigBlobName(for fileName: String) -> String {
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

    /// Load data from a file in the config directory
    public func loadData(from fileName: String) throws -> Data {
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

    /// Save data to a file in the config directory
    public func saveData(_ data: Data, to fileName: String) throws {
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

    // MARK: - Configuration Storage

    /// Saves capture configuration (filters, settings, etc.)
    public func saveConfiguration(_ config: CaptureConfiguration) throws {
        let normalized = config.normalized()
        try saveSettingValue(normalized, scope: SettingScope.capture, key: DefaultsKey.captureConfiguration)
    }

    /// Loads capture configuration
    public func loadConfiguration() -> CaptureConfiguration {
        if let config = loadSettingValue(
            CaptureConfiguration.self,
            scope: SettingScope.capture,
            key: DefaultsKey.captureConfiguration
        ) {
            return config.normalized()
        }
        return CaptureConfiguration.default.normalized()
    }

    // MARK: - Capture Options

    public func saveCaptureOptions(_ options: CaptureOptions) throws {
        let normalized = options.normalized()
        try saveSettingValue(normalized, scope: SettingScope.capture, key: DefaultsKey.captureOptions)
    }

    public func loadCaptureOptions() -> CaptureOptions {
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

    // MARK: - Body Storage Configuration

    public func saveBodyStorageConfig(_ config: BodyStorageConfig) throws {
        let normalized = config.normalized()
        try saveSettingValue(normalized, scope: SettingScope.capture, key: DefaultsKey.bodyStorageConfig)
    }

    public func loadBodyStorageConfig() -> BodyStorageConfig {
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

    // MARK: - Sampling Configuration

    public func saveSamplingConfig(_ config: SamplingConfig) throws {
        let normalized = config.normalized()
        try saveSettingValue(normalized, scope: SettingScope.capture, key: DefaultsKey.samplingConfig)
    }

    public func loadSamplingConfig() -> SamplingConfig {
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

    // MARK: - MITM Allowlist

    public func saveMITMAllowlist(_ allowlist: [String]) throws {
        let sanitized = sanitizeDomainList(allowlist)
        try saveSettingValue(sanitized, scope: SettingScope.capture, key: DefaultsKey.mitmAllowlist)
    }

    public func loadMITMAllowlist() -> [String] {
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
        try saveSettingValue(state, scope: SettingScope.capture, key: DefaultsKey.throttlingState)
    }

    /// Loads network throttling state.
    public func loadThrottlingState() -> NetworkThrottlingState {
        if let state = loadSettingValue(
            NetworkThrottlingState.self,
            scope: SettingScope.capture,
            key: DefaultsKey.throttlingState
        ) {
            return state
        }

        return .disabled
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
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    /// Deletes all WebSocket connections
    public func clearAllWebSocketConnections() throws {
        let didWrite = executeDBWrite { db in
            try db.execute(sql: "DELETE FROM websocket_connections")
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
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    /// Deletes all SSE connections
    public func clearAllSSEConnections() throws {
        let didWrite = executeDBWrite { db in
            try db.execute(sql: "DELETE FROM sse_connections")
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
    }

    // MARK: - Inter-Process Communication

    // Observers for notifications
    private let notificationObserversLock = NSLock()
    private var requestObservers: [UUID: NotificationObserver] = [:]
    private var transportRequestObservers: [UUID: NotificationObserver] = [:]
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
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            partialResult += Int64(fileSize ?? 0)
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
        guard !sessions.isEmpty else { return }
        let encoder = makeEncoder()
        do {
            try withDatabase { pool in
                try pool.write { db in
                    let now = Date().timeIntervalSince1970
                    for session in sessions {
                        let payload = try encoder.encode(session)
                        try db.execute(
                            sql: """
                            INSERT INTO capture_sessions (id, start_time, payload, updated_at)
                            VALUES (?, ?, ?, ?)
                            ON CONFLICT(id) DO UPDATE SET
                                start_time = excluded.start_time,
                                payload = excluded.payload,
                                updated_at = excluded.updated_at
                            """,
                            arguments: [session.id.uuidString, session.startTime.timeIntervalSince1970, payload, now]
                        )
                    }
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Loads all sessions from storage (async)
    public func loadSessions() async throws -> [CaptureSession] {
        try loadAllSessions()
    }

    /// Saves a capture session to the shared container
    public func saveSession(_ session: CaptureSession) throws {
        guard let data = try? makeEncoder().encode(session) else {
            throw StorageError.encodingFailed
        }
        let now = Date().timeIntervalSince1970
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: """
                INSERT INTO capture_sessions (id, start_time, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    start_time = excluded.start_time,
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: [session.id.uuidString, session.startTime.timeIntervalSince1970, data, now]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
        CoreLog.storage.debug("event=storage.session_save outcome=success session_id=\(session.id.uuidString, privacy: .public)")
    }

    /// Loads all capture sessions from storage
    public func loadAllSessions() throws -> [CaptureSession] {
        do {
            return try withDatabase { pool in
                try pool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT payload
                        FROM capture_sessions
                        ORDER BY start_time DESC, id DESC
                        """
                    )
                    let decoder = makeDecoder()
                    var sessions: [CaptureSession] = []
                    sessions.reserveCapacity(rows.count)
                    for row in rows {
                        let payload: Data = row["payload"]
                        if let session = try? decoder.decode(CaptureSession.self, from: payload) {
                            sessions.append(session)
                        }
                    }
                    return sessions
                }
            }
        } catch {
            throw mapDatabaseError(error)
        }
    }

    /// Deletes a specific session from storage
    public func deleteSession(_ sessionID: UUID) throws {
        let didWrite = executeDBWrite { db in
            try db.execute(
                sql: "DELETE FROM capture_sessions WHERE id = ?",
                arguments: [sessionID.uuidString]
            )
        }
        if !didWrite {
            throw StorageError.databaseUnavailable
        }
        CoreLog.storage.debug("event=storage.session_delete outcome=success session_id=\(sessionID.uuidString, privacy: .public)")
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
    case fullTunnelDualMITM

    public var usesPacketTunnelRouting: Bool {
        switch self {
        case .proxyOnly:
            false
        case .fullTunnel, .fullTunnelDualMITM:
            true
        }
    }

    public var usesSystemHTTPProxy: Bool {
        switch self {
        case .proxyOnly, .fullTunnel:
            true
        case .fullTunnelDualMITM:
            false
        }
    }

    public var supportsCustomSocksServer: Bool {
        self == .fullTunnel
    }

    public var enablesTCPTransparentMITM: Bool {
        self == .fullTunnelDualMITM
    }
}

public enum UDPForwardingMode: String, Codable, Sendable {
    case hevOnly
    case direct
    case split
}

public enum DualMITMPolicy: String, Codable, Sendable {
    case adaptiveFailOpen
    case strictMITM
}

public struct CaptureConfiguration: Codable, Sendable {
    public static let defaultFullTunnelDNSServers = ["1.1.1.1", "8.8.8.8"]

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
    public var fullTunnelHybridTCPMITMEnabled: Bool
    public var dualMITMPolicy: DualMITMPolicy
    public var tcpBypassTTLSeconds: Int
    public var quicHostFailOpenSeconds: Int
    public var dualMITMCircuitBreakerEnabled: Bool
    public var quicNoProgressGraceMs: Int
    public var quicNoProgressIdleMs: Int
    public var quicNoProgressAbsoluteMs: Int
    public var quicNoProgressMinClientDatagrams: Int
    public var quicAuthorityRetryAttempts: Int
    public var quicCertMaterialCacheTTLSeconds: Int

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
            fullTunnelUDPForwardingMode: .hevOnly,
            fullTunnelHybridTCPMITMEnabled: false,
            dualMITMPolicy: .adaptiveFailOpen,
            tcpBypassTTLSeconds: 180,
            quicHostFailOpenSeconds: 1800,
            dualMITMCircuitBreakerEnabled: true,
            quicNoProgressGraceMs: 6000,
            quicNoProgressIdleMs: 6000,
            quicNoProgressAbsoluteMs: 20000,
            quicNoProgressMinClientDatagrams: 6,
            quicAuthorityRetryAttempts: 1,
            quicCertMaterialCacheTTLSeconds: 1800
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
        case fullTunnelHybridTCPMITMEnabled
        case dualMITMPolicy
        case tcpBypassTTLSeconds
        case quicHostFailOpenSeconds
        case dualMITMCircuitBreakerEnabled
        case quicNoProgressGraceMs
        case quicNoProgressIdleMs
        case quicNoProgressAbsoluteMs
        case quicNoProgressMinClientDatagrams
        case quicAuthorityRetryAttempts
        case quicCertMaterialCacheTTLSeconds
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
        fullTunnelUDPForwardingMode: UDPForwardingMode,
        fullTunnelHybridTCPMITMEnabled: Bool = false,
        dualMITMPolicy: DualMITMPolicy = .adaptiveFailOpen,
        tcpBypassTTLSeconds: Int = 180,
        quicHostFailOpenSeconds: Int = 1800,
        dualMITMCircuitBreakerEnabled: Bool = true,
        quicNoProgressGraceMs: Int = 6000,
        quicNoProgressIdleMs: Int = 6000,
        quicNoProgressAbsoluteMs: Int = 20000,
        quicNoProgressMinClientDatagrams: Int = 6,
        quicAuthorityRetryAttempts: Int = 1,
        quicCertMaterialCacheTTLSeconds: Int = 1800
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
        self.fullTunnelHybridTCPMITMEnabled = fullTunnelHybridTCPMITMEnabled
        self.dualMITMPolicy = dualMITMPolicy
        self.tcpBypassTTLSeconds = tcpBypassTTLSeconds
        self.quicHostFailOpenSeconds = quicHostFailOpenSeconds
        self.dualMITMCircuitBreakerEnabled = dualMITMCircuitBreakerEnabled
        self.quicNoProgressGraceMs = quicNoProgressGraceMs
        self.quicNoProgressIdleMs = quicNoProgressIdleMs
        self.quicNoProgressAbsoluteMs = quicNoProgressAbsoluteMs
        self.quicNoProgressMinClientDatagrams = quicNoProgressMinClientDatagrams
        self.quicAuthorityRetryAttempts = quicAuthorityRetryAttempts
        self.quicCertMaterialCacheTTLSeconds = quicCertMaterialCacheTTLSeconds
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
        fullTunnelHybridTCPMITMEnabled = try container.decodeIfPresent(Bool.self, forKey: .fullTunnelHybridTCPMITMEnabled)
            ?? defaults.fullTunnelHybridTCPMITMEnabled
        dualMITMPolicy = try container.decodeIfPresent(DualMITMPolicy.self, forKey: .dualMITMPolicy)
            ?? defaults.dualMITMPolicy
        tcpBypassTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .tcpBypassTTLSeconds)
            ?? defaults.tcpBypassTTLSeconds
        quicHostFailOpenSeconds = try container.decodeIfPresent(Int.self, forKey: .quicHostFailOpenSeconds)
            ?? defaults.quicHostFailOpenSeconds
        dualMITMCircuitBreakerEnabled = try container.decodeIfPresent(Bool.self, forKey: .dualMITMCircuitBreakerEnabled)
            ?? defaults.dualMITMCircuitBreakerEnabled
        quicNoProgressGraceMs = try container.decodeIfPresent(Int.self, forKey: .quicNoProgressGraceMs)
            ?? defaults.quicNoProgressGraceMs
        quicNoProgressIdleMs = try container.decodeIfPresent(Int.self, forKey: .quicNoProgressIdleMs)
            ?? defaults.quicNoProgressIdleMs
        quicNoProgressAbsoluteMs = try container.decodeIfPresent(Int.self, forKey: .quicNoProgressAbsoluteMs)
            ?? defaults.quicNoProgressAbsoluteMs
        quicNoProgressMinClientDatagrams = try container.decodeIfPresent(Int.self, forKey: .quicNoProgressMinClientDatagrams)
            ?? defaults.quicNoProgressMinClientDatagrams
        quicAuthorityRetryAttempts = try container.decodeIfPresent(Int.self, forKey: .quicAuthorityRetryAttempts)
            ?? defaults.quicAuthorityRetryAttempts
        quicCertMaterialCacheTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .quicCertMaterialCacheTTLSeconds)
            ?? defaults.quicCertMaterialCacheTTLSeconds
        self = normalized()
    }

    public func encode(to encoder: Encoder) throws {
        let normalized = normalized()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalized.isEnabled, forKey: .isEnabled)
        try container.encode(normalized.filterMode, forKey: .filterMode)
        try container.encode(normalized.domainFilters, forKey: .domainFilters)
        try container.encode(normalized.captureHeaders, forKey: .captureHeaders)
        try container.encode(normalized.captureBody, forKey: .captureBody)
        try container.encode(normalized.maxBodySize, forKey: .maxBodySize)
        try container.encode(normalized.captureMode, forKey: .captureMode)
        try container.encode(normalized.fullTunnelDNSServers, forKey: .fullTunnelDNSServers)
        try container.encode(normalized.fullTunnelSearchDomains, forKey: .fullTunnelSearchDomains)
        try container.encode(normalized.fullTunnelIPv6Enabled, forKey: .fullTunnelIPv6Enabled)
        try container.encode(normalized.fullTunnelSocks5Host, forKey: .fullTunnelSocks5Host)
        try container.encode(normalized.fullTunnelSocks5Port, forKey: .fullTunnelSocks5Port)
        try container.encode(normalized.fullTunnelUDPForwardingMode, forKey: .fullTunnelUDPForwardingMode)
        try container.encode(normalized.fullTunnelHybridTCPMITMEnabled, forKey: .fullTunnelHybridTCPMITMEnabled)
        try container.encode(normalized.dualMITMPolicy, forKey: .dualMITMPolicy)
        try container.encode(normalized.tcpBypassTTLSeconds, forKey: .tcpBypassTTLSeconds)
        try container.encode(normalized.quicHostFailOpenSeconds, forKey: .quicHostFailOpenSeconds)
        try container.encode(normalized.dualMITMCircuitBreakerEnabled, forKey: .dualMITMCircuitBreakerEnabled)
        try container.encode(normalized.quicNoProgressGraceMs, forKey: .quicNoProgressGraceMs)
        try container.encode(normalized.quicNoProgressIdleMs, forKey: .quicNoProgressIdleMs)
        try container.encode(normalized.quicNoProgressAbsoluteMs, forKey: .quicNoProgressAbsoluteMs)
        try container.encode(normalized.quicNoProgressMinClientDatagrams, forKey: .quicNoProgressMinClientDatagrams)
        try container.encode(normalized.quicAuthorityRetryAttempts, forKey: .quicAuthorityRetryAttempts)
        try container.encode(normalized.quicCertMaterialCacheTTLSeconds, forKey: .quicCertMaterialCacheTTLSeconds)
    }

    public func normalized() -> CaptureConfiguration {
        var normalizedConfig = self
        normalizedConfig.normalizeInPlace()
        return normalizedConfig
    }

    private mutating func normalizeInPlace() {
        fullTunnelSocks5Host = fullTunnelSocks5Host.trimmingCharacters(in: .whitespacesAndNewlines)
        if fullTunnelSocks5Host.isEmpty {
            fullTunnelSocks5Port = 0
        }

        fullTunnelDNSServers = Self.normalizedStringList(fullTunnelDNSServers)
        fullTunnelSearchDomains = Self.normalizedStringList(fullTunnelSearchDomains)
        tcpBypassTTLSeconds = max(30, min(86400, tcpBypassTTLSeconds))
        quicHostFailOpenSeconds = max(60, min(86400, quicHostFailOpenSeconds))
        quicNoProgressGraceMs = max(3000, min(20000, quicNoProgressGraceMs))
        quicNoProgressIdleMs = max(3000, min(20000, quicNoProgressIdleMs))
        quicNoProgressAbsoluteMs = max(8000, min(30000, quicNoProgressAbsoluteMs))
        quicNoProgressMinClientDatagrams = max(1, min(8, quicNoProgressMinClientDatagrams))
        quicAuthorityRetryAttempts = max(0, min(2, quicAuthorityRetryAttempts))
        quicCertMaterialCacheTTLSeconds = max(60, min(86400, quicCertMaterialCacheTTLSeconds))

        if captureMode.usesPacketTunnelRouting, fullTunnelDNSServers.isEmpty {
            fullTunnelDNSServers = Self.defaultFullTunnelDNSServers
        }
    }

    private static func normalizedStringList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                normalized.append(trimmed)
            }
        }
        return normalized
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
    case databaseUnavailable
    case encodingFailed
    case decodingFailed
    case fileNotFound

    public var errorDescription: String? {
        switch self {
        case .containerNotFound:
            "App Group container not found. Ensure App Group is configured in entitlements."
        case .databaseUnavailable:
            "Shared GRDB database is unavailable"
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
        case id, url, method, requestMethodRaw, statusCode, statusMessage, timestamp, duration
        case requestHeaders, responseHeaders, requestBody, responseBody, protocolVersion, sessionId
        case capturePath, captureFlowID, capturePolicyModeRaw, captureMetadataVersion
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
        case curlExecutionMetadata
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case rawMethod
        case curlMetadata
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
        self.requestMethodRaw = try container.decodeIfPresent(String.self, forKey: .requestMethodRaw)
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
        if let capturePathRaw = (try? container.decodeIfPresent(String.self, forKey: .capturePath)) ?? nil,
           let parsedCapturePath = NetworkCapturePath(rawValue: capturePathRaw) {
            self.capturePath = parsedCapturePath
        } else {
            self.capturePath = .unknown
        }
        self.captureFlowID = Self.decodeLossyUInt64(from: container, forKey: .captureFlowID)
        self.capturePolicyModeRaw = Self.decodeLossyUInt8(from: container, forKey: .capturePolicyModeRaw)
        self.captureMetadataVersion = Self.decodeLossyUInt8(from: container, forKey: .captureMetadataVersion)
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
        self.curlExecutionMetadata = try container.decodeIfPresent(CurlExecutionMetadata.self, forKey: .curlExecutionMetadata)

        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if self.requestMethodRaw == nil {
            self.requestMethodRaw = try legacyContainer.decodeIfPresent(String.self, forKey: .rawMethod)
        }
        if self.curlExecutionMetadata == nil {
            // Accept either legacy CurlRequestMetadata ("options") or legacy-keyed
            // CurlExecutionMetadata ("effectiveOptions") payloads.
            if let legacyExecution = try? legacyContainer.decode(CurlExecutionMetadata.self, forKey: .curlMetadata) {
                self.curlExecutionMetadata = legacyExecution
            } else if let legacyMetadata = try? legacyContainer.decode(CurlRequestMetadata.self, forKey: .curlMetadata) {
                self.curlExecutionMetadata = legacyMetadata.asExecutionMetadata
            }
        }
    }

    private static func decodeLossyUInt64(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> UInt64? {
        if let value = (try? container.decodeIfPresent(UInt64.self, forKey: key)) ?? nil {
            return value
        }
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil,
           value >= 0 {
            return UInt64(value)
        }
        return nil
    }

    private static func decodeLossyUInt8(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> UInt8? {
        if let value = (try? container.decodeIfPresent(UInt8.self, forKey: key)) ?? nil {
            return value
        }
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil,
           (0 ... 255).contains(value) {
            return UInt8(value)
        }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(requestMethodRaw, forKey: .requestMethodRaw)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(duration, forKey: .duration)
        try container.encode(requestHeaders, forKey: .requestHeaders)
        try container.encode(responseHeaders, forKey: .responseHeaders)
        try container.encode(requestBody, forKey: .requestBody)
        try container.encode(responseBody, forKey: .responseBody)
        try container.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        try container.encode(capturePath.rawValue, forKey: .capturePath)
        try container.encodeIfPresent(captureFlowID, forKey: .captureFlowID)
        try container.encodeIfPresent(capturePolicyModeRaw, forKey: .capturePolicyModeRaw)
        try container.encodeIfPresent(captureMetadataVersion, forKey: .captureMetadataVersion)
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
        try container.encodeIfPresent(curlExecutionMetadata, forKey: .curlExecutionMetadata)
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
