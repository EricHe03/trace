//
//  RuleGroupManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Combine
import Foundation
import TraceCore

@available(*, deprecated, message: "Use RewriteManager.shared group APIs instead.")
@MainActor
public final class RuleGroupManager: ObservableObject {
    public static let shared = RuleGroupManager()

    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    public var groups: [RuleGroup] {
        RewriteManager.shared.groups
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: .ruleGroupsUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public func addGroup(_ group: RuleGroup) {
        RewriteManager.shared.addGroup(group)
    }

    public func updateGroup(_ group: RuleGroup) {
        RewriteManager.shared.updateGroup(group)
    }

    public func deleteGroup(_ group: RuleGroup) {
        RewriteManager.shared.deleteGroup(group)
    }

    public func toggleGroup(_ group: RuleGroup) {
        RewriteManager.shared.toggleGroup(group)
    }

    public func moveGroups(from source: IndexSet, to destination: Int) {
        RewriteManager.shared.moveGroups(from: source, to: destination)
    }

    public func reloadIfNeeded() {
        RewriteManager.shared.reloadGroupsIfNeeded()
    }

    public func importGroups(_ groups: [RuleGroup], merge: Bool = true) {
        RewriteManager.shared.importGroups(groups, merge: merge)
    }
}
