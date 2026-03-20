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
    private var continuations: [String: CheckedContinuation<BreakpointAction, Never>] = [:]
    private var totalHitCount: Int = 0
    private var storedRequestModifications: PausedRequest?
    private var storedResponseModifications: PausedRequest?
    private var storedStreamModifications: PausedRequest?
    private var editOnceApplied: Bool = false
    private nonisolated(unsafe) let storage: AppGroupStorage
    private nonisolated(unsafe) let configFileName = "BreakpointConfiguration.json"

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
        headers: [TraceHTTPHeader],
        body: Data?
    ) async -> BreakpointAction {
        let pausedRequest = PausedRequest(
            id: id,
            url: url,
            method: method,
            headers: headers,
            body: body,
            breakpointType: .request
        )

        pausedRequests[id] = pausedRequest

        return await withCheckedContinuation { continuation in
            continuations[id] = continuation

            // Concurrency: UI notifications are sent on the MainActor.
            // Important: Do not `await` here; yielding before the continuation is registered can race with `resumeRequest`.
            let methodRawValue = method.rawValue
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .breakpointTriggered,
                    object: nil,
                    userInfo: [
                        BreakpointNotificationKey.requestId.rawValue: id,
                        BreakpointNotificationKey.url.rawValue: url,
                        BreakpointNotificationKey.method.rawValue: methodRawValue,
                        BreakpointNotificationKey.breakpointType.rawValue: BreakpointType.request.rawValue
                    ]
                )
            }
        }
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
        statusCode: Int,
        statusMessage: String,
        headers: [TraceHTTPHeader],
        body: Data?
    ) async -> BreakpointAction {
        var pausedRequest = PausedRequest(
            id: id,
            url: url,
            method: method,
            headers: headers,
            body: body,
            breakpointType: .response,
            statusCode: statusCode,
            statusMessage: statusMessage
        )
        pausedRequest.statusCode = statusCode
        pausedRequest.statusMessage = statusMessage

        pausedRequests[id] = pausedRequest

        return await withCheckedContinuation { continuation in
            continuations[id] = continuation

            // Concurrency: UI notifications are sent on the MainActor.
            // Important: Do not `await` here; yielding before the continuation is registered can race with `resumeRequest`.
            let methodRawValue = method.rawValue
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .breakpointTriggered,
                    object: nil,
                    userInfo: [
                        BreakpointNotificationKey.requestId.rawValue: id,
                        BreakpointNotificationKey.url.rawValue: url,
                        BreakpointNotificationKey.method.rawValue: methodRawValue,
                        BreakpointNotificationKey.breakpointType.rawValue: BreakpointType.response.rawValue
                    ]
                )
            }
        }
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

        pausedRequests[id] = pausedRequest

        return await withCheckedContinuation { continuation in
            continuations[id] = continuation

            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .breakpointTriggered,
                    object: nil,
                    userInfo: [
                        BreakpointNotificationKey.requestId.rawValue: id,
                        BreakpointNotificationKey.url.rawValue: url,
                        BreakpointNotificationKey.method.rawValue: HTTPMethod.get.rawValue,
                        BreakpointNotificationKey.breakpointType.rawValue: BreakpointType.stream.rawValue
                    ]
                )
            }
        }
    }

    // MARK: - Request Resuming

    /// Resumes a paused request with the given action.
    /// - Parameters:
    ///   - id: The request identifier.
    ///   - action: The action selected by the user.
    public func resumeRequest(id: String, action: BreakpointAction) {
        guard let continuation = continuations[id] else { return }

        if var pausedRequest = pausedRequests[id] {
            pausedRequest.isPaused = false
            pausedRequest.state = action == .drop ? .dropped : .continuing
            pausedRequests[id] = pausedRequest
            if action == .continue, pausedRequest.hasModifications {
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
            }
        }

        continuation.resume(returning: action)
        continuations.removeValue(forKey: id)

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

    /// Resumes all paused requests with the given action.
    /// - Parameter action: The action to apply to each paused request.
    public func resumeAllRequests(action: BreakpointAction) {
        let requestIds = Array(pausedRequests.keys)
        for id in requestIds {
            resumeRequest(id: id, action: action)
        }
    }

    public func applyStoredRequestModifications(to request: inout NetworkRequest) -> Bool {
        guard let stored = storedRequestModifications else { return false }
        request.requestHeaders = stored.effectiveHeaders
        if let modifiedBody = stored.effectiveBody {
            request.requestBody = BodyStorage.from(data: modifiedBody)
            return true
        }
        return false
    }

    public func applyStoredResponseModifications(to request: inout NetworkRequest) -> Bool {
        guard let stored = storedResponseModifications else { return false }
        request.responseHeaders = stored.effectiveHeaders
        if let modifiedBody = stored.effectiveBody {
            request.responseBody = BodyStorage.from(data: modifiedBody)
        }
        if let code = stored.effectiveStatusCode {
            request.statusCode = code
        }
        if let message = stored.effectiveStatusMessage {
            request.statusMessage = message
        }
        return true
    }

    public func applyStoredStreamModifications(to body: inout Data?) -> Bool {
        guard let stored = storedStreamModifications else { return false }
        body = stored.effectiveBody
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
            case .bodyContains:
                if !bodyString.contains(condition.value) { return false }
            case .bodyRegex:
                if !RegexMatcher.safeMatch(pattern: condition.value, in: bodyString, caseSensitive: false) { return false }
            case .queryParamExists:
                if !queryItems.contains(where: { $0.name == condition.parameter }) { return false }
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
        guard var pausedRequest = pausedRequests[id] else { return }

        pausedRequest.modifiedUrl = modifications.url
        pausedRequest.modifiedMethod = modifications.method
        pausedRequest.modifiedHeaders = modifications.headers
        pausedRequest.modifiedBody = modifications.body
        pausedRequest.modifiedStatusCode = modifications.statusCode
        pausedRequest.modifiedStatusMessage = modifications.statusMessage
        pausedRequest.state = .modified

        pausedRequests[id] = pausedRequest
    }

    /// Returns a paused request by identifier.
    /// - Parameter id: The request identifier.
    public func getPausedRequest(id: String) -> PausedRequest? {
        pausedRequests[id]
    }

    /// Returns all paused requests.
    public func getAllPausedRequests() -> [PausedRequest] {
        Array(pausedRequests.values)
    }

    /// Returns the number of paused requests.
    func pausedRequestsCount() -> Int {
        pausedRequests.count
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
    public var headers: [TraceHTTPHeader]?
    public var body: Data?
    public var statusCode: Int?
    public var statusMessage: String?

    public init(
        url: String? = nil,
        method: HTTPMethod? = nil,
        headers: [TraceHTTPHeader]? = nil,
        body: Data? = nil,
        statusCode: Int? = nil,
        statusMessage: String? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.statusCode = statusCode
        self.statusMessage = statusMessage
    }
}
