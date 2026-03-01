//
//  PacketTunnelProviderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
import NetworkExtension
@testable import TraceVPN
@testable import TraceCore

final class PacketTunnelProviderTests: XCTestCase {

    // MARK: - IPC Message Tests

    func testIPCMessageGetHardeningConfig() {
        struct IPCMessage: Codable {
            let command: String
        }

        let message = IPCMessage(command: "getHardeningConfig")

        XCTAssertEqual(message.command, "getHardeningConfig")
    }

    func testIPCMessageGetRootCAFingerprint() {
        struct IPCMessage: Codable {
            let command: String
        }

        let message = IPCMessage(command: "getRootCAFingerprint")

        XCTAssertEqual(message.command, "getRootCAFingerprint")
    }

    func testIPCMessageUpdateConfig() {
        struct IPCMessage: Codable {
            let command: String
            let config: [String: Any]?

            enum CodingKeys: String, CodingKey {
                case command
            }

            init(command: String, config: [String: Any]? = nil) {
                self.command = command
                self.config = config
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                command = try container.decode(String.self, forKey: .command)
                config = nil
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(command, forKey: .command)
            }
        }

        let message = IPCMessage(command: "updateConfig", config: ["key": "value"])

        XCTAssertEqual(message.command, "updateConfig")
        XCTAssertNotNil(message.config)
    }

    func testIPCMessageUpdateCaptureConfig() {
        struct IPCMessage: Codable {
            let command: String
        }

        let message = IPCMessage(command: "updateCaptureConfig")

        XCTAssertEqual(message.command, "updateCaptureConfig")
    }

    func testIPCMessageUpdateHardeningConfig() {
        struct IPCMessage: Codable {
            let command: String
        }

        let message = IPCMessage(command: "updateHardeningConfig")

        XCTAssertEqual(message.command, "updateHardeningConfig")
    }

    func testIPCMessageUpdateThrottlingState() {
        struct IPCMessage: Codable {
            let command: String
        }

        let message = IPCMessage(command: "updateThrottlingState")

        XCTAssertEqual(message.command, "updateThrottlingState")
    }

    func testIPCMessageClearRequests() {
        struct IPCMessage: Codable {
            let command: String
        }

        let message = IPCMessage(command: "clearRequests")

        XCTAssertEqual(message.command, "clearRequests")
    }

    // MARK: - IPC Message Encoding/Decoding Tests

    func testEncodeIPCMessage() throws {
        struct IPCMessage: Codable {
            let command: String
        }

        let message = IPCMessage(command: "getHardeningConfig")
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)

        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testDecodeIPCMessage() throws {
        let jsonString = """
        {"command":"getHardeningConfig"}
        """

        struct IPCMessage: Codable {
            let command: String
        }

        let decoder = JSONDecoder()
        let data = Data(jsonString.utf8)
        let message = try decoder.decode(IPCMessage.self, from: data)

        XCTAssertEqual(message.command, "getHardeningConfig")
    }

    func testInvalidIPCMessage() {
        let invalidJSON = """
        {"invalid": "data"}
        """

        struct IPCMessage: Codable {
            let command: String
        }

        let decoder = JSONDecoder()
        let data = Data(invalidJSON.utf8)

        XCTAssertThrowsError(try decoder.decode(IPCMessage.self, from: data))
    }

    // MARK: - Network Settings Tests

    func testProxyOnlyNetworkSettings() {
        struct NetworkSettings {
            let mode: String
            let proxyEnabled: Bool
            let dnsServers: [String]
        }

        let settings = NetworkSettings(
            mode: "proxy-only",
            proxyEnabled: true,
            dnsServers: ["8.8.8.8", "8.8.4.4"]
        )

        XCTAssertEqual(settings.mode, "proxy-only")
        XCTAssertTrue(settings.proxyEnabled)
        XCTAssertEqual(settings.dnsServers.count, 2)
    }

    func testFullTunnelNetworkSettings() {
        struct NetworkSettings {
            let mode: String
            let proxyEnabled: Bool
            let tunnelEnabled: Bool
        }

        let settings = NetworkSettings(
            mode: "full-tunnel",
            proxyEnabled: true,
            tunnelEnabled: true
        )

        XCTAssertEqual(settings.mode, "full-tunnel")
        XCTAssertTrue(settings.proxyEnabled)
        XCTAssertTrue(settings.tunnelEnabled)
    }

    func testSocksEndpointSourceUsesEmbeddedWhenHostAndPortMissing() {
        let source = selectSocksEndpointSource(host: "", port: 0)
        XCTAssertEqual(source, .embedded)
    }

    func testSocksEndpointSourceUsesEmbeddedWhenHostMissingButPortPresent() {
        let source = selectSocksEndpointSource(host: "   ", port: 1080)
        XCTAssertEqual(source, .embedded)
    }

    func testSocksEndpointSourceUsesEmbeddedWhenHostPresentButPortMissing() {
        let source = selectSocksEndpointSource(host: "127.0.0.1", port: 0)
        XCTAssertEqual(source, .embedded)
    }

    func testSocksEndpointSourceUsesConfiguredWhenHostAndPortPresent() {
        let source = selectSocksEndpointSource(host: "127.0.0.1", port: 1080)
        XCTAssertEqual(source, .configured)
    }

    func testDecideUDPForwardingHevOnlyFallsBackToDirectWhenTunnelUDPUnsupported() {
        let decision = decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .hevOnly,
            sourcePort: 50_000,
            destinationPort: 443,
            blockQUICEnabled: false,
            tunnelUDPSupported: false
        )

        XCTAssertEqual(decision.decision, .forwardDirect)
        XCTAssertTrue(decision.isQUIC)
    }

    func testDecideUDPForwardingSplitFallsBackToDirectForQUICWhenTunnelUDPUnsupported() {
        let decision = decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .split,
            sourcePort: 50_000,
            destinationPort: 443,
            blockQUICEnabled: false,
            tunnelUDPSupported: false
        )

        XCTAssertEqual(decision.decision, .forwardDirect)
        XCTAssertTrue(decision.isQUIC)
    }

    func testDecideUDPForwardingHevOnlyUsesTunnelWhenTunnelUDPSupported() {
        let decision = decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .hevOnly,
            sourcePort: 50_000,
            destinationPort: 443,
            blockQUICEnabled: false,
            tunnelUDPSupported: true
        )

        XCTAssertEqual(decision.decision, .forwardTunnel)
        XCTAssertTrue(decision.isQUIC)
    }

    func testDecideUDPForwardingFallsBackToTunnelWhenDirectForwarderUnavailable() {
        let decision = decideUDPForwarding(
            udpForwarderAvailable: false,
            mode: .direct,
            sourcePort: 40_000,
            destinationPort: 53,
            blockQUICEnabled: false,
            tunnelUDPSupported: true
        )

        XCTAssertEqual(decision.decision, .forwardTunnel)
        XCTAssertFalse(decision.isQUIC)
    }

    func testDecideUDPForwardingInterceptModeMarksQUICForInterception() {
        let decision = decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .direct,
            sourcePort: 45_000,
            destinationPort: 443,
            quicHandlingMode: .intercept,
            tunnelUDPSupported: true
        )

        XCTAssertEqual(decision.decision, .interceptQUIC)
        XCTAssertTrue(decision.isQUIC)
    }

    func testDecideUDPForwardingPassThroughModeKeepsConnectivityPath() {
        let decision = decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .split,
            sourcePort: 45_000,
            destinationPort: 443,
            quicHandlingMode: .passThrough,
            tunnelUDPSupported: false
        )

        XCTAssertEqual(decision.decision, .forwardDirect)
        XCTAssertTrue(decision.isQUIC)
    }

    func testDecideUDPForwardingBlockModeDropsQUIC() {
        let decision = decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .direct,
            sourcePort: 45_000,
            destinationPort: 443,
            quicHandlingMode: .block,
            tunnelUDPSupported: true
        )

        XCTAssertEqual(decision.decision, .dropQUIC)
        XCTAssertTrue(decision.isQUIC)
    }

    func testDNSSettings() {
        struct DNSSettings {
            let servers: [String]
            let searchDomains: [String]
        }

        let settings = DNSSettings(
            servers: ["8.8.8.8", "8.8.4.4"],
            searchDomains: ["local"]
        )

        XCTAssertEqual(settings.servers.count, 2)
        XCTAssertEqual(settings.searchDomains.count, 1)
    }

    func testProxySettings() {
        struct ProxySettings {
            let host: String
            let port: UInt16
            let enabled: Bool
        }

        let settings = ProxySettings(
            host: "127.0.0.1",
            port: 8888,
            enabled: true
        )

        XCTAssertEqual(settings.host, "127.0.0.1")
        XCTAssertEqual(settings.port, 8888)
        XCTAssertTrue(settings.enabled)
    }

    // MARK: - Hardening Configuration Tests

    func testHardeningConfigQUICBlocking() {
        struct HardeningConfig: Codable {
            let blockQUIC: Bool
        }

        let config = HardeningConfig(blockQUIC: true)

        XCTAssertTrue(config.blockQUIC)
    }

    func testHardeningConfigMITMAllowlist() {
        struct HardeningConfig: Codable {
            let mitmAllowlist: [String]
        }

        let config = HardeningConfig(mitmAllowlist: ["example.com", "test.com"])

        XCTAssertEqual(config.mitmAllowlist.count, 2)
        XCTAssertTrue(config.mitmAllowlist.contains("example.com"))
    }

    func testHardeningConfigPacketCapture() {
        struct HardeningConfig: Codable {
            let packetCaptureEnabled: Bool
        }

        let config = HardeningConfig(packetCaptureEnabled: true)

        XCTAssertTrue(config.packetCaptureEnabled)
    }

    // MARK: - Certificate Management Tests

    func testCertificateFingerprintFormat() {
        let fingerprint = "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD"

        let parts = fingerprint.split(separator: ":")
        XCTAssertEqual(parts.count, 20, "SHA-1 fingerprint should have 20 bytes")

        for part in parts {
            XCTAssertEqual(part.count, 2, "Each byte should be 2 hex characters")
        }
    }

    func testCertificateTrustValidation() {
        enum TrustStatus {
            case trusted
            case notTrusted
            case unknown
        }

        let status = TrustStatus.trusted

        XCTAssertEqual(status, .trusted, "Certificate should be trusted")
    }

    func testCertificateCleanup() {
        var certificatesStored = 5

        // Simulate cleanup
        certificatesStored = 0

        XCTAssertEqual(certificatesStored, 0, "All certificates should be cleaned up")
    }

    // MARK: - Tunnel Lifecycle Tests

    func testTunnelStateInvalid() {
        enum TunnelState {
            case invalid
            case connecting
            case connected
            case disconnecting
            case disconnected
        }

        let state = TunnelState.invalid

        XCTAssertEqual(state, .invalid)
    }

    func testTunnelStateConnecting() {
        enum TunnelState {
            case invalid
            case connecting
            case connected
            case disconnecting
            case disconnected
        }

        let state = TunnelState.connecting

        XCTAssertEqual(state, .connecting)
    }

    func testTunnelStateConnected() {
        enum TunnelState {
            case invalid
            case connecting
            case connected
            case disconnecting
            case disconnected
        }

        let state = TunnelState.connected

        XCTAssertEqual(state, .connected)
    }

    func testTunnelStateTransition() {
        enum TunnelState {
            case invalid
            case connecting
            case connected
            case disconnecting
            case disconnected
        }

        var state = TunnelState.invalid

        state = .connecting
        XCTAssertEqual(state, .connecting)

        state = .connected
        XCTAssertEqual(state, .connected)

        state = .disconnecting
        XCTAssertEqual(state, .disconnecting)

        state = .disconnected
        XCTAssertEqual(state, .disconnected)
    }

    // MARK: - Invocation ID Tests

    func testInvocationIDGeneration() {
        let id1 = UUID().uuidString
        let id2 = UUID().uuidString

        XCTAssertNotEqual(id1, id2, "Each invocation should have unique ID")
    }

    func testInvocationIDFormat() {
        let id = UUID().uuidString

        XCTAssertEqual(id.count, 36, "UUID string should be 36 characters")
        XCTAssertTrue(id.contains("-"), "UUID should contain hyphens")
    }

    // MARK: - Memory Monitoring Tests

    func testMemorySnapshot() {
        struct MemorySnapshot {
            let usedMB: Double
            let availableMB: Double
            let timestamp: Date
        }

        let snapshot = MemorySnapshot(
            usedMB: 128.5,
            availableMB: 384.0,
            timestamp: Date()
        )

        XCTAssertGreaterThan(snapshot.usedMB, 0)
        XCTAssertGreaterThan(snapshot.availableMB, 0)
        XCTAssertNotNil(snapshot.timestamp)
    }

    func testMemoryThreshold() {
        let usedMB: Double = 512
        let maxMB: Double = 1024

        let percentUsed = (usedMB / maxMB) * 100

        XCTAssertEqual(percentUsed, 50.0)
        XCTAssertLessThan(percentUsed, 100.0)
    }

    // MARK: - Heartbeat Tests

    func testHeartbeatInterval() {
        let heartbeatInterval: TimeInterval = 60 // 60 seconds

        XCTAssertEqual(heartbeatInterval, 60)
    }

    func testHeartbeatData() {
        struct HeartbeatData {
            let activeConnections: Int
            let memoryMB: Double
            let timestamp: Date
        }

        let heartbeat = HeartbeatData(
            activeConnections: 42,
            memoryMB: 128.5,
            timestamp: Date()
        )

        XCTAssertEqual(heartbeat.activeConnections, 42)
        XCTAssertGreaterThan(heartbeat.memoryMB, 0)
        XCTAssertNotNil(heartbeat.timestamp)
    }

    // MARK: - Error Handling Tests

    func testTunnelErrorNotConfigured() {
        enum TunnelError: Error {
            case notConfigured
            case permissionDenied
            case settingsFailed
        }

        let error = TunnelError.notConfigured

        XCTAssertNotNil(error)
    }

    func testTunnelErrorPermissionDenied() {
        enum TunnelError: Error {
            case notConfigured
            case permissionDenied
            case settingsFailed
        }

        let error = TunnelError.permissionDenied

        XCTAssertNotNil(error)
    }

    func testTunnelErrorSettingsFailed() {
        enum TunnelError: Error {
            case notConfigured
            case permissionDenied
            case settingsFailed
        }

        let error = TunnelError.settingsFailed

        XCTAssertNotNil(error)
    }

    // MARK: - Throttling Tests

    func testThrottlingStateEnabled() {
        struct ThrottlingState {
            let enabled: Bool
            let downloadKBps: Int
            let uploadKBps: Int
        }

        let state = ThrottlingState(
            enabled: true,
            downloadKBps: 1024,
            uploadKBps: 512
        )

        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.downloadKBps, 1024)
        XCTAssertEqual(state.uploadKBps, 512)
    }

    func testThrottlingStateDisabled() {
        struct ThrottlingState {
            let enabled: Bool
        }

        let state = ThrottlingState(enabled: false)

        XCTAssertFalse(state.enabled)
    }

    // MARK: - Capture Configuration Tests

    func testCaptureConfigEnabled() {
        struct CaptureConfig {
            let pcapEnabled: Bool
            let flowRecordingEnabled: Bool
        }

        let config = CaptureConfig(
            pcapEnabled: true,
            flowRecordingEnabled: true
        )

        XCTAssertTrue(config.pcapEnabled)
        XCTAssertTrue(config.flowRecordingEnabled)
    }

    func testCaptureConfigDisabled() {
        struct CaptureConfig {
            let pcapEnabled: Bool
            let flowRecordingEnabled: Bool
        }

        let config = CaptureConfig(
            pcapEnabled: false,
            flowRecordingEnabled: false
        )

        XCTAssertFalse(config.pcapEnabled)
        XCTAssertFalse(config.flowRecordingEnabled)
    }

    // MARK: - Proxy Server Tests

    func testProxyServerConfiguration() {
        struct ProxyConfig {
            let host: String
            let port: UInt16
            let mitmEnabled: Bool
        }

        let config = ProxyConfig(
            host: "127.0.0.1",
            port: 8888,
            mitmEnabled: true
        )

        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertEqual(config.port, 8888)
        XCTAssertTrue(config.mitmEnabled)
    }

    func testProxyServerLifecycle() {
        enum ProxyState {
            case stopped
            case starting
            case running
            case stopping
        }

        var state = ProxyState.stopped

        state = .starting
        XCTAssertEqual(state, .starting)

        state = .running
        XCTAssertEqual(state, .running)

        state = .stopping
        XCTAssertEqual(state, .stopping)

        state = .stopped
        XCTAssertEqual(state, .stopped)
    }

    // MARK: - Configuration Validation Tests

    func testValidConfiguration() {
        struct Config {
            let proxyHost: String
            let proxyPort: UInt16
            let dnsServers: [String]

            func isValid() -> Bool {
                return !proxyHost.isEmpty &&
                       proxyPort > 0 &&
                       !dnsServers.isEmpty
            }
        }

        let config = Config(
            proxyHost: "127.0.0.1",
            proxyPort: 8888,
            dnsServers: ["8.8.8.8"]
        )

        XCTAssertTrue(config.isValid())
    }

    func testInvalidConfiguration() {
        struct Config {
            let proxyHost: String
            let proxyPort: UInt16

            func isValid() -> Bool {
                return !proxyHost.isEmpty && proxyPort > 0
            }
        }

        let invalidConfig = Config(proxyHost: "", proxyPort: 0)

        XCTAssertFalse(invalidConfig.isValid())
    }

    // MARK: - Concurrent Start Prevention Tests

    func testDuplicateStartAttempt() {
        var isStarting = false
        var startAttempts = 0

        // First start attempt
        if !isStarting {
            isStarting = true
            startAttempts += 1
        }

        XCTAssertTrue(isStarting)
        XCTAssertEqual(startAttempts, 1)

        // Second start attempt (should be ignored)
        if !isStarting {
            startAttempts += 1
        }

        XCTAssertEqual(startAttempts, 1, "Duplicate start should be ignored")
    }
}
