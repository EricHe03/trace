//
//  AppGroupConfiguration.swift
//  TraceCore
//

import Foundation

public enum AppGroupConfiguration {
    /// Centralized App Group identifier to keep the main app and extension in sync.
    public static let appGroupIdentifier: String = {
        // Allow overriding via Info.plist so release builds can set the correct group without code changes.
        if let infoIdentifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           let sanitized = sanitizeIdentifier(infoIdentifier) {
            return sanitized
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           !bundleIdentifier.isEmpty {
            return "group.\(bundleIdentifier)"
        }

        return "group.unknown"
    }()

    private static func sanitizeIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
        return trimmed
    }
}
