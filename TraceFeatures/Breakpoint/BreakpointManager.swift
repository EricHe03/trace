//
//  BreakpointManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

/// Manages breakpoint evaluation and pause/resume flows.
public actor BreakpointManager {
    public static let shared = BreakpointManager()
    private nonisolated(unsafe) static let presetStore: PersistentCollectionManager<BreakpointPreset> = PersistentCollectionManager(
        descriptor: .breakpointPresets,
        logger: FeatureLog.breakpoint
    )

    private var configuration: BreakpointConfiguration
    private var pausedRequests: [String: PausedRequest] = [:]
    private var resumedRequests: [String: PausedRequest] = [:]
    private var continuations: [String: CheckedContinuation<BreakpointAction, Never>] = [:]
    private var sharedCommandPollingTasks: [String: Task<Void, Never>] = [:]
    private var totalHitCount: Int = 0
    private var storedRequestModifications: PausedRequest?
    private var storedResponseModifications: PausedRequest?
    private var storedStreamModifications: PausedRequest?
    private var editOnceApplied: Bool = false
    private nonisolated(unsafe) let storage: AppGroupStorage
    private nonisolated(unsafe) let configFileName = "BreakpointConfiguration.json"
    private let sharedCommandPollIntervalNs: UInt64 = 100_000_000

    private init() {
        self.storage = AppGroupStorage.shared
        self.configuration = BreakpointConfiguration()
        // Rule: Load configuration after initialization to avoid blocking actor creation.
        Task {
            await self.loadConfiguration()
        }
    }

    // MARK: - Presets

    public nonisolated var presets: [BreakpointPreset] {
        Self.presetStore.items
    }

    public nonisolated func savePreset(_ preset: BreakpointPreset) {
        Self.presetStore.add(preset)
    }

    public nonisolated func loadPreset(_ presetId: UUID) -> BreakpointPreset? {
        presets.first { $0.id == presetId }
    }

    public nonisolated func applyPreset(_ presetId: UUID) {
        guard let preset = loadPreset(presetId) else { return }
        Task {
            await self.updateConfiguration(preset.configuration)
        }
    }

    public nonisolated func clearPresets() {
        Self.presetStore.clearAll()
    }

    // MARK: - Configuration Management

    /// Returns the current breakpoint configuration.
    public func getConfiguration() -> BreakpointConfiguration {
        configuration
    }

    /// Updates the breakpoint configuration and persists it.
    /// - Parameter config: The new breakpoint configuration.
    public func updateConfiguration(_ config: BreakpointConfiguration) {
        configuration = config
        saveConfiguration()
    }

    /// Enables or disables breakpoint handling.
    /// - Parameter enabled: Whether breakpoint handling is enabled.
    public func setEnabled(_ enabled: Bool) {
        configuration.enabled = enabled
        saveConfiguration()

        // Rule: Resume all paused requests when breakpoints are disabled.
        if !enabled {
            // Disabling should also clear any stored modifications/hit state to avoid applying
            // breakpoint edits when the feature is turned off.
            storedRequestModifications = nil
            storedResponseModifications = nil
            storedStreamModifications = nil
            resumedRequests.removeAll()
            editOnceApplied = false
            totalHitCount = 0
            Task {
                await resumeAllRequests(action: .continue)
            }
        }
    }

    /// Returns whether breakpoint handling is enabled.
    public func isEnabled() -> Bool {
        configuration.enabled
    }

    // MARK: - Breakpoint Checking

    /// Returns whether a request should be paused.
    /// - Parameters:
    ///   - url: The request URL.
    ///   - method: The HTTP method.
    public func shouldBreakOnRequest(
        url: String,
        method: HTTPMethod,
        headers: [TraceHTTPHeader],
        body: Data?
    ) -> Bool {
        guard configuration.executionMode != .logOnly else { return false }
        if configuration.executionMode == .editOnce, editOnceApplied {
            return false
        }
        if configuration.executionMode == .alwaysApply, storedRequestModifications != nil {
            return false
        }
        if let maxHits = configuration.maxHits, totalHitCount >= maxHits {
            return false
        }
        guard configuration.shouldBreakOnRequest(url: url, method: method) else { return false }
        guard conditionsPass(url: url, headers: headers, body: body) else { return false }
        totalHitCount += 1
        return true
    }

    /// Returns whether a response should be paused.
    /// - Parameters:
    ///   - url: The request URL.
    ///   - statusCode: The HTTP status code.
    public func shouldBreakOnResponse(
        url: String,
        statusCode: Int,
        headers: [TraceHTTPHeader],
        body: Data?
    ) -> Bool {
        guard configuration.executionMode != .logOnly else { return false }
        if configuration.executionMode == .editOnce, editOnceApplied {
            return false
        }
        if configuration.executionMode == .alwaysApply, storedResponseModifications != nil {
            return false
        }
        if let maxHits = configuration.maxHits, totalHitCount >= maxHits {
            return false
        }
        guard configuration.shouldBreakOnResponse(url: url, statusCode: statusCode) else { return false }
        guard conditionsPass(url: url, headers: headers, body: body) else { return false }
        totalHitCount += 1
        return true
    }

    /// Returns whether a stream event should be paused.
    /// - Parameters:
    ///   - url: The stream URL.
    ///   - headers: Stream request headers.
    ///   - body: Stream payload bytes.
    public func shouldBreakOnStream(
        url: String,
        headers: [TraceHTTPHeader],
        body: Data?
    ) -> Bool {
        guard configuration.executionMode != .logOnly else { return false }
        if configuration.executionMode == .editOnce, editOnceApplied {
            return false
        }
        if configuration.executionMode == .alwaysApply, storedStreamModifications != nil {
            return false
        }
        if let maxHits = configuration.maxHits, totalHitCount >= maxHits {
            return false
        }
        guard configuration.shouldBreakOnStream(url: url) else { return false }
        guard conditionsPass(url: url, headers: headers, body: body) else { return false }
        totalHitCount += 1
        return true
    }

    private func registerPausedRequest(_ pausedRequest: PausedRequest) {
        pausedRequests[pausedRequest.id] = pausedRequest

        do {
            try storage.deleteBreakpointResumeCommand(requestId: pausedRequest.id)
            try storage.savePausedBreakpointRequest(pausedRequest)
        } catch {
            FeatureLog.breakpoint.error(
                "event=breakpoint.shared_state_save outcome=failure request_id=\(pausedRequest.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func waitForResumeAction(
        id: String,
        userInfo: [String: String]
    ) async -> BreakpointAction {
        await withCheckedContinuation { continuation in
            continuations[id] = continuation
            startPollingForSharedResumeCommand(id: id)

            // Concurrency: UI notifications are sent on the MainActor.
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .breakpointTriggered,
                    object: nil,
                    userInfo: userInfo
                )
            }
        }
    }

    private func startPollingForSharedResumeCommand(id: String) {
        sharedCommandPollingTasks[id]?.cancel()
        sharedCommandPollingTasks[id] = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    if let command = try self.storage.consumeBreakpointResumeCommand(requestId: id) {
                        let synchronizedRequest = try? self.storage.loadPausedBreakpointRequest(id: id)
                        await self.completeResume(
                            id: id,
                            action: command.action,
                            synchronizedPausedRequest: synchronizedRequest
                        )
                        return
                    }
                } catch {
                    FeatureLog.breakpoint.error(
                        "event=breakpoint.shared_command_poll outcome=failure request_id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }

                try? await Task.sleep(nanoseconds: self.sharedCommandPollIntervalNs)
            }
        }
    }

    private func completeResume(
        id: String,
        action: BreakpointAction,
        synchronizedPausedRequest: PausedRequest? = nil
    ) {
        sharedCommandPollingTasks[id]?.cancel()
        sharedCommandPollingTasks.removeValue(forKey: id)

        if let synchronizedPausedRequest {
            pausedRequests[id] = synchronizedPausedRequest
        }

        if var pausedRequest = pausedRequests[id] {
            pausedRequest.isPaused = false
            pausedRequest.state = action == .drop ? .dropped : .continuing
            pausedRequests[id] = pausedRequest
            if action.appliesModifications, pausedRequest.hasModifications {
                pausedRequest.state = .modified
                resumedRequests[id] = pausedRequest
                if configuration.executionMode == .editOnce || configuration.executionMode == .alwaysApply {
                    switch pausedRequest.breakpointType {
                    case .response:
                        storedResponseModifications = pausedRequest
                    case .stream:
                        storedStreamModifications = pausedRequest
                    case .request, .both:
                        storedRequestModifications = pausedRequest
                    }
                    if configuration.executionMode == .editOnce {
                        editOnceApplied = true
                    }
                }
            } else {
                resumedRequests.removeValue(forKey: id)
            }
        }

        if let continuation = continuations[id] {
            continuation.resume(returning: action)
            continuations.removeValue(forKey: id)
        }

        do {
            try storage.deletePausedBreakpointRequest(id: id)
        } catch {
            FeatureLog.breakpoint.error(
                "event=breakpoint.shared_state_delete outcome=failure request_id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        do {
            try storage.deleteBreakpointResumeCommand(requestId: id)
        } catch {
            FeatureLog.breakpoint.error(
                "event=breakpoint.shared_command_delete outcome=failure request_id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        // Concurrency: UI notifications are sent on the MainActor.
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .breakpointResumed,
                object: nil,
                userInfo: [BreakpointNotificationKey.requestId.rawValue: id]
            )
        }

        pausedRequests.removeValue(forKey: id)
    }

    private func loadSharedPausedRequests() -> [PausedRequest] {
        do {
            return try storage.loadAllPausedBreakpointRequests()
        } catch {
            FeatureLog.breakpoint.error(
                "event=breakpoint.shared_state_load outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Request Pausing

    /// Pauses a request and waits for user action.
    /// - Parameters:
    ///   - id: The request identifier.
    ///   - url: The request URL.
    ///   - method: The HTTP method.
    ///   - headers: The request headers.
    ///   - body: The request body.
    public func pauseRequest(
        id: String,
        url: String,
        method: HTTPMethod,
        methodToken: String? = nil,
        headers: [TraceHTTPHeader],
        body: Data?
    ) async -> BreakpointAction {
        let pausedRequest = PausedRequest(
            id: id,
            url: url,
            method: method,
            methodToken: methodToken,
            headers: headers,
            body: body,
            breakpointType: .request
        )

        registerPausedRequest(pausedRequest)

        return await waitForResumeAction(
            id: id,
            userInfo: [
                BreakpointNotificationKey.requestId.rawValue: id,
                BreakpointNotificationKey.url.rawValue: url,
                BreakpointNotificationKey.method.rawValue: method.rawValue,
                BreakpointNotificationKey.breakpointType.rawValue: BreakpointType.request.rawValue
            ]
        )
    }

    /// Pauses a response and waits for user action.
    /// - Parameters:
    ///   - id: The request identifier.
    ///   - url: The request URL.
    ///   - method: The HTTP method.
    ///   - statusCode: The HTTP status code.
    ///   - statusMessage: The HTTP status message.
    ///   - headers: The response headers.
    ///   - body: The response body.
    public func pauseResponse(
        id: String,
        url: String,
        method: HTTPMethod,
        methodToken: String? = nil,
        statusCode: Int,
        statusMessage: String,
        headers: [TraceHTTPHeader],
        body: Data?
    ) async -> BreakpointAction {
        var pausedRequest = PausedRequest(
            id: id,
            url: url,
            method: method,
            methodToken: methodToken,
            headers: headers,
            body: body,
            breakpointType: .response,
            statusCode: statusCode,
            statusMessage: statusMessage
        )
        pausedRequest.statusCode = statusCode
        pausedRequest.statusMessage = statusMessage

        registerPausedRequest(pausedRequest)

        return await waitForResumeAction(
            id: id,
            userInfo: [
                BreakpointNotificationKey.requestId.rawValue: id,
                BreakpointNotificationKey.url.rawValue: url,
                BreakpointNotificationKey.method.rawValue: method.rawValue,
                BreakpointNotificationKey.breakpointType.rawValue: BreakpointType.response.rawValue
            ]
        )
    }

    /// Pauses a stream event and waits for user action.
    /// - Parameters:
    ///   - id: The stream event identifier.
    ///   - url: The stream URL.
    ///   - headers: Stream request headers.
    ///   - body: Stream payload bytes.
    public func pauseStreamEvent(
        id: String,
        url: String,
        headers: [TraceHTTPHeader],
        body: Data?
    ) async -> BreakpointAction {
        let pausedRequest = PausedRequest(
            id: id,
            url: url,
            method: .get,
            headers: headers,
            body: body,
            breakpointType: .stream
        )

        registerPausedRequest(pausedRequest)

        return await waitForResumeAction(
            id: id,
            userInfo: [
                BreakpointNotificationKey.requestId.rawValue: id,
                BreakpointNotificationKey.url.rawValue: url,
                BreakpointNotificationKey.method.rawValue: HTTPMethod.get.rawValue,
                BreakpointNotificationKey.breakpointType.rawValue: BreakpointType.stream.rawValue
            ]
        )
    }

    // MARK: - Request Resuming

    /// Resumes a paused request with the given action.
    /// - Parameters:
    ///   - id: The request identifier.
    ///   - action: The action selected by the user.
    public func resumeRequest(id: String, action: BreakpointAction) {
        if continuations[id] != nil {
            completeResume(id: id, action: action)
            return
        }

        let knownLocally = pausedRequests[id] != nil
        let knownShared = (try? storage.loadPausedBreakpointRequest(id: id)) != nil
        guard knownLocally || knownShared else { return }

        do {
            try storage.saveBreakpointResumeCommand(
                BreakpointResumeCommand(requestId: id, action: action)
            )
        } catch {
            FeatureLog.breakpoint.error(
                "event=breakpoint.shared_command_save outcome=failure request_id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Resumes all paused requests with the given action.
    /// - Parameter action: The action to apply to each paused request.
    public func resumeAllRequests(action: BreakpointAction) {
        let requestIds = Set(pausedRequests.keys).union(loadSharedPausedRequests().map(\.id))
        for id in requestIds {
            resumeRequest(id: id, action: action)
        }
    }

    public func consumeResumedRequest(id: String) -> PausedRequest? {
        let resumedRequest = resumedRequests[id]
        resumedRequests.removeValue(forKey: id)
        return resumedRequest
    }

    public func applyStoredRequestModifications(to request: inout NetworkRequest) -> Bool {
        guard let stored = storedRequestModifications else { return false }
        guard configuration.shouldBreakOnRequest(url: request.url, method: request.method) else { return false }
        guard conditionsPass(
            url: request.url,
            headers: request.requestHeaders,
            body: request.requestBody.getData()
        ) else { return false }

        var didApply = false
        if request.url != stored.effectiveUrl {
            request.url = stored.effectiveUrl
            didApply = true
        }
        if request.methodToken != stored.effectiveMethodToken {
            request.method = stored.effectiveMethod
            request.requestMethodRaw = stored.effectiveMethodToken == stored.effectiveMethod.rawValue
                ? nil
                : stored.effectiveMethodToken
            didApply = true
        }
        if request.requestHeaders != stored.effectiveHeaders {
            request.requestHeaders = stored.effectiveHeaders
            didApply = true
        }
        if let modifiedBody = stored.effectiveBody {
            request.requestBody = BodyStorage.from(data: modifiedBody)
            didApply = true
        }

        if configuration.executionMode == .editOnce {
            storedRequestModifications = nil
            editOnceApplied = false
        }

        return didApply
    }

    public func applyStoredResponseModifications(to request: inout NetworkRequest) -> Bool {
        guard let stored = storedResponseModifications else { return false }
        guard configuration.shouldBreakOnResponse(
            url: request.url,
            statusCode: request.statusCode ?? stored.statusCode ?? 200
        ) else { return false }
        guard conditionsPass(
            url: request.url,
            headers: request.responseHeaders,
            body: request.responseBody.getData()
        ) else { return false }

        var didApply = false
        if request.responseHeaders != stored.effectiveHeaders {
            request.responseHeaders = stored.effectiveHeaders
            didApply = true
        }
        if let modifiedBody = stored.effectiveBody {
            request.responseBody = BodyStorage.from(data: modifiedBody)
            didApply = true
        }
        if let code = stored.effectiveStatusCode {
            request.statusCode = code
            didApply = true
        }
        if let message = stored.effectiveStatusMessage {
            request.statusMessage = message
            didApply = true
        }

        if configuration.executionMode == .editOnce {
            storedResponseModifications = nil
            editOnceApplied = false
        }

        return didApply
    }

    public func applyStoredStreamModifications(
        url: String,
        headers: [TraceHTTPHeader],
        to body: inout Data?
    ) -> Bool {
        guard let stored = storedStreamModifications else { return false }
        guard configuration.shouldBreakOnStream(url: url) else { return false }
        guard conditionsPass(url: url, headers: headers, body: body) else { return false }

        body = stored.effectiveBody

        if configuration.executionMode == .editOnce {
            storedStreamModifications = nil
            editOnceApplied = false
        }

        return stored.effectiveBody != nil
    }

    private func conditionsPass(url: String, headers: [TraceHTTPHeader], body: Data?) -> Bool {
        guard !configuration.conditions.isEmpty else { return true }
        let headerDict = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let queryItems = URLComponents(string: url)?.queryItems ?? []

        for condition in configuration.conditions {
            switch condition.type {
            case .headerExists:
                if headerDict[condition.parameter.lowercased()] == nil { return false }
            case .headerEquals:
                if headerDict[condition.parameter.lowercased()] != condition.value { return false }
            case .headerContains:
                guard let headerValue = headerDict[condition.parameter.lowercased()],
                      headerValue.contains(condition.value) else { return false }
            case .headerRegex:
                guard let headerValue = headerDict[condition.parameter.lowercased()],
                      RegexMatcher.safeMatch(pattern: condition.value, in: headerValue, caseSensitive: false) else { return false }
            case .bodyContains:
                if !bodyString.contains(condition.value) { return false }
            case .bodyRegex:
                if !RegexMatcher.safeMatch(pattern: condition.value, in: bodyString, caseSensitive: false) { return false }
            case .queryParamExists:
                if !queryItems.contains(where: { $0.name == condition.parameter }) { return false }
            case .queryParamEquals:
                if !queryItems.contains(where: { $0.name == condition.parameter && $0.value == condition.value }) { return false }
            case .queryParamContains:
                if !queryItems.contains(where: { $0.name == condition.parameter && ($0.value?.contains(condition.value) ?? false) }) { return false }
            case .queryParamRegex:
                if !queryItems.contains(where: {
                    $0.name == condition.parameter &&
                        RegexMatcher.safeMatch(pattern: condition.value, in: $0.value ?? "", caseSensitive: false)
                }) { return false }
            }
        }
        return true
    }

    // MARK: - Request Modification

    /// Updates a paused request with user modifications.
    /// - Parameters:
    ///   - id: The request identifier.
    ///   - modifications: The new values to apply.
    public func updatePausedRequest(id: String, modifications: PausedRequestModifications) {
        let hasLocalPauseState = pausedRequests[id] != nil || continuations[id] != nil
        guard var pausedRequest = pausedRequests[id] ?? (try? storage.loadPausedBreakpointRequest(id: id)) else { return }

        pausedRequest.modifiedUrl = modifications.url
        if let methodToken = modifications.resolvedMethodToken {
            pausedRequest.modifiedMethod = HTTPMethod(rawValue: methodToken.uppercased())
            pausedRequest.modifiedMethodToken = methodToken
        } else {
            pausedRequest.modifiedMethod = modifications.method
            pausedRequest.modifiedMethodToken = nil
        }
        pausedRequest.modifiedHeaders = modifications.headers
        pausedRequest.modifiedBody = modifications.body
        pausedRequest.modifiedStatusCode = modifications.statusCode
        pausedRequest.modifiedStatusMessage = modifications.statusMessage
        pausedRequest.state = .modified

        if hasLocalPauseState {
            pausedRequests[id] = pausedRequest
        }

        do {
            try storage.savePausedBreakpointRequest(pausedRequest)
        } catch {
            FeatureLog.breakpoint.error(
                "event=breakpoint.shared_state_update outcome=failure request_id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns a paused request by identifier.
    /// - Parameter id: The request identifier.
    public func getPausedRequest(id: String) -> PausedRequest? {
        (try? storage.loadPausedBreakpointRequest(id: id)) ?? pausedRequests[id]
    }

    /// Returns all paused requests.
    public func getAllPausedRequests() -> [PausedRequest] {
        var merged = Dictionary(uniqueKeysWithValues: pausedRequests.map { ($0.key, $0.value) })
        for request in loadSharedPausedRequests() {
            merged[request.id] = request
        }
        return merged.values.sorted { $0.pausedAt > $1.pausedAt }
    }

    /// Returns the number of paused requests.
    func pausedRequestsCount() -> Int {
        getAllPausedRequests().count
    }

    // MARK: - Persistence

    private func loadConfiguration() {
        do {
            let data = try storage.loadData(from: configFileName)
            configuration = try JSONCoding.decode(BreakpointConfiguration.self, from: data)
            FeatureLog.breakpoint.info("event=breakpoint.config_load outcome=success")
        } catch let error as StorageError where error == .fileNotFound {
            FeatureLog.breakpoint.info("event=breakpoint.config_load outcome=skipped reason=file_not_found")
            configuration = BreakpointConfiguration()
            // Rule: Persist defaults to create the initial configuration record.
            saveConfiguration()
        } catch {
            FeatureLog.breakpoint.error("event=breakpoint.config_load outcome=failure error=\(error.localizedDescription, privacy: .public)")
            configuration = BreakpointConfiguration()
        }
    }

    private func saveConfiguration() {
        do {
            let data = try JSONCoding.makeEncoder().encode(configuration)
            try storage.saveData(data, to: configFileName)
        } catch {
            FeatureLog.breakpoint.error("event=breakpoint.config_save outcome=failure error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Represents user-supplied edits for a paused request.
public struct PausedRequestModifications {
    public var url: String?
    public var method: HTTPMethod?
    public var methodToken: String?
    public var headers: [TraceHTTPHeader]?
    public var body: Data?
    public var statusCode: Int?
    public var statusMessage: String?

    public init(
        url: String? = nil,
        method: HTTPMethod? = nil,
        methodToken: String? = nil,
        headers: [TraceHTTPHeader]? = nil,
        body: Data? = nil,
        statusCode: Int? = nil,
        statusMessage: String? = nil
    ) {
        self.url = url
        self.method = method
        self.methodToken = methodToken
        self.headers = headers
        self.body = body
        self.statusCode = statusCode
        self.statusMessage = statusMessage
    }

    public var resolvedMethodToken: String? {
        if let methodToken {
            let trimmed = methodToken.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.uppercased()
        }
        return method?.rawValue
    }
}
