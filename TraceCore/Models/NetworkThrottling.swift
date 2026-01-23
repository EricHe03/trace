//
//  NetworkThrottling.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

// MARK: - Network Condition Profiles

/// Network condition simulation profiles
public enum NetworkCondition: Codable, Equatable, Hashable, Sendable {
    /// WiFi connection - high speed, low latency
    case wifi

    /// 5G cellular - very high speed, low latency
    case cellular5G

    /// 4G/LTE cellular - high speed, moderate latency
    case cellular4G

    /// 3G cellular - moderate speed, higher latency
    case cellular3G

    /// 2G/EDGE cellular - slow speed, high latency
    case cellular2G

    /// Satellite connection - moderate speed, very high latency
    case satellite

    /// Offline mode - no connectivity
    case offline

    /// Custom throttling with specific parameters
    case custom(download: Int, upload: Int, latency: Int, packetLoss: Double)

    /// Display name for UI
    public var displayName: String {
        switch self {
        case .wifi: "WiFi"
        case .cellular5G: "5G"
        case .cellular4G: "4G LTE"
        case .cellular3G: "3G"
        case .cellular2G: "2G/EDGE"
        case .satellite: "Satellite"
        case .offline: "Offline"
        case .custom: "Custom"
        }
    }

    /// Icon for UI display
    public var icon: String {
        switch self {
        case .wifi: "wifi"
        case .cellular5G: "antenna.radiowaves.left.and.right"
        case .cellular4G: "cellularbars"
        case .cellular3G: "cellularbars"
        case .cellular2G: "cellularbars"
        case .satellite: "antenna.radiowaves.left.and.right.circle"
        case .offline: "wifi.slash"
        case .custom: "slider.horizontal.3"
        }
    }

    /// Download speed in KB/s
    public var downloadSpeed: Int {
        switch self {
        case .wifi: 50000 // 50 MB/s
        case .cellular5G: 100_000 // 100 MB/s
        case .cellular4G: 10000 // 10 MB/s
        case .cellular3G: 750 // 750 KB/s
        case .cellular2G: 40 // 40 KB/s (EDGE)
        case .satellite: 2000 // 2 MB/s
        case .offline: 0
        case let .custom(download, _, _, _): download
        }
    }

    /// Upload speed in KB/s
    public var uploadSpeed: Int {
        switch self {
        case .wifi: 10000 // 10 MB/s
        case .cellular5G: 50000 // 50 MB/s
        case .cellular4G: 5000 // 5 MB/s
        case .cellular3G: 250 // 250 KB/s
        case .cellular2G: 20 // 20 KB/s
        case .satellite: 500 // 500 KB/s (asymmetric)
        case .offline: 0
        case let .custom(_, upload, _, _): upload
        }
    }

    /// Round-trip latency in milliseconds
    public var latency: Int {
        switch self {
        case .wifi: 2
        case .cellular5G: 10
        case .cellular4G: 50
        case .cellular3G: 100
        case .cellular2G: 300
        case .satellite: 600 // High latency for satellite
        case .offline: 0
        case let .custom(_, _, latency, _): latency
        }
    }

    /// Packet loss percentage (0.0 to 1.0)
    public var packetLoss: Double {
        switch self {
        case .wifi: 0.0
        case .cellular5G: 0.001 // 0.1%
        case .cellular4G: 0.005 // 0.5%
        case .cellular3G: 0.01 // 1%
        case .cellular2G: 0.03 // 3%
        case .satellite: 0.02 // 2%
        case .offline: 1.0 // 100% loss
        case let .custom(_, _, _, loss): loss
        }
    }

    /// Description for tooltip
    public var description: String {
        switch self {
        case .wifi:
            "Fast WiFi connection with minimal latency"
        case .cellular5G:
            "5G cellular network - very high speed, low latency"
        case .cellular4G:
            "4G/LTE cellular - high speed, moderate latency"
        case .cellular3G:
            "3G cellular - moderate speed, higher latency"
        case .cellular2G:
            "2G/EDGE cellular - slow speed, high latency"
        case .satellite:
            "Satellite connection - moderate speed, very high latency"
        case .offline:
            "No network connectivity - all requests will fail"
        case let .custom(down, up, lat, loss):
            "Custom: \(down) KB/s ↓, \(up) KB/s ↑, \(lat)ms latency, \(String(format: "%.1f%%", loss * 100)) loss"
        }
    }
}

// MARK: - Runtime Throttling State

/// Shared throttling state persisted across app + extension.
public struct NetworkThrottlingState: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var condition: NetworkCondition?

    public init(enabled: Bool, condition: NetworkCondition?) {
        self.enabled = enabled
        self.condition = condition
    }

    public static let disabled = NetworkThrottlingState(enabled: false, condition: nil)

    /// Returns the active condition only when throttling is enabled.
    public var activeCondition: NetworkCondition? {
        enabled ? condition : nil
    }

    /// Encode to a JSON dictionary for IPC with the tunnel provider.
    public func asJSONDictionary() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// Decode from a JSON dictionary for IPC with the tunnel provider.
    public static func fromJSONDictionary(_ dictionary: [String: Any]) -> NetworkThrottlingState? {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let state = try? JSONDecoder().decode(NetworkThrottlingState.self, from: data) else {
            return nil
        }
        return state
    }
}

// MARK: - Throttling Profile

/// A saved network throttling configuration
public struct ThrottlingProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var condition: NetworkCondition
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, condition: NetworkCondition, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.condition = condition
        self.enabled = enabled
    }

    /// Create a profile from a preset condition
    public static func preset(_ condition: NetworkCondition) -> ThrottlingProfile {
        ThrottlingProfile(
            name: condition.displayName,
            condition: condition,
            enabled: false
        )
    }

    /// Default preset profiles
    public static let presets: [ThrottlingProfile] = [
        .preset(.wifi),
        .preset(.cellular5G),
        .preset(.cellular4G),
        .preset(.cellular3G),
        .preset(.cellular2G),
        .preset(.satellite),
        .preset(.offline)
    ]
}

// MARK: - Throttling Configuration

/// Configuration for network throttling
public struct ThrottlingConfiguration: Codable, Sendable {
    /// Whether throttling is globally enabled
    public var enabled: Bool

    /// Currently active profile
    public var activeProfile: ThrottlingProfile?

    /// All saved custom profiles
    public var customProfiles: [ThrottlingProfile]

    public init(
        enabled: Bool = false,
        activeProfile: ThrottlingProfile? = nil,
        customProfiles: [ThrottlingProfile] = []
    ) {
        self.enabled = enabled
        self.activeProfile = activeProfile
        self.customProfiles = customProfiles
    }

    /// Get all profiles (presets + custom)
    public var allProfiles: [ThrottlingProfile] {
        ThrottlingProfile.presets + customProfiles
    }
}
