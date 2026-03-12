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
    public let timestamp: Date

    public init(
        rewriteRules: [RewriteRule],
        requestMaps: [RequestMap],
        scripts: [Script],
        ruleGroups: [RuleGroup],
        activeProfile: Profile?
    ) {
        self.rewriteRules = rewriteRules
        self.requestMaps = requestMaps
        self.scripts = scripts
        self.ruleGroups = ruleGroups
        self.activeProfile = activeProfile
        self.timestamp = Date()
    }

    public static let empty = ConfigSnapshot(
        rewriteRules: [],
        requestMaps: [],
        scripts: [],
        ruleGroups: [],
        activeProfile: nil
    )
}
