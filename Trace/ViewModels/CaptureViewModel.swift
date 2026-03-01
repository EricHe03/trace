//
//  CaptureViewModel.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
import NetworkExtension
import os
import SwiftUI
import TraceCore
import TraceFeatures
import TraceProxy

// MARK: - Search Scope

enum SearchScope: String, CaseIterable, Sendable {
    case all = "All"
    case url = "URL"
    case headers = "Headers"
    case body = "Body"
}

// MARK: - Response Time Filter

enum ResponseTimeFilter: String, CaseIterable, Sendable {
    case fast = "Fast"
    case normal = "Normal"
    case slow = "Slow"

    var range: ClosedRange<TimeInterval> {
        switch self {
        case .fast: 0 ... 0.1 // < 100ms
        case .normal: 0.1 ... 1.0 // 100ms - 1s
        case .slow: 1.0 ... Double.infinity // > 1s
        }
    }

    var displayName: String {
        switch self {
        case .fast: "Fast (< 100ms)"
        case .normal: "Normal (100ms - 1s)"
        case .slow: "Slow (> 1s)"
        }
    }

    var icon: String {
        switch self {
        case .fast: "hare.fill"
        case .normal: "gauge.medium"
        case .slow: "tortoise.fill"
        }
    }
}

// MARK: - Content Type Filter

enum ContentTypeFilter: String, CaseIterable, Sendable {
    case json = "JSON"
    case html = "HTML"
    case xml = "XML"
    case image = "Image"
    case javascript = "JavaScript"
    case css = "CSS"
    case plainText = "Plain Text"
    case binary = "Binary"

    var mimeTypes: [String] {
        switch self {
        case .json: ["application/json", "text/json"]
        case .html: ["text/html"]
        case .xml: ["application/xml", "text/xml"]
        case .image: [
                "image/png",
                "image/jpeg",
                "image/gif",
                "image/webp",
                "image/svg+xml",
                "image/heic",
                "image/heif",
                "image/avif",
                "image/tiff",
                "image/bmp",
                "image/x-ms-bmp",
                "image/x-icon",
                "image/vnd.microsoft.icon"
            ]
        case .javascript: ["application/javascript", "text/javascript"]
        case .css: ["text/css"]
        case .plainText: ["text/plain"]
        case .binary: ["application/octet-stream", "binary/octet-stream", "octet-stream"]
        }
    }

    var icon: String {
        switch self {
        case .json: "curlybraces"
        case .html: "doc.text"
        case .xml: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .javascript: "scroll"
        case .css: "paintbrush"
        case .plainText: "text.alignleft"
        case .binary: "doc.zipper"
        }
    }
}

// MARK: - Request Grouping

enum RequestGroupingMode: String, CaseIterable, Codable {
    case none = "None"
    case byDomain = "By Domain"
    case bySession = "By Session"
    case hierarchical = "Hierarchical"

    var icon: String {
        switch self {
        case .none: "list.bullet"
        case .byDomain: "globe"
        case .bySession: "clock"
        case .hierarchical: "list.bullet.indent"
        }
    }

    var description: String {
        switch self {
        case .none: "Flat list of all requests"
        case .byDomain: "Group by domain"
        case .bySession: "Group by capture session"
        case .hierarchical: "Group by session, then domain"
        }
    }
}

struct DomainGroup: Identifiable {
    let id: String
    let domain: String
    let requests: [NetworkRequest]

    init(id: String? = nil, domain: String, requests: [NetworkRequest]) {
        self.id = id ?? domain
        self.domain = domain
        self.requests = requests
    }

    var requestCount: Int {
        requests.count
    }

    var totalSize: Int64 {
        requests.reduce(0) { $0 + Int64($1.responseSize ?? 0) }
    }

    var totalSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

struct SessionGroup: Identifiable {
    let session: CaptureSession
    let requests: [NetworkRequest]
    let domainGroups: [DomainGroup]

    var id: UUID {
        session.id
    }

    var requestCount: Int {
        requests.count
    }

    var totalSize: Int64 {
        requests.reduce(0) { $0 + Int64($1.responseSize ?? 0) }
    }

    var totalSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

struct GroupedRequests {
    let mode: RequestGroupingMode
    let domainGroups: [DomainGroup]
    let sessionGroups: [SessionGroup]

    init(mode: RequestGroupingMode, domainGroups: [DomainGroup] = [], sessionGroups: [SessionGroup] = []) {
        self.mode = mode
        self.domainGroups = domainGroups
        self.sessionGroups = sessionGroups
    }

    var isEmpty: Bool {
        domainGroups.isEmpty && sessionGroups.isEmpty
    }
}

// MARK: - Saved Filter Preset

struct SavedFilterPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var filterMethod: String?
    var filterStatusCode: Int?
    var filterDomains: [String]
    var filterFavoritesOnly: Bool
    var filterContentTypes: [String]
    var filterNetworkEventTypes: [String]?
    var filterMinSize: Int?
    var filterMaxSize: Int?
    var filterMinDuration: TimeInterval?
    var filterMaxDuration: TimeInterval?
    var filterRegexPattern: String?
    var filterResponseTime: String?
    var filterShowDuplicatesOnly: Bool
    var filterShowErrorsOnly: Bool

    init(
        id: UUID = UUID(),
        name: String,
        filterMethod: HTTPMethod? = nil,
        filterStatusCode: Int? = nil,
        filterDomains: [String] = [],
        filterFavoritesOnly: Bool = false,
        filterContentTypes: [ContentTypeFilter] = [],
        filterNetworkEventTypes: [NetworkEventType]? = nil,
        filterMinSize: Int? = nil,
        filterMaxSize: Int? = nil,
        filterMinDuration: TimeInterval? = nil,
        filterMaxDuration: TimeInterval? = nil,
        filterRegexPattern: String? = nil,
        filterResponseTime: ResponseTimeFilter? = nil,
        filterShowDuplicatesOnly: Bool = false,
        filterShowErrorsOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.filterMethod = filterMethod?.rawValue
        self.filterStatusCode = filterStatusCode
        self.filterDomains = filterDomains
        self.filterFavoritesOnly = filterFavoritesOnly
        self.filterContentTypes = filterContentTypes.map(\.rawValue)
        self.filterNetworkEventTypes = filterNetworkEventTypes?.map(\.rawValue)
        self.filterMinSize = filterMinSize
        self.filterMaxSize = filterMaxSize
        self.filterMinDuration = filterMinDuration
        self.filterMaxDuration = filterMaxDuration
        self.filterRegexPattern = filterRegexPattern
        self.filterResponseTime = filterResponseTime?.rawValue
        self.filterShowDuplicatesOnly = filterShowDuplicatesOnly
        self.filterShowErrorsOnly = filterShowErrorsOnly
    }
}

@MainActor
final class CaptureViewModel: ObservableObject {
    // Use App Group storage for VPN-captured requests
    private let storage = AppGroupStorage.shared
    private struct FilterCacheKey: Hashable {
        let requestsVersion: Int
        let favoritesVersion: Int
        let bodySearchVersion: Int
        let filterMethod: String?
        let filterStatusCode: Int?
        let filterDomains: [String]
        let filterFavoritesOnly: Bool
        let filterContentTypes: [String]
        let filterNetworkEventTypes: [String]
        let filterMinSize: Int?
        let filterMaxSize: Int?
        let filterMinDuration: TimeInterval?
        let filterMaxDuration: TimeInterval?
        let filterRegexPattern: String?
        let filterResponseTime: String?
        let filterShowDuplicatesOnly: Bool
        let filterShowErrorsOnly: Bool
        let searchText: String
        let searchScope: SearchScope
    }

    private struct GroupingCacheKey: Hashable {
        let mode: RequestGroupingMode
        let filterKey: FilterCacheKey
        let sessionsVersion: Int
    }

    @Published var requests: [NetworkRequest] = [] {
        didSet {
            requestsVersion &+= 1
            requestsChangeToken &+= 1
            filteredRequestsCache = nil
            invalidateGroupingCache()
            if filterShowDuplicatesOnly, !isRunningDuplicateDetection {
                scheduleDuplicateDetection()
            }
        }
    }

    @Published var transportRequests: [TransportRequest] = [] {
        didSet {
            transportRequestsChangeToken &+= 1
        }
    }

    @Published private(set) var requestsChangeToken: UInt64 = 0
    @Published private(set) var transportRequestsChangeToken: UInt64 = 0

    @Published var isCapturing: Bool = false
    @Published var searchText: String = "" {
        didSet { debounceBodySearch() }
    }

    @Published var searchScope: SearchScope = .all {
        didSet { debounceBodySearch() }
    }

    // Basic filters
    @Published var filterMethod: HTTPMethod?
    @Published var filterStatusCode: Int?
    @Published var filterDomains: [String] = []
    @Published var filterFavoritesOnly: Bool = false

    // Advanced filters
    @Published var filterContentTypes: Set<ContentTypeFilter> = []
    @Published var filterNetworkEventTypes: Set<NetworkEventType> = Set(NetworkEventType.allCases) {
        didSet {
            // Affects both `filteredRequests` and whether grouping is allowed (HTTP-only).
            filteredRequestsCache = nil
            invalidateGroupingCache()
        }
    }

    @Published var filterMinSize: Int?
    @Published var filterMaxSize: Int?
    @Published var filterMinDuration: TimeInterval?
    @Published var filterMaxDuration: TimeInterval?
    @Published var filterRegexPattern: String? {
        didSet {
            validateRegexPattern(pattern: filterRegexPattern)
        }
    }

    @Published private(set) var regexFilterError: String?
    @Published var filterResponseTime: ResponseTimeFilter?
    @Published var filterShowDuplicatesOnly: Bool = false {
        didSet {
            if filterShowDuplicatesOnly {
                scheduleDuplicateDetection()
            }
        }
    }

    @Published var filterShowErrorsOnly: Bool = false

    /// Filter convenience properties for UI
    var minResponseTime: Int? {
        get { filterMinDuration.map { Int($0 * 1000) } }
        set { filterMinDuration = newValue.map { TimeInterval($0) / 1000.0 } }
    }

    var maxResponseTime: Int? {
        get { filterMaxDuration.map { Int($0 * 1000) } }
        set { filterMaxDuration = newValue.map { TimeInterval($0) / 1000.0 } }
    }

    var minResponseSize: Int? {
        get { filterMinSize } set { filterMinSize = newValue }
    }

    var maxResponseSize: Int? {
        get { filterMaxSize } set { filterMaxSize = newValue }
    }

    var minDuration: TimeInterval? {
        get { filterMinDuration } set { filterMinDuration = newValue }
    }

    var maxDuration: TimeInterval? {
        get { filterMaxDuration } set { filterMaxDuration = newValue }
    }

    var regexFilter: String {
        get { filterRegexPattern ?? "" } set { filterRegexPattern = newValue.isEmpty ? nil : newValue }
    }

    /// Saved filter presets
    @Published var savedFilterPresets: [SavedFilterPreset] = []

    /// Network Throttling
    @Published var throttlingEnabled: Bool = false {
        didSet { handleThrottlingStateChange() }
    }

    @Published var selectedNetworkCondition: NetworkCondition? {
        didSet { handleThrottlingStateChange() }
    }

    /// Capture Settings
    @Published var captureOptions: CaptureOptions = .default {
        didSet { persistCaptureOptions() }
    }

    @Published var bodyStorageConfig: BodyStorageConfig = .default {
        didSet { persistBodyStorageConfig() }
    }

    @Published var samplingConfig: SamplingConfig = .default {
        didSet { persistSamplingConfig() }
    }

    @Published var mitmAllowlist: [String] = ["*"] {
        didSet { persistHardeningConfig() }
    }

    @Published var quicHandlingMode: QUICHandlingMode = .intercept {
        didSet { persistHardeningConfig() }
    }

    /// Grouping and Sessions
    @Published var groupingMode: RequestGroupingMode = .none {
        didSet {
            UserDefaults.standard.set(groupingMode.rawValue, forKey: "requestGroupingMode")
            invalidateGroupingCache()
        }
    }

    @Published var sessions: [CaptureSession] = [] {
        didSet {
            sessionsVersion &+= 1
            invalidateGroupingCache()
        }
    }

    @Published var currentSession: CaptureSession?
    @Published var selectedSession: CaptureSession?
    @Published var selectedRequestId: UUID?
    private var cachedGroupedRequests: GroupedRequests?
    private var cachedGroupingCacheKey: GroupingCacheKey?
    private var groupingRestoreEventTypes: Set<NetworkEventType>?

    /// Duplicate detection cache
    private var duplicateRequestCache: [String: UUID] = [:] // URL+Method -> First Request ID

    /// Favorites manager
    private let favoritesManager = FavoritesManager.shared

    // Search optimization
    private var searchTask: Task<Void, Never>?
    private let maxSearchBodySize = 100_000 // 100KB limit for body search
    @Published private var bodySearchMatches: Set<UUID> = [] {
        didSet {
            bodySearchVersion &+= 1
            filteredRequestsCache = nil
        }
    }

    // Regex cache
    private var compiledRegex: NSRegularExpression?
    private var lastRegexPattern: String?
    private var filteredRequestsCache: [NetworkRequest]?
    private var filteredRequestsCacheKey: FilterCacheKey?
    private var requestsVersion = 0
    private var favoritesVersion = 0
    private var bodySearchVersion = 0
    private var sessionsVersion = 0

    // Load debouncing to prevent excessive reloads
    private var loadTask: Task<Void, Never>?
    private var activeLoadTask: Task<Void, Never>?
    private var lastLoadTime: Date?
    private var lastRequestFullReloadTime: Date?
    private var requestIncrementalLoadsSinceFullReload = 0
    private var requestIDSet: Set<UUID> = []
    private var transportLoadTask: Task<Void, Never>?
    private var activeTransportLoadTask: Task<Void, Never>?
    private var lastTransportLoadTime: Date?
    private var lastTransportFullReloadTime: Date?
    private var transportIncrementalLoadsSinceFullReload = 0
    private var transportRequestIDSet: Set<UUID> = []
    private let minLoadInterval: TimeInterval = 0.5 // Minimum 500ms between loads
    private let requestFullReloadInterval: TimeInterval = 20
    private let maxIncrementalRequestLoadsBetweenFullReloads = 40
    private let transportFullReloadInterval: TimeInterval = 30
    private let maxIncrementalTransportLoadsBetweenFullReloads = 60
    private var notifiedRequestIds: Set<UUID> = []
    private let notificationDedupLimit = 200
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var newRequestsObserverToken: AppGroupStorageObserverToken?
    private var newTransportRequestsObserverToken: AppGroupStorageObserverToken?
    private var throttlingUpdateTask: Task<Void, Never>?
    private var duplicateDetectionTask: Task<Void, Never>?
    private var isRunningDuplicateDetection = false
    private var isLoadingThrottlingState = false
    private var isLoadingSettings = false
    private static let unknownSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    init() {
        // Unit tests run with the full host app launched. Avoid starting long-lived observers,
        // VPN hooks, and bulk storage loads during tests to prevent hangs/timeouts and to keep
        // tests deterministic.
        if RuntimeEnvironment.isRunningUnitTests {
            return
        }

        // Load saved grouping mode.
        //
        // IMPORTANT: Restore via `setGroupingMode(_:)` (not direct assignment) so we also
        // restore the required invariants (grouping is HTTP-only) and avoid a UI mismatch
        // where the picker shows "Hierarchical" but the list renders flat.
        if let savedMode = UserDefaults.standard.string(forKey: "requestGroupingMode"),
           let mode = RequestGroupingMode(rawValue: savedMode) {
            setGroupingMode(mode)
        }

        // Load initial requests from storage
        loadRequests()
        loadTransportRequests(forceFullReload: true)
        loadSavedPresets()
        loadSessions()
        cleanupOrphanedSessions()
        loadThrottlingState()
        loadSettings()

        // Observe new requests from Network Extension with debouncing
        newRequestsObserverToken = storage.observeNewRequests { [weak self] in
            Task { @MainActor [weak self] in
                self?.debouncedLoadRequests()
            }
        }

        newTransportRequestsObserverToken = storage.observeNewTransportRequests { [weak self] in
            Task { @MainActor [weak self] in
                self?.debouncedLoadTransportRequests()
            }
        }

        // Observe VPN status changes for session tracking
        let vpnStatusObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleVPNStatusChange()
        }
        notificationObservers.append(vpnStatusObserver)

        // Observe VPN connection state changes to sync isCapturing
        VPNManager.shared.$isConnected
            .sink { [weak self] isConnected in
                self?.isCapturing = isConnected
            }
            .store(in: &cancellables)

        // Observe favorites updates to invalidate filter cache
        let favoritesObserver = NotificationCenter.default.addObserver(
            forName: .favoritesUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.favoritesVersion &+= 1
            self?.filteredRequestsCache = nil
        }
        notificationObservers.append(favoritesObserver)
    }

    deinit {
        searchTask?.cancel()
        loadTask?.cancel()
        activeLoadTask?.cancel()
        transportLoadTask?.cancel()
        activeTransportLoadTask?.cancel()
        throttlingUpdateTask?.cancel()
        duplicateDetectionTask?.cancel()

        newRequestsObserverToken?.cancel()
        newRequestsObserverToken = nil
        newTransportRequestsObserverToken?.cancel()
        newTransportRequestsObserverToken = nil

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        cancellables.removeAll()
    }

    private func loadSettings() {
        isLoadingSettings = true
        let config = storage.loadConfiguration()
        captureOptions = CaptureOptions(
            captureHeaders: config.captureHeaders,
            captureBody: config.captureBody,
            maxBodySize: config.maxBodySize
        )
        bodyStorageConfig = storage.loadBodyStorageConfig()
        samplingConfig = storage.loadSamplingConfig()

        Task { [weak self] in
            guard let self else { return }
            let hardening = HardeningConfig.shared
            let allowlist = await hardening.mitmAllowlist
            let quicHandlingMode = await hardening.quicHandlingMode
            await MainActor.run {
                self.mitmAllowlist = allowlist
                self.quicHandlingMode = quicHandlingMode
                self.isLoadingSettings = false
            }
        }
    }

    private func persistCaptureOptions() {
        guard !isLoadingSettings else { return }
        var config = storage.loadConfiguration()
        config.captureHeaders = captureOptions.captureHeaders
        config.captureBody = captureOptions.captureBody
        config.maxBodySize = captureOptions.maxBodySize
        do {
            try storage.saveConfiguration(config)
            try storage.saveCaptureOptions(captureOptions)
        } catch {
            CoreLog.storage.error(
                "event=storage.capture_options_save outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
        Task {
            if VPNManager.shared.isConnected {
                do {
                    try await VPNManager.shared.sendMessage(["command": "updateCaptureConfig"])
                } catch {
                    CoreLog.storage.error(
                        "event=vpn.capture_config_update outcome=failure error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    private func persistBodyStorageConfig() {
        guard !isLoadingSettings else { return }
        do {
            try storage.saveBodyStorageConfig(bodyStorageConfig)
        } catch {
            CoreLog.storage.error(
                "event=storage.body_storage_config_save outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistSamplingConfig() {
        guard !isLoadingSettings else { return }
        do {
            try storage.saveSamplingConfig(samplingConfig)
        } catch {
            CoreLog.storage.error(
                "event=storage.sampling_config_save outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistHardeningConfig() {
        guard !isLoadingSettings else { return }
        let sanitized = mitmAllowlist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let appliedAllowlist = sanitized

        Task {
            let hardening = HardeningConfig.shared
            await hardening.setMitmAllowlist(appliedAllowlist)
            await hardening.setQUICHandlingMode(quicHandlingMode)
            do {
                try storage.saveMITMAllowlist(appliedAllowlist)
            } catch {
                CoreLog.storage.error(
                    "event=storage.mitm_allowlist_save outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
            if VPNManager.shared.isConnected {
                do {
                    try await VPNManager.shared.sendMessage([
                        "command": "updateHardeningConfig",
                        "hardeningConfig": [
                            "mitmAllowlist": appliedAllowlist,
                            "quicHandlingMode": quicHandlingMode.rawValue,
                            // Legacy key for older VPN payloads.
                            "blockQUIC": quicHandlingMode.blocksQUIC
                        ]
                    ])
                } catch {
                    CoreLog.storage.error(
                        "event=vpn.hardening_config_update outcome=failure error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    private func loadThrottlingState() {
        isLoadingThrottlingState = true
        let state = storage.loadThrottlingState()
        throttlingEnabled = state.enabled
        selectedNetworkCondition = state.condition ?? (state.enabled ? .wifi : nil)
        isLoadingThrottlingState = false
    }

    private func handleThrottlingStateChange() {
        guard !isLoadingThrottlingState else { return }

        if throttlingEnabled, selectedNetworkCondition == nil {
            selectedNetworkCondition = .wifi
            return
        }

        throttlingUpdateTask?.cancel()
        throttlingUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.persistThrottlingState()
        }
    }

    private func persistThrottlingState() {
        let state = NetworkThrottlingState(
            enabled: throttlingEnabled,
            condition: selectedNetworkCondition
        )

        do {
            try storage.saveThrottlingState(state)
        } catch {
            CoreLog.storage.error(
                "event=storage.throttling_state_save outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }

        Task {
            await VPNManager.shared.updateThrottlingState(state)
        }
    }

    private func debouncedLoadRequests() {
        // Cancel any pending load task
        loadTask?.cancel()

        // Check if we should skip this load (too soon after last load)
        if let lastLoad = lastLoadTime, Date().timeIntervalSince(lastLoad) < minLoadInterval {
            // Schedule a delayed load instead
            loadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(500_000_000)) // 500ms
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.loadRequests(triggeredByNewRequest: true)
                }
            }
            return
        }

        // Load immediately
        loadRequests(triggeredByNewRequest: true)
    }

    private func debouncedLoadTransportRequests() {
        transportLoadTask?.cancel()

        if let lastLoad = lastTransportLoadTime, Date().timeIntervalSince(lastLoad) < minLoadInterval {
            transportLoadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(500_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.loadTransportRequests(triggeredByNewRequest: true)
                }
            }
            return
        }

        loadTransportRequests(triggeredByNewRequest: true)
    }

    private func loadRequests(triggeredByNewRequest: Bool = false, forceFullReload: Bool = false) {
        lastLoadTime = Date()
        activeLoadTask?.cancel()
        activeLoadTask = Task { [weak self] in
            guard let self else { return }

            let shouldRunFullReload = self.shouldPerformFullRequestReload(
                triggeredByNewRequest: triggeredByNewRequest,
                forceFullReload: forceFullReload
            )

            do {
                let currentSessionId = await MainActor.run { self.currentSession?.id }

                if shouldRunFullReload {
                    var loadedRequests = try await self.storage.loadAllRequestsAsync()
                    loadedRequests = self.assignCurrentSession(to: loadedRequests, currentSessionID: currentSessionId)
                    loadedRequests = self.optimizeRequestsForList(loadedRequests)
                    loadedRequests.sort { $0.timestamp > $1.timestamp }

                    guard !Task.isCancelled else { return }
                    self.requests = self.redirectChainResolver.enrich(loadedRequests)
                    self.requestIDSet = Set(self.requests.map(\.id))
                    self.lastRequestFullReloadTime = Date()
                    self.requestIncrementalLoadsSinceFullReload = 0
                    CoreLog.storage.info(
                        "event=storage.requests_load outcome=success count=\(self.requests.count) mode=full"
                    )
                    if let firstRequest = self.requests.first {
                        CoreLog.storage.debug(
                            "event=storage.requests_load_first outcome=success request_id=\(firstRequest.id.uuidString, privacy: .public) method=\(firstRequest.method.rawValue, privacy: .public) url=\(firstRequest.url, privacy: .private(mask: .hash))"
                        )
                    }

                    // Note: When running in the simulator, you may see network errors in the console for
                    // URLs found in captured requests (e.g., "HTTP load failed" for external resources).
                    // This occurs when iOS system components (like link preview generators or data detectors)
                    // attempt to fetch metadata for URLs displayed in the UI. These errors are harmless and
                    // simulator-specific; they don't affect app functionality or occur on real devices.
                    self.debounceBodySearch()

                    // Update widget with latest data
                    self.updateWidget()

                    if triggeredByNewRequest {
                        self.processNewRequestsForNotifications()
                    }
                    return
                }

                guard let newestKnownTimestamp = self.requests.first?.timestamp else {
                    self.loadRequests(triggeredByNewRequest: triggeredByNewRequest, forceFullReload: true)
                    return
                }

                var loadedRequests = try await self.storage.loadRequestsAsync(
                    newerThan: newestKnownTimestamp,
                    excludingIDs: self.requestIDSet
                )
                loadedRequests = self.assignCurrentSession(to: loadedRequests, currentSessionID: currentSessionId)
                loadedRequests = self.optimizeRequestsForList(loadedRequests)

                guard !Task.isCancelled else { return }
                let newRequestCount = self.mergeRequests(loadedRequests)
                guard newRequestCount > 0 else { return }

                self.requestIncrementalLoadsSinceFullReload += 1
                self.debounceBodySearch()
                self.updateWidget()
                if triggeredByNewRequest {
                    self.processNewRequestsForNotifications()
                }
                CoreLog.storage.debug(
                    "event=storage.requests_load outcome=success count=\(newRequestCount) mode=incremental"
                )
            } catch {
                guard !Task.isCancelled else { return }
                CoreLog.storage.error(
                    "event=storage.requests_load outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
                if shouldRunFullReload {
                    self.requests = []
                    self.requestIDSet = []
                    self.lastRequestFullReloadTime = nil
                    self.requestIncrementalLoadsSinceFullReload = 0
                    self.debounceBodySearch()
                }
            }
        }
    }

    private func shouldPerformFullRequestReload(triggeredByNewRequest: Bool, forceFullReload: Bool) -> Bool {
        if forceFullReload { return true }
        guard triggeredByNewRequest else { return true }
        guard !requests.isEmpty else { return true }
        guard requestIncrementalLoadsSinceFullReload < maxIncrementalRequestLoadsBetweenFullReloads else {
            return true
        }
        guard let lastFullReloadTime = lastRequestFullReloadTime else { return true }
        return Date().timeIntervalSince(lastFullReloadTime) >= requestFullReloadInterval
    }

    private func assignCurrentSession(
        to loadedRequests: [NetworkRequest],
        currentSessionID: UUID?
    ) -> [NetworkRequest] {
        guard let currentSessionID else { return loadedRequests }
        guard !loadedRequests.isEmpty else { return loadedRequests }

        var requestsToStore: [NetworkRequest] = []
        var updatedRequests = loadedRequests
        requestsToStore.reserveCapacity(updatedRequests.count)

        for index in updatedRequests.indices where updatedRequests[index].sessionId == nil {
            updatedRequests[index].sessionId = currentSessionID
            requestsToStore.append(updatedRequests[index])
        }

        for request in requestsToStore {
            try? storage.saveRequest(request)
        }
        return updatedRequests
    }

    private func optimizeRequestsForList(_ requests: [NetworkRequest]) -> [NetworkRequest] {
        requests.map(optimizeRequestForList)
    }

    private func optimizeRequestForList(_ request: NetworkRequest) -> NetworkRequest {
        var optimized = request
        optimized.requestBody = optimizeBodyStorageForList(request.requestBody, previewLimit: maxSearchBodySize)
        optimized.responseBody = optimizeBodyStorageForList(request.responseBody, previewLimit: maxSearchBodySize)
        return optimized
    }

    private func optimizeBodyStorageForList(_ storage: BodyStorage, previewLimit: Int) -> BodyStorage {
        switch storage {
        case let .inline(data, charset, compressionInfo):
            guard data.count > previewLimit else { return storage }
            return .truncated(
                Data(data.prefix(previewLimit)),
                totalSize: data.count,
                charset: charset,
                compressionInfo: compressionInfo
            )
        case let .truncated(data, totalSize, charset, compressionInfo):
            guard data.count > previewLimit else { return storage }
            return .truncated(
                Data(data.prefix(previewLimit)),
                totalSize: totalSize,
                charset: charset,
                compressionInfo: compressionInfo
            )
        case .file, .truncatedFile, .empty:
            return storage
        }
    }

    @discardableResult
    private func mergeRequests(_ loaded: [NetworkRequest]) -> Int {
        guard !loaded.isEmpty else { return 0 }

        var newRequests: [NetworkRequest] = []
        newRequests.reserveCapacity(loaded.count)
        for request in loaded where requestIDSet.insert(request.id).inserted {
            newRequests.append(request)
        }

        guard !newRequests.isEmpty else { return 0 }

        var mergedRequests = requests
        mergedRequests.insert(contentsOf: newRequests, at: 0)
        requests = redirectChainResolver.enrich(mergedRequests)
        return newRequests.count
    }

    private func loadTransportRequests(triggeredByNewRequest: Bool = false, forceFullReload: Bool = false) {
        lastTransportLoadTime = Date()
        activeTransportLoadTask?.cancel()
        activeTransportLoadTask = Task { [weak self] in
            guard let self else { return }

            let shouldRunFullReload = self.shouldPerformFullTransportReload(
                triggeredByNewRequest: triggeredByNewRequest,
                forceFullReload: forceFullReload
            )

            do {
                if shouldRunFullReload {
                    let loaded = try await self.storage.loadAllTransportRequestsAsync()

                    guard !Task.isCancelled else { return }
                    self.transportRequests = loaded
                    self.transportRequestIDSet = Set(loaded.map(\.id))
                    self.lastTransportFullReloadTime = Date()
                    self.transportIncrementalLoadsSinceFullReload = 0
                    return
                }

                guard let newestKnownTimestamp = self.transportRequests.first?.timestamp else {
                    let loaded = try await self.storage.loadAllTransportRequestsAsync()
                    guard !Task.isCancelled else { return }
                    self.transportRequests = loaded
                    self.transportRequestIDSet = Set(loaded.map(\.id))
                    self.lastTransportFullReloadTime = Date()
                    self.transportIncrementalLoadsSinceFullReload = 0
                    return
                }

                let loaded = try await self.storage.loadTransportRequestsAsync(
                    newerThan: newestKnownTimestamp,
                    excludingIDs: self.transportRequestIDSet
                )

                guard !Task.isCancelled else { return }
                self.mergeTransportRequests(loaded)
                self.transportIncrementalLoadsSinceFullReload += 1
            } catch {
                guard !Task.isCancelled else { return }
                CoreLog.storage.error(
                    "event=storage.transport_requests_load outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
                if shouldRunFullReload {
                    self.transportRequests = []
                    self.transportRequestIDSet = []
                    self.lastTransportFullReloadTime = nil
                    self.transportIncrementalLoadsSinceFullReload = 0
                }
            }
        }
    }

    private func shouldPerformFullTransportReload(triggeredByNewRequest: Bool, forceFullReload: Bool) -> Bool {
        if forceFullReload { return true }
        guard triggeredByNewRequest else { return true }
        guard !transportRequests.isEmpty else { return true }
        guard transportIncrementalLoadsSinceFullReload < maxIncrementalTransportLoadsBetweenFullReloads else {
            return true
        }
        guard let lastFullReloadTime = lastTransportFullReloadTime else { return true }
        return Date().timeIntervalSince(lastFullReloadTime) >= transportFullReloadInterval
    }

    private func mergeTransportRequests(_ loaded: [TransportRequest]) {
        guard !loaded.isEmpty else { return }

        var newRequests: [TransportRequest] = []
        newRequests.reserveCapacity(loaded.count)

        for request in loaded where transportRequestIDSet.insert(request.id).inserted {
            newRequests.append(request)
        }

        guard !newRequests.isEmpty else { return }
        transportRequests.insert(contentsOf: newRequests, at: 0)
    }

    private let redirectChainResolver = RedirectChainResolver()

    func reloadRequests() async {
        await MainActor.run {
            loadRequests(forceFullReload: true)
        }
        await activeLoadTask?.value
    }

    func reloadTransportRequests() async {
        await MainActor.run {
            loadTransportRequests(forceFullReload: true)
        }
        await activeTransportLoadTask?.value
    }

    /// Check if network event type filter is user-set (not auto-set by grouping)
    private var hasUserSetNetworkEventTypeFilter: Bool {
        // If grouping is active and filter is exactly [.http], it's auto-set by grouping
        if groupingMode != .none && filterNetworkEventTypes == Set([.http]) {
            return false
        }
        // Otherwise, if it's not all types, it's user-set
        return filterNetworkEventTypes.count != NetworkEventType.allCases.count
    }

    var hasActiveFilters: Bool {
        filterMethod != nil || filterStatusCode != nil || !filterDomains.isEmpty || filterFavoritesOnly ||
            !filterContentTypes.isEmpty || hasUserSetNetworkEventTypeFilter ||
            filterMinSize != nil || filterMaxSize != nil ||
            filterMinDuration != nil || filterMaxDuration != nil || filterRegexPattern != nil ||
            filterResponseTime != nil || filterShowDuplicatesOnly || filterShowErrorsOnly
    }

    var activeFilterCount: Int {
        var count = 0
        if filterMethod != nil { count += 1 }
        if filterStatusCode != nil { count += 1 }
        if filterFavoritesOnly { count += 1 }
        count += filterDomains.count
        count += filterContentTypes.count
        if hasUserSetNetworkEventTypeFilter { count += 1 }
        if filterMinSize != nil || filterMaxSize != nil { count += 1 }
        if filterMinDuration != nil || filterMaxDuration != nil { count += 1 }
        if filterRegexPattern != nil { count += 1 }
        if filterResponseTime != nil { count += 1 }
        if filterShowDuplicatesOnly { count += 1 }
        if filterShowErrorsOnly { count += 1 }
        return count
    }

    var hasAdvancedFilters: Bool {
        !filterContentTypes.isEmpty || filterNetworkEventTypes.count != NetworkEventType.allCases.count ||
            filterMinSize != nil || filterMaxSize != nil ||
            filterMinDuration != nil || filterMaxDuration != nil || filterRegexPattern != nil ||
            filterResponseTime != nil || filterShowDuplicatesOnly || filterShowErrorsOnly
    }

    var eventRebuildFilterToken: Int {
        makeFilterCacheKey().hashValue
    }

    private func makeFilterCacheKey() -> FilterCacheKey {
        FilterCacheKey(
            requestsVersion: requestsVersion,
            favoritesVersion: favoritesVersion,
            bodySearchVersion: bodySearchVersion,
            filterMethod: filterMethod?.rawValue,
            filterStatusCode: filterStatusCode,
            filterDomains: filterDomains.sorted(),
            filterFavoritesOnly: filterFavoritesOnly,
            filterContentTypes: filterContentTypes.map(\.rawValue).sorted(),
            filterNetworkEventTypes: filterNetworkEventTypes.map(\.rawValue).sorted(),
            filterMinSize: filterMinSize,
            filterMaxSize: filterMaxSize,
            filterMinDuration: filterMinDuration,
            filterMaxDuration: filterMaxDuration,
            filterRegexPattern: filterRegexPattern,
            filterResponseTime: filterResponseTime?.rawValue,
            filterShowDuplicatesOnly: filterShowDuplicatesOnly,
            filterShowErrorsOnly: filterShowErrorsOnly,
            searchText: searchText,
            searchScope: searchScope
        )
    }

    var filteredRequests: [NetworkRequest] {
        let cacheKey = makeFilterCacheKey()

        if let cached = filteredRequestsCache, filteredRequestsCacheKey == cacheKey {
            return cached
        }

        if !filterNetworkEventTypes.contains(.http) {
            filteredRequestsCache = []
            filteredRequestsCacheKey = cacheKey
            return []
        }

        if !hasActiveFilters, searchText.isEmpty {
            if requests.count > 1, requests[0].timestamp < requests[1].timestamp {
                let sorted = requests.sorted { $0.timestamp > $1.timestamp }
                filteredRequestsCache = sorted
                filteredRequestsCacheKey = cacheKey
                return sorted
            }
            filteredRequestsCache = requests
            filteredRequestsCacheKey = cacheKey
            return requests
        }

        var results: [NetworkRequest] = []
        results.reserveCapacity(requests.count)
        let favoritedIds = filterFavoritesOnly ? favoritesManager.favoritedRequestIds : nil

        for request in requests {
            if let method = filterMethod, request.method != method { continue }
            if let statusCode = filterStatusCode, request.statusCode != statusCode { continue }

            if !filterDomains.isEmpty {
                let host = request.host
                let matches = filterDomains.contains { domain in
                    matchesDomain(host: host, pattern: domain)
                }
                if !matches { continue }
            }

            if let favoritedIds, !favoritedIds.contains(request.id) { continue }
            if !filterContentTypes.isEmpty, !matchesContentType(request) { continue }

            if filterMinSize != nil || filterMaxSize != nil {
                let size = request.responseSize ?? 0
                if let minSize = filterMinSize, size < minSize { continue }
                if let maxSize = filterMaxSize, size > maxSize { continue }
            }

            if filterMinDuration != nil || filterMaxDuration != nil {
                if let minDuration = filterMinDuration, request.duration < minDuration { continue }
                if let maxDuration = filterMaxDuration, request.duration > maxDuration { continue }
            }

            if let responseTime = filterResponseTime, !responseTime.range.contains(request.duration) { continue }
            if filterShowErrorsOnly, (request.statusCode ?? 0) < 400 { continue }
            if filterShowDuplicatesOnly, !request.isDuplicate { continue }

            if let pattern = filterRegexPattern, !pattern.isEmpty, !matchesRegex(request, pattern: pattern) {
                continue
            }

            if !searchText.isEmpty {
                let matchesSearch: Bool = switch searchScope {
                case .all:
                    request.url.localizedCaseInsensitiveContains(searchText) ||
                        request.statusCodeText.contains(searchText) ||
                        request.method.rawValue.localizedCaseInsensitiveContains(searchText) ||
                        searchInHeaders(request, searchText) ||
                        searchInBody(request, searchText)
                case .url:
                    request.url.localizedCaseInsensitiveContains(searchText)
                case .headers:
                    searchInHeaders(request, searchText)
                case .body:
                    searchInBody(request, searchText)
                }
                if !matchesSearch { continue }
            }

            results.append(request)
        }

        if results.count > 1, results[0].timestamp < results[1].timestamp {
            results.sort { $0.timestamp > $1.timestamp }
        }
        filteredRequestsCache = results
        filteredRequestsCacheKey = cacheKey
        return results
    }

    // MARK: - Content Type Matching

    private func matchesContentType(_ request: NetworkRequest) -> Bool {
        guard let contentTypeHeader = request.responseHeaders.first(where: { $0.key.lowercased() == "content-type" }) else {
            return false
        }

        let contentType = contentTypeHeader.value.lowercased()
        return filterContentTypes.contains { filter in
            filter.mimeTypes.contains { mimeType in
                contentType.contains(mimeType.lowercased())
            }
        }
    }

    // MARK: - Regex Matching

    private func validateRegexPattern(pattern rawPattern: String?) {
        let pattern = rawPattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pattern, !pattern.isEmpty else {
            lastRegexPattern = nil
            compiledRegex = nil
            regexFilterError = nil
            return
        }

        if pattern == lastRegexPattern, compiledRegex != nil || regexFilterError != nil {
            return
        }

        lastRegexPattern = pattern
        do {
            compiledRegex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            regexFilterError = nil
        } catch {
            compiledRegex = nil
            regexFilterError = error.localizedDescription
        }
    }

    private func matchesRegex(_ request: NetworkRequest, pattern: String) -> Bool {
        validateRegexPattern(pattern: pattern)
        guard let regex = compiledRegex else { return false }

        // Check URL
        let urlRange = NSRange(request.url.startIndex..., in: request.url)
        if regex.firstMatch(in: request.url, options: [], range: urlRange) != nil {
            return true
        }

        // Check headers
        for header in request.requestHeaders + request.responseHeaders {
            let headerString = "\(header.key): \(header.value)"
            let headerRange = NSRange(headerString.startIndex..., in: headerString)
            if regex.firstMatch(in: headerString, options: [], range: headerRange) != nil {
                return true
            }
        }

        return false
    }

    private func searchInHeaders(_ request: NetworkRequest, _ searchText: String) -> Bool {
        for header in request.requestHeaders + request.responseHeaders {
            if header.key.localizedCaseInsensitiveContains(searchText) ||
                header.value.localizedCaseInsensitiveContains(searchText) {
                return true
            }
        }
        return false
    }

    private func searchInBody(_ request: NetworkRequest, _ searchText: String) -> Bool {
        bodySearchMatches.contains(request.id)
    }

    // MARK: - Search Helpers

    private func debounceBodySearch() {
        searchTask?.cancel()

        let currentText = searchText
        let currentScope = searchScope

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            await self?.performBodySearch(text: currentText, scope: currentScope)
        }
    }

    @MainActor
    private func performBodySearch(text: String, scope: SearchScope) async {
        guard !text.isEmpty, scope == .body || scope == .all else {
            bodySearchMatches = []
            return
        }

        let requestsSnapshot = requests
        let maxBytes = maxSearchBodySize

        let matches = await Task.detached(priority: .userInitiated) { () -> Set<UUID> in
            var results: Set<UUID> = []
            for request in requestsSnapshot {
                if Task.isCancelled { return results }
                if CaptureViewModel.bodyContains(searchText: text, request: request, maxBytes: maxBytes) {
                    results.insert(request.id)
                }
            }
            return results
        }.value

        bodySearchMatches = matches
    }

    private nonisolated static func bodyContains(searchText: String, request: NetworkRequest, maxBytes: Int) -> Bool {
        if let requestBody = request.requestBody.getPreview(maxBytes: maxBytes),
           let bodyString = String(data: requestBody, encoding: .utf8),
           bodyString.localizedCaseInsensitiveContains(searchText) {
            return true
        }

        if let responseBody = request.responseBody.getPreview(maxBytes: maxBytes),
           let bodyString = String(data: responseBody, encoding: .utf8),
           bodyString.localizedCaseInsensitiveContains(searchText) {
            return true
        }

        return false
    }

    func clearRequests() {
        // Remove any persisted body files tied to current requests
        for request in requests {
            request.requestBody.deleteFile()
            request.responseBody.deleteFile()
        }

        do {
            try storage.clearAllRequests()
            requests = []
            requestIDSet = []
            lastRequestFullReloadTime = nil
            requestIncrementalLoadsSinceFullReload = 0
        } catch {
            CoreLog.storage.error(
                "event=storage.requests_clear outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func clearTransportRequests() {
        for request in transportRequests {
            request.payload.deleteFile()
        }

        do {
            try storage.clearAllTransportRequests()
            transportRequests = []
            transportRequestIDSet = []
            lastTransportFullReloadTime = nil
            transportIncrementalLoadsSinceFullReload = 0
        } catch {
            CoreLog.storage.error(
                "event=storage.transport_requests_clear outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func deleteRequest(_ request: NetworkRequest) {
        // Remove any persisted body files tied to this request
        request.requestBody.deleteFile()
        request.responseBody.deleteFile()

        do {
            try storage.deleteRequest(request)
            requests.removeAll { $0.id == request.id }
            requestIDSet.remove(request.id)
        } catch {
            CoreLog.storage.error(
                "event=storage.request_delete outcome=failure request_id=\(request.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func toggleCapture() {
        if isCapturing {
            isCapturing = false
            VPNManager.shared.stop()
        } else {
            isCapturing = true
            Task {
                do {
                    try await VPNManager.shared.start()
                } catch {
                    isCapturing = false
                    FeatureLog.vpn.error(
                        "event=vpn.start outcome=failure source=ui error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    func clearFilters() {
        filterMethod = nil
        filterStatusCode = nil
        filterDomains = []
        filterFavoritesOnly = false
        // Clear advanced filters
        filterContentTypes = []
        filterNetworkEventTypes = Set(NetworkEventType.allCases)
        filterMinSize = nil
        filterMaxSize = nil
        filterMinDuration = nil
        filterMaxDuration = nil
        filterRegexPattern = nil
        filterResponseTime = nil
        filterShowDuplicatesOnly = false
        filterShowErrorsOnly = false
        // Reset regex cache
        compiledRegex = nil
        lastRegexPattern = nil
    }

    func clearAdvancedFilters() {
        filterContentTypes = []
        filterNetworkEventTypes = Set(NetworkEventType.allCases)
        filterMinSize = nil
        filterMaxSize = nil
        filterMinDuration = nil
        filterMaxDuration = nil
        filterRegexPattern = nil
        filterResponseTime = nil
        filterShowDuplicatesOnly = false
        filterShowErrorsOnly = false
        compiledRegex = nil
        lastRegexPattern = nil
    }

    // MARK: - Saved Filter Presets

    private func loadSavedPresets() {
        guard let data = UserDefaults.standard.data(forKey: "savedFilterPresets") else { return }
        savedFilterPresets = (try? JSONDecoder().decode([SavedFilterPreset].self, from: data)) ?? []
    }

    func saveCurrentFiltersAsPreset(name: String) {
        let preset = SavedFilterPreset(
            name: name,
            filterMethod: filterMethod,
            filterStatusCode: filterStatusCode,
            filterDomains: filterDomains,
            filterFavoritesOnly: filterFavoritesOnly,
            filterContentTypes: Array(filterContentTypes),
            filterNetworkEventTypes: Array(filterNetworkEventTypes),
            filterMinSize: filterMinSize,
            filterMaxSize: filterMaxSize,
            filterMinDuration: filterMinDuration,
            filterMaxDuration: filterMaxDuration,
            filterRegexPattern: filterRegexPattern,
            filterResponseTime: filterResponseTime,
            filterShowDuplicatesOnly: filterShowDuplicatesOnly,
            filterShowErrorsOnly: filterShowErrorsOnly
        )
        savedFilterPresets.append(preset)
        persistSavedPresets()
    }

    func applyPreset(_ preset: SavedFilterPreset) {
        filterMethod = preset.filterMethod.flatMap { HTTPMethod(rawValue: $0) }
        filterStatusCode = preset.filterStatusCode
        filterDomains = preset.filterDomains
        filterFavoritesOnly = preset.filterFavoritesOnly
        filterContentTypes = Set(preset.filterContentTypes.compactMap { ContentTypeFilter(rawValue: $0) })
        filterNetworkEventTypes = preset.filterNetworkEventTypes.map { Set($0.compactMap { NetworkEventType(rawValue: $0) }) } ?? Set(NetworkEventType.allCases)
        filterMinSize = preset.filterMinSize
        filterMaxSize = preset.filterMaxSize
        filterMinDuration = preset.filterMinDuration
        filterMaxDuration = preset.filterMaxDuration
        filterRegexPattern = preset.filterRegexPattern
        filterResponseTime = preset.filterResponseTime.flatMap { ResponseTimeFilter(rawValue: $0) }
        filterShowDuplicatesOnly = preset.filterShowDuplicatesOnly
        filterShowErrorsOnly = preset.filterShowErrorsOnly
    }

    func deletePreset(_ preset: SavedFilterPreset) {
        savedFilterPresets.removeAll { $0.id == preset.id }
        persistSavedPresets()
    }

    private func persistSavedPresets() {
        guard let data = try? JSONEncoder().encode(savedFilterPresets) else { return }
        UserDefaults.standard.set(data, forKey: "savedFilterPresets")
    }

    // MARK: - Duplicate Detection

    private func scheduleDuplicateDetection() {
        duplicateDetectionTask?.cancel()
        duplicateDetectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.detectDuplicates()
            }
        }
    }

    func detectDuplicates() {
        guard !isRunningDuplicateDetection else { return }
        isRunningDuplicateDetection = true
        defer { isRunningDuplicateDetection = false }

        duplicateRequestCache.removeAll()

        var updatedRequests = requests
        let sortedIndices = updatedRequests.indices.sorted {
            updatedRequests[$0].timestamp < updatedRequests[$1].timestamp
        }

        for index in sortedIndices {
            let key = "\(updatedRequests[index].method.rawValue):\(updatedRequests[index].url)"

            if let originalId = duplicateRequestCache[key] {
                updatedRequests[index].isDuplicate = true
                updatedRequests[index].duplicateOfRequestId = originalId
            } else {
                duplicateRequestCache[key] = updatedRequests[index].id
                updatedRequests[index].isDuplicate = false
                updatedRequests[index].duplicateOfRequestId = nil
            }
        }

        requests = updatedRequests
    }

    var duplicateCount: Int {
        requests.filter(\.isDuplicate).count
    }

    func addDomainFilter(_ domain: String) {
        let cleanedDomain = domain.trimmingCharacters(in: .whitespaces).lowercased()
        if !cleanedDomain.isEmpty && !filterDomains.contains(cleanedDomain) {
            filterDomains.append(cleanedDomain)
        }
    }

    func removeDomainFilter(_ domain: String) {
        filterDomains.removeAll { $0 == domain }
    }

    private func matchesDomain(host: String, pattern: String) -> Bool {
        let lowercasedHost = host.lowercased()
        let lowercasedPattern = pattern.lowercased()

        // Exact match
        if lowercasedHost == lowercasedPattern {
            return true
        }

        // Wildcard match (*.example.com)
        if lowercasedPattern.hasPrefix("*.") {
            let domain = String(lowercasedPattern.dropFirst(2))
            return lowercasedHost.hasSuffix(".\(domain)") || lowercasedHost == domain
        }

        // Subdomain match
        if lowercasedHost.hasSuffix(".\(lowercasedPattern)") {
            return true
        }

        return false
    }

    // MARK: - Session Management

    private func loadSessions() {
        do {
            sessions = try storage.loadAllSessions()
            // Find active session if any
            currentSession = sessions.first { $0.isActive }
        } catch {
            CoreLog.storage.error(
                "event=storage.sessions_load outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            sessions = []
        }
    }

    private func cleanupOrphanedSessions() {
        // Mark any orphaned active sessions as ended (e.g., from app crashes)
        for session in sessions where session.isActive {
            var updatedSession = session
            updatedSession.endTime = Date()
            do {
                try storage.updateSession(updatedSession)
                if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[index] = updatedSession
                }
            } catch {
                CoreLog.storage.error(
                    "event=storage.session_cleanup outcome=failure session_id=\(session.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        currentSession = nil
    }

    func startNewSession() {
        // End current session if active
        if let current = currentSession {
            endCurrentSession()
        }

        // Create new session
        let newSession = CaptureSession(
            startTime: Date(),
            endTime: nil,
            requestCount: 0,
            totalDataTransferred: 0
        )

        do {
            try storage.saveSession(newSession)
            currentSession = newSession
            sessions.insert(newSession, at: 0)
            CoreLog.storage.info(
                "event=storage.session_start outcome=success session_id=\(newSession.id.uuidString, privacy: .public)"
            )
        } catch {
            CoreLog.storage.error(
                "event=storage.session_start outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func endCurrentSession() {
        guard var session = currentSession else { return }

        // Calculate statistics
        let sessionRequests = requests.filter { $0.sessionId == session.id }
        session.endTime = Date()
        session.requestCount = sessionRequests.count
        session.totalDataTransferred = sessionRequests.reduce(0) { $0 + Int64($1.responseSize ?? 0) }

        do {
            try storage.updateSession(session)
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
            }
            currentSession = nil
            CoreLog.storage.info(
                "event=storage.session_end outcome=success session_id=\(session.id.uuidString, privacy: .public) request_count=\(session.requestCount)"
            )
        } catch {
            CoreLog.storage.error(
                "event=storage.session_end outcome=failure session_id=\(session.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleVPNStatusChange() {
        // Sync capture state with VPN connection state
        isCapturing = VPNManager.shared.isConnected

        // Handle session management based on VPN state
        if VPNManager.shared.isConnected {
            // VPN connected - ensure we have an active session
            if currentSession == nil {
                startNewSession()
            }
        } else {
            // VPN disconnected - end current session if any
            if currentSession != nil {
                endCurrentSession()
            }
        }
    }

    // MARK: - Grouping Logic

    private func invalidateGroupingCache() {
        cachedGroupedRequests = nil
        cachedGroupingCacheKey = nil
    }

    var groupedRequests: GroupedRequests {
        let cacheKey = GroupingCacheKey(
            mode: groupingMode,
            filterKey: makeFilterCacheKey(),
            sessionsVersion: sessionsVersion
        )
        if let cached = cachedGroupedRequests,
           cachedGroupingCacheKey == cacheKey {
            return cached
        }

        let grouped: GroupedRequests
        let requestsToGroup = filteredRequests

        switch groupingMode {
        case .none:
            grouped = GroupedRequests(mode: .none)
        case .byDomain:
            grouped = groupByDomain(requests: requestsToGroup)
        case .bySession:
            grouped = groupBySession(requests: requestsToGroup)
        case .hierarchical:
            grouped = groupHierarchical(requests: requestsToGroup)
        }

        cachedGroupedRequests = grouped
        cachedGroupingCacheKey = cacheKey
        return grouped
    }

    private func groupByDomain(requests: [NetworkRequest]) -> GroupedRequests {
        let grouped = Dictionary(grouping: requests) { $0.host }
        let domainGroups = grouped.map { domain, reqs in
            DomainGroup(domain: domain, requests: reqs)
        }.sorted { $0.domain < $1.domain }

        return GroupedRequests(mode: .byDomain, domainGroups: domainGroups)
    }

    private func groupBySession(requests: [NetworkRequest]) -> GroupedRequests {
        // Group requests by session
        var sessionMap: [UUID: [NetworkRequest]] = [:]
        var orphanedRequests: [NetworkRequest] = []

        for request in requests {
            if let sessionId = request.sessionId {
                sessionMap[sessionId, default: []].append(request)
            } else {
                orphanedRequests.append(request)
            }
        }

        var sessionGroups: [SessionGroup] = []

        // Add known sessions
        for session in sessions {
            if let requestsForSession = sessionMap[session.id], !requestsForSession.isEmpty {
                sessionGroups.append(SessionGroup(
                    session: session,
                    requests: requestsForSession,
                    domainGroups: []
                ))
            }
        }

        // Add orphaned requests as "Unknown Session"
        if !orphanedRequests.isEmpty {
            let unknownSession = CaptureSession(
                id: Self.unknownSessionID,
                startTime: orphanedRequests.last?.timestamp ?? Date(),
                endTime: orphanedRequests.first?.timestamp,
                requestCount: orphanedRequests.count,
                totalDataTransferred: orphanedRequests.reduce(0) { $0 + Int64($1.responseSize ?? 0) }
            )
            sessionGroups.append(SessionGroup(
                session: unknownSession,
                requests: orphanedRequests,
                domainGroups: []
            ))
        }

        return GroupedRequests(mode: .bySession, sessionGroups: sessionGroups)
    }

    private func groupHierarchical(requests: [NetworkRequest]) -> GroupedRequests {
        // Group requests by session first
        var sessionMap: [UUID: [NetworkRequest]] = [:]
        var orphanedRequests: [NetworkRequest] = []

        for request in requests {
            if let sessionId = request.sessionId {
                sessionMap[sessionId, default: []].append(request)
            } else {
                orphanedRequests.append(request)
            }
        }

        var sessionGroups: [SessionGroup] = []

        // Add known sessions with domain groups
        for session in sessions {
            if let requestsForSession = sessionMap[session.id], !requestsForSession.isEmpty {
                // Group by domain within this session
                let domainGrouped = Dictionary(grouping: requestsForSession) { $0.host }
                let domainGroups = domainGrouped.map { domain, reqs in
                    DomainGroup(
                        id: "\(session.id.uuidString)::\(domain)",
                        domain: domain,
                        requests: reqs
                    )
                }.sorted { $0.domain < $1.domain }

                sessionGroups.append(SessionGroup(
                    session: session,
                    requests: requestsForSession,
                    domainGroups: domainGroups
                ))
            }
        }

        // Add orphaned requests as "Unknown Session"
        if !orphanedRequests.isEmpty {
            let unknownSession = CaptureSession(
                id: Self.unknownSessionID,
                startTime: orphanedRequests.last?.timestamp ?? Date(),
                endTime: orphanedRequests.first?.timestamp,
                requestCount: orphanedRequests.count,
                totalDataTransferred: orphanedRequests.reduce(0) { $0 + Int64($1.responseSize ?? 0) }
            )

            let domainGrouped = Dictionary(grouping: orphanedRequests) { $0.host }
            let domainGroups = domainGrouped.map { domain, reqs in
                DomainGroup(
                    id: "\(Self.unknownSessionID.uuidString)::\(domain)",
                    domain: domain,
                    requests: reqs
                )
            }.sorted { $0.domain < $1.domain }

            sessionGroups.append(SessionGroup(
                session: unknownSession,
                requests: orphanedRequests,
                domainGroups: domainGroups
            ))
        }

        return GroupedRequests(mode: .hierarchical, sessionGroups: sessionGroups)
    }

    func setGroupingMode(_ mode: RequestGroupingMode) {
        if mode != .none {
            if filterNetworkEventTypes != Set([.http]) {
                groupingRestoreEventTypes = filterNetworkEventTypes
                filterNetworkEventTypes = Set([.http])
            }
        } else if let restore = groupingRestoreEventTypes, filterNetworkEventTypes == Set([.http]) {
            filterNetworkEventTypes = restore
            groupingRestoreEventTypes = nil
        }

        groupingMode = mode
    }

    // MARK: - Widget Updates

    /// Update widget with current state
    private func updateWidget() {
        let isCapturing = VPNManager.shared.isConnected
        let requestCount = requests.count

        // Calculate total data transferred
        let totalBytes = requests.reduce(Int64(0)) { sum, request in
            sum + Int64(request.responseSize ?? 0) + Int64(request.requestSize ?? 0)
        }
        let dataTransferred = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)

        // Get recent requests (last 5)
        let recentRequests = requests.prefix(5).map { WidgetRecentRequest(from: $0) }

        WidgetDataManager.shared.updateWidgetData(
            isCapturing: isCapturing,
            requestCount: requestCount,
            dataTransferred: dataTransferred,
            recentRequests: Array(recentRequests)
        )
    }

    // MARK: - Notification Triggers

    /// Check if a request should trigger a notification
    private func checkNotificationTriggers(for request: NetworkRequest) {
        let settings = NotificationSettings.shared

        // Check for HTTP errors (4xx, 5xx)
        if settings.enableErrorNotifications,
           let statusCode = request.statusCode,
           statusCode >= 400 {
            NotificationManager.shared.notifyHTTPError(request: request)
        }

        // Check for slow requests
        if settings.enableSlowRequestNotifications,
           request.duration >= settings.slowRequestThreshold {
            NotificationManager.shared.notifySlowRequest(request: request, duration: request.duration)
        }

        // Check for large data
        if settings.enableLargeDataNotifications {
            let totalSize = Int64(request.requestSize ?? 0) + Int64(request.responseSize ?? 0)
            if totalSize >= settings.largeDataThreshold {
                NotificationManager.shared.notifyLargeData(request: request, size: totalSize)
            }
        }
    }

    /// Process new requests for notification triggers
    /// Call this when new requests are added to check if they should trigger notifications
    func processNewRequestsForNotifications() {
        guard VPNManager.shared.isConnected else { return }

        // Only check the most recent requests (last 10)
        let recentRequests = requests.prefix(10)

        for request in recentRequests {
            guard !notifiedRequestIds.contains(request.id) else { continue }
            // Only notify for completed requests with responses
            guard request.statusCode != nil else { continue }

            checkNotificationTriggers(for: request)
            notifiedRequestIds.insert(request.id)
        }

        if notifiedRequestIds.count > notificationDedupLimit {
            let recentIds = Set(requests.prefix(notificationDedupLimit).map(\.id))
            notifiedRequestIds = notifiedRequestIds.intersection(recentIds)
        }
    }
}
