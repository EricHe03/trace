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
}
