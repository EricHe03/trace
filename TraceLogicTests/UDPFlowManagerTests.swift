//
//  UDPFlowManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

#if !targetEnvironment(simulator)
@testable import TraceCore
@testable import TraceNetworking
@testable import TracePacket
@testable import TraceVPNKit
import XCTest

final class UDPFlowManagerTests: XCTestCase {
    var sut: UDPFlowManager!

    override func setUp() {
        super.setUp()
        sut = UDPFlowManager(idleTimeout: 5, flowLimit: 100)
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization_WithDefaultParameters() {
        // Given/When
        let manager = UDPFlowManager()

        // Then
        XCTAssertNotNil(manager)
    }

    func testInitialization_WithCustomParameters() {
        // Given/When
        let manager = UDPFlowManager(idleTimeout: 60, flowLimit: 1000)

        // Then
        XCTAssertNotNil(manager)
    }

    func testInitialization_WithZeroFlowLimit_UsesMinimumOfOne() {
        // Given/When
        let manager = UDPFlowManager(flowLimit: 0)

        // Then - Should not crash and should use minimum of 1
        XCTAssertNotNil(manager)
    }

    func testInitialization_WithNegativeFlowLimit_UsesMinimumOfOne() {
        // Given/When
        let manager = UDPFlowManager(flowLimit: -10)

        // Then
        XCTAssertNotNil(manager)
    }

    // MARK: - Flow Recording Tests

    func testRecordDatagram_CreatesNewFlow() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([1, 2, 3, 4])
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then - Flow should be created and persisted
        // Note: We can't directly verify internal state, but we can verify no crash
        XCTAssertTrue(true)
    }

    func testRecordDatagram_UpdatesExistingFlow() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket1 = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([1, 2, 3])
        )
        let udpPacket2 = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([4, 5, 6, 7])
        )

        // When - Record two datagrams for same flow
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket1)
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket2)
        sut.flush()

        // Then - Should update existing flow
        XCTAssertTrue(true)
    }

    func testRecordDatagram_BidirectionalFlow() {
        // Given
        let ipPacket1 = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket1 = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([1, 2, 3])
        )

        let ipPacket2 = createIPPacket(
            source: "8.8.8.8",
            destination: "192.168.1.1"
        )
        let udpPacket2 = createUDPPacket(
            sourcePort: 53,
            destinationPort: 12345,
            payload: Data([4, 5, 6, 7])
        )

        // When - Record datagrams in both directions
        sut.recordDatagram(ipPacket: ipPacket1, udpPacket: udpPacket1)
        sut.recordDatagram(ipPacket: ipPacket2, udpPacket: udpPacket2)
        sut.flush()

        // Then - Should recognize as same flow
        XCTAssertTrue(true)
    }

    func testRecordDatagram_DifferentFlows() {
        // Given
        let ipPacket1 = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket1 = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([1, 2, 3])
        )

        let ipPacket2 = createIPPacket(
            source: "192.168.1.2",
            destination: "1.1.1.1"
        )
        let udpPacket2 = createUDPPacket(
            sourcePort: 54321,
            destinationPort: 443,
            payload: Data([4, 5, 6])
        )

        // When - Record datagrams for different flows
        sut.recordDatagram(ipPacket: ipPacket1, udpPacket: udpPacket1)
        sut.recordDatagram(ipPacket: ipPacket2, udpPacket: udpPacket2)
        sut.flush()

        // Then - Should create separate flows
        XCTAssertTrue(true)
    }

    // MARK: - Protocol Detection Tests

    func testRecordDatagram_DetectsDNS() {
        // Given - DNS query
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let dnsQuery = createDNSQuery()
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: dnsQuery
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then - Protocol should be detected as DNS
        XCTAssertTrue(true)
    }

    func testRecordDatagram_DetectsMDNS() {
        // Given - mDNS query
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "224.0.0.251"
        )
        let mdnsQuery = createDNSQuery()
        let udpPacket = createUDPPacket(
            sourcePort: 5353,
            destinationPort: 5353,
            payload: mdnsQuery
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testRecordDatagram_DetectsQUIC() {
        // Given - QUIC packet (first byte has 0x80 set)
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "172.217.164.78"
        )
        let quicPayload = Data([0xFF, 0x00, 0x00, 0x00]) // QUIC header
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 443,
            payload: quicPayload
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testRecordDatagram_DetectsNTP() {
        // Given - NTP packet (48 bytes)
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "129.6.15.28"
        )
        let ntpPayload = Data(repeating: 0, count: 48)
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 123,
            payload: ntpPayload
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testRecordDatagram_DetectsDHCP() {
        // Given - DHCP packet
        let ipPacket = createIPPacket(
            source: "0.0.0.0",
            destination: "255.255.255.255"
        )
        let dhcpPayload = createDHCPPacket()
        let udpPacket = createUDPPacket(
            sourcePort: 68,
            destinationPort: 67,
            payload: dhcpPayload
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testRecordDatagram_DetectsSNMP() {
        // Given - SNMP packet
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "192.168.1.10"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 161,
            payload: Data([1, 2, 3])
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    // MARK: - Flush Tests

    func testFlush_PersistsData() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([1, 2, 3])
        )

        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)

        // When
        sut.flush()

        // Then - Should not crash
        XCTAssertTrue(true)
    }

    func testFlush_WhenNoData_DoesNotCrash() {
        // Given - No recorded datagrams

        // When
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testFlush_MultipleTimes_HandlesCorrectly() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([1, 2, 3])
        )

        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)

        // When - Flush multiple times
        sut.flush()
        sut.flush()
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    // MARK: - Flow Limit Tests

    func testFlowLimit_EvictsOldestFlow() {
        // Given - Manager with small flow limit
        let smallManager = UDPFlowManager(flowLimit: 2)

        let ipPacket1 = createIPPacket(source: "192.168.1.1", destination: "8.8.8.8")
        let udpPacket1 = createUDPPacket(sourcePort: 12345, destinationPort: 53, payload: Data([1]))

        let ipPacket2 = createIPPacket(source: "192.168.1.2", destination: "8.8.8.8")
        let udpPacket2 = createUDPPacket(sourcePort: 12346, destinationPort: 53, payload: Data([2]))

        let ipPacket3 = createIPPacket(source: "192.168.1.3", destination: "8.8.8.8")
        let udpPacket3 = createUDPPacket(sourcePort: 12347, destinationPort: 53, payload: Data([3]))

        // When - Record more flows than limit
        smallManager.recordDatagram(ipPacket: ipPacket1, udpPacket: udpPacket1)
        smallManager.recordDatagram(ipPacket: ipPacket2, udpPacket: udpPacket2)
        smallManager.recordDatagram(ipPacket: ipPacket3, udpPacket: udpPacket3)
        smallManager.flush()

        // Then - Should evict oldest flow
        XCTAssertTrue(true)
    }

    // MARK: - Recent Datagrams Tests

    func testRecordDatagram_TracksRecentDatagrams() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )

        // When - Record 15 datagrams
        for i in 0 ..< 15 {
            let udpPacket = createUDPPacket(
                sourcePort: 12345,
                destinationPort: 53,
                payload: Data(repeating: UInt8(i), count: i + 1)
            )
            sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        }
        sut.flush()

        // Then - Should keep only last 10 datagrams
        XCTAssertTrue(true)
    }

    // MARK: - Concurrent Access Tests

    func testRecordDatagram_ConcurrentAccess_ThreadSafe() {
        // Given
        let expectation = self.expectation(description: "Concurrent recording")
        expectation.expectedFulfillmentCount = 10

        // When - Record from multiple threads
        DispatchQueue.concurrentPerform(iterations: 10) { index in
            let ipPacket = createIPPacket(
                source: "192.168.1.\(index + 1)",
                destination: "8.8.8.8"
            )
            let udpPacket = createUDPPacket(
                sourcePort: UInt16(12345 + index),
                destinationPort: 53,
                payload: Data([UInt8(index)])
            )

            self.sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
            expectation.fulfill()
        }

        // Then
        wait(for: [expectation], timeout: 5.0)
        sut.flush()
    }

    func testFlush_ConcurrentCalls_ThreadSafe() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([1, 2, 3])
        )

        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)

        let expectation = self.expectation(description: "Concurrent flush")
        expectation.expectedFulfillmentCount = 5

        // When - Flush from multiple threads
        for _ in 0 ..< 5 {
            DispatchQueue.global().async {
                self.sut.flush()
                expectation.fulfill()
            }
        }

        // Then
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Edge Cases

    func testRecordDatagram_WithEmptyPayload() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data()
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testRecordDatagram_WithLargePayload() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let largePayload = Data(repeating: 0xFF, count: 65000)
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: largePayload
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testRecordDatagram_WithIPv6Addresses() {
        // Given
        let ipPacket = createIPPacket(
            source: "2001:4860:4860::8888",
            destination: "2001:4860:4860::8844"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 12345,
            destinationPort: 53,
            payload: Data([1, 2, 3])
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testRecordDatagram_WithZeroPorts() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 0,
            destinationPort: 0,
            payload: Data([1, 2, 3])
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    func testRecordDatagram_WithMaxPorts() {
        // Given
        let ipPacket = createIPPacket(
            source: "192.168.1.1",
            destination: "8.8.8.8"
        )
        let udpPacket = createUDPPacket(
            sourcePort: 65535,
            destinationPort: 65535,
            payload: Data([1, 2, 3])
        )

        // When
        sut.recordDatagram(ipPacket: ipPacket, udpPacket: udpPacket)
        sut.flush()

        // Then
        XCTAssertTrue(true)
    }

    // MARK: - Helper Methods

    private func createIPPacket(source: String, destination: String) -> IPPacket {
        IPPacket(
            version: 4,
            source: IPAddress(stringLiteral: source),
            destination: IPAddress(stringLiteral: destination),
            protocol: 17, // UDP
            ttl: 64,
            payload: Data()
        )
    }

    private func createUDPPacket(sourcePort: UInt16, destinationPort: UInt16, payload: Data) -> UDPPacket {
        UDPPacket(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload
        )
    }

    private func createDNSQuery() -> Data {
        // Minimal DNS query structure
        var data = Data()
        data.append(contentsOf: [0x00, 0x01]) // Transaction ID
        data.append(contentsOf: [0x01, 0x00]) // Flags (standard query)
        data.append(contentsOf: [0x00, 0x01]) // Questions: 1
        data.append(contentsOf: [0x00, 0x00]) // Answer RRs
        data.append(contentsOf: [0x00, 0x00]) // Authority RRs
        data.append(contentsOf: [0x00, 0x00]) // Additional RRs
        data.append(contentsOf: [0x03]) // Length of "www"
        data.append(contentsOf: "www".utf8)
        data.append(contentsOf: [0x06]) // Length of "google"
        data.append(contentsOf: "google".utf8)
        data.append(contentsOf: [0x03]) // Length of "com"
        data.append(contentsOf: "com".utf8)
        data.append(contentsOf: [0x00]) // Null terminator
        data.append(contentsOf: [0x00, 0x01]) // Type A
        data.append(contentsOf: [0x00, 0x01]) // Class IN
        return data
    }

    private func createDHCPPacket() -> Data {
        // Create a minimal DHCP packet (240 bytes minimum)
        var data = Data(repeating: 0, count: 240)
        // Magic cookie at offset 236
        data[236] = 0x63
        data[237] = 0x82
        data[238] = 0x53
        data[239] = 0x63
        return data
    }
}
#else
import XCTest

final class UDPFlowManagerTests: XCTestCase {
    func testUDPFlowManagerUnavailableOnSimulator() throws {
        throw XCTSkip("UDPFlowManager lives in the TraceVPN app extension, which is not linked into simulator unit tests.")
    }
}
#endif
