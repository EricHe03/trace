//
//  RuleMigration.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public enum RuleMigration {
    public static func migrateV1ToV2(_ rule: RewriteRule) -> RewriteRule {
        var newRule = rule
        if newRule.matchCriteria == nil, !newRule.matchPattern.isEmpty {
            newRule.matchCriteria = MatchCriteria(
                url: URLMatcher(matchType: newRule.matchType, pattern: newRule.matchPattern)
            )
        }
        return newRule
    }
}
