//
//  RulePackManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

@MainActor
public final class RulePackManager {
    public static let shared = RulePackManager()

    private init() {}

    public func exportRulePack(
        rules: [RewriteRule],
        groups: [RuleGroup],
        metadata: RulePackMetadata
    ) throws -> URL {
        let pack = RulePack(metadata: metadata, rules: rules, groups: groups)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pack)
        let fileName = "RulePack_\(Int(Date().timeIntervalSince1970)).json"
        guard let url = AppGroupStorage.shared.appGroupFileURL(for: fileName) else {
            throw StorageError.containerNotFound
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    public func importRulePack(from url: URL) throws -> RulePack {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RulePack.self, from: data)
    }

    public func mergeRulePack(_ pack: RulePack, strategy: MergeStrategy) {
        switch strategy {
        case .replace:
            RewriteManager.shared.importRules(pack.rules, merge: false)
            RewriteManager.shared.importGroups(pack.groups, merge: false)
        case .merge:
            RewriteManager.shared.importRules(pack.rules, merge: true)
            RewriteManager.shared.importGroups(pack.groups, merge: true)
        case .ask:
            RewriteManager.shared.importRules(pack.rules, merge: true)
            RewriteManager.shared.importGroups(pack.groups, merge: true)
        }
    }
}
