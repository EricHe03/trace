//
//  TagManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

@available(*, deprecated, message: "Use RewriteManager.shared metadata APIs instead.")
@MainActor
public final class TagManager {
    public static let shared = TagManager()

    private init() {}

    public func getAllTags() -> Set<String> {
        RewriteManager.shared.allTags
    }

    public func getRules(withTag tag: String) -> [RewriteRule] {
        RewriteManager.shared.rules(withTag: tag)
    }

    public func addTag(_ tag: String, to ruleId: UUID) {
        RewriteManager.shared.addTag(tag, to: ruleId)
    }

    public func removeTag(_ tag: String, from ruleId: UUID) {
        RewriteManager.shared.removeTag(tag, from: ruleId)
    }
}
