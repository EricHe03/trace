//
//  RuleIndex.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public actor RuleIndex {
    private var hostIndex: [String: [UUID]] = [:]
    private var pathPrefixIndex: [String: [UUID]] = [:]

    public init() {}

    public func buildIndex(rules: [RewriteRule]) {
        hostIndex.removeAll()
        pathPrefixIndex.removeAll()

        for rule in rules {
            guard rule.enabled else { continue }
            let pattern = rule.matchCriteria?.url?.pattern ?? rule.matchPattern
            if let url = URL(string: pattern), let host = url.host {
                hostIndex[host, default: []].append(rule.id)
            }
            if pattern.hasPrefix("/") {
                pathPrefixIndex[pattern, default: []].append(rule.id)
            }
        }
    }

    public func lookup(url: String) -> [UUID] {
        guard let parsed = URL(string: url) else { return [] }
        var candidates: [UUID] = []
        if let host = parsed.host, let hostRules = hostIndex[host] {
            candidates.append(contentsOf: hostRules)
        }
        let path = parsed.path
        for (prefix, ids) in pathPrefixIndex where path.hasPrefix(prefix) {
            candidates.append(contentsOf: ids)
        }
        return Array(Set(candidates))
    }

    public func invalidate() {
        hostIndex.removeAll()
        pathPrefixIndex.removeAll()
    }
}
