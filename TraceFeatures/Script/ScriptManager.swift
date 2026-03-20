//
//  ScriptManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Dispatch
import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

/// Manager for JavaScript scripts
public final class ScriptManager: ObservableObject, @unchecked Sendable {
    public static let shared = ScriptManager()

    // Use composition instead of inheritance for Observable compatibility
    private let baseManager: PersistentCollectionManager<Script>
    private let scriptEngine: ScriptEngine?
    private let executionMutex = ScriptExecutionMutex()
    private lazy var executionCountBuffer: ScriptExecutionCountBuffer = .init(
        flushIntervalSeconds: 5,
        flushBatchSize: 100
    ) { [weak self] deltas in
        guard let self else { return }
        await self.applyExecutionCountDeltas(deltas)
    }

    private var cancellables: Set<AnyCancellable> = []
    private let asyncScriptTimeout: TimeInterval = 2.0

    public let objectWillChange = ObservableObjectPublisher()

    /// Expose items through computed property
    public var scripts: [Script] {
        baseManager.items
    }

    private init() {
        self.baseManager = PersistentCollectionManager(
            descriptor: .scripts,
            logger: FeatureLog.script
        )
        self.scriptEngine = ScriptEngine()
        if scriptEngine == nil {
            FeatureLog.script.warning("event=script.engine_init outcome=failure reason=context_creation_failed")
        }

        // Forward changes from the underlying store for SwiftUI observation.
        baseManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Script Management (Delegate to Base Manager)

    /// Add a new script
    public func addScript(_ script: Script) {
        baseManager.add(script)
    }

    /// Update an existing script
    public func updateScript(_ script: Script) {
        baseManager.update(script)
    }

    /// Delete a script
    public func deleteScript(_ script: Script) {
        baseManager.delete(script)
    }

    /// Delete scripts at indices
    public func deleteScripts(at indices: IndexSet) {
        baseManager.delete(at: indices)
    }

    /// Toggle script enabled state
    public func toggleScript(_ script: Script) {
        baseManager.toggle(script)
    }

    /// Backward-compatible API used by tests and older call sites.
    /// Execution counts are still buffered and flushed in batches.
    public func incrementExecutionCount(for scriptId: UUID) {
        Task {
            await executionCountBuffer.recordExecutions([scriptId])
        }
    }

    @MainActor
    private func applyExecutionCountDeltas(_ deltas: [UUID: Int]) {
        guard !deltas.isEmpty else { return }

        var updated = baseManager.items
        var changed = false

        for index in updated.indices {
            let id = updated[index].id
            guard let delta = deltas[id], delta > 0 else { continue }
            updated[index].executionCount += delta
            changed = true
        }

        guard changed else { return }

        // Rationale: persist execution counts in a single write to avoid per-request I/O.
        baseManager.replaceAll(updated)
    }

    // MARK: - Script Execution

    /// Find all enabled scripts that match a URL for requests
    public func matchingRequestScripts(for url: String) -> [Script] {
        baseManager.matchingItems(for: url)
            .filter { $0.scriptType == .request || $0.scriptType == .both }
    }

    /// Find all enabled scripts that match a URL for responses
    public func matchingResponseScripts(for url: String) -> [Script] {
        baseManager.matchingItems(for: url)
            .filter { $0.scriptType == .response || $0.scriptType == .both }
    }

    /// Find all enabled scripts that match a URL for stream events.
    public func matchingStreamScripts(for url: String) -> [Script] {
        baseManager.matchingItems(for: url)
            .filter { $0.scriptType == .stream }
    }

    /// Execute request scripts on a NetworkRequest
    public func executeRequestScripts(on request: NetworkRequest) -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=request")
            return request
        }

        let matchingScripts = matchingRequestScripts(for: request.url)

        return withExecutionLockSync {
            guard !matchingScripts.isEmpty else { return request }

            var executedScriptIds: [UUID] = []
            var modifiedRequest = request

            for script in matchingScripts {
                do {
                    modifiedRequest = try scriptEngine.executeRequestScript(script.code, request: modifiedRequest)
                    executedScriptIds.append(script.id)
                    FeatureLog.script.debug("event=script.execute outcome=success type=request script=\(script.name, privacy: .private(mask: .hash))")
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=request script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }

            if !executedScriptIds.isEmpty {
                Task {
                    await self.executionCountBuffer.recordExecutions(executedScriptIds)
                }
            }

            return modifiedRequest
        } ?? request
    }

    /// Execute request scripts using a provided list (bypasses matching).
    public func executeRequestScripts(_ scripts: [Script], on request: NetworkRequest) -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=request")
            return request
        }

        return withExecutionLockSync {
            guard !scripts.isEmpty else { return request }

            var executedScriptIds: [UUID] = []
            var modifiedRequest = request

            for script in scripts {
                do {
                    modifiedRequest = try scriptEngine.executeRequestScript(script.code, request: modifiedRequest)
                    executedScriptIds.append(script.id)
                    FeatureLog.script.debug("event=script.execute outcome=success type=request script=\(script.name, privacy: .private(mask: .hash))")
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=request script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }

            if !executedScriptIds.isEmpty {
                Task {
                    await self.executionCountBuffer.recordExecutions(executedScriptIds)
                }
            }

            return modifiedRequest
        } ?? request
    }

    /// Execute request scripts asynchronously (supports await).
    public func executeRequestScriptsAsync(_ scripts: [Script], on request: NetworkRequest) async -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=request")
            return request
        }

        return await withExecutionLock {
            guard !scripts.isEmpty else { return request }

            var executedScriptIds: [UUID] = []
            var modifiedRequest = request
            for script in scripts {
                do {
                    modifiedRequest = try await scriptEngine.executeRequestScriptAsync(
                        script.code,
                        request: modifiedRequest,
                        timeout: asyncScriptTimeout
                    )
                    executedScriptIds.append(script.id)
                    FeatureLog.script.debug("event=script.execute outcome=success type=request script=\(script.name, privacy: .private(mask: .hash))")
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=request script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }

            if !executedScriptIds.isEmpty {
                await executionCountBuffer.recordExecutions(executedScriptIds)
            }

            return modifiedRequest
        }
    }

    /// Execute response scripts on a NetworkRequest
    public func executeResponseScripts(on request: NetworkRequest) -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=response")
            return request
        }

        let matchingScripts = matchingResponseScripts(for: request.url)

        return withExecutionLockSync {
            guard !matchingScripts.isEmpty else { return request }

            var executedScriptIds: [UUID] = []
            var modifiedRequest = request

            for script in matchingScripts {
                do {
                    modifiedRequest = try scriptEngine.executeResponseScript(script.code, request: modifiedRequest)
                    executedScriptIds.append(script.id)
                    FeatureLog.script.debug("event=script.execute outcome=success type=response script=\(script.name, privacy: .private(mask: .hash))")
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=response script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }

            if !executedScriptIds.isEmpty {
                Task {
                    await self.executionCountBuffer.recordExecutions(executedScriptIds)
                }
            }

            return modifiedRequest
        } ?? request
    }

    /// Execute response scripts using a provided list (bypasses matching).
    public func executeResponseScripts(_ scripts: [Script], on request: NetworkRequest) -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=response")
            return request
        }

        return withExecutionLockSync {
            guard !scripts.isEmpty else { return request }

            var executedScriptIds: [UUID] = []
            var modifiedRequest = request

            for script in scripts {
                do {
                    modifiedRequest = try scriptEngine.executeResponseScript(script.code, request: modifiedRequest)
                    executedScriptIds.append(script.id)
                    FeatureLog.script.debug("event=script.execute outcome=success type=response script=\(script.name, privacy: .private(mask: .hash))")
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=response script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }

            if !executedScriptIds.isEmpty {
                Task {
                    await self.executionCountBuffer.recordExecutions(executedScriptIds)
                }
            }

            return modifiedRequest
        } ?? request
    }

    /// Execute response scripts asynchronously (supports await).
    public func executeResponseScriptsAsync(_ scripts: [Script], on request: NetworkRequest) async -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=response")
            return request
        }

        return await withExecutionLock {
            guard !scripts.isEmpty else { return request }

            var executedScriptIds: [UUID] = []
            var modifiedRequest = request
            for script in scripts {
                do {
                    modifiedRequest = try await scriptEngine.executeResponseScriptAsync(
                        script.code,
                        request: modifiedRequest,
                        timeout: asyncScriptTimeout
                    )
                    executedScriptIds.append(script.id)
                    FeatureLog.script.debug("event=script.execute outcome=success type=response script=\(script.name, privacy: .private(mask: .hash))")
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=response script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }

            if !executedScriptIds.isEmpty {
                await executionCountBuffer.recordExecutions(executedScriptIds)
            }

            return modifiedRequest
        }
    }

    /// Execute stream scripts asynchronously (supports await).
    public func executeStreamScriptsAsync(
        _ scripts: [Script],
        context: StreamScriptContext
    ) async -> StreamScriptExecutionResult {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=stream")
            return StreamScriptExecutionResult(action: .forward, event: context.event)
        }

        return await withExecutionLock {
            guard !scripts.isEmpty else {
                return StreamScriptExecutionResult(action: .forward, event: context.event)
            }

            var executedScriptIds: [UUID] = []
            var workingContext = context
            var finalAction = StreamScriptAction.forward

            for script in scripts {
                do {
                    let executionResult = try await scriptEngine.executeStreamScriptAsync(
                        script.code,
                        context: workingContext,
                        timeout: asyncScriptTimeout
                    )
                    executedScriptIds.append(script.id)
                    workingContext.event = executionResult.event
                    finalAction = executionResult.action
                    FeatureLog.script.debug("event=script.execute outcome=success type=stream script=\(script.name, privacy: .private(mask: .hash)) action=\(finalAction.rawValue, privacy: .public)")
                    if finalAction == .block || finalAction == .drop {
                        break
                    }
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=stream script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }

            if !executedScriptIds.isEmpty {
                await executionCountBuffer.recordExecutions(executedScriptIds)
            }

            return StreamScriptExecutionResult(action: finalAction, event: workingContext.event)
        }
    }

    /// Validate a script
    public func validateScript(_ code: String) -> ScriptValidationResult {
        guard let scriptEngine else {
            return .invalid("Script engine unavailable")
        }
        return withExecutionLockSync {
            scriptEngine.validateScript(code)
        } ?? .invalid("Script engine unavailable")
    }

    // MARK: - Persistence (Delegate to Base Manager)

    /// Export scripts to JSON file
    public func exportScripts() throws -> URL {
        try baseManager.exportItems()
    }

    /// Import scripts from JSON file
    public func importScripts(from url: URL, merge: Bool = true) throws {
        try baseManager.importItems(from: url, merge: merge)
    }

    /// Clear all scripts
    public func clearAllScripts() {
        baseManager.clearAll()
    }

    /// Reload scripts if the backing file has changed.
    public func reloadIfNeeded() {
        baseManager.reloadIfNeeded()
    }

    /// Load a template script
    public func loadTemplate(_ template: Script) {
        let newScript = Script(
            id: UUID(),
            name: template.name,
            enabled: template.enabled,
            scriptType: template.scriptType,
            matchType: template.matchType,
            matchPattern: template.matchPattern,
            code: template.code,
            createdAt: Date(),
            modifiedAt: Date(),
            executionCount: 0
        )
        addScript(newScript)
    }

    // MARK: - Statistics (Delegate to Base Manager)

    public var enabledScriptsCount: Int {
        baseManager.enabledCount
    }

    public var totalScriptsCount: Int {
        baseManager.totalCount
    }

    public var totalExecutions: Int {
        scripts.reduce(0) { $0 + $1.executionCount }
    }

    public func scriptsCount(for type: ScriptType) -> Int {
        scripts.count { $0.scriptType == type }
    }

    /// Get most used scripts (by execution count)
    public func mostUsedScripts(limit: Int = 10) -> [Script] {
        scripts.sorted { $0.executionCount > $1.executionCount }.prefix(limit).map(\.self)
    }
}

private extension ScriptManager {
    func withExecutionLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await executionMutex.lock()
        do {
            let value = try await operation()
            await executionMutex.unlock()
            return value
        } catch {
            await executionMutex.unlock()
            throw error
        }
    }

    func withExecutionLockSync<T>(_ operation: @escaping () throws -> T) -> T? {
        let lockSemaphore = DispatchSemaphore(value: 0)
        Task { [executionMutex] in
            await executionMutex.lock()
            lockSemaphore.signal()
        }
        lockSemaphore.wait()

        defer {
            Task { [executionMutex] in
                await executionMutex.unlock()
            }
        }

        do {
            return try operation()
        } catch {
            // All callers already handle failure as a logged error; treat as "no change".
            return nil
        }
    }
}

private actor ScriptExecutionMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if isLocked {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } else {
            isLocked = true
        }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor ScriptExecutionCountBuffer {
    private let flushIntervalSeconds: TimeInterval
    private let flushBatchSize: Int
    private let apply: @Sendable ([UUID: Int]) async -> Void

    private var pending: [UUID: Int] = [:]
    private var flushTask: Task<Void, Never>?

    init(
        flushIntervalSeconds: TimeInterval,
        flushBatchSize: Int,
        apply: @escaping @Sendable ([UUID: Int]) async -> Void
    ) {
        self.flushIntervalSeconds = flushIntervalSeconds
        self.flushBatchSize = flushBatchSize
        self.apply = apply
    }

    func recordExecutions(_ scriptIds: [UUID]) async {
        guard !scriptIds.isEmpty else { return }

        for id in scriptIds {
            pending[id, default: 0] += 1
        }

        let pendingCount = pending.values.reduce(0, +)
        if pendingCount >= flushBatchSize {
            await flush()
            return
        }

        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(flushIntervalSeconds * 1_000_000_000))
            await flush()
        }
    }

    private func flush() async {
        flushTask?.cancel()
        flushTask = nil

        guard !pending.isEmpty else { return }
        let deltas = pending
        pending.removeAll(keepingCapacity: true)

        await apply(deltas)
    }
}
