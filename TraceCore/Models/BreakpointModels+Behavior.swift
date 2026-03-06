//
//  BreakpointModels+Behavior.swift
//  TraceCore
//
//  Created by Justin on 2026/03/06.
//

import Foundation

public extension BreakpointConfiguration {
    func shouldBreakOnRequest(url: String, method: HTTPMethod) -> Bool {
        guard enabled else { return false }
        guard breakpointType == .request || breakpointType == .both else { return false }
        if !methods.isEmpty && !methods.contains(method) { return false }
        return matchesUrl(url)
    }

    func shouldBreakOnResponse(url: String, statusCode: Int) -> Bool {
        guard enabled else { return false }
        guard breakpointType == .response || breakpointType == .both else { return false }
        if !statusCodes.isEmpty && !statusCodes.contains(statusCode) { return false }
        return matchesUrl(url)
    }

    func shouldBreakOnStream(url: String) -> Bool {
        guard enabled else { return false }
        guard breakpointType == .stream else { return false }
        return matchesUrl(url)
    }
}

private extension BreakpointConfiguration {
    func matchesUrl(_ url: String) -> Bool {
        guard let pattern = matchPattern, !pattern.isEmpty else { return true }

        switch matchType {
        case .exact:
            return url == pattern
        case .contains:
            return url.contains(pattern)
        case .wildcard:
            return matchesWildcard(url, pattern: pattern)
        case .regex:
            return RegexMatcher.safeMatch(pattern: pattern, in: url, caseSensitive: true)
        }
    }

    func matchesWildcard(_ url: String, pattern: String) -> Bool {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = "^" + regexPattern + "$"
        return RegexMatcher.safeMatch(pattern: regexPattern, in: url, caseSensitive: false)
    }
}

public extension PausedRequest {
    var hasModifications: Bool {
        modifiedUrl != nil ||
            modifiedMethod != nil ||
            modifiedHeaders != nil ||
            modifiedBody != nil ||
            modifiedStatusCode != nil ||
            modifiedStatusMessage != nil
    }

    var effectiveUrl: String {
        modifiedUrl ?? url
    }

    var effectiveMethod: HTTPMethod {
        modifiedMethod ?? method
    }

    var effectiveHeaders: [TraceHTTPHeader] {
        modifiedHeaders ?? headers
    }

    var effectiveBody: Data? {
        modifiedBody ?? body
    }

    var effectiveStatusCode: Int? {
        modifiedStatusCode ?? statusCode
    }

    var effectiveStatusMessage: String? {
        modifiedStatusMessage ?? statusMessage
    }
}
