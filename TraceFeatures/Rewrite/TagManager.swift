//
//  TagManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

@MainActor
public final class TagManager {
    public static let shared = TagManager()

    private init() {}

    public func getAllTags() -> Set<String> {
        Set(RewriteManager.shared.rules.flatMap(\.tags))
    }

    public func getRules(withTag tag: String) -> [RewriteRule] {
        RewriteManager.shared.rules.filter { $0.tags.contains(tag) }
    }

    public func addTag(_ tag: String, to ruleId: UUID) {
        guard var rule = RewriteManager.shared.rules.first(where: { $0.id == ruleId }) else { return }
        rule.tags.insert(tag)
        RewriteManager.shared.updateRule(rule)
    }

    public func removeTag(_ tag: String, from ruleId: UUID) {
        guard var rule = RewriteManager.shared.rules.first(where: { $0.id == ruleId }) else { return }
        rule.tags.remove(tag)
        RewriteManager.shared.updateRule(rule)
    }
}
