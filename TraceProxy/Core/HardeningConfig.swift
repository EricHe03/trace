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
    public let quicHandlingMode: String
    public let blockQUIC: Bool
    public let enableNIOMITM: Bool
    /// Legacy key kept for compatibility with older app payloads.
    public let enableNetworkFrameworkMITM: Bool
    public let dualMITMPolicyEngineShadow: Bool
    public let dualMITMPolicyEngineEnforcedTCP: Bool
    public let dualMITMPolicyEngineEnforcedProxy: Bool
    public let dualMITMPolicyEngineEnforcedQUIC: Bool
    public let dualMITMMITMEngineV2: Bool
    public let dualMITMHttp2MITMEnabled: Bool
    public let dualMITMStrictEnforcementHardFail: Bool

    public func toDictionary() -> [String: Any] {
        [
            "enableRobustReassembly": enableRobustReassembly,
            "enableMetrics": enableMetrics,
            "enableDebugLogging": enableDebugLogging,
            "rolloutStage": rolloutStage,
            "enableRawCapture": enableRawCapture,
            "maxRawCaptureSize": maxRawCaptureSize,
            "mitmAllowlist": mitmAllowlist,
            "quicHandlingMode": quicHandlingMode,
            "blockQUIC": blockQUIC,
            "enableNIOMITM": enableNIOMITM,
            "enableNetworkFrameworkMITM": enableNetworkFrameworkMITM,
            "dualMitmPolicyEngineShadow": dualMITMPolicyEngineShadow,
            "dualMitmPolicyEngineEnforcedTCP": dualMITMPolicyEngineEnforcedTCP,
            "dualMitmPolicyEngineEnforcedProxy": dualMITMPolicyEngineEnforcedProxy,
            "dualMitmPolicyEngineEnforcedQUIC": dualMITMPolicyEngineEnforcedQUIC,
            "dualMitmMITMEngineV2": dualMITMMITMEngineV2,
            "dualMitmHttp2MITMEnabled": dualMITMHttp2MITMEnabled,
            "dualMitmStrictEnforcementHardFail": dualMITMStrictEnforcementHardFail
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
        case quicHandlingMode = "hardening.quicHandlingMode"
        case blockQUIC = "hardening.blockQUIC"
        case enableNIOMITM = "hardening.enableNIOMITM"
        /// Legacy persisted key kept for backward compatibility.
        case enableNetworkFrameworkMITM = "hardening.enableNetworkFrameworkMITM"
        case dualMITMPolicyEngineShadow = "hardening.dualMitmPolicyEngineShadow"
        case dualMITMPolicyEngineEnforcedTCP = "hardening.dualMitmPolicyEngineEnforcedTCP"
        case dualMITMPolicyEngineEnforcedProxy = "hardening.dualMitmPolicyEngineEnforcedProxy"
        case dualMITMPolicyEngineEnforcedQUIC = "hardening.dualMitmPolicyEngineEnforcedQUIC"
        case dualMITMMITMEngineV2 = "hardening.dualMitmMITMEngineV2"
        case dualMITMHttp2MITMEnabled = "hardening.dualMitmHttp2MITMEnabled"
        case dualMITMStrictEnforcementHardFail = "hardening.dualMitmStrictEnforcementHardFail"
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
    private var _quicHandlingMode: QUICHandlingMode
    private var _blockQUIC: Bool
    private var _enableNIOMITM: Bool
    private var _dualMITMPolicyEngineShadow: Bool
    private var _dualMITMPolicyEngineEnforcedTCP: Bool
    private var _dualMITMPolicyEngineEnforcedProxy: Bool
    private var _dualMITMPolicyEngineEnforcedQUIC: Bool
    private var _dualMITMMITMEngineV2: Bool
    private var _dualMITMHttp2MITMEnabled: Bool
    private var _dualMITMStrictEnforcementHardFail: Bool

    // MARK: - Initialization

    private init() {
        let defaults = UserDefaults(suiteName: AppGroupConfiguration.appGroupIdentifier)
        self.defaults = defaults

        func sanitizeDomainPatterns(_ list: [String]) -> [String] {
            list
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
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

        if let modeRaw = defaults?.string(forKey: ConfigKey.quicHandlingMode.rawValue),
           let mode = QUICHandlingMode(rawValue: modeRaw) {
            _quicHandlingMode = mode
        } else if let storedBlockQUIC = defaults?.object(forKey: ConfigKey.blockQUIC.rawValue) as? Bool {
            _quicHandlingMode = storedBlockQUIC ? .block : .passThrough
        } else {
            // Default to intercept mode for the new QUIC/H3 path.
            _quicHandlingMode = .intercept
        }
        _blockQUIC = _quicHandlingMode.blocksQUIC
        if let stored = defaults?.object(forKey: ConfigKey.enableNIOMITM.rawValue) as? Bool {
            _enableNIOMITM = stored
        } else {
            _enableNIOMITM = boolValue(.enableNetworkFrameworkMITM, default: true)
        }

        #if DEBUG
        let defaultPolicyEngineShadow = true
        #else
        let defaultPolicyEngineShadow = false
        #endif
        _dualMITMPolicyEngineShadow = boolValue(.dualMITMPolicyEngineShadow, default: defaultPolicyEngineShadow)
        _dualMITMPolicyEngineEnforcedTCP = boolValue(.dualMITMPolicyEngineEnforcedTCP, default: false)
        _dualMITMPolicyEngineEnforcedProxy = boolValue(.dualMITMPolicyEngineEnforcedProxy, default: false)
        _dualMITMPolicyEngineEnforcedQUIC = boolValue(.dualMITMPolicyEngineEnforcedQUIC, default: false)
        _dualMITMMITMEngineV2 = boolValue(.dualMITMMITMEngineV2, default: false)
        _dualMITMHttp2MITMEnabled = boolValue(.dualMITMHttp2MITMEnabled, default: false)
        _dualMITMStrictEnforcementHardFail = boolValue(.dualMITMStrictEnforcementHardFail, default: true)

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

    /// Returns the active QUIC handling mode.
    public var quicHandlingMode: QUICHandlingMode {
        _quicHandlingMode
    }

    /// Returns whether QUIC (UDP/443) is blocked.
    public var blockQUIC: Bool {
        _quicHandlingMode.blocksQUIC
    }

    /// Returns whether NIO MITM is enabled.
    public var enableNIOMITM: Bool {
        _enableNIOMITM
    }

    /// Returns whether MITM is enabled (legacy key name).
    public var enableNetworkFrameworkMITM: Bool {
        _enableNIOMITM
    }

    /// Returns whether policy-engine shadow comparisons are enabled.
    public var dualMITMPolicyEngineShadow: Bool {
        _dualMITMPolicyEngineShadow
    }

    /// Returns whether policy-engine routing is enforced for TCP transparent flow starts.
    public var dualMITMPolicyEngineEnforcedTCP: Bool {
        _dualMITMPolicyEngineEnforcedTCP
    }

    /// Returns whether policy-engine routing is enforced for proxy MITM failover/gating.
    public var dualMITMPolicyEngineEnforcedProxy: Bool {
        _dualMITMPolicyEngineEnforcedProxy
    }

    /// Returns whether policy-engine routing is enforced for QUIC intercept failover.
    public var dualMITMPolicyEngineEnforcedQUIC: Bool {
        _dualMITMPolicyEngineEnforcedQUIC
    }

    /// Returns whether MITM engine v2 scaffolding path is enabled.
    public var dualMITMMITMEngineV2: Bool {
        _dualMITMMITMEngineV2
    }

    /// Returns whether HTTP/2 MITM is enabled for dual MITM mode.
    public var dualMITMHttp2MITMEnabled: Bool {
        _dualMITMHttp2MITMEnabled
    }

    /// Returns whether strict enforcement hard-fail behavior is enabled.
    public var dualMITMStrictEnforcementHardFail: Bool {
        _dualMITMStrictEnforcementHardFail
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
        setQUICHandlingMode(enabled ? .block : .passThrough)
    }

    /// Updates QUIC handling mode.
    public func setQUICHandlingMode(_ mode: QUICHandlingMode) {
        _quicHandlingMode = mode
        _blockQUIC = mode.blocksQUIC
        defaults?.set(mode.rawValue, forKey: ConfigKey.quicHandlingMode.rawValue)
        // Keep legacy key in sync for compatibility with older app payloads.
        defaults?.set(_blockQUIC, forKey: ConfigKey.blockQUIC.rawValue)
        ProxyLog.mitm.info(
            "event=config.quic_mode_set outcome=success mode=\(mode.rawValue, privacy: .public) block_quic=\(self._blockQUIC)"
        )
    }

    /// Updates MITM enablement for the NIO proxy engine.
    public func setEnableNIOMITM(_ enabled: Bool) {
        _enableNIOMITM = enabled
        defaults?.set(enabled, forKey: ConfigKey.enableNIOMITM.rawValue)
        // Maintain compatibility for older consumers still reading the legacy key.
        defaults?.set(enabled, forKey: ConfigKey.enableNetworkFrameworkMITM.rawValue)
        ProxyLog.mitm.info("event=config.nio_mitm_toggle outcome=success enabled=\(enabled)")
    }

    /// Updates MITM enablement using the legacy key name.
    public func setEnableNetworkFrameworkMITM(_ enabled: Bool) {
        setEnableNIOMITM(enabled)
    }

    public func setDualMITMPolicyEngineShadow(_ enabled: Bool) {
        _dualMITMPolicyEngineShadow = enabled
        defaults?.set(enabled, forKey: ConfigKey.dualMITMPolicyEngineShadow.rawValue)
        ProxyLog.mitm.info("event=config.dual_mitm_policy_shadow outcome=success enabled=\(enabled)")
    }

    public func setDualMITMPolicyEngineEnforcedTCP(_ enabled: Bool) {
        _dualMITMPolicyEngineEnforcedTCP = enabled
        defaults?.set(enabled, forKey: ConfigKey.dualMITMPolicyEngineEnforcedTCP.rawValue)
        ProxyLog.mitm.info("event=config.dual_mitm_policy_tcp_enforced outcome=success enabled=\(enabled)")
    }

    public func setDualMITMPolicyEngineEnforcedProxy(_ enabled: Bool) {
        _dualMITMPolicyEngineEnforcedProxy = enabled
        defaults?.set(enabled, forKey: ConfigKey.dualMITMPolicyEngineEnforcedProxy.rawValue)
        ProxyLog.mitm.info("event=config.dual_mitm_policy_proxy_enforced outcome=success enabled=\(enabled)")
    }

    public func setDualMITMPolicyEngineEnforcedQUIC(_ enabled: Bool) {
        _dualMITMPolicyEngineEnforcedQUIC = enabled
        defaults?.set(enabled, forKey: ConfigKey.dualMITMPolicyEngineEnforcedQUIC.rawValue)
        ProxyLog.mitm.info("event=config.dual_mitm_policy_quic_enforced outcome=success enabled=\(enabled)")
    }

    public func setDualMITMMITMEngineV2(_ enabled: Bool) {
        _dualMITMMITMEngineV2 = enabled
        defaults?.set(enabled, forKey: ConfigKey.dualMITMMITMEngineV2.rawValue)
        ProxyLog.mitm.info("event=config.dual_mitm_engine_v2 outcome=success enabled=\(enabled)")
    }

    public func setDualMITMHttp2MITMEnabled(_ enabled: Bool) {
        _dualMITMHttp2MITMEnabled = enabled
        defaults?.set(enabled, forKey: ConfigKey.dualMITMHttp2MITMEnabled.rawValue)
        ProxyLog.mitm.info("event=config.dual_mitm_http2_mitm outcome=success enabled=\(enabled)")
    }

    public func setDualMITMStrictEnforcementHardFail(_ enabled: Bool) {
        _dualMITMStrictEnforcementHardFail = enabled
        defaults?.set(enabled, forKey: ConfigKey.dualMITMStrictEnforcementHardFail.rawValue)
        ProxyLog.mitm.info("event=config.dual_mitm_strict_hard_fail outcome=success enabled=\(enabled)")
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
        _quicHandlingMode = .intercept
        _blockQUIC = _quicHandlingMode.blocksQUIC
        _enableNIOMITM = true
        #if DEBUG
        _dualMITMPolicyEngineShadow = true
        #else
        _dualMITMPolicyEngineShadow = false
        #endif
        _dualMITMPolicyEngineEnforcedTCP = false
        _dualMITMPolicyEngineEnforcedProxy = false
        _dualMITMPolicyEngineEnforcedQUIC = false
        _dualMITMMITMEngineV2 = false
        _dualMITMHttp2MITMEnabled = false
        _dualMITMStrictEnforcementHardFail = true
        _enableRawCapture = false
        _maxRawCaptureSize = 10_485_760

        defaults?.set(_enableRobustReassembly, forKey: ConfigKey.enableRobustReassembly.rawValue)
        defaults?.set(_enableMetrics, forKey: ConfigKey.enableMetrics.rawValue)
        defaults?.set(_enableDebugLogging, forKey: ConfigKey.enableDebugLogging.rawValue)
        defaults?.set(_rolloutStage.rawValue, forKey: ConfigKey.rolloutStage.rawValue)
        if let data = try? JSONEncoder().encode(_mitmAllowlist) {
            defaults?.set(data, forKey: ConfigKey.mitmAllowlist.rawValue)
        }
        defaults?.set(_quicHandlingMode.rawValue, forKey: ConfigKey.quicHandlingMode.rawValue)
        defaults?.set(_blockQUIC, forKey: ConfigKey.blockQUIC.rawValue)
        defaults?.set(_enableNIOMITM, forKey: ConfigKey.enableNIOMITM.rawValue)
        defaults?.set(_enableNIOMITM, forKey: ConfigKey.enableNetworkFrameworkMITM.rawValue)
        defaults?.set(_dualMITMPolicyEngineShadow, forKey: ConfigKey.dualMITMPolicyEngineShadow.rawValue)
        defaults?.set(_dualMITMPolicyEngineEnforcedTCP, forKey: ConfigKey.dualMITMPolicyEngineEnforcedTCP.rawValue)
        defaults?.set(_dualMITMPolicyEngineEnforcedProxy, forKey: ConfigKey.dualMITMPolicyEngineEnforcedProxy.rawValue)
        defaults?.set(_dualMITMPolicyEngineEnforcedQUIC, forKey: ConfigKey.dualMITMPolicyEngineEnforcedQUIC.rawValue)
        defaults?.set(_dualMITMMITMEngineV2, forKey: ConfigKey.dualMITMMITMEngineV2.rawValue)
        defaults?.set(_dualMITMHttp2MITMEnabled, forKey: ConfigKey.dualMITMHttp2MITMEnabled.rawValue)
        defaults?.set(_dualMITMStrictEnforcementHardFail, forKey: ConfigKey.dualMITMStrictEnforcementHardFail.rawValue)
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
            quicHandlingMode: _quicHandlingMode.rawValue,
            blockQUIC: _quicHandlingMode.blocksQUIC,
            enableNIOMITM: _enableNIOMITM,
            enableNetworkFrameworkMITM: _enableNIOMITM,
            dualMITMPolicyEngineShadow: _dualMITMPolicyEngineShadow,
            dualMITMPolicyEngineEnforcedTCP: _dualMITMPolicyEngineEnforcedTCP,
            dualMITMPolicyEngineEnforcedProxy: _dualMITMPolicyEngineEnforcedProxy,
            dualMITMPolicyEngineEnforcedQUIC: _dualMITMPolicyEngineEnforcedQUIC,
            dualMITMMITMEngineV2: _dualMITMMITMEngineV2,
            dualMITMHttp2MITMEnabled: _dualMITMHttp2MITMEnabled,
            dualMITMStrictEnforcementHardFail: _dualMITMStrictEnforcementHardFail
        )
    }

    /// Logs the current configuration.
    public func logCurrentConfig() {
        ProxyLog.mitm.info(
            "event=config.current stage=\(self._rolloutStage.rawValue, privacy: .public) reassembly=\(self._enableRobustReassembly) metrics=\(self._enableMetrics) debug=\(self._enableDebugLogging) raw_capture=\(self._enableRawCapture) max_size=\(self._maxRawCaptureSize) allowlist_count=\(self._mitmAllowlist.count) quic_mode=\(self._quicHandlingMode.rawValue, privacy: .public) block_quic=\(self._quicHandlingMode.blocksQUIC) nio_mitm=\(self._enableNIOMITM) dual_mitm_policy_shadow=\(self._dualMITMPolicyEngineShadow) dual_mitm_policy_tcp_enforced=\(self._dualMITMPolicyEngineEnforcedTCP) dual_mitm_policy_proxy_enforced=\(self._dualMITMPolicyEngineEnforcedProxy) dual_mitm_policy_quic_enforced=\(self._dualMITMPolicyEngineEnforcedQUIC) dual_mitm_engine_v2=\(self._dualMITMMITMEngineV2) dual_mitm_http2_mitm=\(self._dualMITMHttp2MITMEnabled) dual_mitm_strict_hard_fail=\(self._dualMITMStrictEnforcementHardFail)"
        )
    }
}
