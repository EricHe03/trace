//
//  MatchCriteria.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

// MARK: - Match Criteria

public struct MatchCriteria: Codable, Sendable {
    public var url: URLMatcher?
    public var methods: Set<HTTPMethod>
    public var hosts: [StringMatcher]
    public var schemes: Set<String>
    public var ports: Set<Int>
    public var headers: [HeaderMatcher]
    public var queryParams: [QueryParamMatcher]
    public var statusCodes: Set<Int>
    public var contentTypes: [StringMatcher]
    public var bodyMatchers: [BodyMatcher]
    public var logic: MatchLogic

    public init(
        url: URLMatcher? = nil,
        methods: Set<HTTPMethod> = [],
        hosts: [StringMatcher] = [],
        schemes: Set<String> = [],
        ports: Set<Int> = [],
        headers: [HeaderMatcher] = [],
        queryParams: [QueryParamMatcher] = [],
        statusCodes: Set<Int> = [],
        contentTypes: [StringMatcher] = [],
        bodyMatchers: [BodyMatcher] = [],
        logic: MatchLogic = .and
    ) {
        self.url = url
        self.methods = methods
        self.hosts = hosts
        self.schemes = schemes
        self.ports = ports
        self.headers = headers
        self.queryParams = queryParams
        self.statusCodes = statusCodes
        self.contentTypes = contentTypes
        self.bodyMatchers = bodyMatchers
        self.logic = logic
    }

    public var isEmpty: Bool {
        url == nil &&
            methods.isEmpty &&
            hosts.isEmpty &&
            schemes.isEmpty &&
            ports.isEmpty &&
            headers.isEmpty &&
            queryParams.isEmpty &&
            statusCodes.isEmpty &&
            contentTypes.isEmpty &&
            bodyMatchers.isEmpty
    }
}

public struct URLMatcher: Codable, Sendable {
    public var matchType: MatchType
    public var pattern: String

    public init(matchType: MatchType, pattern: String) {
        self.matchType = matchType
        self.pattern = pattern
    }

    public func matches(_ value: String) -> Bool {
        StringMatcher(matchType: matchType, pattern: pattern, caseSensitive: false).matches(value)
    }
}

public struct StringMatcher: Codable, Sendable {
    public var matchType: MatchType
    public var pattern: String
    public var caseSensitive: Bool

    public init(matchType: MatchType, pattern: String, caseSensitive: Bool = false) {
        self.matchType = matchType
        self.pattern = pattern
        self.caseSensitive = caseSensitive
    }

    public func matches(_ value: String) -> Bool {
        let target = caseSensitive ? value : value.lowercased()
        let patternValue = caseSensitive ? pattern : pattern.lowercased()

        switch matchType {
        case .exact:
            return target == patternValue
        case .contains:
            return target.contains(patternValue)
        case .wildcard:
            return wildcardMatch(value: value, pattern: pattern, caseSensitive: caseSensitive)
        case .regex:
            return RegexMatcher.safeMatch(pattern: pattern, in: value, caseSensitive: caseSensitive)
        }
    }

    private func wildcardMatch(value: String, pattern: String, caseSensitive: Bool) -> Bool {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = "^" + regexPattern + "$"
        return RegexMatcher.safeMatch(pattern: regexPattern, in: value, caseSensitive: caseSensitive)
    }
}

public struct HeaderMatcher: Codable, Sendable {
    public var name: String
    public var matcher: StringMatcher?
    public var condition: MatchCondition

    public init(name: String, matcher: StringMatcher? = nil, condition: MatchCondition = .exists) {
        self.name = name
        self.matcher = matcher
        self.condition = condition
    }
}

public struct QueryParamMatcher: Codable, Sendable {
    public var name: String
    public var matcher: StringMatcher?
    public var condition: MatchCondition

    public init(name: String, matcher: StringMatcher? = nil, condition: MatchCondition = .exists) {
        self.name = name
        self.matcher = matcher
        self.condition = condition
    }
}

public struct BodyMatcher: Codable, Sendable {
    public var matcherType: BodyMatcherType
    public var pattern: String

    public init(matcherType: BodyMatcherType, pattern: String) {
        self.matcherType = matcherType
        self.pattern = pattern
    }
}

public enum BodyMatcherType: String, Codable, Sendable {
    case regex
    case jsonPath
    case xpath
    case contains
}

public enum MatchLogic: String, Codable, Sendable {
    case and
    case or
}

public enum MatchCondition: String, Codable, Sendable {
    case exists
    case equals
    case contains
    case regex
    case notExists
    case notEquals
}

public enum MatchingStrategy: String, Codable, Sendable {
    case firstMatch
    case allMatches
}
