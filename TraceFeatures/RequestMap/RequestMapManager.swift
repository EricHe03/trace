//
//  RequestMapManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
import JavaScriptCore
#if canImport(TraceCore)
import TraceCore
#endif

// MARK: - Mock Script Engine

/// Lightweight JavaScript engine for generating mock response bodies.
/// This is separate from ScriptEngine to avoid circular dependencies.
private class MockScriptEngine {
    private let context: JSContext
    private var lastError: String?

    init?() {
        guard let jsContext = JSContext() else {
            return nil
        }
        context = jsContext

        context.exceptionHandler = { [weak self] _, exception in
            if let exception {
                self?.lastError = exception.toString()
            }
        }

        // Set up basic utilities
        setupContext()
    }

    private func setupContext() {
        // Add btoa (base64 encode)
        let btoa: @convention(block) (String) -> String = { str in
            str.data(using: .utf8)?.base64EncodedString() ?? ""
        }
        context.setObject(btoa, forKeyedSubscript: "btoa" as NSString)

        // Add atob (base64 decode)
        let atob: @convention(block) (String) -> String = { str in
            guard let data = Data(base64Encoded: str) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)

        // Add JSON helpers
        context.evaluateScript("""
        function parseJSON(str) {
            try { return JSON.parse(str); } catch (e) { return null; }
        }
        function stringifyJSON(obj, indent) {
            try { return JSON.stringify(obj, null, indent || 0); } catch (e) { return null; }
        }
        """)
    }

    /// Execute a script that generates a response body.
    /// The script should return a string or call `setBody(data)`.
    func executeBodyScript(_ script: String, url: String, method: String) throws -> Data {
        lastError = nil

        // Set up request context
        context.setObject(url, forKeyedSubscript: "requestUrl" as NSString)
        context.setObject(method, forKeyedSubscript: "requestMethod" as NSString)
        context.setObject(Date().timeIntervalSince1970, forKeyedSubscript: "timestamp" as NSString)

        // Variable to capture the result
        var resultBody: Data?

        // Add setBody function
        let setBody: @convention(block) (String) -> Void = { bodyString in
            resultBody = bodyString.data(using: .utf8)
        }
        context.setObject(setBody, forKeyedSubscript: "setBody" as NSString)

        // Wrap script to capture return value
        let wrappedScript = """
        (function() {
            \(script)
        })();
        """

        let result = context.evaluateScript(wrappedScript)

        // Check for errors
        if let error = lastError {
            throw MockScriptError.executionFailed(error)
        }

        // If setBody was called, use that
        if let body = resultBody {
            return body
        }

        // Otherwise try to use the return value
        if let resultString = result?.toString(), !resultString.isEmpty && resultString != "undefined" {
            return resultString.data(using: .utf8) ?? Data()
        }

        // Return empty body if nothing was set
        return Data()
    }
}

private enum MockScriptError: LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .executionFailed(message):
            "Script execution failed: \(message)"
        }
    }
}

/// Manager for request mapping - handles mock responses
@MainActor
public final class RequestMapManager: ObservableObject {
    public static let shared = RequestMapManager()

    // Use composition with the base manager
    private let baseManager: PersistentCollectionManager<RequestMap>
    private var cancellables: Set<AnyCancellable> = []
    // Reuse a single MockScriptEngine across calls — JSContext init is expensive (~5–15 ms).
    private lazy var scriptEngine: MockScriptEngine? = MockScriptEngine()

    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    /// Expose items through computed property
    public var maps: [RequestMap] {
        baseManager.items
    }

    private init() {
        self.baseManager = PersistentCollectionManager(
            descriptor: .requestMaps,
            logger: FeatureLog.requestMap
        )

        // Forward changes from the underlying store for SwiftUI observation.
        baseManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Map Management (Delegate to Base Manager)

    /// Add a new request map
    public func addMap(_ map: RequestMap) {
        baseManager.add(map)
    }

    /// Update an existing map
    public func updateMap(_ map: RequestMap) {
        baseManager.update(map)
    }

    /// Delete a map
    public func deleteMap(_ map: RequestMap) {
        baseManager.delete(map)
    }

    /// Delete maps at indices
    public func deleteMaps(at indices: IndexSet) {
        baseManager.delete(at: indices)
    }

    /// Toggle map enabled state
    public func toggleMap(_ map: RequestMap) {
        baseManager.toggle(map)
    }

    /// Increment hit count for a map
    public func incrementHitCount(for mapId: UUID) {
        if let index = baseManager.items.firstIndex(where: { $0.id == mapId }) {
            var map = baseManager.items[index]
            map.hitCount += 1
            baseManager.update(map)
        }
    }

    // MARK: - Map Matching

    /// Find the first enabled map that matches a given URL
    public func matchingMap(for url: String) -> RequestMap? {
        baseManager.matchingItems(for: url).first
    }

    /// Check if a URL has a mapping
    public func hasMapping(for url: String) -> Bool {
        matchingMap(for: url) != nil
    }

    // MARK: - Mock Response Generation

    /// Generate a mock NetworkRequest from a matching map
    public func getMockResponse(for url: String, method: HTTPMethod, requestId: UUID) async throws -> NetworkRequest? {
        guard let map = matchingMap(for: url) else {
            return nil
        }

        let mockResponse = map.mockResponse

        // Add delay if specified
        if mockResponse.delay > 0 {
            let delaySeconds = Double(mockResponse.delay) / 1000.0
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }

        // Get the response body based on body source.
        // Increment hitCount only after successful body generation so that failures
        // (e.g. bad script, missing file) are not counted as hits.
        let body: Data
        switch mockResponse.bodySource {
        case .inline:
            body = mockResponse.bodyContent ?? Data()

        case .file:
            do {
                body = try mockResponse.getBody()
            } catch {
                FeatureLog.requestMap.error("event=request_map.mock_response outcome=failure source=file error=\(error.localizedDescription, privacy: .public)")
                throw error
            }

        case .script:
            do {
                body = try executeScriptForBody(mockResponse.scriptContent, url: url, method: method)
            } catch {
                FeatureLog.requestMap.error("event=request_map.mock_response outcome=failure source=script error=\(error.localizedDescription, privacy: .public)")
                throw error
            }

        case .template:
            if let content = mockResponse.bodyContent,
               let template = String(data: content, encoding: .utf8) {
                let contextRequest = NetworkRequest(
                    url: url,
                    method: method,
                    duration: 0,
                    requestHeaders: [],
                    responseHeaders: [],
                    requestBody: .empty,
                    responseBody: .empty
                )
                let rendered = TemplateEngine().render(template, context: TemplateContext(request: contextRequest))
                body = Data(rendered.utf8)
            } else {
                body = Data()
            }
        }

        // Body generation succeeded — now count the hit.
        incrementHitCount(for: map.id)

        // Create BodyStorage from the body data
        let responseBodyStorage = BodyStorage.from(data: body)

        // Create a mock NetworkRequest
        var mockRequest = NetworkRequest(
            id: requestId,
            url: url,
            method: method,
            statusCode: mockResponse.statusCode,
            timestamp: Date(),
            duration: Double(mockResponse.delay) / 1000.0,
            requestHeaders: [],
            responseHeaders: mockResponse.headers,
            requestBody: .empty,
            responseBody: responseBodyStorage
        )

        // Mark as mocked
        mockRequest.isMocked = true

        return mockRequest
    }

    /// Execute a JavaScript script to generate the response body
    private func executeScriptForBody(_ scriptContent: String?, url: String, method: HTTPMethod) throws -> Data {
        guard let scriptContent, !scriptContent.isEmpty else {
            throw RequestMapError.scriptExecutionNotSupported
        }

        // Use the cached engine. Recreate it if it was never initialised or failed to init.
        if scriptEngine == nil {
            scriptEngine = MockScriptEngine()
        }
        guard let engine = scriptEngine else {
            throw RequestMapError.scriptExecutionNotSupported
        }

        do {
            return try engine.executeBodyScript(scriptContent, url: url, method: method.rawValue)
        } catch {
            FeatureLog.requestMap.error("event=request_map.script_execute outcome=failure error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Create a map from an existing request (for quick mocking)
    public func createMapFromRequest(_ request: NetworkRequest, name: String? = nil) {
        let map = RequestMap.fromRequest(request, name: name)
        addMap(map)
    }

    // MARK: - Persistence (Delegate to Base Manager)

    /// Export maps to JSON file
    public func exportMaps() throws -> URL {
        let data = try JSONEncoder().encode(maps)
        let timestamp = Date().timeIntervalSince1970
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RequestMaps_\(timestamp).json")
        try data.write(to: tempURL)
        return tempURL
    }

    /// Import maps from JSON file
    public func importMaps(from url: URL, merge: Bool = true) throws {
        try baseManager.importItems(from: url, merge: merge)
    }

    /// Import maps from decoded values
    public func importMaps(_ importedMaps: [RequestMap], merge: Bool = true) {
        baseManager.importItems(importedMaps, merge: merge)
    }

    /// Clear all maps
    public func clearAllMaps() {
        baseManager.clearAll()
    }

    /// Reload maps if the backing file has changed.
    public func reloadIfNeeded() {
        baseManager.reloadIfNeeded()
    }

    // MARK: - Statistics (Delegate to Base Manager)

    public var enabledMapsCount: Int {
        baseManager.enabledCount
    }

    public var totalMapsCount: Int {
        baseManager.totalCount
    }

    public var totalHits: Int {
        maps.reduce(0) { $0 + $1.hitCount }
    }

    /// Get most used maps (by hit count)
    public func mostUsedMaps(limit: Int = 10) -> [RequestMap] {
        maps.sorted { $0.hitCount > $1.hitCount }.prefix(limit).map(\.self)
    }
}
