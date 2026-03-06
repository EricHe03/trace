//
//  RewriteManager+Metadata.swift
//  TraceFeatures
//
//  Created by AI Assistant on 2026/03/06.
//

import Foundation
import TraceCore

public extension RewriteManager {
    var allTags: Set<String> {
        Set(rules.flatMap(\.tags))
    }

    func rules(withTag tag: String) -> [RewriteRule] {
        rules.filter { $0.tags.contains(tag) }
    }

    func addTag(_ tag: String, to ruleId: UUID) {
        guard var rule = rules.first(where: { $0.id == ruleId }) else { return }
        rule.tags.insert(tag)
        updateRule(rule)
    }

    func removeTag(_ tag: String, from ruleId: UUID) {
        guard var rule = rules.first(where: { $0.id == ruleId }) else { return }
        rule.tags.remove(tag)
        updateRule(rule)
    }

    nonisolated static func evaluate(rule: RewriteRule, request: NetworkRequest, target: MatchTarget) -> MatchEvaluation {
        if let criteria = rule.matchCriteria {
            if !criteria.isEmpty {
                return RequestMatcher.evaluate(criteria, request: request, target: target)
            }

            return MatchEvaluation(passed: true, details: [
                MatcherEvaluation(matcher: "criteria", passed: true, message: "empty")
            ])
        }

        let passed = rule.matches(request.url)
        return MatchEvaluation(passed: passed, details: [
            MatcherEvaluation(matcher: "url", passed: passed, message: rule.matchPattern)
        ])
    }
}
