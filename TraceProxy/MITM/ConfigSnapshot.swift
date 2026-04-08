//
//  ConfigSnapshot.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import TraceCore

public struct ConfigSnapshot: Sendable {
    public let rewriteRules: [RewriteRule]
    public let requestMaps: [RequestMap]
    public let scripts: [Script]
    public let ruleGroups: [RuleGroup]
    public let activeProfile: Profile?
    public let hostEntries: [HostEntry]
    public let timestamp: Date

    public init(
        rewriteRules: [RewriteRule],
        requestMaps: [RequestMap],
        scripts: [Script],
        ruleGroups: [RuleGroup],
        activeProfile: Profile?,
        hostEntries: [HostEntry] = []
    ) {
        self.rewriteRules = rewriteRules
        self.requestMaps = requestMaps
        self.scripts = scripts
        self.ruleGroups = ruleGroups
        self.activeProfile = activeProfile
        self.hostEntries = hostEntries
        self.timestamp = Date()
    }

    public static let empty = ConfigSnapshot(
        rewriteRules: [],
        requestMaps: [],
        scripts: [],
        ruleGroups: [],
        activeProfile: nil,
        hostEntries: []
    )

    /// Returns the host override (IP + optional port) for a given URL, or nil if none matches.
    public func hostOverride(for url: String) -> (ip: String, port: Int?)? {
        guard let entry = hostEntries.first(where: { $0.matches(url) }) else {
            return nil
        }
        return (ip: entry.targetIP, port: entry.targetPort)
    }
}
