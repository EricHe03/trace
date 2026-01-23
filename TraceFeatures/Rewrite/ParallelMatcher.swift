//
//  ParallelMatcher.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public actor ParallelMatcher {
    public init() {}

    public func matchRules(_ rules: [RewriteRule], against request: NetworkRequest) async -> [RewriteRule] {
        await withTaskGroup(of: (RewriteRule, Bool).self) { group in
            for rule in rules {
                group.addTask {
                    if let criteria = rule.matchCriteria, !criteria.isEmpty {
                        let passed = RequestMatcher.evaluate(criteria, request: request, target: .request).passed
                        return (rule, passed)
                    }
                    return (rule, rule.matches(request.url))
                }
            }

            var matched: [RewriteRule] = []
            for await (rule, didMatch) in group where didMatch {
                matched.append(rule)
            }
            return matched.sorted { $0.priority < $1.priority }
        }
    }
}
