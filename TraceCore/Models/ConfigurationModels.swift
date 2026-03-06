//
//  ConfigurationModels.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

// MARK: - Shared Matching

/// Pattern matching type for rules/maps/scripts/breakpoints.
public enum MatchType: String, Codable, CaseIterable, Sendable {
    case wildcard // Wildcard pattern (*.example.com)
    case regex // Regular expression
    case exact // Exact string match
    case contains // Contains substring

    public var displayName: String {
        switch self {
        case .wildcard: "Wildcard"
        case .regex: "Regex"
        case .exact: "Exact Match"
        case .contains: "Contains"
        }
    }
}

// MARK: - Rewrite Rules

/// Type of rewrite rule to apply to network requests/responses.
public enum RuleType: String, Codable, CaseIterable, Sendable {
    case redirect // URL redirection
    case modifyRequest // Modify headers/body before sending
    case modifyResponse // Modify response before display
    case block // Block request entirely
    case map // Map to local mock response

    public var displayName: String {
        switch self {
        case .redirect: "Redirect"
        case .modifyRequest: "Modify Request"
        case .modifyResponse: "Modify Response"
        case .block: "Block Request"
        case .map: "Map Local"
        }
    }

    public var description: String {
        switch self {
        case .redirect: "Redirect requests to a different URL"
        case .modifyRequest: "Modify request headers or body before sending"
        case .modifyResponse: "Modify response headers or body before display"
        case .block: "Block requests matching the pattern"
        case .map: "Return local mock response without hitting server"
        }
    }
}

/// Individual rewrite rule that can be applied to network traffic.
public struct RewriteRule: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var ruleType: RuleType
    @available(*, deprecated, message: "Use matchCriteria instead")
    public var matchType: MatchType
    @available(*, deprecated, message: "Use matchCriteria instead")
    public var matchPattern: String
    public var matchCriteria: MatchCriteria?
    public var stopProcessing: Bool
    public var matchingStrategy: MatchingStrategy
    public var actions: [RewriteAction]
    public var priority: Int
    public var tags: Set<String>
    public var hitCount: Int
    public var lastHitAt: Date?
    public var averageExecutionTimeMs: Double?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        ruleType: RuleType,
        matchType: MatchType = .wildcard,
        matchPattern: String = "",
        matchCriteria: MatchCriteria? = nil,
        stopProcessing: Bool = false,
        matchingStrategy: MatchingStrategy = .allMatches,
        actions: [RewriteAction] = [],
        priority: Int = 0,
        tags: Set<String> = [],
        hitCount: Int = 0,
        lastHitAt: Date? = nil,
        averageExecutionTimeMs: Double? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.ruleType = ruleType
        self.matchType = matchType
        self.matchPattern = matchPattern
        self.matchCriteria = matchCriteria
        self.stopProcessing = stopProcessing
        self.matchingStrategy = matchingStrategy
        self.actions = actions
        self.priority = priority
        self.tags = tags
        self.hitCount = hitCount
        self.lastHitAt = lastHitAt
        self.averageExecutionTimeMs = averageExecutionTimeMs
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, ruleType, matchType, matchPattern
        case matchCriteria, stopProcessing, matchingStrategy
        case actions, priority, tags, hitCount, lastHitAt, averageExecutionTimeMs, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.ruleType = try container.decode(RuleType.self, forKey: .ruleType)
        self.matchType = try container.decodeIfPresent(MatchType.self, forKey: .matchType) ?? .wildcard
        self.matchPattern = try container.decodeIfPresent(String.self, forKey: .matchPattern) ?? ""
        self.matchCriteria = try container.decodeIfPresent(MatchCriteria.self, forKey: .matchCriteria)
        self.stopProcessing = try container.decodeIfPresent(Bool.self, forKey: .stopProcessing) ?? false
        self.matchingStrategy = try container.decodeIfPresent(MatchingStrategy.self, forKey: .matchingStrategy) ?? .allMatches
        self.actions = try container.decodeIfPresent([RewriteAction].self, forKey: .actions) ?? []
        self.priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        self.tags = try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []
        self.hitCount = try container.decodeIfPresent(Int.self, forKey: .hitCount) ?? 0
        self.lastHitAt = try container.decodeIfPresent(Date.self, forKey: .lastHitAt)
        self.averageExecutionTimeMs = try container.decodeIfPresent(Double.self, forKey: .averageExecutionTimeMs)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()

        if matchCriteria == nil, !matchPattern.isEmpty {
            matchCriteria = MatchCriteria(
                url: URLMatcher(matchType: matchType, pattern: matchPattern)
            )
        } else if matchPattern.isEmpty, let urlMatcher = matchCriteria?.url {
            matchPattern = urlMatcher.pattern
            matchType = urlMatcher.matchType
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(ruleType, forKey: .ruleType)
        try container.encode(matchType, forKey: .matchType)
        try container.encode(matchPattern, forKey: .matchPattern)
        try container.encodeIfPresent(matchCriteria, forKey: .matchCriteria)
        try container.encode(stopProcessing, forKey: .stopProcessing)
        try container.encode(matchingStrategy, forKey: .matchingStrategy)
        try container.encode(actions, forKey: .actions)
        try container.encode(priority, forKey: .priority)
        try container.encode(tags, forKey: .tags)
        try container.encode(hitCount, forKey: .hitCount)
        try container.encodeIfPresent(lastHitAt, forKey: .lastHitAt)
        try container.encodeIfPresent(averageExecutionTimeMs, forKey: .averageExecutionTimeMs)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }

}

/// Action to perform when a rule matches.
public struct RewriteAction: Codable, Identifiable, Sendable {
    public enum ActionType: String, Codable, CaseIterable, Sendable {
        case setHeader
        case removeHeader
        case replaceBody
        case setBody
        case setStatusCode
        case addDelay
        case redirectTo
        case setQueryParam
        case removeQueryParam
        case setCookie
        case removeCookie
        case base64Encode
        case base64Decode
        case urlEncode
        case urlDecode
        case compress
        case decompress
        case jsonToXml
        case xmlToJson
        case jsonPathSet
        case jsonPathDelete
        case throttle
        case addJitter
        case dropConnection
        case resetConnection
        case corruptData
        case timeout
        case packetLoss
        case setBodyFromTemplate

        public var displayName: String {
            switch self {
            case .setHeader: "Set Header"
            case .removeHeader: "Remove Header"
            case .replaceBody: "Replace Body"
            case .setBody: "Set Body"
            case .setStatusCode: "Set Status Code"
            case .addDelay: "Add Delay"
            case .redirectTo: "Redirect To"
            case .setQueryParam: "Set Query Param"
            case .removeQueryParam: "Remove Query Param"
            case .setCookie: "Set Cookie"
            case .removeCookie: "Remove Cookie"
            case .base64Encode: "Base64 Encode"
            case .base64Decode: "Base64 Decode"
            case .urlEncode: "URL Encode"
            case .urlDecode: "URL Decode"
            case .compress: "Compress"
            case .decompress: "Decompress"
            case .jsonToXml: "JSON to XML"
            case .xmlToJson: "XML to JSON"
            case .jsonPathSet: "JSONPath Set"
            case .jsonPathDelete: "JSONPath Delete"
            case .throttle: "Throttle"
            case .addJitter: "Add Jitter"
            case .dropConnection: "Drop Connection"
            case .resetConnection: "Reset Connection"
            case .corruptData: "Corrupt Data"
            case .timeout: "Timeout"
            case .packetLoss: "Packet Loss"
            case .setBodyFromTemplate: "Set Body From Template"
            }
        }
    }

    public let id: UUID
    public var actionType: ActionType
    public var parameters: [String: String]

    public init(
        id: UUID = UUID(),
        actionType: ActionType,
        parameters: [String: String] = [:]
    ) {
        self.id = id
        self.actionType = actionType
        self.parameters = parameters
    }

    /// Convenience initializers for common actions
    public static func setHeader(key: String, value: String) -> RewriteAction {
        RewriteAction(actionType: .setHeader, parameters: ["key": key, "value": value])
    }

    public static func removeHeader(key: String) -> RewriteAction {
        RewriteAction(actionType: .removeHeader, parameters: ["key": key])
    }

    public static func replaceBody(pattern: String, replacement: String) -> RewriteAction {
        RewriteAction(actionType: .replaceBody, parameters: ["pattern": pattern, "replacement": replacement])
    }

    public static func setBody(content: String) -> RewriteAction {
        RewriteAction(actionType: .setBody, parameters: ["content": content])
    }

    public static func setStatusCode(_ code: Int) -> RewriteAction {
        RewriteAction(actionType: .setStatusCode, parameters: ["code": String(code)])
    }

    public static func addDelay(milliseconds: Int) -> RewriteAction {
        RewriteAction(actionType: .addDelay, parameters: ["milliseconds": String(milliseconds)])
    }

    public static func redirectTo(url: String) -> RewriteAction {
        RewriteAction(actionType: .redirectTo, parameters: ["url": url])
    }

    /// Helper methods to extract typed values
    public var headerKey: String? {
        parameters["key"]
    }

    public var headerValue: String? {
        parameters["value"]
    }

    public var bodyPattern: String? {
        parameters["pattern"]
    }

    public var bodyReplacement: String? {
        parameters["replacement"]
    }

    public var bodyContent: String? {
        parameters["content"]
    }

    public var redirectUrl: String? {
        parameters["url"]
    }

    public var queryParamName: String? {
        parameters["name"]
    }

    public var queryParamValue: String? {
        parameters["value"]
    }

    public var cookieName: String? {
        parameters["cookie"] ?? parameters["name"]
    }

    public var cookieValue: String? {
        parameters["value"]
    }

    public var jsonPath: String? {
        parameters["path"]
    }

    public var jsonValue: String? {
        parameters["json"] ?? parameters["value"]
    }

    public var templateBody: String? {
        parameters["template"]
    }

    public var throttleBytesPerSecond: Int? {
        parameters["bandwidth"].flatMap(Int.init)
    }

    public var jitterBaseMs: Int? {
        parameters["baseDelay"].flatMap(Int.init)
    }

    public var jitterVarianceMs: Int? {
        parameters["variance"].flatMap(Int.init)
    }

    public var compressionAlgorithm: String? {
        parameters["algorithm"]
    }

    public var statusCode: Int? {
        guard let codeStr = parameters["code"] else { return nil }
        return Int(codeStr)
    }

    public var delayMilliseconds: Int? {
        guard let delayStr = parameters["milliseconds"] else { return nil }
        return Int(delayStr)
    }
}

// MARK: Protocol Conformances

extension RewriteRule: Toggleable {}
extension RewriteRule: URLMatchable {}
extension RewriteRule: ModificationTrackable {}

extension RewriteRule: Equatable {
    public static func == (lhs: RewriteRule, rhs: RewriteRule) -> Bool {
        lhs.id == rhs.id
    }
}

extension RewriteAction: Equatable {
    public static func == (lhs: RewriteAction, rhs: RewriteAction) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Host Entries

/// A host entry that maps a hostname to a custom IP address and port.
/// Similar to entries in /etc/hosts but with additional port override capability.
public struct HostEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var hostname: String
    public var targetIP: String
    public var targetPort: Int?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        hostname: String,
        targetIP: String,
        targetPort: Int? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.hostname = hostname
        self.targetIP = targetIP
        self.targetPort = targetPort
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

}

extension HostEntry: Toggleable {}
extension HostEntry: URLMatchable {}
extension HostEntry: ModificationTrackable {}

// MARK: - Request Maps

/// Source for mock response body.
public enum BodySource: String, Codable, CaseIterable, Sendable {
    case inline // Body stored inline in the map
    case file // Body loaded from file
    case script // Body generated by script
    case template // Body rendered from template

    public var displayName: String {
        switch self {
        case .inline: "Inline"
        case .file: "From File"
        case .script: "From Script"
        case .template: "Template"
        }
    }
}

/// Mock response to return instead of hitting real server.
public struct MockResponse: Codable, Sendable {
    public var statusCode: Int
    public var statusMessage: String
    public var headers: [TraceHTTPHeader]
    public var bodySource: BodySource
    public var bodyContent: Data?
    public var bodyFilePath: String?
    public var scriptContent: String?
    public var delay: Int // milliseconds

    public init(
        statusCode: Int = 200,
        statusMessage: String = "OK",
        headers: [TraceHTTPHeader] = [],
        bodySource: BodySource = .inline,
        bodyContent: Data? = nil,
        bodyFilePath: String? = nil,
        scriptContent: String? = nil,
        delay: Int = 0
    ) {
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.headers = headers
        self.bodySource = bodySource
        self.bodyContent = bodyContent
        self.bodyFilePath = bodyFilePath
        self.scriptContent = scriptContent
        self.delay = delay
    }

}

/// Request mapping rule to return mock responses.
public struct RequestMap: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var matchType: MatchType
    public var matchPattern: String
    public var mockResponse: MockResponse
    public var createdAt: Date
    public var modifiedAt: Date
    public var hitCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        matchType: MatchType = .wildcard,
        matchPattern: String,
        mockResponse: MockResponse,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        hitCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matchType = matchType
        self.matchPattern = matchPattern
        self.mockResponse = mockResponse
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.hitCount = hitCount
    }

}

public enum RequestMapError: LocalizedError {
    case missingFilePath
    case fileNotFound(String)
    case scriptExecutionNotSupported
    case invalidBodyData

    public var errorDescription: String? {
        switch self {
        case .missingFilePath:
            "File path is required when body source is 'file'"
        case let .fileNotFound(path):
            "File not found at path: \(path)"
        case .scriptExecutionNotSupported:
            "Script execution not yet supported"
        case .invalidBodyData:
            "Invalid body data"
        }
    }
}

extension RequestMap: Toggleable {}
extension RequestMap: URLMatchable {}
extension RequestMap: ModificationTrackable {}

extension RequestMap: Equatable {
    public static func == (lhs: RequestMap, rhs: RequestMap) -> Bool {
        lhs.id == rhs.id
    }
}

extension MockResponse: Equatable {}

// MARK: - Scripts

/// Type of script.
public enum ScriptType: String, Codable, CaseIterable, Sendable {
    case request = "Request"
    case response = "Response"
    case stream = "Stream"
    case both = "Both"

    public var displayName: String {
        rawValue
    }

    public var description: String {
        switch self {
        case .request: "Runs on outgoing requests"
        case .response: "Runs on incoming responses"
        case .stream: "Runs on stream events (SSE/WebSocket)"
        case .both: "Runs on both requests and responses"
        }
    }
}

/// JavaScript script for request/response modification.
public struct Script: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var scriptType: ScriptType
    public var matchType: MatchType
    public var matchPattern: String?
    public var code: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var executionCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        scriptType: ScriptType,
        matchType: MatchType = .wildcard,
        matchPattern: String? = nil,
        code: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        executionCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.scriptType = scriptType
        self.matchType = matchType
        self.matchPattern = matchPattern
        self.code = code
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.executionCount = executionCount
    }

}

extension Script: Toggleable {}
extension Script: URLMatchable {}
extension Script: ModificationTrackable {}

extension Script: Equatable {
    public static func == (lhs: Script, rhs: Script) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Breakpoints

public enum BreakpointType: String, Codable, CaseIterable, Equatable, Sendable {
    case request
    case response
    case stream
    case both

    public var displayName: String {
        switch self {
        case .request: "Request"
        case .response: "Response"
        case .stream: "Stream Event"
        case .both: "Request & Response"
        }
    }
}

public struct Breakpoint: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var configuration: BreakpointConfiguration
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, configuration: BreakpointConfiguration, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.createdAt = createdAt
    }
}

public struct BreakpointConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var breakpointType: BreakpointType
    public var matchType: MatchType
    public var matchPattern: String?
    public var methods: Set<HTTPMethod>
    public var statusCodes: Set<Int>
    public var executionMode: BreakpointExecutionMode
    public var maxHits: Int?
    public var conditions: [BreakpointCondition]

    public init(
        enabled: Bool = false,
        breakpointType: BreakpointType = .both,
        matchType: MatchType = .wildcard,
        matchPattern: String? = nil,
        methods: Set<HTTPMethod> = [],
        statusCodes: Set<Int> = [],
        executionMode: BreakpointExecutionMode = .pause,
        maxHits: Int? = nil,
        conditions: [BreakpointCondition] = []
    ) {
        self.enabled = enabled
        self.breakpointType = breakpointType
        self.matchType = matchType
        self.matchPattern = matchPattern
        self.methods = methods
        self.statusCodes = statusCodes
        self.executionMode = executionMode
        self.maxHits = maxHits
        self.conditions = conditions
    }

}

public enum BreakpointExecutionMode: String, Codable, Equatable, Sendable {
    case pause
    case editOnce
    case alwaysApply
    case logOnly
}

public struct BreakpointCondition: Codable, Equatable, Sendable {
    public var type: ConditionType
    public var parameter: String
    public var value: String

    public init(type: ConditionType, parameter: String, value: String) {
        self.type = type
        self.parameter = parameter
        self.value = value
    }
}

public enum ConditionType: String, Codable, Equatable, Sendable {
    case headerExists
    case headerEquals
    case bodyContains
    case bodyRegex
    case queryParamExists
}

public enum BreakpointState: String, Codable, Equatable, Sendable {
    case paused
    case modified
    case continuing
    case dropped
    case error
}

public enum BreakpointAction: String, Codable, Equatable, Sendable {
    case `continue`
    case drop
    case continueAndDisable
}

public struct PausedRequest: Identifiable, Sendable {
    public let id: String
    public var url: String
    public var method: HTTPMethod
    public var headers: [TraceHTTPHeader]
    public var body: Data?
    public var isPaused: Bool
    public var state: BreakpointState
    public var breakpointType: BreakpointType
    public var pausedAt: Date

    public var statusCode: Int?
    public var statusMessage: String?

    public var modifiedUrl: String?
    public var modifiedMethod: HTTPMethod?
    public var modifiedHeaders: [TraceHTTPHeader]?
    public var modifiedBody: Data?
    public var modifiedStatusCode: Int?
    public var modifiedStatusMessage: String?

    public init(
        id: String,
        url: String,
        method: HTTPMethod,
        headers: [TraceHTTPHeader],
        body: Data? = nil,
        breakpointType: BreakpointType,
        statusCode: Int? = nil,
        statusMessage: String? = nil
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.isPaused = true
        self.state = .paused
        self.breakpointType = breakpointType
        self.pausedAt = Date()
        self.statusCode = statusCode
        self.statusMessage = statusMessage
    }

}

public extension Notification.Name {
    static let breakpointTriggered = Notification.Name("breakpointTriggered")
    static let breakpointResumed = Notification.Name("breakpointResumed")
}

public enum BreakpointNotificationKey: String {
    case requestId
    case url
    case method
    case breakpointType
}

// MARK: - Favorites

/// Represents a favorited network request with optional notes.
public struct Favorite: Codable, Identifiable, Equatable {
    public let id: UUID
    public let requestId: UUID
    public var name: String?
    public var notes: String?
    public let createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        requestId: UUID,
        name: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.requestId = requestId
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

extension Favorite: ModificationTrackable {}
