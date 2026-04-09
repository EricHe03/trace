//
//  TraceIdentifiers.swift
//  TraceCore
//
//  Created by Justin on 2026/02/04.
//

import Foundation

// MARK: - UserDefaults Keys

public enum TraceUserDefaultsKey {
    /// Tracks whether the user has completed onboarding.
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"
}

// MARK: - Quick Actions

public enum TraceQuickActionType {
    public static let startCapture = "com.trace.startCapture"
    public static let stopCapture = "com.trace.stopCapture"
    public static let viewLastSession = "com.trace.viewLastSession"
    public static let exportData = "com.trace.exportData"
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when onboarding completes, used to defer VPN setup/permission prompts.
    static let onboardingCompleted = Notification.Name("onboardingCompleted")

    /// Posted to request the app open a specific tab.
    static let openTab = Notification.Name("com.trace.openTab")

    /// Posted to request the app show favorites (typically after opening the Network tab).
    static let showFavorites = Notification.Name("com.trace.showFavorites")

    /// Posted when a push/local notification action requests opening a specific request.
    static let viewRequest = Notification.Name("viewRequest")

    /// Posted when favorites are updated cross-process.
    static let favoritesUpdated = Notification.Name("com.trace.favoritesUpdated")

    /// Posted when hosts entries are updated cross-process.
    static let hostsUpdated = Notification.Name("com.trace.hostsUpdated")

    /// Posted when rewrite rules change within the current process.
    static let rewriteRulesUpdated = Notification.Name("com.trace.rewriteRulesUpdated")

    /// Posted when request maps change within the current process.
    static let requestMapsUpdated = Notification.Name("com.trace.requestMapsUpdated")

    /// Posted when scripts change within the current process.
    static let scriptsUpdated = Notification.Name("com.trace.scriptsUpdated")

    /// Posted when rule groups change within the current process.
    static let ruleGroupsUpdated = Notification.Name("com.trace.ruleGroupsUpdated")

    /// Posted when profiles change within the current process.
    static let profilesUpdated = Notification.Name("com.trace.profilesUpdated")

    /// Posted when breakpoint presets change within the current process.
    static let breakpointPresetsUpdated = Notification.Name("com.trace.breakpointPresetsUpdated")

    /// Posted when DNS repository content changes.
    static let dnsRepositoryDidChange = Notification.Name("com.trace.dnsRepositoryDidChange")
}

// MARK: - Onboarding State

public enum OnboardingState {
    public static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: TraceUserDefaultsKey.hasCompletedOnboarding)
    }
}
