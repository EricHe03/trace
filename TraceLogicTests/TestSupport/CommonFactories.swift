import Foundation
@testable import TraceCore
@testable import TraceProxy

func makeNetworkRequest(
    id: UUID = UUID(),
    url: String = "https://api.example.com/test",
    method: HTTPMethod = .get,
    statusCode: Int? = 200,
    statusMessage: String? = "OK",
    timestamp: Date = Date(),
    duration: TimeInterval = 0.5,
    requestHeaders: [TraceHTTPHeader] = [],
    responseHeaders: [TraceHTTPHeader] = [],
    requestBody: BodyStorage = .empty,
    responseBody: BodyStorage = .empty,
    wasThrottled: Bool = false,
    throttlingProfile: String? = nil
) -> NetworkRequest {
    NetworkRequest(
        id: id,
        url: url,
        method: method,
        statusCode: statusCode,
        statusMessage: statusMessage,
        timestamp: timestamp,
        duration: duration,
        requestHeaders: requestHeaders,
        responseHeaders: responseHeaders,
        requestBody: requestBody,
        responseBody: responseBody,
        wasThrottled: wasThrottled,
        throttlingProfile: throttlingProfile
    )
}

func makeRewriteRule(
    id: UUID = UUID(),
    name: String = "Test Rule",
    matchURL: String = "*.example.com",
    enabled: Bool = true,
    ruleType: RuleType = .modifyRequest,
    modifyHeadersAdd: [String: String] = [:],
    modifyHeadersSet: [String: String] = [:],
    modifyHeadersRemove: [String] = []
) -> RewriteRule {
    var actions: [RewriteAction] = []
    for (key, value) in modifyHeadersAdd {
        actions.append(.setHeader(key: key, value: value))
    }
    for (key, value) in modifyHeadersSet {
        actions.append(.setHeader(key: key, value: value))
    }
    for key in modifyHeadersRemove {
        actions.append(.removeHeader(key: key))
    }

    return RewriteRule(
        id: id,
        name: name,
        enabled: enabled,
        ruleType: ruleType,
        matchType: .wildcard,
        matchPattern: matchURL,
        actions: actions
    )
}

func makeRequestMap(
    id: UUID = UUID(),
    name: String = "Test Map",
    enabled: Bool = true,
    matchURL: String = "https://api.example.com/old",
    statusCode: Int = 200,
    body: String = "{\"ok\":true}"
) -> RequestMap {
    let mockResponse = MockResponse(
        statusCode: statusCode,
        statusMessage: HTTPURLResponse.localizedString(forStatusCode: statusCode),
        headers: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
        bodySource: .inline,
        bodyContent: body.data(using: .utf8),
        delay: 0
    )

    return RequestMap(
        id: id,
        name: name,
        enabled: enabled,
        matchType: .exact,
        matchPattern: matchURL,
        mockResponse: mockResponse
    )
}

func makeScript(
    id: UUID = UUID(),
    name: String = "Test Script",
    enabled: Bool = true,
    code: String = "// Test script",
    scriptType: ScriptType = .request
) -> Script {
    Script(
        id: id,
        name: name,
        enabled: enabled,
        scriptType: scriptType,
        code: code
    )
}

func makeRuleGroup(
    id: UUID = UUID(),
    name: String = "Test Group",
    enabled: Bool = true,
    ruleIds: [UUID] = []
) -> RuleGroup {
    RuleGroup(
        id: id,
        name: name,
        enabled: enabled,
        rules: ruleIds
    )
}

func makeProfile(
    id: UUID = UUID(),
    name: String = "Test Profile",
    isActive: Bool = true,
    ruleGroupIds: [UUID] = []
) -> Profile {
    Profile(
        id: id,
        name: name,
        ruleGroups: ruleGroupIds,
        isActive: isActive
    )
}

func makeConfigSnapshot(
    rewriteRules: [RewriteRule] = [],
    requestMaps: [RequestMap] = [],
    scripts: [Script] = [],
    ruleGroups: [RuleGroup] = [],
    activeProfile: Profile? = nil
) -> ConfigSnapshot {
    ConfigSnapshot(
        rewriteRules: rewriteRules,
        requestMaps: requestMaps,
        scripts: scripts,
        ruleGroups: ruleGroups,
        activeProfile: activeProfile
    )
}
