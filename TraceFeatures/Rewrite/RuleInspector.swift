//
//  RuleInspector.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

@available(*, deprecated, message: "Use RewriteManager.evaluate(rule:request:target:) instead.")
public enum RuleInspector {
    public static func evaluate(rule: RewriteRule, request: NetworkRequest, target: MatchTarget) -> MatchEvaluation {
        RewriteManager.evaluate(rule: rule, request: request, target: target)
    }
}
