//
//  IPPacketParserTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/21.
//

import XCTest
@testable import TracePacket

final class IPPacketParserTests: XCTestCase {
    // MARK: - IPv4 Parsing Tests

    func testParseIPv4BasicPacket() {
        // IPv4 packet: version=4, IHL=5 (20 bytes), total length=40, protocol=6 (TCP)
        // Source: 192.168.1.1, Destination: 192.168.1.2
        var data = Data([
            0x45,       // Version (4) + IHL (5)
            0x00,       // DSCP + ECN
            0x00, 0x28, // Total length: 40
            0x00, 0x00, // Identification
            0x00, 0x00, // Flags + Fragment offset
            0x40,       // TTL: 64
            0x06,       // Protocol: TCP (6)
            0x00, 0x00, // Header checksum
            0xC0, 0xA8, 0x01, 0x01, // Source: 192.168.1.1
            0xC0, 0xA8, 0x01, 0x02, // Destination: 192.168.1.2
        ])

        // Add 20 bytes of payload
        data.append(Data(repeating: 0xFF, count: 20))

        let packet = IPPacketParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.version, 4)
        XCTAssertEqual(packet?.headerLength, 20)
        XCTAssertEqual(packet?.totalLength, 40)
        XCTAssertEqual(packet?.protocolNumber, 6)
        XCTAssertEqual(packet?.source, .v4(0xC0A80101))
        XCTAssertEqual(packet?.destination, .v4(0xC0A80102))
        XCTAssertEqual(packet?.payload.count, 20)
        XCTAssertEqual(packet?.transport, .tcp)
    }

    func testParseIPv4WithOptions() {
        // IPv4 packet with options: IHL=6 (24 bytes)
        var data = Data([
            0x46,       // Version (4) + IHL (6)
            0x00,       // DSCP + ECN
            0x00, 0x2C, // Total length: 44
            0x00, 0x00, // Identification
            0x00, 0x00, // Flags + Fragment offset
            0x40,       // TTL: 64
            0x11,       // Protocol: UDP (17)
            0x00, 0x00, // Header checksum
            0x0A, 0x00, 0x00, 0x01, // Source: 10.0.0.1
            0x0A, 0x00, 0x00, 0x02, // Destination: 10.0.0.2
            0x01, 0x02, 0x03, 0x04, // Options (4 bytes)
        ])

        // Add 20 bytes of payload
        data.append(Data(repeating: 0xAA, count: 20))

        let packet = IPPacketParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.version, 4)
        XCTAssertEqual(packet?.headerLength, 24)
        XCTAssertEqual(packet?.totalLength, 44)
        XCTAssertEqual(packet?.protocolNumber, 17)
        XCTAssertEqual(packet?.source, .v4(0x0A000001))
        XCTAssertEqual(packet?.destination, .v4(0x0A000002))
        XCTAssertEqual(packet?.payload.count, 20)
        XCTAssertEqual(packet?.transport, .udp)
    }

    func testParseIPv4EmptyPayload() {
        // Minimal IPv4 packet with no payload
        let data = Data([
            0x45,       // Version (4) + IHL (5)
            0x00,       // DSCP + ECN
            0x00, 0x14, // Total length: 20
            0x00, 0x00, // Identification
            0x00, 0x00, // Flags + Fragment offset
            0x40,       // TTL: 64
            0x06,       // Protocol: TCP (6)
            0x00, 0x00, // Header checksum
            0x7F, 0x00, 0x00, 0x01, // Source: 127.0.0.1
            0x7F, 0x00, 0x00, 0x01, // Destination: 127.0.0.1
        ])

        let packet = IPPacketParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.payload.count, 0)
    }

    func testParseIPv4InvalidTooShort() {
        let data = Data([0x45, 0x00, 0x00]) // Only 3 bytes
        let packet = IPPacketParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseIPv4InvalidHeaderLength() {
        // IHL too small (< 5)
        let data = Data([
            0x44,       // Version (4) + IHL (4) - invalid!
            0x00,
            0x00, 0x14,
            0x00, 0x00, 0x00, 0x00,
            0x40, 0x06, 0x00, 0x00,
            0x7F, 0x00, 0x00, 0x01,
            0x7F, 0x00, 0x00, 0x01,
        ])

        let packet = IPPacketParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseIPv4InvalidTotalLength() {
        // Total length is less than header length
        let data = Data([
            0x45,       // Version (4) + IHL (5)
            0x00,
            0x00, 0x10, // Total length: 16 (less than IHL * 4 = 20)
            0x00, 0x00, 0x00, 0x00,
            0x40, 0x06, 0x00, 0x00,
            0x7F, 0x00, 0x00, 0x01,
            0x7F, 0x00, 0x00, 0x01,
        ])

        let packet = IPPacketParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseIPv4UnknownProtocol() {
        var data = Data([
            0x45,       // Version (4) + IHL (5)
            0x00,
            0x00, 0x14, // Total length: 20
            0x00, 0x00, 0x00, 0x00,
            0x40,
            0xFF,       // Protocol: 255 (unknown)
            0x00, 0x00,
            0x7F, 0x00, 0x00, 0x01,
            0x7F, 0x00, 0x00, 0x01,
        ])

        let packet = IPPacketParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.protocolNumber, 255)
        XCTAssertNil(packet?.transport) // Unknown protocol
    }

    // MARK: - IPv6 Parsing Tests

    func testParseIPv6BasicPacket() {
        // IPv6 packet: version=6, payload length=20, next header=6 (TCP)
        // Source: 2001:0db8::1, Destination: 2001:0db8::2
        var data = Data([
            0x60,       // Version (6) + Traffic class (upper 4 bits)
            0x00, 0x00, 0x00, // Traffic class (lower 4) + Flow label
            0x00, 0x14, // Payload length: 20
            0x06,       // Next header: TCP (6)
            0x40,       // Hop limit: 64
            // Source address: 2001:0db8:0000:0000:0000:0000:0000:0001
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            // Destination address: 2001:0db8:0000:0000:0000:0000:0000:0002
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        ])

        // Add 20 bytes of payload
        data.append(Data(repeating: 0xFF, count: 20))

        let packet = IPPacketParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.version, 6)
        XCTAssertEqual(packet?.headerLength, 40)
        XCTAssertEqual(packet?.totalLength, 60)
        XCTAssertEqual(packet?.protocolNumber, 6)
        XCTAssertEqual(packet?.source, .v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001)))
        XCTAssertEqual(packet?.destination, .v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0002)))
        XCTAssertEqual(packet?.payload.count, 20)
        XCTAssertEqual(packet?.transport, .tcp)
    }

    func testParseIPv6Loopback() {
        // IPv6 loopback: ::1
        var data = Data([
            0x60, 0x00, 0x00, 0x00,
            0x00, 0x08, // Payload length: 8
            0x11,       // Next header: UDP (17)
            0x40,
            // Source: ::1
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            // Destination: ::1
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        ])

        data.append(Data(repeating: 0xAA, count: 8))

        let packet = IPPacketParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.source, .v6((0, 1)))
        XCTAssertEqual(packet?.destination, .v6((0, 1)))
        XCTAssertEqual(packet?.transport, .udp)
    }

    func testParseIPv6EmptyPayload() {
        let data = Data([
            0x60, 0x00, 0x00, 0x00,
            0x00, 0x00, // Payload length: 0
            0x06,       // Next header: TCP
            0x40,
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        ])

        let packet = IPPacketParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.payload.count, 0)
    }

    func testParseIPv6InvalidTooShort() {
        let data = Data([0x60, 0x00, 0x00]) // Only 3 bytes
        let packet = IPPacketParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseIPv6InvalidPayloadLength() {
        // Payload length larger than available data
        let data = Data([
            0x60, 0x00, 0x00, 0x00,
            0xFF, 0xFF, // Payload length: 65535
            0x06, 0x40,
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        ])

        let packet = IPPacketParser.parse(data)
        XCTAssertNil(packet)
    }

    // MARK: - Version Detection Tests

    func testParseEmptyData() {
        let packet = IPPacketParser.parse(Data())
        XCTAssertNil(packet)
    }

    func testParseInvalidVersion() {
        // Version 5 (not supported)
        let data = Data([0x50, 0x00, 0x00, 0x00])
        let packet = IPPacketParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseVersion7() {
        // Version 7 (not supported)
        let data = Data([0x70, 0x00, 0x00, 0x00])
        let packet = IPPacketParser.parse(data)
        XCTAssertNil(packet)
    }

    // MARK: - Transport Protocol Tests

    func testTransportProtocolTCP() {
        var data = Data([
            0x45, 0x00, 0x00, 0x14,
            0x00, 0x00, 0x00, 0x00,
            0x40, 0x06, 0x00, 0x00, // Protocol: 6 (TCP)
            0x7F, 0x00, 0x00, 0x01,
            0x7F, 0x00, 0x00, 0x01,
        ])

        let packet = IPPacketParser.parse(data)
        XCTAssertEqual(packet?.transport, .tcp)
    }

    func testTransportProtocolUDP() {
        var data = Data([
            0x45, 0x00, 0x00, 0x14,
            0x00, 0x00, 0x00, 0x00,
            0x40, 0x11, 0x00, 0x00, // Protocol: 17 (UDP)
            0x7F, 0x00, 0x00, 0x01,
            0x7F, 0x00, 0x00, 0x01,
        ])

        let packet = IPPacketParser.parse(data)
        XCTAssertEqual(packet?.transport, .udp)
    }
}
