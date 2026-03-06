//
//  RewriteRule+Matching.swift
//  TraceCore
//
//  Created by Justin on 2026/03/06.
//

import Foundation

public extension RewriteRule {
    func matches(_ url: String) -> Bool {
        guard enabled else { return false }

        if let criteria = matchCriteria, let urlMatcher = criteria.url {
            return urlMatcher.matches(url)
        }

        let pattern = matchPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty {
            return url.isEmpty
        }

        let (subject, isHostMatch) = matchSubject(for: url, pattern: pattern, matchType: matchType)

        switch matchType {
        case .exact:
            if isHostMatch {
                return subject.lowercased() == pattern.lowercased()
            }
            return subject == pattern
        case .contains:
            if isHostMatch {
                let lowerPattern = pattern.lowercased()
                return subject.lowercased().contains(lowerPattern) || url.lowercased().contains(lowerPattern)
            }
            return subject.contains(pattern) || url.contains(pattern)
        case .wildcard:
            return matchesWildcard(subject, pattern: pattern)
        case .regex:
            return RegexMatcher.safeMatch(pattern: pattern, in: subject, caseSensitive: !isHostMatch)
        }
    }
}

private extension RewriteRule {
    func matchesWildcard(_ url: String, pattern: String) -> Bool {
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = "^" + regexPattern + "$"
        return RegexMatcher.safeMatch(pattern: regexPattern, in: url, caseSensitive: false)
    }
}
