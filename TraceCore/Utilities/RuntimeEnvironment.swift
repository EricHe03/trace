//
//  RuntimeEnvironment.swift
//  TraceCore
//
//  Created by Justin on 2026/02/02.
//

import Foundation

public enum RuntimeEnvironment {
    /// Best-effort detection for running under XCTest.
    ///
    /// Note: This is intentionally conservative and uses the environment variable set by Xcode/xcodebuild.
    public static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    public static var isAppExtension: Bool {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            return true
        }
        return Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil
    }

    public static var isPacketTunnelExtension: Bool {
        guard isAppExtension else { return false }

        if let extensionInfo = Bundle.main.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
           let extensionPointID = extensionInfo["NSExtensionPointIdentifier"] as? String {
            return extensionPointID == "com.apple.networkextension.packet-tunnel"
        }

        return Bundle.main.bundleIdentifier?.contains("TraceVPN") == true
    }
}
