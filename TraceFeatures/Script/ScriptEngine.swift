//
//  ScriptEngine.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import CryptoKit
import Foundation
import JavaScriptCore
#if canImport(TraceCore)
import TraceCore
#endif

/// JavaScript execution engine for request/response modification
public class ScriptEngine {
    private let context: JSContext
    private var lastError: String?

    init?() {
        guard let jsContext = JSContext() else {
            return nil
        }
        context = jsContext

        // Set up exception handler
        context.exceptionHandler = { [weak self] _, exception in
            if let exception {
                self?.lastError = exception.toString()
                FeatureLog.script.error(
                    "event=script.js_exception outcome=failure error=\(exception.toString() ?? "Unknown error", privacy: .private(mask: .hash))"
                )
            }
        }

        configureContext(context)
    }

    // MARK: - Public API

    /// Execute a script on a request
    public func executeRequestScript(_ script: String, request: NetworkRequest) throws -> NetworkRequest {
        lastError = nil

        // Convert request to JavaScript object
        let requestObject = createJSRequest(from: request)
        context.setObject(requestObject, forKeyedSubscript: "request" as NSString)

        // Execute the script
        context.evaluateScript(script)

        // Check for errors
        if let error = lastError {
            throw ScriptError.executionFailed(error)
        }

        // Get modified request from context
        guard let modifiedRequestObj = context.objectForKeyedSubscript("request"),
              !modifiedRequestObj.isUndefined else {
            throw ScriptError.invalidReturn
        }

        // Convert back to NetworkRequest
        return try createNetworkRequest(from: modifiedRequestObj, original: request)
    }

    /// Execute an async script on a request
    public func executeRequestScriptAsync(
        _ script: String,
        request: NetworkRequest,
        timeout: TimeInterval
    ) async throws -> NetworkRequest {
        lastError = nil
        let requestObject = createJSRequest(from: request)
        context.setObject(requestObject, forKeyedSubscript: "request" as NSString)

        let wrapped = "(async function(){ \(script) })()"
        guard let result = context.evaluateScript(wrapped) else {
            throw ScriptError.invalidScript
        }
        _ = try await resolveIfNeeded(result, timeout: timeout)

        if let error = lastError {
            throw ScriptError.executionFailed(error)
        }

        guard let modifiedRequestObj = context.objectForKeyedSubscript("request"),
              !modifiedRequestObj.isUndefined else {
            throw ScriptError.invalidReturn
        }

        return try createNetworkRequest(from: modifiedRequestObj, original: request)
    }

    /// Execute a script on a response
    public func executeResponseScript(_ script: String, request: NetworkRequest) throws -> NetworkRequest {
        lastError = nil

        // Convert to JavaScript objects
        let requestObject = createJSRequest(from: request)
        let responseObject = createJSResponse(from: request)

        context.setObject(requestObject, forKeyedSubscript: "request" as NSString)
        context.setObject(responseObject, forKeyedSubscript: "response" as NSString)
        context.evaluateScript("""
        response.json = function() { return parseJSON(response.body || ""); };
        response.xml = function() { return response.body || ""; };
        """)

        // Execute the script
        context.evaluateScript(script)

        // Check for errors
        if let error = lastError {
            throw ScriptError.executionFailed(error)
        }

        // Get modified response
        guard let modifiedResponseObj = context.objectForKeyedSubscript("response"),
              !modifiedResponseObj.isUndefined else {
            throw ScriptError.invalidReturn
        }

        // Convert back to NetworkRequest
        return try createNetworkRequest(from: modifiedResponseObj, original: request, isResponse: true)
    }

    /// Execute an async script on a response
    public func executeResponseScriptAsync(
        _ script: String,
        request: NetworkRequest,
        timeout: TimeInterval
    ) async throws -> NetworkRequest {
        lastError = nil
        let requestObject = createJSRequest(from: request)
        let responseObject = createJSResponse(from: request)

        context.setObject(requestObject, forKeyedSubscript: "request" as NSString)
        context.setObject(responseObject, forKeyedSubscript: "response" as NSString)
        context.evaluateScript("""
        response.json = function() { return parseJSON(response.body || ""); };
        response.xml = function() { return response.body || ""; };
        """)

        let wrapped = "(async function(){ \(script) })()"
        guard let result = context.evaluateScript(wrapped) else {
            throw ScriptError.invalidScript
        }
        _ = try await resolveIfNeeded(result, timeout: timeout)

        if let error = lastError {
            throw ScriptError.executionFailed(error)
        }

        guard let modifiedResponseObj = context.objectForKeyedSubscript("response"),
              !modifiedResponseObj.isUndefined else {
            throw ScriptError.invalidReturn
        }

        return try createNetworkRequest(from: modifiedResponseObj, original: request, isResponse: true)
    }

    /// Execute a script on a stream session/event context.
    public func executeStreamScript(_ script: String, context streamContext: StreamScriptContext) throws -> StreamScriptExecutionResult {
        lastError = nil

        let streamObject = createJSStreamContext(from: streamContext)
        context.setObject(streamObject, forKeyedSubscript: "stream" as NSString)

        context.evaluateScript(script)

        if let error = lastError {
            throw ScriptError.executionFailed(error)
        }

        let modifiedStreamObject = context.objectForKeyedSubscript("stream")
        return try createStreamScriptExecutionResult(
            from: modifiedStreamObject,
            original: streamContext
        )
    }

    /// Execute an async script on a stream session/event context.
    public func executeStreamScriptAsync(
        _ script: String,
        context streamContext: StreamScriptContext,
        timeout: TimeInterval
    ) async throws -> StreamScriptExecutionResult {
        lastError = nil

        let streamObject = createJSStreamContext(from: streamContext)
        context.setObject(streamObject, forKeyedSubscript: "stream" as NSString)

        let wrapped = "(async function(){ \(script) })()"
        guard let result = context.evaluateScript(wrapped) else {
            throw ScriptError.invalidScript
        }
        _ = try await resolveIfNeeded(result, timeout: timeout)

        if let error = lastError {
            throw ScriptError.executionFailed(error)
        }

        let modifiedStreamObject = context.objectForKeyedSubscript("stream")
        return try createStreamScriptExecutionResult(
            from: modifiedStreamObject,
            original: streamContext
        )
    }

    /// Validate a script without executing it
    public func validateScript(_ script: String) -> ScriptValidationResult {
        var validationError: String?

        // Try to parse the script
        guard let testContext = JSContext() else {
            return .invalid("Failed to create JavaScript context for validation")
        }
        testContext.exceptionHandler = { _, exception in
            validationError = exception?.toString()
        }

        configureContext(testContext)

        // Set up dummy request/response objects for validation
        testContext.evaluateScript("""
        var request = {
            url: '',
            method: 'GET',
            headers: {},
            body: null
        };
        var response = {
            statusCode: 200,
            headers: {},
            body: null
        };
        """)

        testContext.evaluateScript(script)

        if let error = validationError {
            return .invalid(error)
        }

        return .valid
    }

    // MARK: - Setup

    private func configureContext(_ context: JSContext) {
        // Console API for logging
        let console = ConsoleAPI()
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        // Utility functions
        setupUtilityFunctions(in: context)

        // Helper functions
        context.evaluateScript("""
        function getQueryParam(url, name) {
            try {
                const u = new URL(url);
                return u.searchParams.get(name);
            } catch (e) { return null; }
        }
        function setQueryParam(url, name, value) {
            try {
                const u = new URL(url);
                u.searchParams.set(name, value);
                return u.toString();
            } catch (e) { return url; }
        }
        function getCookie(headers, name) {
            if (!headers || !headers['Cookie']) return null;
            const parts = headers['Cookie'].split(';').map(s => s.trim());
            for (const part of parts) {
                const [k, v] = part.split('=');
                if (k === name) return v || '';
            }
            return null;
        }
        function setCookie(headers, name, value) {
            if (!headers) headers = {};
            const existing = headers['Cookie'] || '';
            const parts = existing ? existing.split(';').map(s => s.trim()).filter(Boolean) : [];
            const filtered = parts.filter(p => !p.startsWith(name + '='));
            filtered.push(name + '=' + value);
            headers['Cookie'] = filtered.join('; ');
            return headers;
        }

        // Helper to parse JSON safely
        function parseJSON(str) {
            try {
                return JSON.parse(str);
            } catch (e) {
                console.error('Failed to parse JSON: ' + e);
                return null;
            }
        }

        // Helper to stringify JSON safely
        function stringifyJSON(obj) {
            try {
                return JSON.stringify(obj);
            } catch (e) {
                console.error('Failed to stringify JSON: ' + e);
                return null;
            }
        }

        // Helper to decode base64
        function decodeBase64(str) {
            return atob(str);
        }

        // Helper to encode base64
        function encodeBase64(str) {
            return btoa(str);
        }
        """)
    }

    private func setupUtilityFunctions(in context: JSContext) {
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

        let md5: @convention(block) (String) -> String = { str in
            let digest = Insecure.MD5.hash(data: Data(str.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(md5, forKeyedSubscript: "md5" as NSString)

        let sha256: @convention(block) (String) -> String = { str in
            let digest = SHA256.hash(data: Data(str.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(sha256, forKeyedSubscript: "sha256" as NSString)

        let hmacSha256: @convention(block) (String, String) -> String = { message, key in
            let keyData = SymmetricKey(data: Data(key.utf8))
            let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: keyData)
            return signature.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(hmacSha256, forKeyedSubscript: "hmacSha256" as NSString)
    }

    private func resolveIfNeeded(_ value: JSValue, timeout: TimeInterval) async throws -> JSValue {
        if value.isObject, value.hasProperty("then") {
            return try await awaitPromise(value, timeout: timeout)
        }
        return value
    }

    private func awaitPromise(_ promise: JSValue, timeout: TimeInterval) async throws -> JSValue {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let lock = NSLock()
            func resumeSuccess(_ value: JSValue) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                continuation.resume(returning: value)
            }
            func resumeFailure(_ error: Error) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                continuation.resume(throwing: error)
            }
            let resolve: @convention(block) (JSValue) -> Void = { value in
                resumeSuccess(value)
            }
            let reject: @convention(block) (JSValue) -> Void = { error in
                resumeFailure(ScriptError.executionFailed(error.toString() ?? "Promise rejected"))
            }
            promise.invokeMethod("then", withArguments: [resolve])
            promise.invokeMethod("catch", withArguments: [reject])

            if timeout > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    resumeFailure(ScriptError.executionFailed("Script timed out"))
                }
            }
        }
    }

    // MARK: - Object Conversion

    private func createJSRequest(from request: NetworkRequest) -> [String: Any] {
        var headers: [String: String] = [:]
        for header in request.requestHeaders {
            headers[header.key] = header.value
        }
        let queryParams = queryParamsDictionary(from: request.url)
        let cookies = cookiesDictionary(from: request.requestHeaders)

        var obj: [String: Any] = [
            "url": request.url,
            "method": request.method.rawValue,
            "headers": headers,
            "queryParams": queryParams,
            "cookies": cookies
        ]

        if let body = request.requestBody.getString() {
            obj["body"] = body
        }

        return obj
    }

    private func createJSResponse(from request: NetworkRequest) -> [String: Any] {
        var headers: [String: String] = [:]
        for header in request.responseHeaders {
            headers[header.key] = header.value
        }
        let cookies = cookiesDictionary(from: request.responseHeaders)

        var obj: [String: Any] = [
            "statusCode": request.statusCode,
            "headers": headers,
            "cookies": cookies
        ]

        if let body = request.responseBody.getString() {
            obj["body"] = body
        }

        return obj
    }

    private func queryParamsDictionary(from url: String) -> [String: String] {
        guard let items = URLComponents(string: url)?.queryItems else { return [:] }
        var dict: [String: String] = [:]
        for item in items {
            dict[item.name] = item.value ?? ""
        }
        return dict
    }

    private func cookiesDictionary(from headers: [TraceHTTPHeader]) -> [String: String] {
        guard let cookieHeader = headers.first(where: { $0.key.lowercased() == "cookie" })?.value else { return [:] }
        let parts = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var dict: [String: String] = [:]
        for part in parts {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pieces.count == 2 {
                dict[pieces[0]] = pieces[1]
            }
        }
        return dict
    }

    private func createNetworkRequest(
        from jsObject: JSValue,
        original: NetworkRequest,
        isResponse: Bool = false
    ) throws -> NetworkRequest {
        // Extract modified values
        let modifiedUrl = !isResponse ? (jsObject.forProperty("url")?.toString() ?? original.url) : original.url

        let modifiedMethod: HTTPMethod = if !isResponse,
                                            let methodStr = jsObject.forProperty("method")?.toString(),
                                            let method = HTTPMethod(rawValue: methodStr.uppercased()) {
            method
        } else {
            original.method
        }

        let modifiedRequestHeaders: [TraceHTTPHeader]
        let modifiedResponseHeaders: [TraceHTTPHeader]

        if let headersObj = jsObject.forProperty("headers")?.toDictionary() as? [String: String] {
            let headers = headersObj.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
            if isResponse {
                modifiedRequestHeaders = original.requestHeaders
                modifiedResponseHeaders = headers
            } else {
                modifiedRequestHeaders = headers
                modifiedResponseHeaders = original.responseHeaders
            }
        } else {
            modifiedRequestHeaders = original.requestHeaders
            modifiedResponseHeaders = original.responseHeaders
        }

        let modifiedRequestBody: BodyStorage
        let modifiedResponseBody: BodyStorage

        if let bodyStr = jsObject.forProperty("body")?.toString() {
            if isResponse {
                modifiedRequestBody = original.requestBody
                modifiedResponseBody = BodyStorage.from(string: bodyStr)
            } else {
                modifiedRequestBody = BodyStorage.from(string: bodyStr)
                modifiedResponseBody = original.responseBody
            }
        } else {
            modifiedRequestBody = original.requestBody
            modifiedResponseBody = original.responseBody
        }

        let modifiedStatusCode: Int? = if isResponse, let statusCode = jsObject.forProperty("statusCode")?.toInt32() {
            Int(statusCode)
        } else {
            original.statusCode
        }

        // Create new NetworkRequest with modified values
        var updatedRequest = NetworkRequest(
            id: original.id,
            url: modifiedUrl,
            method: modifiedMethod,
            statusCode: modifiedStatusCode,
            statusMessage: original.statusMessage,
            timestamp: original.timestamp,
            duration: original.duration,
            requestHeaders: modifiedRequestHeaders,
            responseHeaders: modifiedResponseHeaders,
            requestBody: modifiedRequestBody,
            responseBody: modifiedResponseBody
        )
        updatedRequest.protocolVersion = original.protocolVersion
        updatedRequest.timingPhases = original.timingPhases
        updatedRequest.tlsInfo = original.tlsInfo
        updatedRequest.wasThrottled = original.wasThrottled
        updatedRequest.throttlingProfile = original.throttlingProfile
        updatedRequest.isDuplicate = original.isDuplicate
        updatedRequest.duplicateOfRequestId = original.duplicateOfRequestId
        updatedRequest.sessionId = original.sessionId
        updatedRequest.isManual = original.isManual
        updatedRequest.contentType = original.contentType
        updatedRequest.contentEncoding = original.contentEncoding
        updatedRequest.userAgent = original.userAgent
        updatedRequest.cacheControl = original.cacheControl
        updatedRequest.requestCookies = original.requestCookies
        updatedRequest.responseCookies = original.responseCookies
        updatedRequest.queryParameters = original.queryParameters
        updatedRequest.authorization = original.authorization
        updatedRequest.tlsAlerts = original.tlsAlerts

        // Copy interception metadata
        updatedRequest.wasBlocked = original.wasBlocked
        updatedRequest.wasCancelled = original.wasCancelled
        updatedRequest.wasRewritten = original.wasRewritten
        updatedRequest.requestBodyModified = original.requestBodyModified
        updatedRequest.isMocked = original.isMocked
        updatedRequest.isReplayed = original.isReplayed
        updatedRequest.appliedScriptName = original.appliedScriptName
        updatedRequest.hitBreakpoint = original.hitBreakpoint
        updatedRequest.retryAttempts = original.retryAttempts
        updatedRequest.executionLog = original.executionLog
        updatedRequest.executionErrors = original.executionErrors
        updatedRequest.appliedRuleIds = original.appliedRuleIds

        return updatedRequest
    }

    private func createJSStreamContext(from context: StreamScriptContext) -> [String: Any] {
        var payloadObject: [String: Any] = [:]
        if let text = context.event.payload.text {
            payloadObject["text"] = text
        }
        if let binary = context.event.payload.binary {
            payloadObject["base64"] = binary.base64EncodedString()
        }
        if let contentType = context.event.payload.contentType {
            payloadObject["contentType"] = contentType
        }
        if let encoding = context.event.payload.encoding {
            payloadObject["encoding"] = encoding
        }

        let eventObject: [String: Any] = [
            "id": context.event.id.uuidString,
            "sessionId": context.event.sessionID.uuidString,
            "sequence": context.event.sequence,
            "timestamp": context.event.timestamp.timeIntervalSince1970,
            "direction": context.event.direction.rawValue,
            "kind": context.event.kind.rawValue,
            "metadata": context.event.metadata,
            "payload": payloadObject
        ]

        let sessionObject: [String: Any] = [
            "id": context.session.id.uuidString,
            "protocol": context.session.protocolType.rawValue,
            "url": context.session.url,
            "status": context.session.status.rawValue,
            "metadata": context.session.metadata,
            "requestHeaders": headersDictionary(from: context.session.requestHeaders),
            "responseHeaders": headersDictionary(from: context.session.responseHeaders)
        ]

        return [
            "session": sessionObject,
            "event": eventObject,
            "action": StreamScriptAction.forward.rawValue
        ]
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func createStreamScriptExecutionResult(
        from jsObject: JSValue?,
        original context: StreamScriptContext
    ) throws -> StreamScriptExecutionResult {
        guard let jsObject, !jsObject.isUndefined else {
            throw ScriptError.invalidReturn
        }

        var action = StreamScriptAction.forward
        if let rawAction = jsString(from: jsObject.forProperty("action"))?.lowercased(),
           let parsedAction = StreamScriptAction(rawValue: rawAction) {
            action = parsedAction
        }

        guard let eventObject = jsObject.forProperty("event"), !eventObject.isUndefined else {
            throw ScriptError.invalidReturn
        }

        var event = context.event
        if let sequenceNumber = eventObject.forProperty("sequence")?.toNumber() {
            event.sequence = sequenceNumber.int64Value
        }
        if let timestampNumber = eventObject.forProperty("timestamp")?.toNumber() {
            event.timestamp = Date(timeIntervalSince1970: timestampNumber.doubleValue)
        }
        if let directionRaw = jsString(from: eventObject.forProperty("direction")),
           let direction = StreamEventDirection(rawValue: directionRaw) {
            event.direction = direction
        }
        if let kindRaw = jsString(from: eventObject.forProperty("kind")),
           let kind = StreamEventKind(rawValue: kindRaw) {
            event.kind = kind
        }
        if let metadata = stringDictionary(from: eventObject.forProperty("metadata")) {
            event.metadata = metadata
        }

        if let payloadObject = eventObject.forProperty("payload"), !payloadObject.isUndefined {
            var payload = event.payload
            let textValue = payloadObject.forProperty("text")
            let textProvided = textValue != nil && !(textValue?.isUndefined ?? true)
            if textProvided {
                payload.text = jsString(from: textValue)
                if payload.text != nil {
                    payload.binary = nil
                }
            }

            let base64Value = payloadObject.forProperty("base64")
            let base64Provided = base64Value != nil && !(base64Value?.isUndefined ?? true)
            if base64Provided {
                if let base64String = jsString(from: base64Value),
                   let decoded = Data(base64Encoded: base64String) {
                    payload.binary = decoded
                    if !textProvided {
                        payload.text = nil
                    }
                } else {
                    payload.binary = nil
                }
            }

            if let contentTypeValue = payloadObject.forProperty("contentType"),
               !contentTypeValue.isUndefined {
                payload.contentType = jsString(from: contentTypeValue)
            }

            if let encodingValue = payloadObject.forProperty("encoding"),
               !encodingValue.isUndefined {
                payload.encoding = jsString(from: encodingValue)
            }

            event.payload = payload
        }

        return StreamScriptExecutionResult(action: action, event: event)
    }

    private func headersDictionary(from headers: [TraceHTTPHeader]) -> [String: String] {
        var dictionary: [String: String] = [:]
        for header in headers {
            dictionary[header.key] = header.value
        }
        return dictionary
    }

    private func jsString(from value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString()
    }

    private func stringDictionary(from value: JSValue?) -> [String: String]? {
        guard let value, !value.isUndefined, !value.isNull,
              let dictionary = value.toDictionary() as? [String: Any] else {
            return nil
        }

        return dictionary.reduce(into: [String: String]()) { partialResult, pair in
            partialResult[pair.key] = String(describing: pair.value)
        }
    }
}

// MARK: - Console API

@objc protocol ConsoleJSExports: JSExport {
    func log(_ message: String)
    func error(_ message: String)
    func warn(_ message: String)
    func info(_ message: String)
}

@objc class ConsoleAPI: NSObject, ConsoleJSExports {
    private static let consoleSampler = LogSampler.shared

    private func shouldLog(_ level: String) -> Bool {
        ConsoleAPI.consoleSampler.shouldLog(event: "script.console", key: level, first: 5, every: 200)
    }

    private func consoleMetadata(for message: String) -> String {
        let hash = LogRedaction.hash(message)
        return "message_hash=\(hash) message_len=\(message.count)"
    }

    func log(_ message: String) {
        guard shouldLog("log") else { return }
        FeatureLog.script.debug("event=script.console_log \(self.consoleMetadata(for: message))")
    }

    func error(_ message: String) {
        guard shouldLog("error") else { return }
        FeatureLog.script.debug("event=script.console_error \(self.consoleMetadata(for: message))")
    }

    func warn(_ message: String) {
        guard shouldLog("warn") else { return }
        FeatureLog.script.debug("event=script.console_warn \(self.consoleMetadata(for: message))")
    }

    func info(_ message: String) {
        guard shouldLog("info") else { return }
        FeatureLog.script.debug("event=script.console_info \(self.consoleMetadata(for: message))")
    }
}

// MARK: - Errors

public enum ScriptError: LocalizedError {
    case executionFailed(String)
    case invalidReturn
    case invalidScript

    public var errorDescription: String? {
        switch self {
        case let .executionFailed(message):
            "Script execution failed: \(message)"
        case .invalidReturn:
            "Script did not return a valid object"
        case .invalidScript:
            "Invalid script syntax"
        }
    }
}

public enum ScriptValidationResult {
    case valid
    case invalid(String)

    public var isValid: Bool {
        if case .valid = self {
            return true
        }
        return false
    }

    public var errorMessage: String? {
        if case let .invalid(message) = self {
            return message
        }
        return nil
    }
}
