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
    nonisolated let scriptManager: ScriptManager

    // MARK: - Configuration Snapshot

    // Rationale: Store an immutable snapshot updated only when dirty flags change.
    var configSnapshot: ConfigSnapshot = .empty

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

    let maxBodyModificationBytes = 10 * 1024 * 1024

    // MARK: - Notification Observers

    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []

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
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Sets up notification observers that mark dirty flags without reloading.
    /// - Note: This avoids per-notification I/O because reloads are debounced.
    private func setupNotificationObservers() {
        let queue = OperationQueue()
        queue.name = "com.trace.interceptor.notifications"
        queue.maxConcurrentOperationCount = 1

        let observedCollections: [(Notification.Name, String)] = [
            (.rewriteRulesUpdated, "rules"),
            (.requestMapsUpdated, "maps"),
            (.scriptsUpdated, "scripts"),
            (.ruleGroupsUpdated, "rule_groups"),
            (.profilesUpdated, "profiles")
        ]

        notificationObservers = observedCollections.map { notificationName, label in
            NotificationCenter.default.addObserver(
                forName: notificationName,
                object: nil,
                queue: queue
            ) { [weak dirtyFlags] _ in
                dirtyFlags?.markDirty()
                ProxyLog.interceptor.debug("event=intercept.\(label, privacy: .public)_dirty outcome=flagged")
            }
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
            RewriteManager.shared.reloadGroupsIfNeeded()
            return RewriteManager.shared.groups
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

        lastRulesFileDate = AppGroupStorage.shared.configFileModificationDate(for: PersistentCollectionDescriptor.rewriteRules.fileName)
        lastMapsFileDate = AppGroupStorage.shared.configFileModificationDate(for: PersistentCollectionDescriptor.requestMaps.fileName)
        lastScriptsFileDate = AppGroupStorage.shared.configFileModificationDate(for: PersistentCollectionDescriptor.scripts.fileName)
        lastGroupsFileDate = AppGroupStorage.shared.configFileModificationDate(for: PersistentCollectionDescriptor.ruleGroups.fileName)
        lastProfilesFileDate = AppGroupStorage.shared.configFileModificationDate(for: PersistentCollectionDescriptor.profiles.fileName)

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
            requestMethodRaw: HTTPMethod(rawValue: method.uppercased()) == nil ? method.uppercased() : nil,
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
        let breakpointConfig = await breakpointManager.getConfiguration()
        ProxyLog.interceptor.info(
            "event=intercept.breakpoint_check enabled=\(breakpointConfig.enabled, privacy: .public) url=\(modifiedRequest.url, privacy: .private(mask: .hash)) method=\(httpMethod.rawValue, privacy: .public) breakpointType=\(String(describing: breakpointConfig.breakpointType), privacy: .public) matchType=\(String(describing: breakpointConfig.matchType), privacy: .public) matchPattern=\(breakpointConfig.matchPattern ?? "none", privacy: .public) request_id=\(flowIdString, privacy: .public)"
        )
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
                methodToken: modifiedRequest.methodToken,
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

            case .cancel:
                ProxyLog.interceptor.debug(
                    "event=intercept.breakpoint_cancel outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                fallthrough

            case .continue:
                ProxyLog.interceptor.debug(
                    "event=intercept.breakpoint_continue outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                if let pausedRequest = await breakpointManager.consumeResumedRequest(id: flowIdString) {
                    modifiedRequest.url = pausedRequest.effectiveUrl
                    modifiedRequest.method = pausedRequest.effectiveMethod
                    modifiedRequest.requestMethodRaw = pausedRequest.effectiveMethodToken == pausedRequest.effectiveMethod.rawValue
                        ? nil
                        : pausedRequest.effectiveMethodToken
                    modifiedRequest.requestHeaders = pausedRequest.effectiveHeaders
                    if let modifiedBody = pausedRequest.effectiveBody {
                        modifiedRequest.requestBody = BodyStorage.from(data: modifiedBody, charset: charset)
                        modifiedRequest.requestBodyModified = true
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
                methodToken: modifiedRequest.methodToken,
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

            case .cancel:
                ProxyLog.interceptor.debug(
                    "event=intercept.response_breakpoint_cancel outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                fallthrough

            case .continue:
                ProxyLog.interceptor.debug(
                    "event=intercept.response_breakpoint_continue outcome=success request_id=\(flowIdString, privacy: .public)"
                )
                if let pausedRequest = await breakpointManager.consumeResumedRequest(id: flowIdString) {
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

    // MARK: - Config File Change Detection

    private func configFilesChanged() -> Bool {
        let storage = AppGroupStorage.shared

        let rulesDate = storage.configFileModificationDate(for: PersistentCollectionDescriptor.rewriteRules.fileName)
        let mapsDate = storage.configFileModificationDate(for: PersistentCollectionDescriptor.requestMaps.fileName)
        let scriptsDate = storage.configFileModificationDate(for: PersistentCollectionDescriptor.scripts.fileName)
        let groupsDate = storage.configFileModificationDate(for: PersistentCollectionDescriptor.ruleGroups.fileName)
        let profilesDate = storage.configFileModificationDate(for: PersistentCollectionDescriptor.profiles.fileName)

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

    /// Returns whether any interception features are enabled (rules, maps, scripts, breakpoints, profiles).
    ///
    /// This method performs a **fast-path check** to determine if the expensive interception
    /// machinery needs to be invoked. When all features are disabled, the proxy can skip
    /// interception entirely and use the fallback request directly, reducing latency by 1-3ms
    /// per request in capture-only mode.
    ///
    /// - Returns: `true` if any feature is active; `false` if all are disabled (capture-only mode)
    public func areAnyFeaturesEnabled() async -> Bool {
        await refreshConfigSnapshotIfNeeded()

        let hasEnabledRewriteRules = configSnapshot.rewriteRules.contains { $0.enabled }
        let hasEnabledRequestMaps = configSnapshot.requestMaps.contains { $0.enabled }
        let hasEnabledScripts = configSnapshot.scripts.contains { $0.enabled }
        let breakpointsEnabled = await breakpointManager.isEnabled()
        let activeProfileEnabled = configSnapshot.activeProfile != nil

        return hasEnabledRewriteRules || hasEnabledRequestMaps || hasEnabledScripts || breakpointsEnabled || activeProfileEnabled
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

    public func interceptStreamOpen(session: StreamSession) async -> StreamInterceptionDecision {
        await refreshConfigSnapshotIfNeeded()

        let pseudoRequest = NetworkRequest(
            url: session.url,
            method: .get,
            duration: 0,
            requestHeaders: session.requestHeaders
        )
        if shouldBlock(request: pseudoRequest) {
            return .block
        }

        return .forward
    }

    public func interceptStreamEvent(session: StreamSession, event: StreamEvent) async -> StreamInterceptionDecision {
        await refreshConfigSnapshotIfNeeded()

        var payloadData = event.payload.binary
            ?? event.payload.text?.data(using: .utf8)
            ?? Data()
        var expectsTextPayload = event.payload.text != nil ||
            event.kind == .sseEvent ||
            event.metadata["message_type"] == "text"
        var payloadContentType = event.payload.contentType
        var payloadEncoding = event.payload.encoding
        var metadata = event.metadata
        var didModify = false

        var didPauseForStreamBreakpoint = false
        if await breakpointManager.shouldBreakOnStream(
            url: session.url,
            headers: session.requestHeaders,
            body: payloadData
        ) {
            didPauseForStreamBreakpoint = true
            let action = await breakpointManager.pauseStreamEvent(
                id: event.id.uuidString,
                url: session.url,
                headers: session.requestHeaders,
                body: payloadData
            )

            switch action {
            case .drop:
                return .drop
            case .continueAndDisable:
                await breakpointManager.setEnabled(false)
            case .cancel:
                break
            case .continue:
                break
            }

            if let pausedEvent = await breakpointManager.consumeResumedRequest(id: event.id.uuidString),
               let modifiedBody = pausedEvent.effectiveBody {
                payloadData = modifiedBody
                metadata["breakpoint"] = "modified"
                didModify = true
            }
        }

        if !didPauseForStreamBreakpoint {
            var storedPayload: Data? = payloadData
            if await breakpointManager.applyStoredStreamModifications(to: &storedPayload),
               let storedPayload {
                payloadData = storedPayload
                metadata["breakpoint"] = "stored_modifications_applied"
                didModify = true
            }
        }

        let matchingStreamScripts = configSnapshot.scripts.filter { script in
            script.enabled &&
                script.scriptType == .stream &&
                scriptMatchesUrl(script: script, url: session.url)
        }

        if !matchingStreamScripts.isEmpty {
            let scriptEvent = StreamEvent(
                id: event.id,
                sessionID: event.sessionID,
                sequence: event.sequence,
                timestamp: event.timestamp,
                direction: event.direction,
                kind: event.kind,
                payload: StreamEventPayload(
                    text: expectsTextPayload ? String(data: payloadData, encoding: .utf8) : nil,
                    binary: payloadData,
                    contentType: payloadContentType,
                    encoding: payloadEncoding
                ),
                wasModified: event.wasModified || didModify,
                wasBlocked: event.wasBlocked,
                metadata: metadata
            )
            let scriptResult = await scriptManager.executeStreamScriptsAsync(
                matchingStreamScripts,
                context: StreamScriptContext(session: session, event: scriptEvent)
            )

            switch scriptResult.action {
            case .block:
                return .block
            case .drop:
                return .drop
            case .forward:
                break
            }

            let scriptPayload = scriptResult.event.payload.binary
                ?? scriptResult.event.payload.text?.data(using: .utf8)
                ?? Data()
            if scriptPayload != payloadData || scriptResult.event.metadata != metadata {
                didModify = true
            }
            payloadData = scriptPayload
            metadata = scriptResult.event.metadata
            payloadContentType = scriptResult.event.payload.contentType ?? payloadContentType
            payloadEncoding = scriptResult.event.payload.encoding ?? payloadEncoding

            if scriptResult.event.payload.text != nil {
                expectsTextPayload = true
            }
            metadata["applied_stream_scripts"] = matchingStreamScripts.map(\.name).joined(separator: ",")
        }

        var modifiedText = expectsTextPayload
            ? (String(data: payloadData, encoding: .utf8) ?? event.payload.text ?? "")
            : ""
        var appliedRuleNames: [String] = []

        if expectsTextPayload {
            for rule in configSnapshot.rewriteRules where rule.enabled {
                guard matchesPattern(url: session.url, pattern: rule.matchPattern, matchType: rule.matchType) else { continue }
                guard rule.ruleType == .modifyResponse || rule.ruleType == .modifyRequest else { continue }

                for action in rule.actions where action.actionType == .replaceBody {
                    guard let pattern = action.bodyPattern, let replacement = action.bodyReplacement else { continue }
                    guard pattern.count <= RegexMatcher.maxPatternLength else { continue }
                    guard modifiedText.count <= RegexMatcher.maxInputLength else { continue }
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

                    let range = NSRange(modifiedText.startIndex..., in: modifiedText)
                    let replaced = regex.stringByReplacingMatches(
                        in: modifiedText,
                        range: range,
                        withTemplate: replacement
                    )
                    if replaced != modifiedText {
                        modifiedText = replaced
                        didModify = true
                        appliedRuleNames.append(rule.name)
                    }
                }
            }
        }

        guard didModify else { return .forward }

        if !appliedRuleNames.isEmpty {
            metadata["applied_rules"] = appliedRuleNames.joined(separator: ",")
        }
        metadata["interceptor"] = "request_interceptor"

        if expectsTextPayload {
            payloadData = Data(modifiedText.utf8)
        }

        return .modify(
            StreamMutation(
                payload: StreamEventPayload(
                    text: expectsTextPayload ? modifiedText : nil,
                    binary: expectsTextPayload ? nil : payloadData,
                    contentType: payloadContentType,
                    encoding: payloadEncoding
                ),
                metadata: metadata
            )
        )
    }

    public func interceptStreamClose(session _: StreamSession, reason _: String?) async -> StreamInterceptionDecision {
        .forward
    }
}
