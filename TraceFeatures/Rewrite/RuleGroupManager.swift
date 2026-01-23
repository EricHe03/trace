//
//  RuleGroupManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Combine
import Foundation
import TraceCore

@MainActor
public final class RuleGroupManager: ObservableObject {
    public static let shared = RuleGroupManager()

    private let baseManager: PersistentCollectionManager<RuleGroup>
    private var cancellables: Set<AnyCancellable> = []
    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    public var groups: [RuleGroup] {
        baseManager.items.sorted { $0.priority < $1.priority }
    }

    private init() {
        self.baseManager = PersistentCollectionManager(
            fileName: "RuleGroups.json",
            notificationName: "RuleGroupsChanged",
            logger: FeatureLog.rewrite,
            itemName: "group"
        )

        baseManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    public func addGroup(_ group: RuleGroup) {
        var newGroup = group
        newGroup.priority = groups.count
        baseManager.add(newGroup)
        updatePriorities()
    }

    public func updateGroup(_ group: RuleGroup) {
        baseManager.update(group)
    }

    public func deleteGroup(_ group: RuleGroup) {
        baseManager.delete(group)
    }

    public func toggleGroup(_ group: RuleGroup) {
        baseManager.toggle(group)
    }

    public func moveGroups(from source: IndexSet, to destination: Int) {
        var current = groups
        let itemsToMove = source.sorted().reversed().map { current.remove(at: $0) }.reversed()
        let adjustedDestination = destination - source.count(where: { $0 < destination })
        for (offset, item) in itemsToMove.enumerated() {
            current.insert(item, at: adjustedDestination + offset)
        }
        baseManager.importItems(current, merge: false)
        updatePriorities()
    }

    public func updatePriorities() {
        var updated = groups
        for (index, _) in updated.enumerated() {
            updated[index].priority = index
        }
        baseManager.importItems(updated, merge: false)
    }

    public func reloadIfNeeded() {
        baseManager.reloadIfNeeded()
    }

    public func importGroups(_ groups: [RuleGroup], merge: Bool = true) {
        baseManager.importItems(groups, merge: merge)
        updatePriorities()
    }
}
