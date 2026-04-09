//
//  UDPFlowMetadataTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

final class UDPFlowMetadataTests: XCTestCase {
    // MARK: - UDPFlowProtocol Tests

    func testUDPFlowProtocolRawValues() {
        XCTAssertEqual(UDPFlowProtocol.dns.rawValue, "dns")
        XCTAssertEqual(UDPFlowProtocol.quic.rawValue, "quic")
        XCTAssertEqual(UDPFlowProtocol.dhcp.rawValue, "dhcp")
        XCTAssertEqual(UDPFlowProtocol.ntp.rawValue, "ntp")
        XCTAssertEqual(UDPFlowProtocol.mdns.rawValue, "mdns")
        XCTAssertEqual(UDPFlowProtocol.snmp.rawValue, "snmp")
        XCTAssertEqual(UDPFlowProtocol.unknown.rawValue, "unknown")
    }

    func testUDPFlowProtocolDisplayNames() {
        XCTAssertEqual(UDPFlowProtocol.dns.displayName, "DNS")
        XCTAssertEqual(UDPFlowProtocol.quic.displayName, "QUIC")
        XCTAssertEqual(UDPFlowProtocol.dhcp.displayName, "DHCP")
        XCTAssertEqual(UDPFlowProtocol.ntp.displayName, "NTP")
        XCTAssertEqual(UDPFlowProtocol.mdns.displayName, "mDNS")
        XCTAssertEqual(UDPFlowProtocol.snmp.displayName, "SNMP")
        XCTAssertEqual(UDPFlowProtocol.unknown.displayName, "Unknown")
    }

    func testUDPFlowProtocolCodable() throws {
        for protocolCase in UDPFlowProtocol.allCases {
            let encoded = try JSONEncoder().encode(protocolCase)
            let decoded = try JSONDecoder().decode(UDPFlowProtocol.self, from: encoded)
            XCTAssertEqual(protocolCase, decoded)
        }
    }

    func testUDPFlowProtocolCaseIterable() {
        let allCases = UDPFlowProtocol.allCases
        XCTAssertEqual(allCases.count, 7)
    }

    // MARK: - UDPFlowTermination Tests

    func testUDPFlowTerminationRawValues() {
        XCTAssertEqual(UDPFlowTermination.active.rawValue, "active")
        XCTAssertEqual(UDPFlowTermination.timeout.rawValue, "timeout")
        XCTAssertEqual(UDPFlowTermination.evicted.rawValue, "evicted")
        XCTAssertEqual(UDPFlowTermination.closed.rawValue, "closed")
    }

    func testUDPFlowTerminationDisplayNames() {
        XCTAssertEqual(UDPFlowTermination.active.displayName, "Active")
        XCTAssertEqual(UDPFlowTermination.timeout.displayName, "Timeout")
        XCTAssertEqual(UDPFlowTermination.evicted.displayName, "Evicted")
        XCTAssertEqual(UDPFlowTermination.closed.displayName, "Closed")
    }

    func testUDPFlowTerminationCodable() throws {
        for termination in UDPFlowTermination.allCases {
            let encoded = try JSONEncoder().encode(termination)
            let decoded = try JSONDecoder().decode(UDPFlowTermination.self, from: encoded)
            XCTAssertEqual(termination, decoded)
        }
    }

    // MARK: - UDPFlowDirection Tests

    func testUDPFlowDirectionRawValues() {
        XCTAssertEqual(UDPFlowDirection.sourceToDestination.rawValue, "sourceToDestination")
        XCTAssertEqual(UDPFlowDirection.destinationToSource.rawValue, "destinationToSource")
    }

    func testUDPFlowDirectionCodable() throws {
        let directions: [UDPFlowDirection] = [.sourceToDestination, .destinationToSource]
        for direction in directions {
            let encoded = try JSONEncoder().encode(direction)
            let decoded = try JSONDecoder().decode(UDPFlowDirection.self, from: encoded)
            XCTAssertEqual(direction, decoded)
        }
    }

    // MARK: - UDPDatagramSample Tests

    func testUDPDatagramSampleInit() {
        let timestamp = Date()
        let sample = UDPDatagramSample(
            timestamp: timestamp,
            size: 512,
            direction: .sourceToDestination
        )

        XCTAssertNotNil(sample.id)
        XCTAssertEqual(sample.timestamp, timestamp)
        XCTAssertEqual(sample.size, 512)
        XCTAssertEqual(sample.direction, .sourceToDestination)
    }

    func testUDPDatagramSampleWithCustomID() {
        let id = UUID()
        let sample = UDPDatagramSample(
            id: id,
            timestamp: Date(),
            size: 256,
            direction: .destinationToSource
        )

        XCTAssertEqual(sample.id, id)
    }

    func testUDPDatagramSampleCodable() throws {
        let original = UDPDatagramSample(
            timestamp: Date(),
            size: 1024,
            direction: .sourceToDestination
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UDPDatagramSample.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.size, original.size)
        XCTAssertEqual(decoded.direction, original.direction)
    }

    // MARK: - UDPFlowMetadata Initializer Tests

    func testUDPFlowMetadataInitWithDefaults() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.100",
            destinationIP: "8.8.8.8",
            sourcePort: 54321,
            destinationPort: 53
        )

        XCTAssertNotNil(metadata.id)
        XCTAssertEqual(metadata.sourceIP, "192.168.1.100")
        XCTAssertEqual(metadata.destinationIP, "8.8.8.8")
        XCTAssertEqual(metadata.sourcePort, 54321)
        XCTAssertEqual(metadata.destinationPort, 53)
        XCTAssertEqual(metadata.bytesFromSource, 0)
        XCTAssertEqual(metadata.bytesToSource, 0)
        XCTAssertEqual(metadata.datagramsFromSource, 0)
        XCTAssertEqual(metadata.datagramsToSource, 0)
        XCTAssertNotNil(metadata.startTime)
        XCTAssertNotNil(metadata.lastActivity)
        XCTAssertNil(metadata.endTime)
        XCTAssertEqual(metadata.termination, .active)
        XCTAssertEqual(metadata.detectedProtocol, .unknown)
        XCTAssertNil(metadata.quicInspectionOutcome)
        XCTAssertNil(metadata.quicFlowMetadata)
        XCTAssertTrue(metadata.recentDatagrams.isEmpty)
    }

    func testUDPFlowMetadataInitWithAllParameters() {
        let id = UUID()
        let startTime = Date()
        let lastActivity = Date().addingTimeInterval(5)
        let endTime = Date().addingTimeInterval(10)
        let datagrams = [UDPDatagramSample(timestamp: Date(), size: 100, direction: .sourceToDestination)]
        let quicMetadata = QUICFlowMetadata(
            version: "0x00000001",
            sourceConnectionIDLength: 8,
            destinationConnectionIDLength: 8,
            handshakeOutcome: .passThrough,
            failureReason: "quic_mitm_engine_unavailable"
        )

        let metadata = UDPFlowMetadata(
            id: id,
            sourceIP: "10.0.0.1",
            destinationIP: "10.0.0.2",
            sourcePort: 12345,
            destinationPort: 443,
            bytesFromSource: 1000,
            bytesToSource: 2000,
            datagramsFromSource: 5,
            datagramsToSource: 3,
            startTime: startTime,
            lastActivity: lastActivity,
            endTime: endTime,
            termination: .closed,
            detectedProtocol: .quic,
            quicInspectionOutcome: .passThroughMarked,
            quicFlowMetadata: quicMetadata,
            recentDatagrams: datagrams
        )

        XCTAssertEqual(metadata.id, id)
        XCTAssertEqual(metadata.sourceIP, "10.0.0.1")
        XCTAssertEqual(metadata.destinationIP, "10.0.0.2")
        XCTAssertEqual(metadata.sourcePort, 12345)
        XCTAssertEqual(metadata.destinationPort, 443)
        XCTAssertEqual(metadata.bytesFromSource, 1000)
        XCTAssertEqual(metadata.bytesToSource, 2000)
        XCTAssertEqual(metadata.datagramsFromSource, 5)
        XCTAssertEqual(metadata.datagramsToSource, 3)
        XCTAssertEqual(metadata.startTime, startTime)
        XCTAssertEqual(metadata.lastActivity, lastActivity)
        XCTAssertEqual(metadata.endTime, endTime)
        XCTAssertEqual(metadata.termination, .closed)
        XCTAssertEqual(metadata.detectedProtocol, .quic)
        XCTAssertEqual(metadata.quicInspectionOutcome, .passThroughMarked)
        XCTAssertEqual(metadata.quicFlowMetadata, quicMetadata)
        XCTAssertEqual(metadata.recentDatagrams.count, 1)
    }

    // MARK: - UDPFlowMetadata Computed Properties Tests

    func testTotalBytes() {
        var metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53
        )
        metadata.bytesFromSource = 1000
        metadata.bytesToSource = 2000

        XCTAssertEqual(metadata.totalBytes, 3000)
    }

    func testTotalDatagrams() {
        var metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53
        )
        metadata.datagramsFromSource = 10
        metadata.datagramsToSource = 5

        XCTAssertEqual(metadata.totalDatagrams, 15)
    }

    func testDurationWhenActive() {
        let startTime = Date()
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            startTime: startTime
        )

        let duration = metadata.duration
        XCTAssertGreaterThanOrEqual(duration, 0)
    }

    func testDurationWhenClosed() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(10.5)
        var metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            startTime: startTime
        )
        metadata.endTime = endTime

        XCTAssertEqual(metadata.duration, 10.5, accuracy: 0.001)
    }

    func testThroughputBytesPerSecond() {
        let startTime = Date()
        let endTime = startTime.addingTimeInterval(2.0)
        var metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            bytesFromSource: 1000,
            bytesToSource: 1000,
            startTime: startTime
        )
        metadata.endTime = endTime

        XCTAssertEqual(metadata.throughputBytesPerSecond, 1000.0, accuracy: 1.0)
    }

    func testThroughputBytesPerSecondZeroDuration() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            bytesFromSource: 100,
            startTime: Date()
        )

        // Should not crash with division by zero
        let throughput = metadata.throughputBytesPerSecond
        XCTAssertGreaterThan(throughput, 0)
    }

    func testAverageDatagramSize() {
        var metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53
        )
        metadata.bytesFromSource = 1000
        metadata.bytesToSource = 500
        metadata.datagramsFromSource = 5
        metadata.datagramsToSource = 5

        XCTAssertEqual(metadata.averageDatagramSize, 150.0)
    }

    func testAverageDatagramSizeZeroDatagrams() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            bytesFromSource: 1000
        )

        XCTAssertEqual(metadata.averageDatagramSize, 0.0)
    }

    func testIsActiveWhenActive() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            termination: .active
        )

        XCTAssertTrue(metadata.isActive)
    }

    func testIsActiveWhenClosed() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            termination: .closed
        )

        XCTAssertFalse(metadata.isActive)
    }

    func testIsBidirectionalTrue() {
        var metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53
        )
        metadata.datagramsFromSource = 5
        metadata.datagramsToSource = 3

        XCTAssertTrue(metadata.isBidirectional)
    }

    func testIsBidirectionalFalseSourceOnly() {
        var metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53
        )
        metadata.datagramsFromSource = 5
        metadata.datagramsToSource = 0

        XCTAssertFalse(metadata.isBidirectional)
    }

    func testIsBidirectionalFalseDestinationOnly() {
        var metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53
        )
        metadata.datagramsFromSource = 0
        metadata.datagramsToSource = 3

        XCTAssertFalse(metadata.isBidirectional)
    }

    func testWellKnownPortDescriptionDNS() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 54321,
            destinationPort: 53
        )

        XCTAssertEqual(metadata.wellKnownPortDescription, "Destination: DNS")
    }

    func testWellKnownPortDescriptionSourcePort() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 53,
            destinationPort: 54321
        )

        XCTAssertEqual(metadata.wellKnownPortDescription, "Source: DNS")
    }

    func testWellKnownPortDescriptionUnknown() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 12345,
            destinationPort: 54321
        )

        XCTAssertNil(metadata.wellKnownPortDescription)
    }

    func testWellKnownPortNameDNS() {
        XCTAssertEqual(UDPFlowMetadata.wellKnownPortName(53), "DNS")
    }

    func testWellKnownPortNameDHCP() {
        XCTAssertEqual(UDPFlowMetadata.wellKnownPortName(67), "DHCP")
        XCTAssertEqual(UDPFlowMetadata.wellKnownPortName(68), "DHCP")
    }

    func testWellKnownPortNameNTP() {
        XCTAssertEqual(UDPFlowMetadata.wellKnownPortName(123), "NTP")
    }

    func testWellKnownPortNameSNMP() {
        XCTAssertEqual(UDPFlowMetadata.wellKnownPortName(161), "SNMP")
        XCTAssertEqual(UDPFlowMetadata.wellKnownPortName(162), "SNMP")
    }

    func testWellKnownPortNameQUIC() {
        XCTAssertEqual(UDPFlowMetadata.wellKnownPortName(443), "QUIC")
    }

    func testWellKnownPortNameMDNS() {
        XCTAssertEqual(UDPFlowMetadata.wellKnownPortName(5353), "mDNS")
    }

    func testWellKnownPortNameUnknown() {
        XCTAssertNil(UDPFlowMetadata.wellKnownPortName(9999))
    }

    // MARK: - UDPFlowMetadata Codable Tests

    func testUDPFlowMetadataEncodeDecode() throws {
        let original = UDPFlowMetadata(
            sourceIP: "192.168.1.100",
            destinationIP: "8.8.8.8",
            sourcePort: 54321,
            destinationPort: 53,
            bytesFromSource: 512,
            bytesToSource: 256,
            datagramsFromSource: 2,
            datagramsToSource: 1,
            termination: .active,
            detectedProtocol: .dns
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UDPFlowMetadata.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.sourceIP, original.sourceIP)
        XCTAssertEqual(decoded.destinationIP, original.destinationIP)
        XCTAssertEqual(decoded.sourcePort, original.sourcePort)
        XCTAssertEqual(decoded.destinationPort, original.destinationPort)
        XCTAssertEqual(decoded.bytesFromSource, original.bytesFromSource)
        XCTAssertEqual(decoded.bytesToSource, original.bytesToSource)
        XCTAssertEqual(decoded.termination, original.termination)
        XCTAssertEqual(decoded.detectedProtocol, original.detectedProtocol)
    }

    // MARK: - Edge Cases

    func testUDPFlowMetadataWithIPv6() {
        let metadata = UDPFlowMetadata(
            sourceIP: "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
            destinationIP: "2001:0db8:85a3:0000:0000:8a2e:0370:7335",
            sourcePort: 1234,
            destinationPort: 5678
        )

        XCTAssertEqual(metadata.sourceIP, "2001:0db8:85a3:0000:0000:8a2e:0370:7334")
        XCTAssertEqual(metadata.destinationIP, "2001:0db8:85a3:0000:0000:8a2e:0370:7335")
    }

    func testUDPFlowMetadataWithMaxPortNumbers() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "192.168.1.2",
            sourcePort: UInt16.max,
            destinationPort: UInt16.max
        )

        XCTAssertEqual(metadata.sourcePort, 65535)
        XCTAssertEqual(metadata.destinationPort, 65535)
    }

    func testUDPFlowMetadataWithZeroBytes() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            bytesFromSource: 0,
            bytesToSource: 0
        )

        XCTAssertEqual(metadata.totalBytes, 0)
        XCTAssertEqual(metadata.averageDatagramSize, 0.0)
    }

    func testUDPFlowMetadataWithLargeByteCount() {
        let metadata = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53,
            bytesFromSource: UInt64.max / 2,
            bytesToSource: UInt64.max / 2
        )

        XCTAssertGreaterThan(metadata.totalBytes, 0)
    }

    func testUDPFlowMetadataIdentifiable() {
        let metadata1 = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53
        )
        let metadata2 = UDPFlowMetadata(
            sourceIP: "192.168.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 1234,
            destinationPort: 53
        )

        XCTAssertNotEqual(metadata1.id, metadata2.id)
    }
}
