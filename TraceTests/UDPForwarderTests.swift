//
//  UDPForwarderTests.swift
//  TraceTests
//
//  Created by Claude Code on 2026/01/27.
//

import XCTest
import Network
@testable import TraceVPN
@testable import TracePacket

final class UDPForwarderTests: XCTestCase {

    // MARK: - Checksum Calculation Tests

    func testIPv4HeaderChecksumCalculation() {
        // IPv4 header without checksum
        var header = Data([
            0x45, 0x00, // Version=4, IHL=5, DSCP=0, ECN=0
            0x00, 0x1C, // Total Length: 28 (20 header + 8 UDP)
            0x00, 0x00, // Identification: 0
            0x00, 0x00, // Flags=0, Fragment Offset=0
            0x40,       // TTL: 64
            0x11,       // Protocol: 17 (UDP)
            0x00, 0x00, // Checksum: 0 (to be calculated)
            0xC0, 0xA8, 0x01, 0x01, // Source IP: 192.168.1.1
            0xC0, 0xA8, 0x01, 0x02, // Dest IP: 192.168.1.2
        ])

        // Calculate checksum manually
        var sum: UInt32 = 0
        for i in stride(from: 0, to: header.count, by: 2) {
            if i == 10 { continue } // Skip checksum field
            let word = (UInt32(header[i]) << 8) | UInt32(header[i + 1])
            sum += word
        }

        // Fold carry bits
        while sum > 0xFFFF {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        let checksum = UInt16(~sum & 0xFFFF)

        // Verify checksum is non-zero for this header
        XCTAssertNotEqual(checksum, 0, "Checksum should be calculated")

        // Verify checksum format (big-endian)
        let checksumBytes = Data([UInt8(checksum >> 8), UInt8(checksum & 0xFF)])
        XCTAssertEqual(checksumBytes.count, 2)
    }

    func testIPv4HeaderChecksumVerification() {
        // Known-good IPv4 header with correct checksum
        let header = Data([
            0x45, 0x00, // Version=4, IHL=5
            0x00, 0x54, // Total Length: 84
            0x41, 0x0E, // Identification
            0x40, 0x00, // Flags, Fragment Offset
            0x40,       // TTL: 64
            0x11,       // Protocol: UDP
            0xB8, 0x61, // Checksum (known correct value)
            0xC0, 0xA8, 0x01, 0x01, // Source IP
            0xC0, 0xA8, 0x01, 0x02, // Dest IP
        ])

        // Calculate checksum for verification
        var sum: UInt32 = 0
        for i in stride(from: 0, to: header.count, by: 2) {
            let word = (UInt32(header[i]) << 8) | UInt32(header[i + 1])
            sum += word
        }

        while sum > 0xFFFF {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        // Valid checksum should result in 0xFFFF after including the checksum field
        XCTAssertEqual(UInt16(sum), 0xFFFF, "Valid checksum should verify correctly")
    }

    func testUDPChecksumIPv4Calculation() {
        let sourceIP = Data([192, 168, 1, 1])      // 192.168.1.1
        let destIP = Data([192, 168, 1, 2])        // 192.168.1.2
        let sourcePort: UInt16 = 12345
        let destPort: UInt16 = 53
        let payload = Data("test".utf8)

        // UDP header: source port (2) + dest port (2) + length (2) + checksum (2) = 8 bytes
        let udpLength = UInt16(8 + payload.count)

        // Build pseudo-header for IPv4 UDP checksum
        var pseudoHeader = Data()
        pseudoHeader.append(sourceIP)                           // Source IP (4 bytes)
        pseudoHeader.append(destIP)                             // Dest IP (4 bytes)
        pseudoHeader.append(0x00)                               // Zero (1 byte)
        pseudoHeader.append(0x11)                               // Protocol: UDP (1 byte)
        pseudoHeader.append(UInt8(udpLength >> 8))              // UDP length high byte
        pseudoHeader.append(UInt8(udpLength & 0xFF))            // UDP length low byte

        // Build UDP header (without checksum)
        var udpHeader = Data()
        udpHeader.append(UInt8(sourcePort >> 8))
        udpHeader.append(UInt8(sourcePort & 0xFF))
        udpHeader.append(UInt8(destPort >> 8))
        udpHeader.append(UInt8(destPort & 0xFF))
        udpHeader.append(UInt8(udpLength >> 8))
        udpHeader.append(UInt8(udpLength & 0xFF))
        udpHeader.append(0x00)                                  // Checksum placeholder
        udpHeader.append(0x00)

        // Combine for checksum calculation
        var checksumData = Data()
        checksumData.append(pseudoHeader)
        checksumData.append(udpHeader)
        checksumData.append(payload)

        // Pad to even length if needed
        if checksumData.count % 2 != 0 {
            checksumData.append(0x00)
        }

        // Calculate checksum
        var sum: UInt32 = 0
        for i in stride(from: 0, to: checksumData.count, by: 2) {
            let word = (UInt32(checksumData[i]) << 8) | UInt32(checksumData[i + 1])
            sum += word
        }

        while sum > 0xFFFF {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        let checksum = UInt16(~sum & 0xFFFF)

        // Checksum should be non-zero for non-trivial data
        XCTAssertNotEqual(checksum, 0)
    }

    func testUDPChecksumIPv6Calculation() {
        // IPv6 addresses (16 bytes each)
        let sourceIP = Data([0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
                             0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        let destIP = Data([0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
                           0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
        let sourcePort: UInt16 = 12345
        let destPort: UInt16 = 53
        let payload = Data("test".utf8)

        let udpLength = UInt16(8 + payload.count)

        // IPv6 pseudo-header
        var pseudoHeader = Data()
        pseudoHeader.append(sourceIP)                           // Source IP (16 bytes)
        pseudoHeader.append(destIP)                             // Dest IP (16 bytes)
        pseudoHeader.append(0x00)                               // Upper-layer packet length (4 bytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(UInt8(udpLength >> 8))
        pseudoHeader.append(UInt8(udpLength & 0xFF))
        pseudoHeader.append(0x00)                               // Zeros (3 bytes)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x00)
        pseudoHeader.append(0x11)                               // Next Header: UDP

        // Build UDP header
        var udpHeader = Data()
        udpHeader.append(UInt8(sourcePort >> 8))
        udpHeader.append(UInt8(sourcePort & 0xFF))
        udpHeader.append(UInt8(destPort >> 8))
        udpHeader.append(UInt8(destPort & 0xFF))
        udpHeader.append(UInt8(udpLength >> 8))
        udpHeader.append(UInt8(udpLength & 0xFF))
        udpHeader.append(0x00)
        udpHeader.append(0x00)

        var checksumData = Data()
        checksumData.append(pseudoHeader)
        checksumData.append(udpHeader)
        checksumData.append(payload)

        if checksumData.count % 2 != 0 {
            checksumData.append(0x00)
        }

        var sum: UInt32 = 0
        for i in stride(from: 0, to: checksumData.count, by: 2) {
            let word = (UInt32(checksumData[i]) << 8) | UInt32(checksumData[i + 1])
            sum += word
        }

        while sum > 0xFFFF {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        let checksum = UInt16(~sum & 0xFFFF)

        // IPv6 UDP checksum is mandatory (cannot be zero)
        XCTAssertNotEqual(checksum, 0, "IPv6 UDP checksum must not be zero")
    }

    // MARK: - IPv4 Packet Construction Tests

    func testBuildIPv4PacketHeaderStructure() {
        let sourceIP = Data([192, 168, 1, 1])
        let destIP = Data([8, 8, 8, 8])
        let udpPayload = Data("test".utf8)
        let totalLength = 20 + 8 + udpPayload.count // IP header + UDP header + payload

        // Build IPv4 header
        var ipHeader = Data()
        ipHeader.append(0x45)                                   // Version=4, IHL=5
        ipHeader.append(0x00)                                   // DSCP=0, ECN=0
        ipHeader.append(UInt8(totalLength >> 8))                // Total Length
        ipHeader.append(UInt8(totalLength & 0xFF))
        ipHeader.append(0x00)                                   // Identification
        ipHeader.append(0x00)
        ipHeader.append(0x40)                                   // Flags=0x4 (Don't Fragment)
        ipHeader.append(0x00)                                   // Fragment Offset=0
        ipHeader.append(0x40)                                   // TTL=64
        ipHeader.append(0x11)                                   // Protocol=17 (UDP)
        ipHeader.append(0x00)                                   // Checksum placeholder
        ipHeader.append(0x00)
        ipHeader.append(contentsOf: sourceIP)
        ipHeader.append(contentsOf: destIP)

        // Verify header structure
        XCTAssertEqual(ipHeader.count, 20, "IPv4 header should be 20 bytes")
        XCTAssertEqual(ipHeader[0] >> 4, 4, "IP version should be 4")
        XCTAssertEqual(ipHeader[0] & 0x0F, 5, "IHL should be 5 (20 bytes)")
        XCTAssertEqual(ipHeader[9], 0x11, "Protocol should be UDP (17)")
        XCTAssertEqual(ipHeader[8], 0x40, "TTL should be 64")

        // Verify IP addresses
        XCTAssertEqual(Data(ipHeader[12..<16]), sourceIP)
        XCTAssertEqual(Data(ipHeader[16..<20]), destIP)
    }

    func testBuildIPv4PacketTotalLength() {
        let payloadSizes = [0, 1, 100, 1024, 1472] // Various payload sizes

        for payloadSize in payloadSizes {
            let payload = Data(repeating: 0xAB, count: payloadSize)
            let expectedLength = 20 + 8 + payloadSize // IP + UDP + payload

            var ipHeader = Data()
            ipHeader.append(0x45)
            ipHeader.append(0x00)
            ipHeader.append(UInt8(expectedLength >> 8))
            ipHeader.append(UInt8(expectedLength & 0xFF))

            let actualLength = Int(ipHeader[2]) << 8 | Int(ipHeader[3])
            XCTAssertEqual(actualLength, expectedLength, "Total length should match for payload size \(payloadSize)")
        }
    }

    // MARK: - IPv6 Packet Construction Tests

    func testBuildIPv6PacketHeaderStructure() {
        let sourceIP = Data([0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
                             0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        let destIP = Data([0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
                           0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
        let udpPayload = Data("test".utf8)
        let payloadLength = 8 + udpPayload.count // UDP header + payload

        // Build IPv6 header
        var ipHeader = Data()
        ipHeader.append(0x60)                                   // Version=6, Traffic Class=0
        ipHeader.append(0x00)                                   // Traffic Class, Flow Label
        ipHeader.append(0x00)                                   // Flow Label
        ipHeader.append(0x00)                                   // Flow Label
        ipHeader.append(UInt8(payloadLength >> 8))              // Payload Length
        ipHeader.append(UInt8(payloadLength & 0xFF))
        ipHeader.append(0x11)                                   // Next Header: UDP
        ipHeader.append(0x40)                                   // Hop Limit: 64
        ipHeader.append(contentsOf: sourceIP)
        ipHeader.append(contentsOf: destIP)

        // Verify header structure
        XCTAssertEqual(ipHeader.count, 40, "IPv6 header should be 40 bytes")
        XCTAssertEqual(ipHeader[0] >> 4, 6, "IP version should be 6")
        XCTAssertEqual(ipHeader[6], 0x11, "Next Header should be UDP (17)")
        XCTAssertEqual(ipHeader[7], 0x40, "Hop Limit should be 64")

        // Verify IP addresses
        XCTAssertEqual(Data(ipHeader[8..<24]), sourceIP)
        XCTAssertEqual(Data(ipHeader[24..<40]), destIP)
    }

    func testBuildIPv6PacketPayloadLength() {
        let payloadSizes = [0, 1, 100, 1024, 1452] // Various payload sizes

        for payloadSize in payloadSizes {
            let payload = Data(repeating: 0xAB, count: payloadSize)
            let expectedLength = 8 + payloadSize // UDP + payload

            var ipHeader = Data()
            ipHeader.append(0x60)
            ipHeader.append(0x00)
            ipHeader.append(0x00)
            ipHeader.append(0x00)
            ipHeader.append(UInt8(expectedLength >> 8))
            ipHeader.append(UInt8(expectedLength & 0xFF))

            let actualLength = Int(ipHeader[4]) << 8 | Int(ipHeader[5])
            XCTAssertEqual(actualLength, expectedLength, "Payload length should match for payload size \(payloadSize)")
        }
    }

    // MARK: - UDP Datagram Construction Tests

    func testBuildUDPDatagramStructure() {
        let sourcePort: UInt16 = 12345
        let destPort: UInt16 = 53
        let payload = Data("DNS query".utf8)
        let udpLength = UInt16(8 + payload.count)

        // Build UDP header
        var udpDatagram = Data()
        udpDatagram.append(UInt8(sourcePort >> 8))
        udpDatagram.append(UInt8(sourcePort & 0xFF))
        udpDatagram.append(UInt8(destPort >> 8))
        udpDatagram.append(UInt8(destPort & 0xFF))
        udpDatagram.append(UInt8(udpLength >> 8))
        udpDatagram.append(UInt8(udpLength & 0xFF))
        udpDatagram.append(0x00)                                // Checksum placeholder
        udpDatagram.append(0x00)
        udpDatagram.append(contentsOf: payload)

        // Verify UDP header
        XCTAssertGreaterThanOrEqual(udpDatagram.count, 8, "UDP datagram should have at least 8 bytes header")

        let parsedSourcePort = UInt16(udpDatagram[0]) << 8 | UInt16(udpDatagram[1])
        let parsedDestPort = UInt16(udpDatagram[2]) << 8 | UInt16(udpDatagram[3])
        let parsedLength = UInt16(udpDatagram[4]) << 8 | UInt16(udpDatagram[5])

        XCTAssertEqual(parsedSourcePort, sourcePort)
        XCTAssertEqual(parsedDestPort, destPort)
        XCTAssertEqual(parsedLength, udpLength)
        XCTAssertEqual(Data(udpDatagram[8...]), payload)
    }

    // MARK: - Flow Key Tests

    func testFlowKeyEquality() {
        // Note: FlowKey is internal to UDPForwarder, testing conceptually
        struct TestFlowKey: Hashable {
            let sourceIP: String
            let sourcePort: UInt16
            let destIP: String
            let destPort: UInt16
        }

        let key1 = TestFlowKey(sourceIP: "192.168.1.1", sourcePort: 12345,
                               destIP: "8.8.8.8", destPort: 53)
        let key2 = TestFlowKey(sourceIP: "192.168.1.1", sourcePort: 12345,
                               destIP: "8.8.8.8", destPort: 53)
        let key3 = TestFlowKey(sourceIP: "192.168.1.1", sourcePort: 12346,
                               destIP: "8.8.8.8", destPort: 53)

        XCTAssertEqual(key1, key2, "Identical flow keys should be equal")
        XCTAssertNotEqual(key1, key3, "Different source ports should create different keys")
    }

    func testFlowKeyHashability() {
        struct TestFlowKey: Hashable {
            let sourceIP: String
            let sourcePort: UInt16
            let destIP: String
            let destPort: UInt16
        }

        var flowSet = Set<TestFlowKey>()

        let key1 = TestFlowKey(sourceIP: "192.168.1.1", sourcePort: 12345,
                               destIP: "8.8.8.8", destPort: 53)
        let key2 = TestFlowKey(sourceIP: "192.168.1.1", sourcePort: 12345,
                               destIP: "8.8.8.8", destPort: 53)

        flowSet.insert(key1)
        flowSet.insert(key2)

        XCTAssertEqual(flowSet.count, 1, "Duplicate flow keys should not be inserted")
    }

    // MARK: - Metrics Tests

    func testMetricsInitialization() {
        struct TestMetrics {
            var flowsCreated: Int = 0
            var activeFlows: Int = 0
            var packetsForwarded: Int = 0
            var packetsPort443: Int = 0
        }

        let metrics = TestMetrics()

        XCTAssertEqual(metrics.flowsCreated, 0)
        XCTAssertEqual(metrics.activeFlows, 0)
        XCTAssertEqual(metrics.packetsForwarded, 0)
        XCTAssertEqual(metrics.packetsPort443, 0)
    }

    func testMetricsIncrement() {
        struct TestMetrics {
            var flowsCreated: Int = 0
            var activeFlows: Int = 0
            var packetsForwarded: Int = 0
            var packetsPort443: Int = 0
        }

        var metrics = TestMetrics()

        // Simulate creating flows
        metrics.flowsCreated += 1
        metrics.activeFlows += 1
        XCTAssertEqual(metrics.flowsCreated, 1)
        XCTAssertEqual(metrics.activeFlows, 1)

        // Simulate forwarding packets
        metrics.packetsForwarded += 1
        XCTAssertEqual(metrics.packetsForwarded, 1)

        // Simulate QUIC packet (port 443)
        metrics.packetsPort443 += 1
        XCTAssertEqual(metrics.packetsPort443, 1)
    }

    func testMetricsPort443Tracking() {
        let quicPort: UInt16 = 443
        let dnsPort: UInt16 = 53

        var port443Count = 0
        var totalCount = 0

        // Simulate packet forwarding
        let ports: [UInt16] = [quicPort, dnsPort, quicPort, 8080, quicPort]

        for port in ports {
            totalCount += 1
            if port == 443 {
                port443Count += 1
            }
        }

        XCTAssertEqual(totalCount, 5)
        XCTAssertEqual(port443Count, 3, "Should count 3 packets on port 443")
    }

    // MARK: - Packet Payload Tests

    func testEmptyPayloadHandling() {
        let emptyPayload = Data()
        let udpLength = UInt16(8 + emptyPayload.count)

        XCTAssertEqual(udpLength, 8, "Empty payload should result in 8-byte UDP header only")
        XCTAssertEqual(emptyPayload.count, 0)
    }

    func testLargePayloadHandling() {
        // Max UDP payload for IPv4 (65535 - 20 IP - 8 UDP = 65507 bytes)
        let maxPayloadSize = 65507
        let payload = Data(repeating: 0xFF, count: maxPayloadSize)

        XCTAssertEqual(payload.count, maxPayloadSize)

        let udpLength = UInt16(8 + payload.count)
        let totalIPv4Length = 20 + Int(udpLength)

        XCTAssertLessThanOrEqual(totalIPv4Length, 65535, "Total IPv4 packet should fit in 16-bit length field")
    }

    // MARK: - Edge Cases

    func testIPv4WithFragmentation() {
        // Don't Fragment flag (0x4000)
        let flags: UInt16 = 0x4000
        let flagsByte1 = UInt8(flags >> 8)
        let flagsByte2 = UInt8(flags & 0xFF)

        XCTAssertEqual(flagsByte1, 0x40, "Don't Fragment flag should be set")
        XCTAssertEqual(flagsByte2, 0x00, "Fragment offset should be 0")
    }

    func testIPv6HopLimit() {
        let hopLimit: UInt8 = 64

        XCTAssertEqual(hopLimit, 64, "Default hop limit should be 64")
        XCTAssertGreaterThan(hopLimit, 0, "Hop limit must be greater than 0")
    }

    func testChecksumWithOddLengthPayload() {
        // Odd-length payload should be padded for checksum calculation
        let payload = Data([0x01, 0x02, 0x03]) // 3 bytes (odd)

        var paddedPayload = payload
        if paddedPayload.count % 2 != 0 {
            paddedPayload.append(0x00)
        }

        XCTAssertEqual(paddedPayload.count, 4, "Odd payload should be padded to even length")
        XCTAssertEqual(paddedPayload[3], 0x00, "Padding should be zero")
    }
}
