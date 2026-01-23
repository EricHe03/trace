//
//  RuleInspector.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public enum RuleInspector {
    public static func evaluate(rule: RewriteRule, request: NetworkRequest, target: MatchTarget) -> MatchEvaluation {
        if let criteria = rule.matchCriteria, !criteria.isEmpty {
            return RequestMatcher.evaluate(criteria, request: request, target: target)
        }
        let passed = rule.matches(request.url)
        return MatchEvaluation(passed: passed, details: [
            MatcherEvaluation(matcher: "url", passed: passed, message: rule.matchPattern)
        ])
    }
}
