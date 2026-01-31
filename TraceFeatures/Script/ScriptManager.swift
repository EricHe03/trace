//
//  ScriptManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
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
    private let scriptLock = NSLock()
    private let asyncScriptGate = ScriptExecutionGate()
    private var cancellables: Set<AnyCancellable> = []
    private let asyncScriptTimeout: TimeInterval = 2.0

    public let objectWillChange = ObservableObjectPublisher()

    /// Expose items through computed property
    public var scripts: [Script] {
        baseManager.items
    }

    private init() {
        self.baseManager = PersistentCollectionManager(
            fileName: "Scripts.json",
            notificationName: "ScriptsChanged",
            logger: FeatureLog.script,
            itemName: "script"
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

    /// Increment execution count for a script
    public func incrementExecutionCount(for scriptId: UUID) {
        if let index = baseManager.items.firstIndex(where: { $0.id == scriptId }) {
            var script = baseManager.items[index]
            script.executionCount += 1
            baseManager.update(script)
            // Don't save immediately to avoid excessive I/O
            // Could batch save periodically
        }
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

    /// Execute request scripts on a NetworkRequest
    public func executeRequestScripts(on request: NetworkRequest) -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=request")
            return request
        }

        scriptLock.lock()
        defer { scriptLock.unlock() }

        let matchingScripts = matchingRequestScripts(for: request.url)

        var modifiedRequest = request

        for script in matchingScripts {
            do {
                modifiedRequest = try scriptEngine.executeRequestScript(script.code, request: modifiedRequest)
                incrementExecutionCount(for: script.id)
                FeatureLog.script.debug("event=script.execute outcome=success type=request script=\(script.name, privacy: .private(mask: .hash))")
            } catch {
                FeatureLog.script.error(
                    "event=script.execute outcome=failure type=request script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }

        return modifiedRequest
    }

    /// Execute request scripts using a provided list (bypasses matching).
    public func executeRequestScripts(_ scripts: [Script], on request: NetworkRequest) -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=request")
            return request
        }

        scriptLock.lock()
        defer { scriptLock.unlock() }

        guard !scripts.isEmpty else { return request }

        var modifiedRequest = request

        for script in scripts {
            do {
                modifiedRequest = try scriptEngine.executeRequestScript(script.code, request: modifiedRequest)
                incrementExecutionCount(for: script.id)
                FeatureLog.script.debug("event=script.execute outcome=success type=request script=\(script.name, privacy: .private(mask: .hash))")
            } catch {
                FeatureLog.script.error(
                    "event=script.execute outcome=failure type=request script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }

        return modifiedRequest
    }

    /// Execute request scripts asynchronously (supports await).
    public func executeRequestScriptsAsync(_ scripts: [Script], on request: NetworkRequest) async -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=request")
            return request
        }

        return await asyncScriptGate.run {
            guard !scripts.isEmpty else { return request }

            var modifiedRequest = request
            for script in scripts {
                do {
                    modifiedRequest = try await scriptEngine.executeRequestScriptAsync(
                        script.code,
                        request: modifiedRequest,
                        timeout: asyncScriptTimeout
                    )
                    incrementExecutionCount(for: script.id)
                    FeatureLog.script.debug("event=script.execute outcome=success type=request script=\(script.name, privacy: .private(mask: .hash))")
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=request script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
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

        scriptLock.lock()
        defer { scriptLock.unlock() }

        let matchingScripts = matchingResponseScripts(for: request.url)

        var modifiedRequest = request

        for script in matchingScripts {
            do {
                modifiedRequest = try scriptEngine.executeResponseScript(script.code, request: modifiedRequest)
                incrementExecutionCount(for: script.id)
                FeatureLog.script.debug("event=script.execute outcome=success type=response script=\(script.name, privacy: .private(mask: .hash))")
            } catch {
                FeatureLog.script.error(
                    "event=script.execute outcome=failure type=response script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }

        return modifiedRequest
    }

    /// Execute response scripts using a provided list (bypasses matching).
    public func executeResponseScripts(_ scripts: [Script], on request: NetworkRequest) -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=response")
            return request
        }

        scriptLock.lock()
        defer { scriptLock.unlock() }

        guard !scripts.isEmpty else { return request }

        var modifiedRequest = request

        for script in scripts {
            do {
                modifiedRequest = try scriptEngine.executeResponseScript(script.code, request: modifiedRequest)
                incrementExecutionCount(for: script.id)
                FeatureLog.script.debug("event=script.execute outcome=success type=response script=\(script.name, privacy: .private(mask: .hash))")
            } catch {
                FeatureLog.script.error(
                    "event=script.execute outcome=failure type=response script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }

        return modifiedRequest
    }

    /// Execute response scripts asynchronously (supports await).
    public func executeResponseScriptsAsync(_ scripts: [Script], on request: NetworkRequest) async -> NetworkRequest {
        guard let scriptEngine else {
            FeatureLog.script.debug("event=script.execute outcome=skipped reason=engine_unavailable type=response")
            return request
        }

        return await asyncScriptGate.run {
            guard !scripts.isEmpty else { return request }

            var modifiedRequest = request
            for script in scripts {
                do {
                    modifiedRequest = try await scriptEngine.executeResponseScriptAsync(
                        script.code,
                        request: modifiedRequest,
                        timeout: asyncScriptTimeout
                    )
                    incrementExecutionCount(for: script.id)
                    FeatureLog.script.debug("event=script.execute outcome=success type=response script=\(script.name, privacy: .private(mask: .hash))")
                } catch {
                    FeatureLog.script.error(
                        "event=script.execute outcome=failure type=response script=\(script.name, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }

            return modifiedRequest
        }
    }

    /// Validate a script
    public func validateScript(_ code: String) -> ScriptValidationResult {
        guard let scriptEngine else {
            return .invalid("Script engine unavailable")
        }
        scriptLock.lock()
        defer { scriptLock.unlock() }
        return scriptEngine.validateScript(code)
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
        scripts.count(where: { $0.scriptType == type })
    }

    /// Get most used scripts (by execution count)
    public func mostUsedScripts(limit: Int = 10) -> [Script] {
        scripts.sorted { $0.executionCount > $1.executionCount }.prefix(limit).map(\.self)
    }
}

private actor ScriptExecutionGate {
    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await operation()
    }
}
