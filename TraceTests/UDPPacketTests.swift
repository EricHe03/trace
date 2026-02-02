//
//  UDPPacketTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TracePacket

final class UDPPacketTests: XCTestCase {

    // MARK: - Initialization Tests

    func testUDPPacketInitialization() {
        let packet = UDPPacket(
            sourcePort: 53,
            destinationPort: 12345,
            length: 16,
            payload: Data([0x01, 0x02, 0x03, 0x04])
        )

        XCTAssertEqual(packet.sourcePort, 53)
        XCTAssertEqual(packet.destinationPort, 12345)
        XCTAssertEqual(packet.length, 16)
        XCTAssertEqual(packet.payload.count, 4)
        XCTAssertEqual(packet.payload, Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testUDPPacketWithEmptyPayload() {
        let packet = UDPPacket(
            sourcePort: 53,
            destinationPort: 12345,
            length: 8,
            payload: Data()
        )

        XCTAssertEqual(packet.sourcePort, 53)
        XCTAssertEqual(packet.destinationPort, 12345)
        XCTAssertEqual(packet.length, 8)
        XCTAssertEqual(packet.payload.count, 0)
    }

    // MARK: - Port Tests

    func testSourcePort() {
        let packet = createUDPPacket(sourcePort: 8080)
        XCTAssertEqual(packet.sourcePort, 8080)
    }

    func testDestinationPort() {
        let packet = createUDPPacket(destinationPort: 53)
        XCTAssertEqual(packet.destinationPort, 53)
    }

    func testWellKnownPorts() {
        let ports: [UInt16] = [
            53,    // DNS
            67,    // DHCP server
            68,    // DHCP client
            123,   // NTP
            161,   // SNMP
            162,   // SNMP trap
            514,   // Syslog
            1900,  // SSDP
            5353   // mDNS
        ]

        for port in ports {
            let packet = createUDPPacket(destinationPort: port)
            XCTAssertEqual(packet.destinationPort, port)
        }
    }

    func testEphemeralPorts() {
        let ports: [UInt16] = [49152, 50000, 55555, 60000, 65535]

        for port in ports {
            let packet = createUDPPacket(sourcePort: port)
            XCTAssertEqual(packet.sourcePort, port)
        }
    }

    func testPortZero() {
        let packet = createUDPPacket(sourcePort: 0)
        XCTAssertEqual(packet.sourcePort, 0)
    }

    func testMaxPort() {
        let packet = createUDPPacket(destinationPort: 65535)
        XCTAssertEqual(packet.destinationPort, 65535)
    }

    // MARK: - Length Tests

    func testMinimumLength() {
        // UDP header is 8 bytes minimum
        let packet = createUDPPacket(length: 8, payload: Data())
        XCTAssertEqual(packet.length, 8)
    }

    func testLengthWithSmallPayload() {
        let payload = Data([0x01, 0x02])
        let packet = createUDPPacket(length: 10, payload: payload)
        XCTAssertEqual(packet.length, 10)
        XCTAssertEqual(packet.payload.count, 2)
    }

    func testLengthWithLargePayload() {
        let payload = Data(repeating: 0xFF, count: 1024)
        let packet = createUDPPacket(length: 1032, payload: payload)
        XCTAssertEqual(packet.length, 1032)
        XCTAssertEqual(packet.payload.count, 1024)
    }

    func testMaximumLength() {
        // Maximum UDP packet size is 65535 bytes
        let packet = createUDPPacket(length: 65535)
        XCTAssertEqual(packet.length, 65535)
    }

    func testLengthIncludesHeader() {
        // Length should be header (8 bytes) + payload
        let payload = Data(repeating: 0x00, count: 100)
        let packet = createUDPPacket(length: 108, payload: payload)

        XCTAssertEqual(packet.length, 108)
        XCTAssertEqual(packet.payload.count, 100)
    }

    // MARK: - Payload Tests

    func testEmptyPayload() {
        let packet = createUDPPacket(payload: Data())
        XCTAssertEqual(packet.payload.count, 0)
    }

    func testSingleBytePayload() {
        let payload = Data([0x42])
        let packet = createUDPPacket(payload: payload)

        XCTAssertEqual(packet.payload, payload)
        XCTAssertEqual(packet.payload.count, 1)
    }

    func testSmallPayload() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let packet = createUDPPacket(payload: payload)

        XCTAssertEqual(packet.payload, payload)
        XCTAssertEqual(packet.payload.count, 4)
    }

    func testMediumPayload() {
        let payload = Data(repeating: 0xAA, count: 512)
        let packet = createUDPPacket(payload: payload)

        XCTAssertEqual(packet.payload.count, 512)
    }

    func testLargePayload() {
        let payload = Data(repeating: 0xFF, count: 1472) // Typical max UDP payload for Ethernet
        let packet = createUDPPacket(payload: payload)

        XCTAssertEqual(packet.payload.count, 1472)
    }

    func testMaximumPayload() {
        let payload = Data(repeating: 0x55, count: 65527) // Max UDP payload (65535 - 8)
        let packet = createUDPPacket(length: 65535, payload: payload)

        XCTAssertEqual(packet.payload.count, 65527)
    }

    func testPayloadWithAllByteValues() {
        var payload = Data()
        for byte: UInt8 in 0...255 {
            payload.append(byte)
        }

        let packet = createUDPPacket(payload: payload)
        XCTAssertEqual(packet.payload.count, 256)
        XCTAssertEqual(packet.payload, payload)
    }

    // MARK: - Sendable Conformance Tests

    func testUDPPacketIsSendable() {
        let packet = createUDPPacket()

        Task {
            let _ = packet.sourcePort // Should compile without warnings
        }
    }

    func testConcurrentAccess() async {
        let packet = createUDPPacket()

        await withTaskGroup(of: UInt16.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    return packet.sourcePort
                }
            }

            for await port in group {
                XCTAssertEqual(port, 53)
            }
        }
    }

    // MARK: - Edge Cases

    func testPacketWithZeroPorts() {
        let packet = UDPPacket(
            sourcePort: 0,
            destinationPort: 0,
            length: 8,
            payload: Data()
        )

        XCTAssertEqual(packet.sourcePort, 0)
        XCTAssertEqual(packet.destinationPort, 0)
    }

    func testPacketWithMaxPorts() {
        let packet = UDPPacket(
            sourcePort: 65535,
            destinationPort: 65535,
            length: 8,
            payload: Data()
        )

        XCTAssertEqual(packet.sourcePort, 65535)
        XCTAssertEqual(packet.destinationPort, 65535)
    }

    func testPacketLengthMismatch() {
        // Length says 16, but payload is 4 bytes
        // This is allowed as the struct doesn't validate
        let packet = UDPPacket(
            sourcePort: 53,
            destinationPort: 12345,
            length: 16,
            payload: Data([0x01, 0x02, 0x03, 0x04])
        )

        XCTAssertEqual(packet.length, 16)
        XCTAssertEqual(packet.payload.count, 4)
    }

    // MARK: - DNS Packet Tests

    func testDNSQueryPacket() {
        // Typical DNS query structure
        let dnsQuery = Data([
            0x12, 0x34, // Transaction ID
            0x01, 0x00, // Flags
            0x00, 0x01, // Questions
            0x00, 0x00, // Answer RRs
            0x00, 0x00, // Authority RRs
            0x00, 0x00  // Additional RRs
        ])

        let packet = UDPPacket(
            sourcePort: 54321,
            destinationPort: 53,
            length: UInt16(8 + dnsQuery.count),
            payload: dnsQuery
        )

        XCTAssertEqual(packet.destinationPort, 53)
        XCTAssertEqual(packet.payload.count, 12)
    }

    func testDNSResponsePacket() {
        let dnsResponse = Data([
            0x12, 0x34, // Transaction ID
            0x81, 0x80, // Flags (response)
            0x00, 0x01, // Questions
            0x00, 0x01, // Answer RRs
            0x00, 0x00, // Authority RRs
            0x00, 0x00  // Additional RRs
        ])

        let packet = UDPPacket(
            sourcePort: 53,
            destinationPort: 54321,
            length: UInt16(8 + dnsResponse.count),
            payload: dnsResponse
        )

        XCTAssertEqual(packet.sourcePort, 53)
        XCTAssertEqual(packet.payload.count, 12)
    }

    // MARK: - DHCP Packet Tests

    func testDHCPDiscoverPacket() {
        let dhcpPayload = Data(repeating: 0x00, count: 236) // Simplified DHCP structure
        let packet = UDPPacket(
            sourcePort: 68,
            destinationPort: 67,
            length: UInt16(8 + dhcpPayload.count),
            payload: dhcpPayload
        )

        XCTAssertEqual(packet.sourcePort, 68)
        XCTAssertEqual(packet.destinationPort, 67)
    }

    func testDHCPOfferPacket() {
        let dhcpPayload = Data(repeating: 0x00, count: 236)
        let packet = UDPPacket(
            sourcePort: 67,
            destinationPort: 68,
            length: UInt16(8 + dhcpPayload.count),
            payload: dhcpPayload
        )

        XCTAssertEqual(packet.sourcePort, 67)
        XCTAssertEqual(packet.destinationPort, 68)
    }

    // MARK: - NTP Packet Tests

    func testNTPPacket() {
        let ntpPayload = Data(repeating: 0x00, count: 48) // NTP packet is 48 bytes
        let packet = UDPPacket(
            sourcePort: 54321,
            destinationPort: 123,
            length: UInt16(8 + ntpPayload.count),
            payload: ntpPayload
        )

        XCTAssertEqual(packet.destinationPort, 123)
        XCTAssertEqual(packet.payload.count, 48)
    }

    // MARK: - mDNS Packet Tests

    func testMDNSPacket() {
        let mdnsPayload = Data([
            0x00, 0x00, // Transaction ID
            0x00, 0x00, // Flags
            0x00, 0x01, // Questions
            0x00, 0x00, // Answer RRs
            0x00, 0x00, // Authority RRs
            0x00, 0x00  // Additional RRs
        ])

        let packet = UDPPacket(
            sourcePort: 5353,
            destinationPort: 5353,
            length: UInt16(8 + mdnsPayload.count),
            payload: mdnsPayload
        )

        XCTAssertEqual(packet.sourcePort, 5353)
        XCTAssertEqual(packet.destinationPort, 5353)
    }

    // MARK: - Comparison Tests

    func testUDPVsTCPHeaderSize() {
        // UDP header is 8 bytes, TCP is 20 bytes minimum
        let udpPacket = createUDPPacket(length: 8)
        XCTAssertEqual(udpPacket.length, 8)

        // UDP is more lightweight than TCP
        let udpHeaderSize = 8
        let tcpHeaderSize = 20
        XCTAssertLessThan(udpHeaderSize, tcpHeaderSize)
    }

    // MARK: - Real-World Scenarios

    func testStreamingAudioPacket() {
        // Typical RTP/audio streaming packet
        let audioPayload = Data(repeating: 0x00, count: 160) // 20ms of audio
        let packet = UDPPacket(
            sourcePort: 50000,
            destinationPort: 5004,
            length: UInt16(8 + audioPayload.count),
            payload: audioPayload
        )

        XCTAssertEqual(packet.payload.count, 160)
    }

    func testStreamingVideoPacket() {
        // Typical video streaming packet
        let videoPayload = Data(repeating: 0x00, count: 1400)
        let packet = UDPPacket(
            sourcePort: 50001,
            destinationPort: 5005,
            length: UInt16(8 + videoPayload.count),
            payload: videoPayload
        )

        XCTAssertEqual(packet.payload.count, 1400)
    }

    func testVoIPPacket() {
        // Typical VoIP packet (RTP)
        let voipPayload = Data(repeating: 0x00, count: 172) // RTP header + audio
        let packet = UDPPacket(
            sourcePort: 50002,
            destinationPort: 5060,
            length: UInt16(8 + voipPayload.count),
            payload: voipPayload
        )

        XCTAssertEqual(packet.payload.count, 172)
    }

    func testSyslogPacket() {
        let syslogMessage = "<34>1 2023-01-01T12:00:00Z host app - - - Test message".data(using: .utf8)!
        let packet = UDPPacket(
            sourcePort: 50003,
            destinationPort: 514,
            length: UInt16(8 + syslogMessage.count),
            payload: syslogMessage
        )

        XCTAssertEqual(packet.destinationPort, 514)
        XCTAssertGreaterThan(packet.payload.count, 0)
    }

    func testSNMPPacket() {
        let snmpPayload = Data(repeating: 0x00, count: 128)
        let packet = UDPPacket(
            sourcePort: 50004,
            destinationPort: 161,
            length: UInt16(8 + snmpPayload.count),
            payload: snmpPayload
        )

        XCTAssertEqual(packet.destinationPort, 161)
        XCTAssertEqual(packet.payload.count, 128)
    }

    // MARK: - Fragmentation Tests

    func testUnfragmentedPacket() {
        // Packet small enough to not require fragmentation
        let payload = Data(repeating: 0x00, count: 1400)
        let packet = createUDPPacket(payload: payload)

        XCTAssertLessThan(packet.length, 1500) // MTU size
    }

    func testLargePacketRequiringFragmentation() {
        // Packet that would require IP fragmentation
        let payload = Data(repeating: 0x00, count: 9000)
        let packet = createUDPPacket(length: 9008, payload: payload)

        XCTAssertGreaterThan(packet.length, 1500) // Larger than typical MTU
    }

    // MARK: - Performance Tests

    func testCreateManyPackets() {
        measure {
            for i in 0..<1000 {
                let payload = Data([UInt8(i % 256)])
                _ = createUDPPacket(
                    sourcePort: UInt16(i % 65536),
                    destinationPort: 53,
                    payload: payload
                )
            }
        }
    }

    func testAccessPacketProperties() {
        let packet = createUDPPacket()

        measure {
            for _ in 0..<10000 {
                _ = packet.sourcePort
                _ = packet.destinationPort
                _ = packet.length
                _ = packet.payload
            }
        }
    }

    // MARK: - Helper Methods

    private func createUDPPacket(
        sourcePort: UInt16 = 53,
        destinationPort: UInt16 = 12345,
        length: UInt16 = 12,
        payload: Data = Data([0x01, 0x02, 0x03, 0x04])
    ) -> UDPPacket {
        UDPPacket(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            length: length,
            payload: payload
        )
    }
}
