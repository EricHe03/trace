//
//  RuleCompiler.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public actor RuleCompiler {
    private var compiledRules: [UUID: CompiledRule] = [:]

    public init() {}

    public func compile(_ rule: RewriteRule) -> CompiledRule {
        let compiled = CompiledRule(rule: rule, compiledMatchers: [], estimatedCost: 1)
        compiledRules[rule.id] = compiled
        return compiled
    }

    public func getCompiled(_ ruleId: UUID) -> CompiledRule? {
        compiledRules[ruleId]
    }

    public func invalidate(_ ruleId: UUID) {
        compiledRules.removeValue(forKey: ruleId)
    }
}

public struct CompiledRule: Sendable {
    public var rule: RewriteRule
    public var compiledMatchers: [CompiledMatcher]
    public var estimatedCost: Int

    public init(rule: RewriteRule, compiledMatchers: [CompiledMatcher], estimatedCost: Int) {
        self.rule = rule
        self.compiledMatchers = compiledMatchers
        self.estimatedCost = estimatedCost
    }
}

public struct CompiledMatcher: Sendable {
    public var description: String

    public init(description: String) {
        self.description = description
    }
}
