//
//  PersistentCollectionDescriptor.swift
//  TraceCore
//
//  Created by Justin on 2026/03/20.
//

import Foundation

/// Canonical metadata for collection-backed feature state persisted in app-group storage.
public struct PersistentCollectionDescriptor: Sendable, Hashable {
    public let fileName: String
    public let itemName: String
    public let notificationName: Notification.Name

    public init(
        fileName: String,
        itemName: String,
        notificationName: Notification.Name
    ) {
        self.fileName = fileName
        self.itemName = itemName
        self.notificationName = notificationName
    }
}

public extension PersistentCollectionDescriptor {
    static let rewriteRules = Self(
        fileName: "RewriteRules.json",
        itemName: "rule",
        notificationName: .rewriteRulesUpdated
    )

    static let requestMaps = Self(
        fileName: "RequestMaps.json",
        itemName: "map",
        notificationName: .requestMapsUpdated
    )

    static let hostEntries = Self(
        fileName: "HostEntries.json",
        itemName: "entry",
        notificationName: .hostsUpdated
    )

    static let scripts = Self(
        fileName: "Scripts.json",
        itemName: "script",
        notificationName: .scriptsUpdated
    )

    static let ruleGroups = Self(
        fileName: "RuleGroups.json",
        itemName: "group",
        notificationName: .ruleGroupsUpdated
    )

    static let profiles = Self(
        fileName: "Profiles.json",
        itemName: "profile",
        notificationName: .profilesUpdated
    )

    static let breakpointPresets = Self(
        fileName: "BreakpointPresets.json",
        itemName: "breakpoint_preset",
        notificationName: .breakpointPresetsUpdated
    )

    static let favorites = Self(
        fileName: "Favorites.json",
        itemName: "favorite",
        notificationName: .favoritesUpdated
    )

    static let all: [Self] = [
        .rewriteRules,
        .requestMaps,
        .hostEntries,
        .scripts,
        .ruleGroups,
        .profiles,
        .breakpointPresets,
        .favorites
    ]
}
