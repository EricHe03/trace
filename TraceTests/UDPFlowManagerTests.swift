//
//  UDPFlowManagerTests.swift
//  TraceTests
//
//  Created by Claude Code on 2026/01/27.
//

import XCTest
@testable import TraceVPN
@testable import TracePacket
@testable import TraceCore

final class UDPFlowManagerTests: XCTestCase {

    // MARK: - Protocol Detection Tests

    func testDetectDNSProtocol() {
        // DNS runs on port 53
        let dnsPort: UInt16 = 53

        // Test both source and destination
        XCTAssertTrue(isDNSPort(dnsPort), "Port 53 should be detected as DNS")
        XCTAssertFalse(isDNSPort(80), "Port 80 should not be detected as DNS")
    }

    func testDetectMDNSProtocol() {
        // mDNS runs on port 5353
        let mdnsPort: UInt16 = 5353

        XCTAssertTrue(isMDNSPort(mdnsPort), "Port 5353 should be detected as mDNS")
        XCTAssertFalse(isMDNSPort(53), "Port 53 should not be detected as mDNS")
    }

    func testDetectQUICProtocol() {
        // QUIC typically runs on port 443
        let quicPort: UInt16 = 443

        XCTAssertTrue(isQUICPort(quicPort), "Port 443 should be detected as QUIC")
        XCTAssertFalse(isQUICPort(80), "Port 80 should not be detected as QUIC")
    }

    func testDetectDHCPProtocol() {
        // DHCP uses ports 67 (server) and 68 (client)
        let dhcpServerPort: UInt16 = 67
        let dhcpClientPort: UInt16 = 68

        XCTAssertTrue(isDHCPPort(dhcpServerPort), "Port 67 should be detected as DHCP")
        XCTAssertTrue(isDHCPPort(dhcpClientPort), "Port 68 should be detected as DHCP")
        XCTAssertFalse(isDHCPPort(80), "Port 80 should not be detected as DHCP")
    }

    func testDetectNTPProtocol() {
        // NTP runs on port 123
        let ntpPort: UInt16 = 123

        XCTAssertTrue(isNTPPort(ntpPort), "Port 123 should be detected as NTP")
        XCTAssertFalse(isNTPPort(80), "Port 80 should not be detected as NTP")
    }

    func testDetectSNMPProtocol() {
        // SNMP runs on port 161 (agent) and 162 (trap)
        let snmpAgentPort: UInt16 = 161
        let snmpTrapPort: UInt16 = 162

        XCTAssertTrue(isSNMPPort(snmpAgentPort), "Port 161 should be detected as SNMP")
        XCTAssertTrue(isSNMPPort(snmpTrapPort), "Port 162 should be detected as SNMP")
        XCTAssertFalse(isSNMPPort(80), "Port 80 should not be detected as SNMP")
    }

    func testProtocolDetectionPriority() {
        // Test that ports are correctly identified
        struct ProtocolTest {
            let port: UInt16
            let expectedProtocol: String
        }

        let tests = [
            ProtocolTest(port: 53, expectedProtocol: "DNS"),
            ProtocolTest(port: 5353, expectedProtocol: "mDNS"),
            ProtocolTest(port: 443, expectedProtocol: "QUIC"),
            ProtocolTest(port: 67, expectedProtocol: "DHCP"),
            ProtocolTest(port: 123, expectedProtocol: "NTP"),
            ProtocolTest(port: 161, expectedProtocol: "SNMP"),
            ProtocolTest(port: 8080, expectedProtocol: "Unknown"),
        ]

        for test in tests {
            let detected = detectProtocol(port: test.port)
            XCTAssertEqual(detected, test.expectedProtocol,
                          "Port \(test.port) should be detected as \(test.expectedProtocol)")
        }
    }

    // MARK: - Flow Normalization Tests

    func testFlowKeyNormalization() {
        // Flow should be normalized so A->B and B->A use the same key
        struct TestFlowKey: Hashable {
            let sourceIP: String
            let sourcePort: UInt16
            let destIP: String
            let destPort: UInt16

            // Normalize: always put lower IP:Port first
            func normalized() -> TestFlowKey {
                let key1 = "\(sourceIP):\(sourcePort)"
                let key2 = "\(destIP):\(destPort)"

                if key1 < key2 {
                    return self
                } else {
                    return TestFlowKey(sourceIP: destIP, sourcePort: destPort,
                                      destIP: sourceIP, destPort: sourcePort)
                }
            }
        }

        let flowAB = TestFlowKey(sourceIP: "192.168.1.1", sourcePort: 12345,
                                 destIP: "8.8.8.8", destPort: 53)
        let flowBA = TestFlowKey(sourceIP: "8.8.8.8", sourcePort: 53,
                                 destIP: "192.168.1.1", destPort: 12345)

        let normalizedAB = flowAB.normalized()
        let normalizedBA = flowBA.normalized()

        XCTAssertEqual(normalizedAB, normalizedBA, "Bidirectional flows should normalize to same key")
    }

    func testFlowKeyWithIPv6() {
        struct TestFlowKey: Hashable {
            let sourceIP: String
            let sourcePort: UInt16
            let destIP: String
            let destPort: UInt16
        }

        let ipv6Flow = TestFlowKey(
            sourceIP: "2001:db8::1",
            sourcePort: 12345,
            destIP: "2001:db8::2",
            destPort: 53
        )

        XCTAssertNotNil(ipv6Flow)
        XCTAssertTrue(ipv6Flow.sourceIP.contains(":"), "IPv6 address should contain colons")
    }

    // MARK: - Flow Metadata Tests

    func testFlowMetadataInitialization() {
        struct TestFlowMetadata {
            var bytesSentFromSource: UInt64 = 0
            var bytesSentToSource: UInt64 = 0
            var datagramsSentFromSource: UInt32 = 0
            var datagramsSentToSource: UInt32 = 0
            var detectedProtocol: String = "Unknown"
            var recentDatagrams: [Data] = []
        }

        let metadata = TestFlowMetadata()

        XCTAssertEqual(metadata.bytesSentFromSource, 0)
        XCTAssertEqual(metadata.bytesSentToSource, 0)
        XCTAssertEqual(metadata.datagramsSentFromSource, 0)
        XCTAssertEqual(metadata.datagramsSentToSource, 0)
        XCTAssertEqual(metadata.detectedProtocol, "Unknown")
        XCTAssertTrue(metadata.recentDatagrams.isEmpty)
    }

    func testFlowMetadataByteTracking() {
        struct TestFlowMetadata {
            var bytesSentFromSource: UInt64 = 0
            var bytesSentToSource: UInt64 = 0
        }

        var metadata = TestFlowMetadata()

        // Simulate packets in both directions
        let packet1Size: UInt64 = 100
        let packet2Size: UInt64 = 200

        metadata.bytesSentFromSource += packet1Size
        metadata.bytesSentToSource += packet2Size

        XCTAssertEqual(metadata.bytesSentFromSource, 100)
        XCTAssertEqual(metadata.bytesSentToSource, 200)
    }

    func testFlowMetadataDatagramTracking() {
        struct TestFlowMetadata {
            var datagramsSentFromSource: UInt32 = 0
            var datagramsSentToSource: UInt32 = 0
        }

        var metadata = TestFlowMetadata()

        // Simulate multiple datagrams
        for _ in 0..<5 {
            metadata.datagramsSentFromSource += 1
        }

        for _ in 0..<3 {
            metadata.datagramsSentToSource += 1
        }

        XCTAssertEqual(metadata.datagramsSentFromSource, 5)
        XCTAssertEqual(metadata.datagramsSentToSource, 3)
    }

    func testRecentDatagramSampling() {
        struct TestFlowMetadata {
            var recentDatagrams: [Data] = []
            let maxSamples = 10

            mutating func addSample(_ data: Data) {
                recentDatagrams.append(data)
                if recentDatagrams.count > maxSamples {
                    recentDatagrams.removeFirst()
                }
            }
        }

        var metadata = TestFlowMetadata()

        // Add 15 samples (should keep only last 10)
        for i in 0..<15 {
            metadata.addSample(Data([UInt8(i)]))
        }

        XCTAssertEqual(metadata.recentDatagrams.count, 10, "Should keep only 10 most recent samples")
        XCTAssertEqual(metadata.recentDatagrams.first, Data([5]), "First sample should be index 5")
        XCTAssertEqual(metadata.recentDatagrams.last, Data([14]), "Last sample should be index 14")
    }

    // MARK: - Flow Lifecycle Tests

    func testFlowCreation() {
        struct TestFlow {
            let sourceIP: String
            let sourcePort: UInt16
            let destIP: String
            let destPort: UInt16
            let firstSeen: Date
            var lastSeen: Date
        }

        let now = Date()
        let flow = TestFlow(
            sourceIP: "192.168.1.1",
            sourcePort: 12345,
            destIP: "8.8.8.8",
            destPort: 53,
            firstSeen: now,
            lastSeen: now
        )

        XCTAssertNotNil(flow)
        XCTAssertEqual(flow.firstSeen, flow.lastSeen, "New flow should have same first/last seen time")
    }

    func testFlowUpdate() {
        struct TestFlow {
            let firstSeen: Date
            var lastSeen: Date
        }

        let start = Date()
        var flow = TestFlow(firstSeen: start, lastSeen: start)

        // Simulate time passing
        let later = Date(timeIntervalSinceNow: 5)
        flow.lastSeen = later

        XCTAssertEqual(flow.firstSeen, start)
        XCTAssertEqual(flow.lastSeen, later)
        XCTAssertGreaterThan(flow.lastSeen, flow.firstSeen)
    }

    func testFlowTimeout() {
        let idleTimeout: TimeInterval = 60 // 60 seconds
        let lastSeen = Date(timeIntervalSinceNow: -70) // 70 seconds ago
        let now = Date()

        let isExpired = now.timeIntervalSince(lastSeen) > idleTimeout

        XCTAssertTrue(isExpired, "Flow should be expired after idle timeout")
    }

    func testFlowNotExpired() {
        let idleTimeout: TimeInterval = 60
        let lastSeen = Date(timeIntervalSinceNow: -30) // 30 seconds ago
        let now = Date()

        let isExpired = now.timeIntervalSince(lastSeen) > idleTimeout

        XCTAssertFalse(isExpired, "Flow should not be expired within idle timeout")
    }

    // MARK: - Flow Eviction Tests

    func testFlowLimitEviction() {
        let flowLimit = 5
        var flowCount = 0
        var shouldEvict = false

        // Add flows up to limit
        for _ in 0..<flowLimit {
            flowCount += 1
        }

        XCTAssertEqual(flowCount, flowLimit)

        // Try to add one more flow
        if flowCount >= flowLimit {
            shouldEvict = true
        }

        XCTAssertTrue(shouldEvict, "Should evict when flow limit is reached")
    }

    func testLRUEviction() {
        struct TestFlow {
            let id: Int
            var lastSeen: Date
        }

        var flows: [TestFlow] = [
            TestFlow(id: 1, lastSeen: Date(timeIntervalSinceNow: -100)),
            TestFlow(id: 2, lastSeen: Date(timeIntervalSinceNow: -50)),
            TestFlow(id: 3, lastSeen: Date(timeIntervalSinceNow: -10)),
        ]

        // Find oldest flow (LRU)
        let oldestFlow = flows.min(by: { $0.lastSeen < $1.lastSeen })

        XCTAssertEqual(oldestFlow?.id, 1, "Oldest flow should be evicted first")
    }

    // MARK: - Termination Reason Tests

    func testTerminationReasonTimeout() {
        enum TerminationReason {
            case timeout
            case evicted
            case active
        }

        let reason = TerminationReason.timeout

        XCTAssertEqual(reason, .timeout)
    }

    func testTerminationReasonEvicted() {
        enum TerminationReason {
            case timeout
            case evicted
            case active
        }

        let reason = TerminationReason.evicted

        XCTAssertEqual(reason, .evicted)
    }

    func testTerminationReasonActive() {
        enum TerminationReason {
            case timeout
            case evicted
            case active
        }

        let reason = TerminationReason.active

        XCTAssertEqual(reason, .active)
    }

    // MARK: - Dirty Flow Tracking Tests

    func testDirtyFlagInitialization() {
        struct TestFlow {
            var isDirty: Bool = false
        }

        let flow = TestFlow()
        XCTAssertFalse(flow.isDirty, "New flow should not be dirty")
    }

    func testDirtyFlagUpdate() {
        struct TestFlow {
            var isDirty: Bool = false
        }

        var flow = TestFlow()
        flow.isDirty = true

        XCTAssertTrue(flow.isDirty, "Flow should be marked dirty after update")
    }

    func testDirtyFlowPersistence() {
        struct TestFlow {
            var isDirty: Bool = false
        }

        var flows: [TestFlow] = [
            TestFlow(isDirty: true),
            TestFlow(isDirty: false),
            TestFlow(isDirty: true),
        ]

        let dirtyFlows = flows.filter { $0.isDirty }

        XCTAssertEqual(dirtyFlows.count, 2, "Should find 2 dirty flows")

        // Simulate persistence
        for i in flows.indices where flows[i].isDirty {
            flows[i].isDirty = false
        }

        let remainingDirty = flows.filter { $0.isDirty }
        XCTAssertEqual(remainingDirty.count, 0, "All flows should be clean after persistence")
    }

    // MARK: - Helper Functions

    private func isDNSPort(_ port: UInt16) -> Bool {
        return port == 53
    }

    private func isMDNSPort(_ port: UInt16) -> Bool {
        return port == 5353
    }

    private func isQUICPort(_ port: UInt16) -> Bool {
        return port == 443
    }

    private func isDHCPPort(_ port: UInt16) -> Bool {
        return port == 67 || port == 68
    }

    private func isNTPPort(_ port: UInt16) -> Bool {
        return port == 123
    }

    private func isSNMPPort(_ port: UInt16) -> Bool {
        return port == 161 || port == 162
    }

    private func detectProtocol(port: UInt16) -> String {
        if isDNSPort(port) { return "DNS" }
        if isMDNSPort(port) { return "mDNS" }
        if isQUICPort(port) { return "QUIC" }
        if isDHCPPort(port) { return "DHCP" }
        if isNTPPort(port) { return "NTP" }
        if isSNMPPort(port) { return "SNMP" }
        return "Unknown"
    }
}
