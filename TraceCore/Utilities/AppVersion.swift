//
//  AppVersion.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Centralized app version information.
///
/// Version numbers are read from the app bundle's Info.plist at runtime,
/// ensuring consistency with Xcode project settings and App Store Connect.
///
/// - Important: When updating versions for release:
///   1. Update MARKETING_VERSION in Xcode project (applies to all targets)
///   2. Increment CURRENT_PROJECT_VERSION for each TestFlight/App Store build
///   3. All extensions (VPN, Widget) automatically share the main app's version
public enum AppVersion {
    /// The marketing version (CFBundleShortVersionString), e.g., "1.0.0"
    /// This is the version shown to users on the App Store.
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// The build number (CFBundleVersion), e.g., "1", "42"
    /// Must be incremented for each TestFlight/App Store submission.
    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Full version string for display, e.g., "1.0.0 (42)"
    public static var fullVersion: String {
        "\(version) (\(build))"
    }

    /// Semantic version components parsed from the marketing version.
    public static var major: Int {
        let components = version.split(separator: ".")
        return components.first.flatMap { Int($0) } ?? 1
    }

    public static var minor: Int {
        let components = version.split(separator: ".")
        return components.dropFirst().first.flatMap { Int($0) } ?? 0
    }

    public static var patch: Int {
        let components = version.split(separator: ".")
        return components.dropFirst(2).first.flatMap { Int($0) } ?? 0
    }
}
