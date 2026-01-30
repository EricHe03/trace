//
//  HardeningConfig.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import OSLog
import TraceCore

public struct HardeningConfigSnapshot: Sendable {
    public let enableRobustReassembly: Bool
    public let enableMetrics: Bool
    public let enableDebugLogging: Bool
    public let rolloutStage: String
    public let enableRawCapture: Bool
    public let maxRawCaptureSize: UInt64
    public let mitmAllowlist: [String]
    public let blockQUIC: Bool
    public let enableNetworkFrameworkMITM: Bool

    public func toDictionary() -> [String: Any] {
        [
            "enableRobustReassembly": enableRobustReassembly,
            "enableMetrics": enableMetrics,
            "enableDebugLogging": enableDebugLogging,
            "rolloutStage": rolloutStage,
            "enableRawCapture": enableRawCapture,
            "maxRawCaptureSize": maxRawCaptureSize,
            "mitmAllowlist": mitmAllowlist,
            "blockQUIC": blockQUIC,
            "enableNetworkFrameworkMITM": enableNetworkFrameworkMITM
        ]
    }
}

/// Provides configuration for proxy and capture features.
/// Allows runtime control of HTTP/HTTPS capture settings.
public actor HardeningConfig {
    public static let shared = HardeningConfig()

    private let defaults: UserDefaults?

    // MARK: - Configuration Keys

    private enum ConfigKey: String {
        case enableRobustReassembly = "hardening.enableRobustReassembly"
        case enableMetrics = "hardening.enableMetrics"
        case enableDebugLogging = "hardening.enableDebugLogging"
        case rolloutStage = "hardening.rolloutStage"
        case enableRawCapture = "hardening.enableRawCapture"
        case maxRawCaptureSize = "hardening.maxRawCaptureSize"
        case mitmAllowlist = "hardening.mitmAllowlist"
        case blockQUIC = "hardening.blockQUIC"
        case enableNetworkFrameworkMITM = "hardening.enableNetworkFrameworkMITM"
    }

    // MARK: - Rollout Stages

    public enum RolloutStage: String, Codable {
        /// Disables all features.
        case disabled
        /// Enables features for internal and debug builds only.
        case internalStage = "internal"
        /// Enables features for beta testers.
        case beta
        /// Enables features for all users.
        case production
    }

    // MARK: - Configuration State

    private var _enableRobustReassembly: Bool
    private var _enableMetrics: Bool
    private var _enableDebugLogging: Bool
    private var _rolloutStage: RolloutStage
    private var _enableRawCapture: Bool
    private var _maxRawCaptureSize: UInt64
    private var _mitmAllowlist: [String]
    private var _blockQUIC: Bool
    private var _enableNetworkFrameworkMITM: Bool

    // MARK: - Initialization

    private init() {
        let defaults = UserDefaults(suiteName: AppGroupConfiguration.appGroupIdentifier)
        self.defaults = defaults

        func sanitizeDomainPatterns(_ list: [String]) -> [String] {
            let cleaned = list
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return cleaned
        }

        func boolValue(_ key: ConfigKey, default defaultValue: Bool) -> Bool {
            if let stored = defaults?.object(forKey: key.rawValue) as? Bool {
                return stored
            }
            return defaultValue
        }

        _enableRobustReassembly = boolValue(.enableRobustReassembly, default: true)
        _enableMetrics = boolValue(.enableMetrics, default: true)
        _enableDebugLogging = boolValue(.enableDebugLogging, default: false)

        if let stageString = defaults?.string(forKey: ConfigKey.rolloutStage.rawValue),
           let stage = RolloutStage(rawValue: stageString) {
            _rolloutStage = stage
        } else {
            _rolloutStage = .production
        }

        _enableRawCapture = boolValue(.enableRawCapture, default: false)
        if let stored = defaults?.object(forKey: ConfigKey.maxRawCaptureSize.rawValue) as? NSNumber {
            _maxRawCaptureSize = stored.uint64Value
        } else {
            // Default is 10 MB.
            _maxRawCaptureSize = 10_485_760
        }

        if let data = defaults?.data(forKey: ConfigKey.mitmAllowlist.rawValue),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            _mitmAllowlist = sanitizeDomainPatterns(list)
        } else {
            _mitmAllowlist = ["*"]
        }

        _blockQUIC = boolValue(.blockQUIC, default: true)
        _enableNetworkFrameworkMITM = boolValue(.enableNetworkFrameworkMITM, default: true)

        // Rationale: Apply rollout stage restrictions inline to avoid actor isolation in init.
        switch _rolloutStage {
        case .disabled:
            _enableRobustReassembly = false
            _enableMetrics = false
            _enableDebugLogging = false

        case .internalStage:
            #if DEBUG
            _enableRobustReassembly = true
            _enableMetrics = true
            _enableDebugLogging = true
            #else
            _enableRobustReassembly = false
            _enableMetrics = false
            _enableDebugLogging = false
            #endif

        case .beta:
            _enableRobustReassembly = true
            _enableMetrics = true
            _enableDebugLogging = false

        case .production:
            _enableRobustReassembly = true
            _enableMetrics = true
            _enableDebugLogging = false
        }
    }

    // MARK: - Public API

    /// Returns whether robust reassembly logic is enabled.
    public var enableRobustReassembly: Bool {
        _enableRobustReassembly
    }

    /// Returns whether metrics collection is enabled.
    public var enableMetrics: Bool {
        _enableMetrics
    }

    /// Returns whether debug logging is enabled.
    public var enableDebugLogging: Bool {
        _enableDebugLogging
    }

    /// Returns the current rollout stage.
    public var rolloutStage: RolloutStage {
        _rolloutStage
    }

    /// Returns whether raw stream capture (PCAP) is enabled.
    public var enableRawCapture: Bool {
        _enableRawCapture
    }

    /// Returns the maximum size in bytes for raw capture.
    public var maxRawCaptureSize: UInt64 {
        _maxRawCaptureSize
    }

    /// Returns the MITM allowlisted hosts using suffix matching.
    public var mitmAllowlist: [String] {
        _mitmAllowlist
    }

    /// Returns whether QUIC (UDP/443) is blocked.
    public var blockQUIC: Bool {
        _blockQUIC
    }

    /// Returns whether Network.framework MITM is enabled.
    public var enableNetworkFrameworkMITM: Bool {
        _enableNetworkFrameworkMITM
    }

    // MARK: - Configuration Updates

    /// Updates the robust reassembly setting.
    public func setEnableRobustReassembly(_ enabled: Bool) {
        let allowed = isFeatureToggleAllowed(enabled)
        _enableRobustReassembly = allowed ? enabled : false
        defaults?.set(_enableRobustReassembly, forKey: ConfigKey.enableRobustReassembly.rawValue)
        if allowed {
            ProxyLog.mitm.info("event=config.reassembly_toggle outcome=success enabled=\(enabled)")
        } else {
            ProxyLog.mitm.warning("event=config.reassembly_toggle outcome=blocked enabled=\(enabled)")
        }
    }

    /// Updates the metrics collection setting.
    public func setEnableMetrics(_ enabled: Bool) {
        let allowed = isFeatureToggleAllowed(enabled)
        _enableMetrics = allowed ? enabled : false
        defaults?.set(_enableMetrics, forKey: ConfigKey.enableMetrics.rawValue)
        if allowed {
            ProxyLog.mitm.info("event=config.metrics_toggle outcome=success enabled=\(enabled)")
        } else {
            ProxyLog.mitm.warning("event=config.metrics_toggle outcome=blocked enabled=\(enabled)")
        }
    }

    /// Updates the debug logging setting.
    public func setEnableDebugLogging(_ enabled: Bool) {
        let allowed = isFeatureToggleAllowed(enabled)
        _enableDebugLogging = allowed ? enabled : false
        defaults?.set(_enableDebugLogging, forKey: ConfigKey.enableDebugLogging.rawValue)
        if allowed {
            ProxyLog.mitm.info("event=config.debug_logging_toggle outcome=success enabled=\(enabled)")
        } else {
            ProxyLog.mitm.warning("event=config.debug_logging_toggle outcome=blocked enabled=\(enabled)")
        }
    }

    /// Updates the rollout stage.
    public func setRolloutStage(_ stage: RolloutStage) {
        _rolloutStage = stage
        defaults?.set(stage.rawValue, forKey: ConfigKey.rolloutStage.rawValue)
        applyRolloutStage()
        ProxyLog.mitm.info("event=config.rollout_stage_set outcome=success stage=\(stage.rawValue, privacy: .public)")
    }

    /// Updates the raw capture setting.
    public func setEnableRawCapture(_ enabled: Bool) {
        _enableRawCapture = enabled
        defaults?.set(enabled, forKey: ConfigKey.enableRawCapture.rawValue)
        ProxyLog.mitm.info("event=config.raw_capture_toggle outcome=success enabled=\(enabled)")
    }

    /// Updates the maximum raw capture size.
    public func setMaxRawCaptureSize(_ size: UInt64) {
        _maxRawCaptureSize = size
        defaults?.set(size, forKey: ConfigKey.maxRawCaptureSize.rawValue)
        ProxyLog.mitm.info("event=config.max_capture_size_set outcome=success size=\(size)")
    }

    /// Updates the MITM allowlist (suffix patterns).
    public func setMitmAllowlist(_ list: [String]) {
        let sanitized = list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        _mitmAllowlist = sanitized
        if let data = try? JSONEncoder().encode(_mitmAllowlist) {
            defaults?.set(data, forKey: ConfigKey.mitmAllowlist.rawValue)
        }
        ProxyLog.mitm.info("event=config.allowlist_update outcome=success count=\(self._mitmAllowlist.count)")
    }

    /// Updates QUIC blocking.
    public func setBlockQUIC(_ enabled: Bool) {
        _blockQUIC = enabled
        defaults?.set(enabled, forKey: ConfigKey.blockQUIC.rawValue)
        ProxyLog.mitm.info("event=config.block_quic_toggle outcome=success enabled=\(enabled)")
    }

    /// Updates Network.framework MITM enablement.
    public func setEnableNetworkFrameworkMITM(_ enabled: Bool) {
        _enableNetworkFrameworkMITM = enabled
        defaults?.set(enabled, forKey: ConfigKey.enableNetworkFrameworkMITM.rawValue)
        ProxyLog.mitm.info("event=config.nw_mitm_toggle outcome=success enabled=\(enabled)")
    }

    /// Applies rollout stage restrictions.
    private func applyRolloutStage() {
        switch _rolloutStage {
        case .disabled:
            _enableRobustReassembly = false
            _enableMetrics = false
            _enableDebugLogging = false

        case .internalStage:
            #if DEBUG
            _enableRobustReassembly = true
            _enableMetrics = true
            _enableDebugLogging = true
            #else
            _enableRobustReassembly = false
            _enableMetrics = false
            _enableDebugLogging = false
            #endif

        case .beta:
            _enableRobustReassembly = true
            _enableMetrics = true
            _enableDebugLogging = false

        case .production:
            _enableRobustReassembly = true
            _enableMetrics = true
            _enableDebugLogging = false
        }
    }

    private func isFeatureToggleAllowed(_ enabled: Bool) -> Bool {
        guard enabled else { return true }
        switch _rolloutStage {
        case .disabled:
            return false
        case .internalStage:
            #if DEBUG
            return true
            #else
            return false
            #endif
        case .beta, .production:
            return true
        }
    }

    /// Resets all values to defaults.
    func resetToDefaults() {
        _rolloutStage = .production
        applyRolloutStage()

        _mitmAllowlist = ["*"]
        _blockQUIC = true
        _enableNetworkFrameworkMITM = true
        _enableRawCapture = false
        _maxRawCaptureSize = 10_485_760

        defaults?.set(_enableRobustReassembly, forKey: ConfigKey.enableRobustReassembly.rawValue)
        defaults?.set(_enableMetrics, forKey: ConfigKey.enableMetrics.rawValue)
        defaults?.set(_enableDebugLogging, forKey: ConfigKey.enableDebugLogging.rawValue)
        defaults?.set(_rolloutStage.rawValue, forKey: ConfigKey.rolloutStage.rawValue)
        if let data = try? JSONEncoder().encode(_mitmAllowlist) {
            defaults?.set(data, forKey: ConfigKey.mitmAllowlist.rawValue)
        }
        defaults?.set(_blockQUIC, forKey: ConfigKey.blockQUIC.rawValue)
        defaults?.set(_enableNetworkFrameworkMITM, forKey: ConfigKey.enableNetworkFrameworkMITM.rawValue)
        defaults?.set(_enableRawCapture, forKey: ConfigKey.enableRawCapture.rawValue)
        defaults?.set(_maxRawCaptureSize, forKey: ConfigKey.maxRawCaptureSize.rawValue)

        ProxyLog.mitm.info("event=config.reset_defaults outcome=success")
    }

    /// Returns the current configuration as a sendable snapshot.
    public func getCurrentConfig() -> HardeningConfigSnapshot {
        HardeningConfigSnapshot(
            enableRobustReassembly: _enableRobustReassembly,
            enableMetrics: _enableMetrics,
            enableDebugLogging: _enableDebugLogging,
            rolloutStage: _rolloutStage.rawValue,
            enableRawCapture: _enableRawCapture,
            maxRawCaptureSize: _maxRawCaptureSize,
            mitmAllowlist: _mitmAllowlist,
            blockQUIC: _blockQUIC,
            enableNetworkFrameworkMITM: _enableNetworkFrameworkMITM
        )
    }

    /// Logs the current configuration.
    public func logCurrentConfig() {
        ProxyLog.mitm.info("event=config.current stage=\(self._rolloutStage.rawValue, privacy: .public) reassembly=\(self._enableRobustReassembly) metrics=\(self._enableMetrics) debug=\(self._enableDebugLogging) raw_capture=\(self._enableRawCapture) max_size=\(self._maxRawCaptureSize) allowlist_count=\(self._mitmAllowlist.count) block_quic=\(self._blockQUIC) nw_mitm=\(self._enableNetworkFrameworkMITM)")
    }
}
