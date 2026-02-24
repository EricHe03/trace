//
//  RequestInterceptor.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import OSLog
import TraceCore
import TraceFeatures

// MARK: - Configuration Snapshot

/// Represents an immutable snapshot of interception configuration.
/// Captured once and reused across many requests until marked dirty.
public struct ConfigSnapshot: Sendable {
    public let rewriteRules: [RewriteRule]
    public let requestMaps: [RequestMap]
    public let scripts: [Script]
    public let ruleGroups: [RuleGroup]
    public let activeProfile: Profile?
    public let timestamp: Date

    public init(
        rewriteRules: [RewriteRule],
        requestMaps: [RequestMap],
        scripts: [Script],
        ruleGroups: [RuleGroup],
        activeProfile: Profile?
    ) {
        self.rewriteRules = rewriteRules
        self.requestMaps = requestMaps
        self.scripts = scripts
        self.ruleGroups = ruleGroups
        self.activeProfile = activeProfile
        self.timestamp = Date()
    }

    /// Provides an empty snapshot for the initial state.
    public static let empty = ConfigSnapshot(
        rewriteRules: [],
        requestMaps: [],
        scripts: [],
        ruleGroups: [],
        activeProfile: nil
    )
}

// MARK: - Interception Metrics

/// Tracks lightweight metrics for monitoring interceptor performance.
public struct InterceptionMetrics: Sendable {
    public var totalRequests: Int = 0
    public var totalResponses: Int = 0
    public var blockedCount: Int = 0
    public var redirectedCount: Int = 0
    public var mockedCount: Int = 0
    public var breakpointHits: Int = 0
    public var scriptFailures: Int = 0
    public var redirectLoopsPrevented: Int = 0

    // Rule: Timing values are cumulative nanoseconds.
    public var blockCheckTimeNs: UInt64 = 0
    public var redirectCheckTimeNs: UInt64 = 0
    public var mockCheckTimeNs: UInt64 = 0
    public var ruleApplicationTimeNs: UInt64 = 0
    public var scriptExecutionTimeNs: UInt64 = 0
    public var breakpointTimeNs: UInt64 = 0

    public var configReloadCount: Int = 0
    public var lastConfigReload: Date?
}

// MARK: - Request Interceptor Actor

/// Handles interception and modification of requests/responses using rules, maps, and breakpoints.
///
/// This actor runs on its own serial executor (not MainActor) to ensure high throughput
/// in VPN/proxy extension contexts where blocking the Main thread would cause stalls.
public actor RequestInterceptor {
    // MARK: - Singleton

    /// Provides a shared instance. Access via `await RequestInterceptor.shared`.
    public static let shared = RequestInterceptor()

    // MARK: - Dependencies

    // Concurrency: These managers are @MainActor isolated, so access them carefully.
    private nonisolated let breakpointManager: BreakpointManager
    private nonisolated let scriptManager: ScriptManager

    // MARK: - Configuration Snapshot

    // Rationale: Store an immutable snapshot updated only when dirty flags change.
    private var configSnapshot: ConfigSnapshot = .empty

    // Concurrency: Dirty flags use atomic operations for nonisolated access.
    private let dirtyFlags = DirtyFlags()

    // Rule: Debounce config refresh by 50 ms.
    private let configRefreshDebounceMs: UInt64 = 50
    // Rule: Limit config file stat calls to avoid per-request filesystem churn.
    private let configFileCheckIntervalMs: Double = 1000

    private var lastConfigRefresh: Date = .distantPast
    private var lastConfigFileCheck: Date = .distantPast

    private var lastRulesFileDate: Date?
    private var lastMapsFileDate: Date?
    private var lastScriptsFileDate: Date?
    private var lastGroupsFileDate: Date?
    private var lastProfilesFileDate: Date?

    // MARK: - Metrics

    private var metrics = InterceptionMetrics()
    private var logSampler = LogSampler()

    // MARK: - Redirect Loop Prevention

    // Rule: Cap redirects per flow to prevent loops.
    private let maxRedirectsPerFlow = 10

    // MARK: - Safety Limits

    private let maxBodyModificationBytes = 10 * 1024 * 1024

    // MARK: - Notification Observers

    private nonisolated(unsafe) var rulesObserver: NSObjectProtocol?
    private nonisolated(unsafe) var mapsObserver: NSObjectProtocol?
    private nonisolated(unsafe) var scriptsObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        self.breakpointManager = BreakpointManager.shared
        self.scriptManager = ScriptManager.shared

        // Concurrency: Set observers on a background queue to avoid MainActor contention.
        Task { [weak self] in
            await self?.setupNotificationObservers()
            await self?.refreshConfigSnapshotIfNeeded(force: true)
        }
    }

    deinit {
        if let observer = rulesObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mapsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = scriptsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Sets up notification observers that mark dirty flags without reloading.
    /// - Note: This avoids per-notification I/O because reloads are debounced.
    private func setupNotificationObservers() {
        let queue = OperationQueue()
        queue.name = "com.trace.interceptor.notifications"
        queue.maxConcurrentOperationCount = 1

        rulesObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("RewriteRulesChanged"),
            object: nil,
            queue: queue
        ) { [weak dirtyFlags] _ in
            dirtyFlags?.markRulesDirty()
            ProxyLog.interceptor.debug("event=intercept.rules_dirty outcome=flagged")
        }

        mapsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("RequestMapsChanged"),
            object: nil,
            queue: queue
        ) { [weak dirtyFlags] _ in
            dirtyFlags?.markMapsDirty()
            ProxyLog.interceptor.debug("event=intercept.maps_dirty outcome=flagged")
        }

        scriptsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ScriptsChanged"),
            object: nil,
            queue: queue
        ) { [weak dirtyFlags] _ in
            dirtyFlags?.markScriptsDirty()
            ProxyLog.interceptor.debug("event=intercept.scripts_dirty outcome=flagged")
        }
    }

    // MARK: - Configuration Refresh

    /// Refreshes the config snapshot when dirty flags are set and the debounce period has passed.
    /// This runs at the start of each intercept and does minimal work when config is fresh.
    private func refreshConfigSnapshotIfNeeded(force: Bool = false) async {
        let now = Date()
        let timeSinceLastRefresh = now.timeIntervalSince(lastConfigRefresh) * 1000 // Unit is milliseconds.
        let timeSinceLastFileCheck = now.timeIntervalSince(lastConfigFileCheck) * 1000
        let shouldCheckFiles = force || timeSinceLastFileCheck >= configFileCheckIntervalMs
        let filesChanged = shouldCheckFiles ? configFilesChanged() : false
        if shouldCheckFiles {
            lastConfigFileCheck = now
        }
        let shouldForceRefresh = force || filesChanged

        guard shouldForceRefresh || (dirtyFlags.isDirty && timeSinceLastRefresh >= Double(configRefreshDebounceMs)) else {
            return
        }

        // Concurrency: Clear dirty flags before refresh to avoid race conditions.
        let wasDirty = dirtyFlags.clearAll()
        guard shouldForceRefresh || wasDirty else { return }

        ProxyLog.interceptor.debug("event=intercept.config_refresh outcome=starting force=\(shouldForceRefresh)")

        // Concurrency: Access @MainActor managers from this actor context.
        let rules = await MainActor.run {
            RewriteManager.shared.reloadIfNeeded()
            return RewriteManager.shared.rules
        }
        let maps = await MainActor.run {
            RequestMapManager.shared.reloadIfNeeded()
            return RequestMapManager.shared.maps
        }
        let groups = await MainActor.run {
            RuleGroupManager.shared.reloadIfNeeded()
            return RuleGroupManager.shared.groups
        }
        let activeProfile = await MainActor.run {
            ProfileManager.shared.reloadIfNeeded()
            return ProfileManager.shared.getActiveProfile()
        }
        scriptManager.reloadIfNeeded()
        // Concurrency: ScriptManager is Sendable.
        let scripts = scriptManager.scripts

        configSnapshot = ConfigSnapshot(
            rewriteRules: rules,
            requestMaps: maps,
            scripts: scripts,
            ruleGroups: groups,
            activeProfile: activeProfile
        )

        lastRulesFileDate = AppGroupStorage.shared.configFileModificationDate(for: "RewriteRules.json")
        lastMapsFileDate = AppGroupStorage.shared.configFileModificationDate(for: "RequestMaps.json")
        lastScriptsFileDate = AppGroupStorage.shared.configFileModificationDate(for: "Scripts.json")
        lastGroupsFileDate = AppGroupStorage.shared.configFileModificationDate(for: "RuleGroups.json")
        lastProfilesFileDate = AppGroupStorage.shared.configFileModificationDate(for: "Profiles.json")

        lastConfigRefresh = now
        metrics.configReloadCount += 1
        metrics.lastConfigReload = now

        ProxyLog.interceptor.info("event=intercept.config_refresh outcome=success rules=\(rules.count) maps=\(maps.count) scripts=\(scripts.count)")
    }

    // MARK: - Request Interception

    /// Intercepts an outgoing request before it is sent to the server.
    ///
    /// - Parameters:
    ///   - flowId: Canonical flow ID (UUID) for this request/response pair. Create once per flow.
    ///   - url: The request URL.
    ///   - method: The HTTP method string.
    ///   - headers: The request headers.
    ///   - body: The request body as raw Data (preserves binary/compressed content).
    /// - Returns: The interception result indicating how to proceed.
    public func interceptRequest(
        flowId: UUID,
        url: String,
        method: String,
        headers: [String: String],
        body: Data?
    ) async -> InterceptionResult {
        let startTime = DispatchTime.now()
        let flowIdString = flowId.uuidString
        let debugLoggingEnabled = await HardeningConfig.shared.enableDebugLogging

        if debugLoggingEnabled || logSampler.shouldLog(key: "intercept.request_start", first: 5, every: 500) {
            ProxyLog.interceptor.debug(
                "event=intercept.request_start method=\(method, privacy: .public) url=\(url, privacy: .private(mask: .hash)) request_id=\(flowIdString, privacy: .public)"
            )
        }

        metrics.totalRequests += 1
        await refreshConfigSnapshotIfNeeded()

        let httpMethod = HTTPMethod(rawValue: method.uppercased()) ?? .get
        let httpHeaders = headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
        let charset = BodyStorage.extractCharset(from: headers)
        let contentEncoding = headers.first { $0.key.lowercased() == "content-encoding" }?.value

        var modifiedRequest = NetworkRequest(
            id: flowId,
            url: url,
            method: httpMethod,
            statusCode: nil,
            statusMessage: nil,
            timestamp: Date(),
            duration: 0,
            requestHeaders: httpHeaders,
            responseHeaders: [],
            requestBody: body != nil ? BodyStorage.from(data: body!, charset: charset, contentEncoding: contentEncoding) : .empty,
            responseBody: .empty
        )

        // Phase 1: Block
        let blockStart = DispatchTime.now()
        if shouldBlock(request: modifiedRequest) {
            metrics.blockCheckTimeNs += DispatchTime.now().uptimeNanoseconds - blockStart.uptimeNanoseconds
            metrics.blockedCount += 1
            ProxyLog.interceptor.info(
                "event=intercept.blocked outcome=success url=\(modifiedRequest.url, privacy: .private(mask: .hash)) request_id=\(flowIdString, privacy: .public)"
            )
            return .blocked
        }
        metrics.blockCheckTimeNs += DispatchTime.now().uptimeNanoseconds - blockStart.uptimeNanoseconds

        // Phase 2: Redirect (with loop prevention)
        let redirectStart = DispatchTime.now()
        var redirectCount = 0
        var visitedRedirectURLs = Set<String>()
        visitedRedirectURLs.insert(modifiedRequest.url)

        while let redirectUrl = getRedirectUrl(for: modifiedRequest),
              redirectUrl != modifiedRequest.url {
            if visitedRedirectURLs.contains(redirectUrl) || redirectCount >= maxRedirectsPerFlow {
                metrics.redirectLoopsPrevented += 1
                ProxyLog.interceptor.warning(
                    "event=intercept.redirect_loop_prevented outcome=success url=\(modifiedRequest.url, privacy: .private(mask: .hash)) to=\(redirectUrl, privacy: .private(mask: .hash)) count=\(redirectCount) request_id=\(flowIdString, privacy: .public)"
                )
                break
            }

            redirectCount += 1
            visitedRedirectURLs.insert(redirectUrl)

            metrics.redirectedCount += 1
            modifiedRequest.url = redirectUrl
            modifiedRequest.wasRewritten = true
            ProxyLog.interceptor.info(
                "event=intercept.redirected outcome=success to=\(redirectUrl, privacy: .private(mask: .hash)) count=\(redirectCount) request_id=\(flowIdString, privacy: .public)"
            )

            if shouldBlock(request: modifiedRequest) {
                metrics.blockedCount += 1
                ProxyLog.interceptor.info(
                    "event=intercept.blocked_after_redirect outcome=success url=\(modifiedRequest.url, privacy: .private(mask: .hash)) request_id=\(flowIdString, privacy: .public)"
                )
                return .blocked
            }
        }
        metrics.redirectCheckTimeNs += DispatchTime.now().uptimeNanoseconds - redirectStart.uptimeNanoseconds

        // Phase 3: Mock
        let mockStart = DispatchTime.now()
        if var mockResponse = await getMockResponse(for: modifiedRequest.url, method: httpMethod, flowId: flowId) {
            metrics.mockCheckTimeNs += DispatchTime.now().uptimeNanoseconds - mockStart.uptimeNanoseconds
            metrics.mockedCount += 1
            mockResponse.isMocked = true
            ProxyLog.interceptor.info(
                "event=intercept.mocked outcome=success url=\(modifiedRequest.url, privacy: .private(mask: .hash)) request_id=\(flowIdString, privacy: .public)"
            )
            return .mocked(mockResponse)
        }
        metrics.mockCheckTimeNs += DispatchTime.now().uptimeNanoseconds - mockStart.uptimeNanoseconds

        // Phase 4: Breakpoint (Request)
        let breakpointStart = DispatchTime.now()
        var didPauseForBreakpoint = false
        if await breakpointManager.shouldBreakOnRequest(
            url: modifiedRequest.url,
            method: httpMethod,
            headers: modifiedRequest.requestHeaders,
            body: modifiedRequest.requestBody.getData()
        ) {
            didPauseForBreakpoint = true
            metrics.breakpointHits += 1
            modifiedRequest.hitBreakpoint = true
            ProxyLog.interceptor.info(
                "event=intercept.breakpoint_hit url=\(modifiedRequest.url, privacy: .private(mask: .hash)) request_id=\(flowIdString, privacy: .public)"
            )

            let action = await breakpointManager.pauseRequest(
                id: flowIdString,
                url: modifiedRequest.url,
                method: modifiedRequest.method,
                headers: modifiedRequest.requestHeaders,
                body: modifiedRequest.requestBody.getData()
            )

            switch action {
            case .drop:
                metrics.breakpointTimeNs += DispatchTime.now().uptimeNanoseconds - breakpointStart.uptimeNanoseconds
                modifiedRequest.wasBlocked = true
                ProxyLog.interceptor.info(
                    "event=intercept.user_dropped outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                return .blocked

            case .continueAndDisable:
                ProxyLog.interceptor.debug(
                    "event=intercept.breakpoint_disable outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                await breakpointManager.setEnabled(false)
                fallthrough

            case .continue:
                ProxyLog.interceptor.debug(
                    "event=intercept.breakpoint_continue outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                if let pausedRequest = await breakpointManager.getPausedRequest(id: flowIdString) {
                    modifiedRequest.requestHeaders = pausedRequest.effectiveHeaders
                    if let modifiedBody = pausedRequest.effectiveBody {
                        modifiedRequest.requestBody = BodyStorage.from(data: modifiedBody, charset: charset)
                    }
                }
            }
        }
        if !didPauseForBreakpoint {
            if await breakpointManager.applyStoredRequestModifications(to: &modifiedRequest) {
                modifiedRequest.requestBodyModified = true
            }
        }
        metrics.breakpointTimeNs += DispatchTime.now().uptimeNanoseconds - breakpointStart.uptimeNanoseconds

        // Phase 5: Scripts (Request)
        let scriptStart = DispatchTime.now()
        let bodyBeforeScripts = modifiedRequest.requestBody
        modifiedRequest = await executeRequestScripts(on: modifiedRequest)
        var requestBodyModified = modifiedRequest.requestBody != bodyBeforeScripts
        metrics.scriptExecutionTimeNs += DispatchTime.now().uptimeNanoseconds - scriptStart.uptimeNanoseconds

        // Phase 6: Rewrite (Request)
        let ruleStart = DispatchTime.now()
        if applyRequestRules(to: &modifiedRequest) {
            requestBodyModified = true
        }
        metrics.ruleApplicationTimeNs += DispatchTime.now().uptimeNanoseconds - ruleStart.uptimeNanoseconds

        if let policy = failurePolicy(for: modifiedRequest.appliedRuleIds),
           !modifiedRequest.executionErrors.isEmpty {
            switch policy {
            case .failClosed, .failMock:
                return .blocked
            case .failOpen:
                break
            }
        }

        // Network simulation actions
        let simulationActions = simulationActions(for: modifiedRequest, type: .modifyRequest, target: .request)
        if let failure = await applyNetworkSimulation(actions: simulationActions, request: &modifiedRequest, target: .request) {
            return .failed(failure)
        }

        let requestDelay = totalDelay(for: modifiedRequest, type: .modifyRequest, target: .request)
        if requestDelay > 0 {
            if debugLoggingEnabled || logSampler.shouldLog(key: "intercept.delay_request", first: 3, every: 100) {
                ProxyLog.interceptor.debug(
                    "event=intercept.delay_request outcome=pending delay_ms=\(requestDelay) request_id=\(flowIdString, privacy: .public)"
                )
            }
            try? await Task.sleep(nanoseconds: UInt64(requestDelay) * 1_000_000)
        }

        let totalTimeMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
        if debugLoggingEnabled || logSampler.shouldLog(key: "intercept.request_complete", first: 5, every: 500) {
            ProxyLog.interceptor.debug(
                "event=intercept.request_complete outcome=success duration_ms=\(totalTimeMs, format: .fixed(precision: 2)) request_id=\(flowIdString, privacy: .public)"
            )
        }

        modifiedRequest.requestBodyModified = requestBodyModified
        return .modified(modifiedRequest)
    }

    // MARK: - Response Interception

    /// Intercepts an incoming response before it is returned to the client.
    ///
    /// - Parameters:
    ///   - request: The original NetworkRequest (contains flowId via request.id).
    ///   - statusCode: The HTTP status code.
    ///   - statusMessage: The HTTP status message.
    ///   - headers: The response headers.
    ///   - body: The response body as raw Data (preserves binary/compressed content).
    /// - Returns: The modified NetworkRequest with response data.
    public func interceptResponse(
        request: NetworkRequest,
        statusCode: Int,
        statusMessage: String,
        headers: [TraceHTTPHeader],
        body: Data?
    ) async -> NetworkRequest {
        let startTime = DispatchTime.now()
        let flowIdString = request.id.uuidString
        let debugLoggingEnabled = await HardeningConfig.shared.enableDebugLogging

        if debugLoggingEnabled || logSampler.shouldLog(key: "intercept.response_start", first: 5, every: 500) {
            ProxyLog.interceptor.debug(
                "event=intercept.response_start status=\(statusCode) url=\(request.url, privacy: .private(mask: .hash)) request_id=\(flowIdString, privacy: .public)"
            )
        }

        metrics.totalResponses += 1
        await refreshConfigSnapshotIfNeeded()

        let charset = BodyStorage.extractCharset(from: headers)
        let contentEncoding = headers.first { $0.key.lowercased() == "content-encoding" }?.value

        var modifiedRequest = request
        modifiedRequest.statusCode = statusCode
        modifiedRequest.statusMessage = statusMessage
        modifiedRequest.responseHeaders = headers

        if let data = body {
            modifiedRequest.responseBody = BodyStorage.from(
                data: data,
                charset: charset,
                contentEncoding: contentEncoding
            )
        }

        // Phase 8: Scripts (Response)
        let scriptStart = DispatchTime.now()
        modifiedRequest = await executeResponseScripts(on: modifiedRequest)
        metrics.scriptExecutionTimeNs += DispatchTime.now().uptimeNanoseconds - scriptStart.uptimeNanoseconds

        // Phase 9: Rewrite (Response)
        let ruleStart = DispatchTime.now()
        applyResponseRules(to: &modifiedRequest)
        metrics.ruleApplicationTimeNs += DispatchTime.now().uptimeNanoseconds - ruleStart.uptimeNanoseconds

        // Network simulation actions
        let simulationActions = simulationActions(for: modifiedRequest, type: .modifyResponse, target: .response)
        _ = await applyNetworkSimulation(actions: simulationActions, request: &modifiedRequest, target: .response)

        // QUIC hardening: prevent HTTP/3 upgrades when QUIC is blocked.
        if await HardeningConfig.shared.blockQUIC,
           modifiedRequest.url.lowercased().hasPrefix("https://") {
            let hadAltSvc = modifiedRequest.responseHeaders.contains { $0.key.lowercased() == "alt-svc" }
            modifiedRequest.responseHeaders.removeAll { $0.key.lowercased() == "alt-svc" }
            modifiedRequest.responseHeaders.append(TraceHTTPHeader(key: "Alt-Svc", value: "clear"))

            if debugLoggingEnabled || (hadAltSvc && logSampler.shouldLog(key: "hardening.alt_svc_clear", first: 5, every: 500)) {
                ProxyLog.interceptor.info(
                    "event=hardening.alt_svc_clear outcome=success had_alt_svc=\(hadAltSvc) url=\(modifiedRequest.url, privacy: .private(mask: .hash)) request_id=\(flowIdString, privacy: .public)"
                )
            }
        }

        // Phase 10: Breakpoint (Response)
        let breakpointStart = DispatchTime.now()
        var didPauseForResponseBreakpoint = false
        if await breakpointManager.shouldBreakOnResponse(
            url: modifiedRequest.url,
            statusCode: statusCode,
            headers: modifiedRequest.responseHeaders,
            body: modifiedRequest.responseBody.getData()
        ) {
            didPauseForResponseBreakpoint = true
            metrics.breakpointHits += 1
            modifiedRequest.hitBreakpoint = true
            ProxyLog.interceptor.info(
                "event=intercept.response_breakpoint_hit status=\(statusCode) url=\(modifiedRequest.url, privacy: .private(mask: .hash)) request_id=\(flowIdString, privacy: .public)"
            )

            let action = await breakpointManager.pauseResponse(
                id: flowIdString,
                url: modifiedRequest.url,
                method: modifiedRequest.method,
                statusCode: statusCode,
                statusMessage: statusMessage,
                headers: headers,
                body: body
            )

            switch action {
            case .drop:
                ProxyLog.interceptor.info(
                    "event=intercept.response_dropped outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                modifiedRequest.statusCode = 204
                modifiedRequest.statusMessage = "No Content"
                modifiedRequest.responseBody = .empty
                modifiedRequest.wasBlocked = true

            case .continueAndDisable:
                ProxyLog.interceptor.debug(
                    "event=intercept.response_breakpoint_disable outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                await breakpointManager.setEnabled(false)
                fallthrough

            case .continue:
                ProxyLog.interceptor.debug(
                    "event=intercept.response_breakpoint_continue outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                if let pausedRequest = await breakpointManager.getPausedRequest(id: flowIdString) {
                    if let code = pausedRequest.effectiveStatusCode {
                        modifiedRequest.statusCode = code
                    }
                    if let message = pausedRequest.effectiveStatusMessage {
                        modifiedRequest.statusMessage = message
                    }
                    modifiedRequest.responseHeaders = pausedRequest.effectiveHeaders
                    if let modifiedBody = pausedRequest.effectiveBody {
                        modifiedRequest.responseBody = BodyStorage.from(data: modifiedBody, charset: charset)
                    }
                }
            }
        }
        if !didPauseForResponseBreakpoint {
            _ = await breakpointManager.applyStoredResponseModifications(to: &modifiedRequest)
        }
        metrics.breakpointTimeNs += DispatchTime.now().uptimeNanoseconds - breakpointStart.uptimeNanoseconds

        let responseDelay = totalDelay(for: modifiedRequest, type: .modifyResponse, target: .response)
        if responseDelay > 0 {
            if debugLoggingEnabled || logSampler.shouldLog(key: "intercept.delay_response", first: 3, every: 100) {
                ProxyLog.interceptor.debug(
                    "event=intercept.delay_response outcome=pending delay_ms=\(responseDelay) request_id=\(flowIdString, privacy: .public)"
                )
            }
            try? await Task.sleep(nanoseconds: UInt64(responseDelay) * 1_000_000)
        }

        let totalTimeMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
        if debugLoggingEnabled || logSampler.shouldLog(key: "intercept.response_complete", first: 5, every: 500) {
            ProxyLog.interceptor.debug(
                "event=intercept.response_complete outcome=success duration_ms=\(totalTimeMs, format: .fixed(precision: 2)) request_id=\(flowIdString, privacy: .public)"
            )
        }

        return modifiedRequest
    }

    // MARK: - Snapshot-Based Rule Operations

    /// Returns whether a request should be blocked using the snapshot.
    private func shouldBlock(request: NetworkRequest) -> Bool {
        let blockRules = configSnapshot.rewriteRules.filter { $0.enabled && $0.ruleType == .block }
        return blockRules.contains { rule in
            ruleMatches(rule, request: request, target: .request)
        }
    }

    /// Returns the redirect URL using the snapshot.
    private func getRedirectUrl(for request: NetworkRequest) -> String? {
        let redirectRules = configSnapshot.rewriteRules.filter { $0.enabled && $0.ruleType == .redirect }
        let sorted = redirectRules.sorted(by: { $0.priority < $1.priority })
        let matched = sorted.filter { ruleMatches($0, request: request, target: .request) }
        guard let first = matched.first else { return nil }
        let candidates = first.matchingStrategy == .firstMatch ? [first] : matched

        for rule in candidates {
            guard let redirectAction = rule.actions.first(where: { $0.actionType == .redirectTo }),
                  let redirectUrl = redirectAction.redirectUrl else {
                continue
            }

            let pattern = rule.matchCriteria?.url?.pattern ?? rule.matchPattern
            if pattern.contains("*"), redirectUrl.contains("*"),
               let captures = wildcardCaptures(url: request.url, pattern: pattern) {
                return applyWildcardCaptures(to: redirectUrl, captures: captures)
            }

            return redirectUrl
        }

        return nil
    }

    /// Returns whether a URL has a mock mapping using the snapshot.
    private func hasMockMapping(for url: String) -> Bool {
        configSnapshot.requestMaps.contains { map in
            map.enabled && matchesPattern(url: url, pattern: map.matchPattern, matchType: map.matchType)
        }
    }

    /// Returns a mock response using the snapshot and map manager.
    private func getMockResponse(for url: String, method: HTTPMethod, flowId: UUID) async -> NetworkRequest? {
        guard hasMockMapping(for: url) else { return nil }

        // Rationale: Delegate response generation to the map manager to honor delays and hit counts.
        do {
            return try await MainActor.run {
                // Concurrency: Execute async work synchronously on MainActor.
                Task {
                    try await RequestMapManager.shared.getMockResponse(for: url, method: method, requestId: flowId)
                }
            }.value
        } catch {
            ProxyLog.interceptor.error("event=intercept.mock_error outcome=failure url=\(url, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Applies request modification rules from the snapshot.
    private func applyRequestRules(to request: inout NetworkRequest) -> Bool {
        let rules = matchingRules(for: request, type: .modifyRequest, target: .request)

        var didModifyBody = false

        for rule in rules {
            let start = Date()
            let before = request
            for action in rule.actions {
                if applyAction(action, to: &request, target: .request) {
                    didModifyBody = true
                }
            }
            request.appliedRuleIds.append(rule.id)
            validateContent(&request, target: .request, ruleId: rule.id)
            let summary = diffSummary(before: before, after: request, target: .request)
            let duration = Date().timeIntervalSince(start)
            request.executionLog.append(
                ExecutionLogEntry(
                    phase: .rewriteRequest,
                    ruleId: rule.id,
                    ruleName: rule.name,
                    outcome: .applied,
                    duration: duration,
                    diffSummary: summary
                )
            )
            Task { @MainActor in
                RewriteManager.shared.recordRuleHit(rule.id, durationMs: duration * 1000)
            }
            if rule.stopProcessing { break }
        }

        if !rules.isEmpty {
            request.wasRewritten = true
        }

        return didModifyBody
    }

    /// Applies response modification rules from the snapshot.
    private func applyResponseRules(to request: inout NetworkRequest) {
        let rules = matchingRules(for: request, type: .modifyResponse, target: .response)

        for rule in rules {
            let start = Date()
            let before = request
            for action in rule.actions {
                applyAction(action, to: &request, target: .response)
            }
            request.appliedRuleIds.append(rule.id)
            validateContent(&request, target: .response, ruleId: rule.id)
            let summary = diffSummary(before: before, after: request, target: .response)
            let duration = Date().timeIntervalSince(start)
            request.executionLog.append(
                ExecutionLogEntry(
                    phase: .rewriteResponse,
                    ruleId: rule.id,
                    ruleName: rule.name,
                    outcome: .applied,
                    duration: duration,
                    diffSummary: summary
                )
            )
            Task { @MainActor in
                RewriteManager.shared.recordRuleHit(rule.id, durationMs: duration * 1000)
            }
            if rule.stopProcessing { break }
        }

        if !rules.isEmpty {
            request.wasRewritten = true
        }
    }

    /// Returns the total delay for a URL using the snapshot.
    private func totalDelay(for request: NetworkRequest, type: RuleType, target: MatchTarget) -> Int {
        let rules = matchingRules(for: request, type: type, target: target)

        return rules.reduce(0) { total, rule in
            let ruleDelay = rule.actions.reduce(0) { innerTotal, action in
                guard action.actionType == .addDelay, let delay = action.delayMilliseconds else {
                    return innerTotal
                }
                return innerTotal + delay
            }
            return total + ruleDelay
        }
    }

    private func simulationActions(for request: NetworkRequest, type: RuleType, target: MatchTarget) -> [RewriteAction] {
        matchingRules(for: request, type: type, target: target)
            .flatMap(\.actions)
            .filter { action in
                switch action.actionType {
                case .throttle, .addJitter, .dropConnection, .resetConnection, .corruptData, .timeout, .packetLoss:
                    true
                default:
                    false
                }
            }
    }

    private func applyNetworkSimulation(
        actions: [RewriteAction],
        request: inout NetworkRequest,
        target: ActionTarget
    ) async -> RequestInterceptionFailure? {
        guard !actions.isEmpty else { return nil }
        let simulator = NetworkSimulator()

        for action in actions {
            switch action.actionType {
            case .addJitter:
                let baseDelay = action.jitterBaseMs ?? 0
                let variance = action.jitterVarianceMs ?? 0
                await simulator.applyJitter(baseDelay: baseDelay, variance: variance)

            case .throttle:
                let bandwidth = action.throttleBytesPerSecond ?? 0
                let data = target == .request ? (request.requestBody.getData() ?? Data()) : (request.responseBody.getData() ?? Data())
                let throttled = await simulator.applyThrottle(bandwidth: bandwidth, to: data)
                if target == .request {
                    request.requestBody = BodyStorage.from(data: throttled)
                    request.requestBodyModified = true
                } else {
                    request.responseBody = BodyStorage.from(data: throttled)
                    request.wasRewritten = true
                }

            case .corruptData:
                corruptBody(request: &request, target: target)

            case .timeout:
                return .timeout

            case .resetConnection:
                return .connectionReset

            case .dropConnection:
                return .dropConnection

            case .packetLoss:
                return .packetLoss

            default:
                break
            }
        }
        return nil
    }

    // MARK: - Script Execution (Isolated)

    /// Executes request scripts with isolation and error handling.
    /// - Note: Script failures are logged and do not crash the interceptor.
    private func executeRequestScripts(on request: NetworkRequest) async -> NetworkRequest {
        let matchingScripts = configSnapshot.scripts.filter { script in
            script.enabled &&
                (script.scriptType == .request || script.scriptType == .both) &&
                scriptMatchesUrl(script: script, url: request.url)
        }

        guard !matchingScripts.isEmpty else { return request }

        // Rationale: Delegate execution to ScriptManager to centralize script error handling.
        var modifiedRequest = await scriptManager.executeRequestScriptsAsync(matchingScripts, on: request)

        // Rationale: Record applied script names for observability.
        if !matchingScripts.isEmpty {
            let scriptNames = matchingScripts.map(\.name).joined(separator: ", ")
            modifiedRequest.appliedScriptName = scriptNames
        }

        return modifiedRequest
    }

    /// Executes response scripts with isolation and error handling.
    private func executeResponseScripts(on request: NetworkRequest) async -> NetworkRequest {
        let matchingScripts = configSnapshot.scripts.filter { script in
            script.enabled &&
                (script.scriptType == .response || script.scriptType == .both) &&
                scriptMatchesUrl(script: script, url: request.url)
        }

        guard !matchingScripts.isEmpty else { return request }

        // Rationale: Delegate execution to ScriptManager to centralize script error handling.
        var modifiedRequest = await scriptManager.executeResponseScriptsAsync(matchingScripts, on: request)

        // Rationale: Append response script names to any request scripts for observability.
        if !matchingScripts.isEmpty {
            let scriptNames = matchingScripts.map(\.name).joined(separator: ", ")
            if let existing = modifiedRequest.appliedScriptName {
                modifiedRequest.appliedScriptName = "\(existing); \(scriptNames)"
            } else {
                modifiedRequest.appliedScriptName = scriptNames
            }
        }

        return modifiedRequest
    }

    /// Returns whether a script matches the given URL.
    private func scriptMatchesUrl(script: Script, url: String) -> Bool {
        guard let pattern = script.matchPattern, !pattern.isEmpty else {
            // Rule: Empty patterns match all URLs.
            return true
        }
        return matchesPattern(url: url, pattern: pattern, matchType: script.matchType)
    }

    // MARK: - Action Application

    private enum ActionTarget {
        case request
        case response
    }

    /// Applies a single action to a request.
    // swiftlint:disable:next cyclomatic_complexity
    private func applyAction(_ action: RewriteAction, to request: inout NetworkRequest, target: ActionTarget) -> Bool {
        switch action.actionType {
        case .setHeader:
            guard let key = action.headerKey, let value = action.headerValue else { return false }

            switch target {
            case .request:
                if let index = request.requestHeaders.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) {
                    request.requestHeaders[index] = TraceHTTPHeader(key: key, value: value)
                } else {
                    request.requestHeaders.append(TraceHTTPHeader(key: key, value: value))
                }
            case .response:
                if let index = request.responseHeaders.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) {
                    request.responseHeaders[index] = TraceHTTPHeader(key: key, value: value)
                } else {
                    request.responseHeaders.append(TraceHTTPHeader(key: key, value: value))
                }
            }
            return false

        case .removeHeader:
            guard let key = action.headerKey else { return false }
            switch target {
            case .request:
                request.requestHeaders.removeAll { $0.key.lowercased() == key.lowercased() }
            case .response:
                request.responseHeaders.removeAll { $0.key.lowercased() == key.lowercased() }
            }
            return false

        case .replaceBody:
            guard let pattern = action.bodyPattern,
                  let replacement = action.bodyReplacement else { return false }

            let bodyString: String? = switch target {
            case .request: request.requestBody.getString()
            case .response: request.responseBody.getString()
            }
            guard let bodyString else { return false }
            guard pattern.count <= RegexMatcher.maxPatternLength else { return false }
            guard bodyString.count <= RegexMatcher.maxInputLength else { return false }

            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(bodyString.startIndex..., in: bodyString)
                let replaced = regex.stringByReplacingMatches(
                    in: bodyString,
                    range: range,
                    withTemplate: replacement
                )
                switch target {
                case .request:
                    request.requestBody = BodyStorage.from(string: replaced)
                case .response:
                    request.responseBody = BodyStorage.from(string: replaced)
                }
                return target == .request
            } catch {
                ProxyLog.interceptor.error("event=intercept.regex_replace outcome=failure pattern=\(pattern, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            return false

        case .setBody:
            guard let content = action.bodyContent else { return false }
            switch target {
            case .request:
                request.requestBody = BodyStorage.from(string: content)
            case .response:
                request.responseBody = BodyStorage.from(string: content)
            }
            return target == .request

        case .setStatusCode:
            guard let code = action.statusCode else { return false }
            if target == .response {
                request.statusCode = code
            }
            return false

        case .addDelay:
            // Rationale: Delay is applied separately in totalDelay().
            return false

        case .redirectTo:
            // Rationale: Redirects are handled separately in getRedirectUrl().
            return false

        case .setQueryParam:
            guard target == .request, let name = action.queryParamName else { return false }
            let value = action.queryParamValue
            request.url = updateQueryParameter(url: request.url, name: name, value: value)
            request.wasRewritten = true
            return false

        case .removeQueryParam:
            guard target == .request, let name = action.queryParamName else { return false }
            request.url = removeQueryParameter(url: request.url, name: name)
            request.wasRewritten = true
            return false

        case .setCookie:
            guard let name = action.cookieName else { return false }
            let value = action.cookieValue ?? ""
            switch target {
            case .request:
                request.requestHeaders = setCookieHeader(headers: request.requestHeaders, name: name, value: value)
            case .response:
                request.responseHeaders = setSetCookieHeader(headers: request.responseHeaders, name: name, value: value)
            }
            return false

        case .removeCookie:
            guard let name = action.cookieName else { return false }
            switch target {
            case .request:
                request.requestHeaders = removeCookieHeader(headers: request.requestHeaders, name: name)
            case .response:
                request.responseHeaders = removeSetCookieHeader(headers: request.responseHeaders, name: name)
            }
            return false

        case .base64Encode:
            return transformBody(request: &request, target: target) { data in
                Data(data.base64EncodedString().utf8)
            }

        case .base64Decode:
            return transformBody(request: &request, target: target) { data in
                Data(base64Encoded: data) ?? data
            }

        case .urlEncode:
            return transformBody(request: &request, target: target) { data in
                guard let str = String(data: data, encoding: .utf8) else { return data }
                return Data((str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str).utf8)
            }

        case .urlDecode:
            return transformBody(request: &request, target: target) { data in
                guard let str = String(data: data, encoding: .utf8) else { return data }
                return Data((str.removingPercentEncoding ?? str).utf8)
            }

        case .compress:
            return transformBody(request: &request, target: target) { data in
                CompressionHelper.compress(data: data, algorithm: action.compressionAlgorithm) ?? data
            }

        case .decompress:
            return transformBody(request: &request, target: target) { data in
                CompressionHelper.decompress(
                    data: data,
                    algorithm: action.compressionAlgorithm,
                    maxOutputBytes: maxBodyModificationBytes
                ) ?? data
            }

        case .jsonToXml:
            return transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonToXML(data: data) ?? data
            }

        case .xmlToJson:
            return transformBody(request: &request, target: target) { data in
                JSONXMLConverter.xmlToJSON(data: data) ?? data
            }

        case .jsonPathSet:
            guard let path = action.jsonPath, let rawValue = action.jsonValue else { return false }
            return transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonPathSet(data: data, path: path, rawValue: rawValue) ?? data
            }

        case .jsonPathDelete:
            guard let path = action.jsonPath else { return false }
            return transformBody(request: &request, target: target) { data in
                JSONXMLConverter.jsonPathDelete(data: data, path: path) ?? data
            }

        case .setBodyFromTemplate:
            guard let template = action.templateBody else { return false }
            let rendered = TemplateEngine().render(template, context: TemplateContext(request: request))
            switch target {
            case .request:
                request.requestBody = BodyStorage.from(string: rendered)
            case .response:
                request.responseBody = BodyStorage.from(string: rendered)
            }
            return target == .request

        case .throttle, .addJitter, .dropConnection, .resetConnection, .corruptData, .timeout, .packetLoss:
            return false
        }
    }

    private func updateQueryParameter(url: String, name: String, value: String?) -> String {
        guard var components = URLComponents(string: url) else { return url }
        var items = components.queryItems ?? []
        if let index = items.firstIndex(where: { $0.name == name }) {
            items[index].value = value
        } else {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        return components.string ?? url
    }

    private func removeQueryParameter(url: String, name: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != name }
        return components.string ?? url
    }

    private func setCookieHeader(headers: [TraceHTTPHeader], name: String, value: String) -> [TraceHTTPHeader] {
        var updated = headers
        let cookieValue = "\(name)=\(value)"
        if let index = updated.firstIndex(where: { $0.key.lowercased() == "cookie" }) {
            var existing = updated[index].value
            if existing.isEmpty {
                existing = cookieValue
            } else if existing.contains("\(name)=") {
                existing = removeCookieValue(from: existing, name: name)
                existing = existing.isEmpty ? cookieValue : "\(existing); \(cookieValue)"
            } else {
                existing += "; \(cookieValue)"
            }
            updated[index] = TraceHTTPHeader(key: updated[index].key, value: existing)
        } else {
            updated.append(TraceHTTPHeader(key: "Cookie", value: cookieValue))
        }
        return updated
    }

    private func removeCookieHeader(headers: [TraceHTTPHeader], name: String) -> [TraceHTTPHeader] {
        var updated = headers
        guard let index = updated.firstIndex(where: { $0.key.lowercased() == "cookie" }) else { return updated }
        let cleaned = removeCookieValue(from: updated[index].value, name: name)
        if cleaned.isEmpty {
            updated.remove(at: index)
        } else {
            updated[index] = TraceHTTPHeader(key: updated[index].key, value: cleaned)
        }
        return updated
    }

    private func removeCookieValue(from headerValue: String, name: String) -> String {
        let parts = headerValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let filtered = parts.filter { !$0.hasPrefix("\(name)=") }
        return filtered.joined(separator: "; ")
    }

    private func setSetCookieHeader(headers: [TraceHTTPHeader], name: String, value: String) -> [TraceHTTPHeader] {
        var updated = headers
        let headerValue = "\(name)=\(value)"
        if let index = updated.firstIndex(where: { header in
            guard header.key.lowercased() == "set-cookie" else { return false }
            return header.value.trimmingCharacters(in: .whitespaces).hasPrefix("\(name)=")
        }) {
            updated[index] = TraceHTTPHeader(key: updated[index].key, value: headerValue)
        } else {
            updated.append(TraceHTTPHeader(key: "Set-Cookie", value: headerValue))
        }
        return updated
    }

    private func removeSetCookieHeader(headers: [TraceHTTPHeader], name: String) -> [TraceHTTPHeader] {
        headers.filter { header in
            guard header.key.lowercased() == "set-cookie" else { return true }
            return !header.value.hasPrefix("\(name)=")
        }
    }

    private func headerValue(for name: String, request: NetworkRequest, target: ActionTarget) -> String? {
        let headers = target == .request ? request.requestHeaders : request.responseHeaders
        return headers.first(where: { $0.key.lowercased() == name.lowercased() })?.value
    }

    private func diffSummary(before: NetworkRequest, after: NetworkRequest, target: ActionTarget) -> String {
        let beforeHeaders = target == .request ? before.requestHeaders : before.responseHeaders
        let afterHeaders = target == .request ? after.requestHeaders : after.responseHeaders
        let beforeHeaderDict = Dictionary(uniqueKeysWithValues: beforeHeaders.map { ($0.key.lowercased(), $0.value) })
        let afterHeaderDict = Dictionary(uniqueKeysWithValues: afterHeaders.map { ($0.key.lowercased(), $0.value) })

        let added = afterHeaderDict.keys.filter { beforeHeaderDict[$0] == nil }
        let removed = beforeHeaderDict.keys.filter { afterHeaderDict[$0] == nil }
        let changed = afterHeaderDict.keys.filter { key in
            if let beforeValue = beforeHeaderDict[key], let afterValue = afterHeaderDict[key] {
                return beforeValue != afterValue
            }
            return false
        }

        let beforeBodySize = (target == .request ? before.requestBody.getData() : before.responseBody.getData())?.count ?? 0
        let afterBodySize = (target == .request ? after.requestBody.getData() : after.responseBody.getData())?.count ?? 0

        return "headers:+\(added.count)/-\(removed.count)/~\(changed.count) body:\(beforeBodySize)->\(afterBodySize)"
    }

    private func validateContent(_ request: inout NetworkRequest, target: ActionTarget, ruleId: UUID) {
        let contentType = headerValue(for: "content-type", request: request, target: target) ?? ""
        let data = target == .request ? request.requestBody.getData() : request.responseBody.getData()
        guard let data else { return }

        if contentType.contains("json") {
            let result = ContentValidator().validateJSON(data)
            if !result.isValid {
                request.executionErrors.append(ExecutionError(ruleId: ruleId, message: "Invalid JSON after rewrite"))
            }
        } else if contentType.contains("xml") {
            let result = ContentValidator().validateXML(data)
            if !result.isValid {
                request.executionErrors.append(ExecutionError(ruleId: ruleId, message: "Invalid XML after rewrite"))
            }
        }
    }

    private func failurePolicy(for ruleIds: [UUID]) -> FailurePolicy? {
        let groups = configSnapshot.ruleGroups
        for group in groups {
            if group.rules.contains(where: { ruleIds.contains($0) }) {
                if group.failurePolicy == .failClosed {
                    return .failClosed
                }
                if group.failurePolicy == .failMock {
                    return .failMock
                }
            }
        }
        return groups.contains(where: { $0.failurePolicy == .failOpen }) ? .failOpen : nil
    }

    private func transformBody(
        request: inout NetworkRequest,
        target: ActionTarget,
        transform: (Data) -> Data
    ) -> Bool {
        let originalData = target == .request ? (request.requestBody.getData() ?? Data()) : (request.responseBody.getData() ?? Data())
        if originalData.count > maxBodyModificationBytes {
            return false
        }
        let contentType = headerValue(for: "content-type", request: request, target: target) ?? request.contentType
        if ContentSafety.shouldSkipTextOperation(originalData, contentType: contentType) {
            return false
        }
        let transformed = transform(originalData)
        if target == .request {
            request.requestBody = BodyStorage.from(data: transformed)
            return true
        } else {
            request.responseBody = BodyStorage.from(data: transformed)
            return false
        }
    }

    // MARK: - Pattern Matching

    private func matchingRules(for request: NetworkRequest, type: RuleType, target: MatchTarget) -> [RewriteRule] {
        let enabledGroups = configSnapshot.ruleGroups.filter(\.enabled)
        let groupedRuleIds = Set(enabledGroups.flatMap(\.rules))
        let allowedGroupIds = Set(configSnapshot.activeProfile?.ruleGroups ?? enabledGroups.map(\.id))
        let allowedRuleIds = Set(enabledGroups.filter { allowedGroupIds.contains($0.id) }.flatMap(\.rules))

        let candidates = configSnapshot.rewriteRules.filter { rule in
            guard rule.enabled, rule.ruleType == type else { return false }
            if groupedRuleIds.contains(rule.id) {
                return allowedRuleIds.contains(rule.id)
            }
            return true
        }
        let matched = candidates.filter { ruleMatches($0, request: request, target: target) }
        let sorted = matched.sorted { $0.priority < $1.priority }
        guard let first = sorted.first else { return [] }
        if first.matchingStrategy == .firstMatch {
            return [first]
        }
        return sorted
    }

    private func ruleMatches(_ rule: RewriteRule, request: NetworkRequest, target: MatchTarget) -> Bool {
        if let criteria = rule.matchCriteria, !criteria.isEmpty {
            return RequestMatcher.evaluate(criteria, request: request, target: target).passed
        }
        return matchesPattern(url: request.url, pattern: rule.matchPattern, matchType: rule.matchType)
    }

    /// Returns whether a URL matches a pattern.
    private func matchesPattern(url: String, pattern: String, matchType: MatchType) -> Bool {
        switch matchType {
        case .contains:
            url.localizedCaseInsensitiveContains(pattern)
        case .exact:
            url == pattern
        case .regex:
            RegexMatcher.safeMatch(pattern: pattern, in: url, caseSensitive: false)
        case .wildcard:
            matchesWildcard(url: url, pattern: pattern)
        }
    }

    /// Matches wildcard patterns where `*` matches any characters.
    private func matchesWildcard(url: String, pattern: String) -> Bool {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = "^" + regexPattern + "$"

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive) else {
            return false
        }

        let range = NSRange(url.startIndex..., in: url)
        return regex.firstMatch(in: url, range: range) != nil
    }

    /// Extracts wildcard captures from a URL.
    private func wildcardCaptures(url: String, pattern: String) -> [String]? {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: "(.*?)")
        regexPattern = "^" + regexPattern + "$"

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(url.startIndex..., in: url)
        guard let match = regex.firstMatch(in: url, range: range) else {
            return nil
        }

        var captures: [String] = []
        for index in 1 ..< match.numberOfRanges {
            let captureRange = match.range(at: index)
            if let swiftRange = Range(captureRange, in: url) {
                captures.append(String(url[swiftRange]))
            } else {
                captures.append("")
            }
        }

        return captures
    }

    /// Applies wildcard captures to a template URL.
    private func applyWildcardCaptures(to template: String, captures: [String]) -> String {
        var result = template
        var remainingCaptures = captures

        while let range = result.range(of: "*"), !remainingCaptures.isEmpty {
            result.replaceSubrange(range, with: remainingCaptures.removeFirst())
        }

        return result
    }

    private func corruptBody(request: inout NetworkRequest, target: ActionTarget) {
        var data = target == .request ? (request.requestBody.getData() ?? Data()) : (request.responseBody.getData() ?? Data())
        guard !data.isEmpty else { return }
        let index = max(0, data.count / 2)
        data[index] = data[index] ^ 0xFF
        if target == .request {
            request.requestBody = BodyStorage.from(data: data)
            request.requestBodyModified = true
        } else {
            request.responseBody = BodyStorage.from(data: data)
            request.wasRewritten = true
        }
    }

    // MARK: - Config File Change Detection

    private func configFilesChanged() -> Bool {
        let storage = AppGroupStorage.shared

        let rulesDate = storage.configFileModificationDate(for: "RewriteRules.json")
        let mapsDate = storage.configFileModificationDate(for: "RequestMaps.json")
        let scriptsDate = storage.configFileModificationDate(for: "Scripts.json")
        let groupsDate = storage.configFileModificationDate(for: "RuleGroups.json")
        let profilesDate = storage.configFileModificationDate(for: "Profiles.json")

        let rulesChanged = (rulesDate ?? .distantPast) > (lastRulesFileDate ?? .distantPast)
        let mapsChanged = (mapsDate ?? .distantPast) > (lastMapsFileDate ?? .distantPast)
        let scriptsChanged = (scriptsDate ?? .distantPast) > (lastScriptsFileDate ?? .distantPast)
        let groupsChanged = (groupsDate ?? .distantPast) > (lastGroupsFileDate ?? .distantPast)
        let profilesChanged = (profilesDate ?? .distantPast) > (lastProfilesFileDate ?? .distantPast)

        return rulesChanged || mapsChanged || scriptsChanged || groupsChanged || profilesChanged
    }

    // MARK: - Public Utilities

    /// Returns the current metrics snapshot.
    public func getMetrics() -> InterceptionMetrics {
        metrics
    }

    /// Resets metrics.
    public func resetMetrics() {
        metrics = InterceptionMetrics()
    }

    /// Forces a configuration refresh.
    public func forceConfigRefresh() async {
        await refreshConfigSnapshotIfNeeded(force: true)
    }

    // MARK: - Response Pipeline Decision

    /// Returns whether interception is currently "active" from the perspective of TLS protocol
    /// negotiation (ALPN).
    ///
    /// When this is true, the TLS MITM layer should prefer negotiating HTTP/1.1 to ensure full
    /// interception/modification feature parity (rewrite rules, maps, scripts, breakpoints).
    ///
    /// This is intentionally coarse: it is evaluated before any request URL/path is known.
    public func requiresHTTP1Interception() async -> Bool {
        await refreshConfigSnapshotIfNeeded()

        let hasEnabledRewriteRules = configSnapshot.rewriteRules.contains { $0.enabled }
        let hasEnabledRequestMaps = configSnapshot.requestMaps.contains { $0.enabled }
        let hasEnabledScripts = configSnapshot.scripts.contains { $0.enabled }
        let breakpointsEnabled = await breakpointManager.isEnabled()

        return hasEnabledRewriteRules || hasEnabledRequestMaps || hasEnabledScripts || breakpointsEnabled
    }

    public func responsePipeline(for url: String) async -> ResponsePipeline {
        // Rationale: Buffer when a response might be modified or delayed to avoid mismatches.
        await refreshConfigSnapshotIfNeeded()

        let hasResponseRewriteRules = configSnapshot.rewriteRules.contains { rule in
            rule.enabled &&
                rule.ruleType == .modifyResponse &&
                matchesPattern(url: url, pattern: rule.matchPattern, matchType: rule.matchType)
        }

        // Rationale: Script matching is handled by ScriptManager, so any enabled script is a signal.
        let hasAnyEnabledScripts = configSnapshot.scripts.contains { $0.enabled }

        let breakpointsEnabled = await breakpointManager.isEnabled()

        return (hasResponseRewriteRules || hasAnyEnabledScripts || breakpointsEnabled)
            ? .bufferAndIntercept
            : .streamAndCapture
    }
}

// MARK: - Dirty Flags (Thread-Safe)

/// Thread-safe dirty flags using atomic operations.
/// Used to mark when configuration needs refresh without requiring actor isolation.
private final class DirtyFlags: @unchecked Sendable {
    private var _rulesDirty: Bool = false
    private var _mapsDirty: Bool = false
    private var _scriptsDirty: Bool = false
    private let lock = NSLock()

    var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _rulesDirty || _mapsDirty || _scriptsDirty
    }

    func markRulesDirty() {
        lock.lock()
        defer { lock.unlock() }
        _rulesDirty = true
    }

    func markMapsDirty() {
        lock.lock()
        defer { lock.unlock() }
        _mapsDirty = true
    }

    func markScriptsDirty() {
        lock.lock()
        defer { lock.unlock() }
        _scriptsDirty = true
    }

    /// Clears all flags and returns whether any were set.
    func clearAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasDirty = _rulesDirty || _mapsDirty || _scriptsDirty
        _rulesDirty = false
        _mapsDirty = false
        _scriptsDirty = false
        return wasDirty
    }
}

// MARK: - Legacy Compatibility

/// Provides a convenience extension for call sites using the old API with a String body.
public extension RequestInterceptor {
    /// Intercepts a request using the legacy String body API.
    /// - Warning: This may corrupt binary bodies. Prefer the Data-based API.
    @available(*, deprecated, message: "Use interceptRequest(flowId:url:method:headers:body:) with Data body to preserve binary content")
    func interceptRequest(
        url: String,
        method: String,
        headers: [String: String],
        body: String?,
        requestId: String = UUID().uuidString
    ) async -> InterceptionResult {
        let flowId = UUID(uuidString: requestId) ?? UUID()
        let bodyData = body?.data(using: .utf8)
        return await interceptRequest(flowId: flowId, url: url, method: method, headers: headers, body: bodyData)
    }

    /// Intercepts a response using the legacy String body API.
    /// - Warning: This may corrupt binary bodies. Prefer the Data-based API.
    @available(*, deprecated, message: "Use interceptResponse(request:statusCode:statusMessage:headers:body:) with Data body to preserve binary content")
    func interceptResponse(
        request: NetworkRequest,
        statusCode: Int,
        statusMessage: String,
        headers: [String: String],
        body: String?
    ) async -> NetworkRequest {
        let bodyData = body?.data(using: .utf8)
        let headerList = headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
        return await interceptResponse(request: request, statusCode: statusCode, statusMessage: statusMessage, headers: headerList, body: bodyData)
    }
}

// MARK: - InterceptionProviding

extension RequestInterceptor: InterceptionProviding {}
