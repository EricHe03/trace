//
//  RewriteManager+Groups.swift
//  TraceFeatures
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import TraceCore

public extension RewriteManager {
    var groups: [RuleGroup] {
        RuleGroupManager.shared.groups
    }

    func addGroup(_ group: RuleGroup) {
        RuleGroupManager.shared.addGroup(group)
    }

    func updateGroup(_ group: RuleGroup) {
        RuleGroupManager.shared.updateGroup(group)
    }

    func deleteGroup(_ group: RuleGroup) {
        RuleGroupManager.shared.deleteGroup(group)
    }

    func toggleGroup(_ group: RuleGroup) {
        RuleGroupManager.shared.toggleGroup(group)
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        RuleGroupManager.shared.moveGroups(from: source, to: destination)
    }

    func importGroups(_ groups: [RuleGroup], merge: Bool = true) {
        RuleGroupManager.shared.importGroups(groups, merge: merge)
    }

    func reloadGroupsIfNeeded() {
        RuleGroupManager.shared.reloadIfNeeded()
    }
}
