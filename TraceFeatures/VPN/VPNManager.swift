//
//  VPNManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
import NetworkExtension
#if canImport(TraceCore)
import TraceCore
#endif

@MainActor
public protocol VPNManaging: AnyObject {
    var isConnected: Bool { get }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { get }
    func start() async throws
    func stop()
}

/// Manages the VPN connection lifecycle for packet capture
@MainActor
public final class VPNManager: ObservableObject, VPNManaging {
    public static let shared = VPNManager()

    // VPN connection status
    @Published public private(set) var status: NEVPNStatus = .invalid
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isSimulator: Bool = false

    /// Whether the VPN has been initialized (configuration loaded/created)
    @Published private(set) var isInitialized: Bool = false

    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: Any?

    private init() {
        checkSimulator()
        // Don't call setupVPN() here - it will be called lazily when needed
        // This prevents the VPN permission popup from appearing immediately on app launch
        observeStatus()
    }

    /// Initializes the VPN by loading existing configuration (if any).
    /// This does NOT create a new configuration or trigger the permission popup.
    /// Call this when the app needs to check VPN status without prompting the user.
    public func initializeIfNeeded() {
        guard !isInitialized && !isSimulator else { return }

        Task {
            do {
                try await loadExistingVPNConfiguration()
                await MainActor.run {
                    isInitialized = true
                }
            } catch {
                // No existing configuration found, that's fine
                // The configuration will be created when user explicitly requests it
                FeatureLog.vpn.info("event=vpn.config_load outcome=skipped reason=no_existing_config")
                await MainActor.run {
                    isInitialized = true
                }
            }
        }
    }

    /// Loads existing VPN configuration without creating a new one.
    /// - Throws: Error if loading fails
    private func loadExistingVPNConfiguration() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        if let existing = managers.first(where: { $0.localizedDescription == "Trace Network Debugger" }) {
            try await applyProtocolRoutingDefaults(to: existing)
            tunnelManager = existing
            FeatureLog.vpn.info("event=vpn.config_load outcome=success")
            updateStatus()
        }
        // If no existing configuration found, don't create one - just return
    }

    public var isConnectedPublisher: AnyPublisher<Bool, Never> {
        $isConnected.eraseToAnyPublisher()
    }

    // MARK: - Simulator Detection

    private func checkSimulator() {
        #if targetEnvironment(simulator)
        isSimulator = true
        errorMessage = "VPN Network Extensions cannot run in iOS Simulator. Please test on a real device."
        FeatureLog.vpn.warning("event=vpn.init outcome=skipped reason=simulator")
        #else
        isSimulator = false
        #endif
    }

    // MARK: - VPN Setup

    /// Sets up the VPN configuration (legacy method, kept for compatibility)
    /// Prefer using initializeIfNeeded() for loading and requestVPNPermission() for creating
    private func setupVPN() {
        // Skip VPN setup in simulator
        if isSimulator {
            FeatureLog.vpn.warning("event=vpn.setup outcome=skipped reason=simulator")
            return
        }

        Task {
            do {
                try await loadOrCreateVPNConfiguration()
                await MainActor.run {
                    isInitialized = true
                }
            } catch {
                self.errorMessage = "Failed to setup VPN: \(error.localizedDescription)"
                FeatureLog.vpn.error("event=vpn.setup outcome=failure error=\(error.localizedDescription, privacy: .public)")

                // Provide helpful error messages
                if let nsError = error as NSError? {
                    if nsError.domain == "NEVPNErrorDomain" && nsError.code == 5 {
                        FeatureLog.vpn.warning("event=vpn.setup outcome=failure reason=ipc_failed hint=check_entitlements_or_use_real_device")
                    }
                }
                await MainActor.run {
                    isInitialized = true
                }
            }
        }
    }

    /// Loads existing VPN configuration or creates a new one
    /// This triggers the iOS permission prompt if no configuration exists
    private func loadOrCreateVPNConfiguration() async throws {
        // ✅ Step 1: Load all existing VPN configurations from system preferences
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        if let existing = managers.first(where: { $0.localizedDescription == "Trace Network Debugger" }) {
            // Found existing configuration - use it
            try await applyProtocolRoutingDefaults(to: existing)
            tunnelManager = existing
            FeatureLog.vpn.info("event=vpn.config_load outcome=success source=existing")
        } else {
            // No existing configuration found - create a new one
            // This will trigger the iOS permission prompt on first save
            try await createVPNConfiguration()
        }

        // Update connection status
        updateStatus()
    }

    /// Creates a new VPN configuration
    /// This follows the documented workflow: load → configure → save
    /// The saveToPreferences() call triggers the iOS system permission prompt
    private func createVPNConfiguration() async throws {
        let manager = NETunnelProviderManager()

        // IMPORTANT: Must load from preferences BEFORE configuring
        // This is required by Apple's NetworkExtension framework
        try await manager.loadFromPreferences()

        // Configure the protocol
        let protocolConfiguration = NETunnelProviderProtocol()

        // IMPORTANT: This must match your Network Extension's bundle identifier
        protocolConfiguration.providerBundleIdentifier = "com.justin.trace.vpn"

        // Server address (required but not used for local VPN)
        protocolConfiguration.serverAddress = "Trace Local VPN"

        // Configuration dictionary passed to the extension
        protocolConfiguration.providerConfiguration = [
            "version": "1.0",
            "proxyPort": 8888
        ]
        let routingDefaults = desiredRoutingDefaults()
        protocolConfiguration.includeAllNetworks = routingDefaults.includeAllNetworks
        protocolConfiguration.excludeLocalNetworks = routingDefaults.excludeLocalNetworks
        // Keep the tunnel running during device sleep (avoid stop reason: sleep).
        protocolConfiguration.disconnectOnSleep = false

        manager.protocolConfiguration = protocolConfiguration
        manager.localizedDescription = "Trace Network Debugger"

        // Enable on demand if desired
        manager.isOnDemandEnabled = false

        // IMPORTANT: Must set isEnabled = true before saving
        // This is required for the VPN configuration to be active
        manager.isEnabled = true

        // ✅ THIS LINE triggers the iOS permission popup on first save:
        // "Trace would like to add VPN configurations"
        // Allow / Don't Allow
        try await manager.saveToPreferences()

        // Store the configured manager
        tunnelManager = manager

        FeatureLog.vpn.info("event=vpn.config_create outcome=success")
    }

    private func applyProtocolRoutingDefaults(to manager: NETunnelProviderManager) async throws {
        guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            return
        }

        // IMPORTANT:
        // Saving VPN preferences while the tunnel is active can trigger reassert/reconnect cycles.
        // Only persist defaults when we're safely disconnected.
        let status = manager.connection.status
        if status == .connected || status == .connecting || status == .reasserting || status == .disconnecting {
            FeatureLog.vpn.debug("event=vpn.config_update outcome=skipped reason=tunnel_active status=\(status.description, privacy: .public)")
            return
        }

        var needsSave = false

        let routingDefaults = desiredRoutingDefaults()

        if protocolConfiguration.includeAllNetworks != routingDefaults.includeAllNetworks {
            protocolConfiguration.includeAllNetworks = routingDefaults.includeAllNetworks
            needsSave = true
        }

        if protocolConfiguration.excludeLocalNetworks != routingDefaults.excludeLocalNetworks {
            protocolConfiguration.excludeLocalNetworks = routingDefaults.excludeLocalNetworks
            needsSave = true
        }

        // Avoid disconnects on device sleep.
        if protocolConfiguration.disconnectOnSleep != false {
            protocolConfiguration.disconnectOnSleep = false
            needsSave = true
        }

        guard needsSave else { return }
        manager.protocolConfiguration = protocolConfiguration
        FeatureLog.vpn.info(
            "event=vpn.config_update outcome=success changes=routing_defaults include_all=\(routingDefaults.includeAllNetworks) exclude_local=\(routingDefaults.excludeLocalNetworks)"
        )
        try await manager.saveToPreferences()
    }

    private func desiredRoutingDefaults() -> (includeAllNetworks: Bool, excludeLocalNetworks: Bool) {
        let mode = AppGroupStorage.shared.loadConfiguration().captureMode
        switch mode {
        case .proxyOnly:
            return (includeAllNetworks: false, excludeLocalNetworks: false)
        case .fullTunnel:
            return (includeAllNetworks: true, excludeLocalNetworks: true)
        }
    }

    /// Refreshes routing defaults based on the latest capture mode.
    ///
    /// - Note: Updates are skipped if the tunnel is active to avoid reassert cycles.
    public func refreshRoutingDefaultsIfNeeded() async {
        if tunnelManager == nil {
            try? await loadExistingVPNConfiguration()
        }

        guard let manager = tunnelManager else {
            FeatureLog.vpn.debug("event=vpn.routing_defaults_refresh outcome=skipped reason=no_manager")
            return
        }

        do {
            try await applyProtocolRoutingDefaults(to: manager)
            FeatureLog.vpn.info("event=vpn.routing_defaults_refresh outcome=success")
        } catch {
            FeatureLog.vpn.error(
                "event=vpn.routing_defaults_refresh outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - VPN Permission

    /// Requests VPN permission by creating and saving VPN configuration
    ///
    /// ✅ This triggers the iOS system permission prompt:
    /// "Trace would like to add VPN configurations"
    /// Allow / Don't Allow
    ///
    /// The prompt is shown by iOS when saveToPreferences() is called for the first time.
    /// Subsequent calls to saveToPreferences() will NOT show the prompt again unless
    /// the VPN configuration is removed from Settings.
    ///
    /// - Throws: VPNError if the VPN cannot be configured (e.g., running in simulator)
    public func requestVPNPermission() async throws {
        // VPN Network Extensions do not work in iOS Simulator
        if isSimulator {
            throw VPNError.simulatorNotSupported
        }

        // If already configured, no need to request again
        if tunnelManager != nil {
            FeatureLog.vpn.info("event=vpn.permission_request outcome=skipped reason=already_configured")
            return
        }

        // ✅ Create and save the configuration - this triggers the system permission prompt
        try await createVPNConfiguration()
    }

    // MARK: - VPN Control

    /// Starts the VPN connection
    ///
    /// This follows the standard workflow documented by Apple:
    /// 1. Load current configuration from preferences
    /// 2. Start the VPN tunnel connection
    ///
    /// - Throws: VPNError if VPN is not configured or cannot be started
    public func start() async throws {
        FeatureLog.vpn.info("event=vpn.start_begin")

        // VPN Network Extensions do not work in iOS Simulator
        if isSimulator {
            FeatureLog.vpn.error("event=vpn.start outcome=failure reason=simulator_not_supported")
            throw VPNError.simulatorNotSupported
        }

        // If we haven't initialized yet, attempt to load an existing configuration
        // (without prompting) so "Start Capture" works reliably after app launch.
        if tunnelManager == nil {
            do {
                try await loadExistingVPNConfiguration()
            } catch {
                FeatureLog.vpn.warning(
                    "event=vpn.start_config_load outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
                isInitialized = true
                throw error
            }
            isInitialized = true
        }

        guard let manager = tunnelManager else {
            FeatureLog.vpn.error("event=vpn.start outcome=failure reason=not_configured")
            throw VPNError.notConfigured
        }

        // Guard against repeated start calls (can lead to reconnect/reassert loops).
        let currentStatus = manager.connection.status
        if currentStatus == .connected || currentStatus == .connecting || currentStatus == .reasserting || currentStatus == .disconnecting {
            FeatureLog.vpn.debug("event=vpn.start outcome=skipped reason=already_active status=\(currentStatus.description, privacy: .public)")
            return
        }

        FeatureLog.vpn.info("event=vpn.start_load_preferences")
        // ✅ Always load from preferences before starting
        // This ensures we have the latest configuration from system preferences
        try await manager.loadFromPreferences()
        FeatureLog.vpn.info("event=vpn.start_preferences_loaded is_enabled=\(manager.isEnabled)")

        // If another VPN was enabled recently, iOS may have disabled this configuration.
        // Re-enable and persist before starting to avoid start failures.
        if !manager.isEnabled {
            FeatureLog.vpn.warning("event=vpn.start_enable_config outcome=pending")
            manager.isEnabled = true
            do {
                try await manager.saveToPreferences()
                FeatureLog.vpn.info("event=vpn.start_enable_config outcome=success")
                try await manager.loadFromPreferences()
            } catch {
                FeatureLog.vpn.error(
                    "event=vpn.start_enable_config outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }

        // ✅ Start the VPN tunnel
        // This will call startTunnel() in PacketTunnelProvider
        FeatureLog.vpn.info("event=vpn.start_tunnel_begin")
        do {
            try manager.connection.startVPNTunnel()
            FeatureLog.vpn.info("event=vpn.start outcome=pending tunnel_start_called=true")
        } catch {
            FeatureLog.vpn.error("event=vpn.start outcome=failure error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Stops the VPN connection
    public func stop() {
        FeatureLog.vpn.info("event=vpn.stop_begin current_status=\(self.status.description, privacy: .public)")

        guard let manager = tunnelManager else {
            FeatureLog.vpn.warning("event=vpn.stop outcome=skipped reason=no_tunnel_manager")
            return
        }

        let currentStatus = manager.connection.status
        FeatureLog.vpn.info("event=vpn.stop_tunnel current_status=\(currentStatus.description, privacy: .public)")
        manager.connection.stopVPNTunnel()

        FeatureLog.vpn.info("event=vpn.stop outcome=pending stop_called=true")
    }

    /// Sends a message to the Network Extension
    public func sendMessage(_ message: [String: Any]) async throws -> Data? {
        guard let manager = tunnelManager,
              let session = manager.connection as? NETunnelProviderSession else {
            throw VPNError.notConfigured
        }

        let data = try JSONSerialization.data(withJSONObject: message)

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Sends the latest throttling state to the Network Extension if connected.
    public func updateThrottlingState(_ state: NetworkThrottlingState) async {
        guard isConnected else { return }
        guard let stateDict = state.asJSONDictionary() else { return }

        let message: [String: Any] = [
            "command": "updateThrottlingState",
            "state": stateDict
        ]

        try? await sendMessage(message)
    }

    // MARK: - Status Observation

    /// Observes VPN status changes
    private func observeStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatus()
        }
    }

    /// Updates the current VPN status
    private func updateStatus() {
        let previousStatus = status
        let wasConnected = isConnected

        guard let connection = tunnelManager?.connection else {
            status = .invalid
            isConnected = false
            FeatureLog.vpn.warning("event=vpn.status_update no_connection=true previous_status=\(previousStatus.description, privacy: .public)")
            return
        }

        status = connection.status
        isConnected = connection.status == .connected

        // Log status transitions with previous state for debugging
        let statusChanged = previousStatus != status
        let connectionChanged = wasConnected != isConnected

        // Update widget with capture state
        #if canImport(WidgetKit)
        Task { @MainActor in
            WidgetDataManager.shared.notifyCaptureStateChanged(isCapturing: isConnected)
        }
        #endif

        // Log status changes with detailed transition info
        switch status {
        case .invalid:
            FeatureLog.vpn.warning("event=vpn.status_change status=invalid previous=\(previousStatus.description, privacy: .public) status_changed=\(statusChanged)")
        case .disconnected:
            // This is important - log when VPN disconnects unexpectedly
            if wasConnected {
                FeatureLog.vpn.error("event=vpn.status_change status=disconnected previous=\(previousStatus.description, privacy: .public) was_connected=\(wasConnected) UNEXPECTED_DISCONNECT=true")
            } else {
                FeatureLog.vpn.info("event=vpn.status_change status=disconnected previous=\(previousStatus.description, privacy: .public)")
            }
        case .connecting:
            FeatureLog.vpn.info("event=vpn.status_change status=connecting previous=\(previousStatus.description, privacy: .public)")
        case .connected:
            FeatureLog.vpn.info("event=vpn.status_change status=connected previous=\(previousStatus.description, privacy: .public)")
            Task {
                let state = AppGroupStorage.shared.loadThrottlingState()
                await updateThrottlingState(state)
            }
        case .reasserting:
            FeatureLog.vpn.warning("event=vpn.status_change status=reasserting previous=\(previousStatus.description, privacy: .public) connection_changed=\(connectionChanged)")
        case .disconnecting:
            FeatureLog.vpn.info("event=vpn.status_change status=disconnecting previous=\(previousStatus.description, privacy: .public)")
        @unknown default:
            FeatureLog.vpn.warning("event=vpn.status_change status=unknown previous=\(previousStatus.description, privacy: .public)")
        }
    }

    // MARK: - Status Helpers

    public var statusText: String {
        switch status {
        case .invalid: return "Not Configured"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting..."
        case .disconnecting: return "Disconnecting..."
        @unknown default: return "Unknown"
        }
    }

    public var statusColor: String {
        switch status {
        case .connected: return "green"
        case .connecting, .reasserting: return "yellow"
        case .disconnected, .disconnecting: return "red"
        case .invalid: return "gray"
        @unknown default: return "gray"
        }
    }
}

// MARK: - VPN Error

public enum VPNError: LocalizedError, Equatable {
    case notConfigured
    case permissionDenied
    case connectionFailed(Error)
    case simulatorNotSupported

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "VPN not configured. Open Settings → Show Onboarding to add it."
        case .permissionDenied:
            "VPN permission denied. Please allow VPN access in Settings."
        case let .connectionFailed(error):
            "VPN connection failed: \(error.localizedDescription)"
        case .simulatorNotSupported:
            "VPN Network Extensions are not supported in iOS Simulator. Please test on a real device."
        }
    }

    public static func == (lhs: VPNError, rhs: VPNError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured),
             (.permissionDenied, .permissionDenied),
             (.simulatorNotSupported, .simulatorNotSupported):
            true
        case let (.connectionFailed(lhsError), .connectionFailed(rhsError)):
            lhsError.localizedDescription == rhsError.localizedDescription
        default:
            false
        }
    }
}

// MARK: - NEVPNStatus Extension

public extension NEVPNStatus {
    var description: String {
        switch self {
        case .invalid: return "Invalid"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reasserting"
        case .disconnecting: return "Disconnecting"
        @unknown default: return "Unknown"
        }
    }
}
