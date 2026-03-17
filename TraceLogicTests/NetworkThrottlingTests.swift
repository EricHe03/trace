//
//  NetworkThrottlingTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

final class NetworkThrottlingTests: XCTestCase {
    // MARK: - NetworkCondition Tests

    func testNetworkConditionDisplayNames() {
        XCTAssertEqual(NetworkCondition.wifi.displayName, "WiFi")
        XCTAssertEqual(NetworkCondition.cellular5G.displayName, "5G")
        XCTAssertEqual(NetworkCondition.cellular4G.displayName, "4G LTE")
        XCTAssertEqual(NetworkCondition.cellular3G.displayName, "3G")
        XCTAssertEqual(NetworkCondition.cellular2G.displayName, "2G/EDGE")
        XCTAssertEqual(NetworkCondition.satellite.displayName, "Satellite")
        XCTAssertEqual(NetworkCondition.offline.displayName, "Offline")
        XCTAssertEqual(NetworkCondition.custom(download: 100, upload: 50, latency: 10, packetLoss: 0.01).displayName, "Custom")
    }

    func testNetworkConditionIcons() {
        XCTAssertEqual(NetworkCondition.wifi.icon, "wifi")
        XCTAssertEqual(NetworkCondition.cellular5G.icon, "antenna.radiowaves.left.and.right")
        XCTAssertEqual(NetworkCondition.cellular4G.icon, "cellularbars")
        XCTAssertEqual(NetworkCondition.cellular3G.icon, "cellularbars")
        XCTAssertEqual(NetworkCondition.cellular2G.icon, "cellularbars")
        XCTAssertEqual(NetworkCondition.satellite.icon, "antenna.radiowaves.left.and.right.circle")
        XCTAssertEqual(NetworkCondition.offline.icon, "wifi.slash")
        XCTAssertEqual(NetworkCondition.custom(download: 100, upload: 50, latency: 10, packetLoss: 0.01).icon, "slider.horizontal.3")
    }

    func testNetworkConditionDownloadSpeed() {
        XCTAssertEqual(NetworkCondition.wifi.downloadSpeed, 50000)
        XCTAssertEqual(NetworkCondition.cellular5G.downloadSpeed, 100_000)
        XCTAssertEqual(NetworkCondition.cellular4G.downloadSpeed, 10000)
        XCTAssertEqual(NetworkCondition.cellular3G.downloadSpeed, 750)
        XCTAssertEqual(NetworkCondition.cellular2G.downloadSpeed, 40)
        XCTAssertEqual(NetworkCondition.satellite.downloadSpeed, 2000)
        XCTAssertEqual(NetworkCondition.offline.downloadSpeed, 0)
        XCTAssertEqual(NetworkCondition.custom(download: 1234, upload: 50, latency: 10, packetLoss: 0.01).downloadSpeed, 1234)
    }

    func testNetworkConditionUploadSpeed() {
        XCTAssertEqual(NetworkCondition.wifi.uploadSpeed, 10000)
        XCTAssertEqual(NetworkCondition.cellular5G.uploadSpeed, 50000)
        XCTAssertEqual(NetworkCondition.cellular4G.uploadSpeed, 5000)
        XCTAssertEqual(NetworkCondition.cellular3G.uploadSpeed, 250)
        XCTAssertEqual(NetworkCondition.cellular2G.uploadSpeed, 20)
        XCTAssertEqual(NetworkCondition.satellite.uploadSpeed, 500)
        XCTAssertEqual(NetworkCondition.offline.uploadSpeed, 0)
        XCTAssertEqual(NetworkCondition.custom(download: 100, upload: 567, latency: 10, packetLoss: 0.01).uploadSpeed, 567)
    }

    func testNetworkConditionLatency() {
        XCTAssertEqual(NetworkCondition.wifi.latency, 2)
        XCTAssertEqual(NetworkCondition.cellular5G.latency, 10)
        XCTAssertEqual(NetworkCondition.cellular4G.latency, 50)
        XCTAssertEqual(NetworkCondition.cellular3G.latency, 100)
        XCTAssertEqual(NetworkCondition.cellular2G.latency, 300)
        XCTAssertEqual(NetworkCondition.satellite.latency, 600)
        XCTAssertEqual(NetworkCondition.offline.latency, 0)
        XCTAssertEqual(NetworkCondition.custom(download: 100, upload: 50, latency: 42, packetLoss: 0.01).latency, 42)
    }

    func testNetworkConditionPacketLoss() {
        XCTAssertEqual(NetworkCondition.wifi.packetLoss, 0.0)
        XCTAssertEqual(NetworkCondition.cellular5G.packetLoss, 0.001)
        XCTAssertEqual(NetworkCondition.cellular4G.packetLoss, 0.005)
        XCTAssertEqual(NetworkCondition.cellular3G.packetLoss, 0.01)
        XCTAssertEqual(NetworkCondition.cellular2G.packetLoss, 0.03)
        XCTAssertEqual(NetworkCondition.satellite.packetLoss, 0.02)
        XCTAssertEqual(NetworkCondition.offline.packetLoss, 1.0)
        XCTAssertEqual(NetworkCondition.custom(download: 100, upload: 50, latency: 10, packetLoss: 0.123).packetLoss, 0.123)
    }

    func testNetworkConditionDescription() {
        XCTAssertTrue(NetworkCondition.wifi.description.contains("WiFi"))
        XCTAssertTrue(NetworkCondition.cellular5G.description.contains("5G"))
        XCTAssertTrue(NetworkCondition.cellular4G.description.contains("4G"))
        XCTAssertTrue(NetworkCondition.cellular3G.description.contains("3G"))
        XCTAssertTrue(NetworkCondition.cellular2G.description.contains("2G"))
        XCTAssertTrue(NetworkCondition.satellite.description.contains("Satellite"))
        XCTAssertTrue(NetworkCondition.offline.description.contains("No network"))
        XCTAssertTrue(NetworkCondition.custom(download: 100, upload: 50, latency: 42, packetLoss: 0.05).description.contains("100 KB/s"))
        XCTAssertTrue(NetworkCondition.custom(download: 100, upload: 50, latency: 42, packetLoss: 0.05).description.contains("50 KB/s"))
        XCTAssertTrue(NetworkCondition.custom(download: 100, upload: 50, latency: 42, packetLoss: 0.05).description.contains("42ms"))
    }

    func testNetworkConditionEquatable() {
        XCTAssertEqual(NetworkCondition.wifi, NetworkCondition.wifi)
        XCTAssertEqual(NetworkCondition.cellular5G, NetworkCondition.cellular5G)
        XCTAssertNotEqual(NetworkCondition.wifi, NetworkCondition.cellular4G)

        let custom1 = NetworkCondition.custom(download: 100, upload: 50, latency: 10, packetLoss: 0.01)
        let custom2 = NetworkCondition.custom(download: 100, upload: 50, latency: 10, packetLoss: 0.01)
        let custom3 = NetworkCondition.custom(download: 200, upload: 50, latency: 10, packetLoss: 0.01)

        XCTAssertEqual(custom1, custom2)
        XCTAssertNotEqual(custom1, custom3)
    }

    func testNetworkConditionHashable() {
        var conditions = Set<NetworkCondition>()
        conditions.insert(.wifi)
        conditions.insert(.cellular4G)
        conditions.insert(.wifi) // Duplicate

        XCTAssertEqual(conditions.count, 2)
        XCTAssertTrue(conditions.contains(.wifi))
        XCTAssertTrue(conditions.contains(.cellular4G))
    }

    func testNetworkConditionCodable() throws {
        let conditions: [NetworkCondition] = [
            .wifi,
            .cellular5G,
            .cellular4G,
            .cellular3G,
            .cellular2G,
            .satellite,
            .offline,
            .custom(download: 1000, upload: 500, latency: 25, packetLoss: 0.02)
        ]

        for condition in conditions {
            let encoder = JSONEncoder()
            let data = try encoder.encode(condition)

            let decoder = JSONDecoder()
            let decoded = try decoder.decode(NetworkCondition.self, from: data)

            XCTAssertEqual(decoded, condition)
            XCTAssertEqual(decoded.downloadSpeed, condition.downloadSpeed)
            XCTAssertEqual(decoded.uploadSpeed, condition.uploadSpeed)
            XCTAssertEqual(decoded.latency, condition.latency)
            XCTAssertEqual(decoded.packetLoss, condition.packetLoss)
        }
    }

    // MARK: - NetworkThrottlingState Tests

    func testNetworkThrottlingStateInitialization() {
        let state = NetworkThrottlingState(enabled: true, condition: .wifi)
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.condition, .wifi)
    }

    func testNetworkThrottlingStateDisabled() {
        let state = NetworkThrottlingState.disabled
        XCTAssertFalse(state.enabled)
        XCTAssertNil(state.condition)
    }

    func testNetworkThrottlingStateActiveCondition() {
        let enabledState = NetworkThrottlingState(enabled: true, condition: .cellular4G)
        XCTAssertEqual(enabledState.activeCondition, .cellular4G)

        let disabledState = NetworkThrottlingState(enabled: false, condition: .cellular4G)
        XCTAssertNil(disabledState.activeCondition)

        let noConditionState = NetworkThrottlingState(enabled: true, condition: nil)
        XCTAssertNil(noConditionState.activeCondition)
    }

    func testNetworkThrottlingStateEquatable() {
        let state1 = NetworkThrottlingState(enabled: true, condition: .wifi)
        let state2 = NetworkThrottlingState(enabled: true, condition: .wifi)
        let state3 = NetworkThrottlingState(enabled: false, condition: .wifi)
        let state4 = NetworkThrottlingState(enabled: true, condition: .cellular4G)

        XCTAssertEqual(state1, state2)
        XCTAssertNotEqual(state1, state3)
        XCTAssertNotEqual(state1, state4)
    }

    func testNetworkThrottlingStateCodable() throws {
        let original = NetworkThrottlingState(enabled: true, condition: .custom(download: 500, upload: 250, latency: 20, packetLoss: 0.01))

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NetworkThrottlingState.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.enabled, original.enabled)
        XCTAssertEqual(decoded.condition, original.condition)
    }

    func testNetworkThrottlingStateJSONDictionary() {
        let state = NetworkThrottlingState(enabled: true, condition: .cellular4G)
        let dict = state.asJSONDictionary()

        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["enabled"] as? Bool, true)

        // Test round-trip
        if let dict {
            let restored = NetworkThrottlingState.fromJSONDictionary(dict)
            XCTAssertNotNil(restored)
            XCTAssertEqual(restored?.enabled, state.enabled)
            XCTAssertEqual(restored?.condition, state.condition)
        }
    }

    func testNetworkThrottlingStateJSONDictionaryWithNilCondition() {
        let state = NetworkThrottlingState(enabled: false, condition: nil)
        let dict = state.asJSONDictionary()

        XCTAssertNotNil(dict)

        if let dict {
            let restored = NetworkThrottlingState.fromJSONDictionary(dict)
            XCTAssertNotNil(restored)
            XCTAssertEqual(restored?.enabled, state.enabled)
            XCTAssertNil(restored?.condition)
        }
    }

    // MARK: - ThrottlingProfile Tests

    func testThrottlingProfileInitialization() {
        let profile = ThrottlingProfile(name: "Test Profile", condition: .wifi, enabled: true)

        XCTAssertEqual(profile.name, "Test Profile")
        XCTAssertEqual(profile.condition, .wifi)
        XCTAssertTrue(profile.enabled)
        XCTAssertNotNil(profile.id)
    }

    func testThrottlingProfileDefaultValues() {
        let profile = ThrottlingProfile(name: "Test", condition: .cellular4G)

        XCTAssertEqual(profile.name, "Test")
        XCTAssertEqual(profile.condition, .cellular4G)
        XCTAssertFalse(profile.enabled)
    }

    func testThrottlingProfilePreset() {
        let preset = ThrottlingProfile.preset(.wifi)

        XCTAssertEqual(preset.name, "WiFi")
        XCTAssertEqual(preset.condition, .wifi)
        XCTAssertFalse(preset.enabled)
    }

    func testThrottlingProfilePresets() {
        let presets = ThrottlingProfile.presets

        XCTAssertEqual(presets.count, 7)
        XCTAssertTrue(presets.contains { $0.condition == .wifi })
        XCTAssertTrue(presets.contains { $0.condition == .cellular5G })
        XCTAssertTrue(presets.contains { $0.condition == .cellular4G })
        XCTAssertTrue(presets.contains { $0.condition == .cellular3G })
        XCTAssertTrue(presets.contains { $0.condition == .cellular2G })
        XCTAssertTrue(presets.contains { $0.condition == .satellite })
        XCTAssertTrue(presets.contains { $0.condition == .offline })
    }

    func testThrottlingProfileIdentifiable() {
        let profile1 = ThrottlingProfile(name: "Profile 1", condition: .wifi)
        let profile2 = ThrottlingProfile(name: "Profile 2", condition: .wifi)

        XCTAssertNotEqual(profile1.id, profile2.id)
    }

    func testThrottlingProfileEquatable() {
        let id = UUID()
        let profile1 = ThrottlingProfile(id: id, name: "Test", condition: .wifi, enabled: true)
        let profile2 = ThrottlingProfile(id: id, name: "Test", condition: .wifi, enabled: true)
        let profile3 = ThrottlingProfile(id: UUID(), name: "Test", condition: .wifi, enabled: true)

        XCTAssertEqual(profile1, profile2)
        XCTAssertNotEqual(profile1, profile3)
    }

    func testThrottlingProfileHashable() {
        let profile1 = ThrottlingProfile(name: "Profile 1", condition: .wifi)
        let profile2 = ThrottlingProfile(name: "Profile 2", condition: .cellular4G)

        var profiles = Set<ThrottlingProfile>()
        profiles.insert(profile1)
        profiles.insert(profile2)
        profiles.insert(profile1) // Duplicate

        XCTAssertEqual(profiles.count, 2)
    }

    func testThrottlingProfileCodable() throws {
        let original = ThrottlingProfile(
            id: UUID(),
            name: "Custom Profile",
            condition: .custom(download: 1000, upload: 500, latency: 30, packetLoss: 0.05),
            enabled: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ThrottlingProfile.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.condition, original.condition)
        XCTAssertEqual(decoded.enabled, original.enabled)
    }

    // MARK: - ThrottlingConfiguration Tests

    func testThrottlingConfigurationInitialization() {
        let config = ThrottlingConfiguration()

        XCTAssertFalse(config.enabled)
        XCTAssertNil(config.activeProfile)
        XCTAssertTrue(config.customProfiles.isEmpty)
    }

    func testThrottlingConfigurationWithValues() {
        let profile = ThrottlingProfile(name: "Test", condition: .wifi, enabled: true)
        let customProfiles = [
            ThrottlingProfile(name: "Custom 1", condition: .cellular4G),
            ThrottlingProfile(name: "Custom 2", condition: .cellular3G)
        ]

        let config = ThrottlingConfiguration(
            enabled: true,
            activeProfile: profile,
            customProfiles: customProfiles
        )

        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.activeProfile?.name, "Test")
        XCTAssertEqual(config.customProfiles.count, 2)
    }

    func testThrottlingConfigurationAllProfiles() {
        let customProfiles = [
            ThrottlingProfile(name: "Custom 1", condition: .cellular4G),
            ThrottlingProfile(name: "Custom 2", condition: .cellular3G)
        ]

        let config = ThrottlingConfiguration(customProfiles: customProfiles)
        let allProfiles = config.allProfiles

        // 7 presets + 2 custom = 9 total
        XCTAssertEqual(allProfiles.count, 9)

        // First 7 should be presets
        XCTAssertTrue(allProfiles[0 ..< 7].contains { $0.condition == .wifi })
        XCTAssertTrue(allProfiles[0 ..< 7].contains { $0.condition == .cellular5G })

        // Last 2 should be custom
        XCTAssertTrue(allProfiles.contains { $0.name == "Custom 1" })
        XCTAssertTrue(allProfiles.contains { $0.name == "Custom 2" })
    }

    func testThrottlingConfigurationCodable() throws {
        let profile = ThrottlingProfile(name: "Active", condition: .wifi, enabled: true)
        let customProfiles = [
            ThrottlingProfile(name: "Custom", condition: .cellular4G)
        ]

        let original = ThrottlingConfiguration(
            enabled: true,
            activeProfile: profile,
            customProfiles: customProfiles
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ThrottlingConfiguration.self, from: data)

        XCTAssertEqual(decoded.enabled, original.enabled)
        XCTAssertEqual(decoded.activeProfile?.name, original.activeProfile?.name)
        XCTAssertEqual(decoded.customProfiles.count, original.customProfiles.count)
    }

    // MARK: - Edge Cases

    func testNetworkConditionCustomWithZeroValues() {
        let condition = NetworkCondition.custom(download: 0, upload: 0, latency: 0, packetLoss: 0.0)

        XCTAssertEqual(condition.downloadSpeed, 0)
        XCTAssertEqual(condition.uploadSpeed, 0)
        XCTAssertEqual(condition.latency, 0)
        XCTAssertEqual(condition.packetLoss, 0.0)
    }

    func testNetworkConditionCustomWithMaxValues() {
        let condition = NetworkCondition.custom(download: Int.max, upload: Int.max, latency: Int.max, packetLoss: 1.0)

        XCTAssertEqual(condition.downloadSpeed, Int.max)
        XCTAssertEqual(condition.uploadSpeed, Int.max)
        XCTAssertEqual(condition.latency, Int.max)
        XCTAssertEqual(condition.packetLoss, 1.0)
    }

    func testNetworkThrottlingStateWithNilCondition() throws {
        let state = NetworkThrottlingState(enabled: true, condition: nil)

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NetworkThrottlingState.self, from: data)

        XCTAssertTrue(decoded.enabled)
        XCTAssertNil(decoded.condition)
    }

    func testThrottlingConfigurationWithEmptyCustomProfiles() {
        let config = ThrottlingConfiguration(enabled: true, customProfiles: [])

        XCTAssertEqual(config.allProfiles.count, 7) // Only presets
        XCTAssertTrue(config.customProfiles.isEmpty)
    }

    func testThrottlingProfileWithSpecialCharactersInName() throws {
        let profile = ThrottlingProfile(
            name: "Test@#$%^&*()Profile",
            condition: .wifi
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(profile)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ThrottlingProfile.self, from: data)

        XCTAssertEqual(decoded.name, profile.name)
    }
}
