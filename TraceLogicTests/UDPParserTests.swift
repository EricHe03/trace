//
//  UDPParserTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/21.
//

@testable import TracePacket
import XCTest

final class UDPParserTests: XCTestCase {
    // MARK: - Basic Parsing Tests

    func testParseBasicUDPPacket() {
        let data = Data([
            0x00, 0x35, // Source port: 53 (DNS)
            0x1F, 0x90, // Destination port: 8080
            0x00, 0x10, // Length: 16 (8 header + 8 payload)
            0x00, 0x00, // Checksum
            // Payload (8 bytes)
            0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08
        ])

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.sourcePort, 53)
        XCTAssertEqual(packet?.destinationPort, 8080)
        XCTAssertEqual(packet?.length, 16)
        XCTAssertEqual(packet?.payload.count, 8)
        XCTAssertEqual(packet?.payload, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
    }

    func testParseUDPPacketEmptyPayload() {
        let data = Data([
            0x00, 0x35, // Source port: 53
            0x00, 0x35, // Destination port: 53
            0x00, 0x08, // Length: 8 (header only, no payload)
            0x00, 0x00 // Checksum
        ])

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.sourcePort, 53)
        XCTAssertEqual(packet?.destinationPort, 53)
        XCTAssertEqual(packet?.length, 8)
        XCTAssertEqual(packet?.payload.count, 0)
    }

    func testParseUDPPacketWithTextPayload() throws {
        var data = Data([
            0x1F, 0x90, // Source port: 8080
            0x1F, 0x90, // Destination port: 8080
            0x00, 0x15, // Length: 21 (8 header + 13 payload)
            0x00, 0x00 // Checksum
        ])

        // Add text payload
        let payload = Data("Hello, World!".utf8)
        data.append(payload)

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.payload, payload)
        XCTAssertEqual(try String(data: XCTUnwrap(packet?.payload), encoding: .utf8), "Hello, World!")
    }

    func testParseUDPPacketLargePayload() {
        var data = Data([
            0x00, 0x35, // Source port: 53
            0x1F, 0x90, // Destination port: 8080
            0x04, 0x08, // Length: 1032 (8 header + 1024 payload)
            0x00, 0x00 // Checksum
        ])

        // Add 1024 bytes of payload
        let payload = Data(repeating: 0xFF, count: 1024)
        data.append(payload)

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.length, 1032)
        XCTAssertEqual(packet?.payload.count, 1024)
    }

    // MARK: - Invalid Input Tests

    func testParseUDPPacketTooShort() {
        let data = Data([0x00, 0x35, 0x1F]) // Only 3 bytes
        let packet = UDPParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseUDPPacketInvalidLengthTooSmall() {
        let data = Data([
            0x00, 0x35,
            0x1F, 0x90,
            0x00, 0x07, // Length: 7 (less than minimum 8)
            0x00, 0x00
        ])

        let packet = UDPParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseUDPPacketInvalidLengthTooLarge() {
        let data = Data([
            0x00, 0x35,
            0x1F, 0x90,
            0xFF, 0xFF, // Length: 65535 (larger than available data)
            0x00, 0x00
        ])

        let packet = UDPParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseUDPPacketLengthMismatch() {
        // Length field says 16 bytes but only 12 bytes total
        let data = Data([
            0x00, 0x35,
            0x1F, 0x90,
            0x00, 0x10, // Length: 16
            0x00, 0x00,
            0x01, 0x02, 0x03, 0x04 // Only 4 bytes of payload (need 8)
        ])

        let packet = UDPParser.parse(data)
        XCTAssertNil(packet)
    }

    // MARK: - Edge Cases

    func testParseUDPPacketZeroPorts() {
        let data = Data([
            0x00, 0x00, // Source port: 0
            0x00, 0x00, // Destination port: 0
            0x00, 0x08, // Length: 8
            0x00, 0x00 // Checksum
        ])

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.sourcePort, 0)
        XCTAssertEqual(packet?.destinationPort, 0)
    }

    func testParseUDPPacketMaxPorts() {
        let data = Data([
            0xFF, 0xFF, // Source port: 65535
            0xFF, 0xFF, // Destination port: 65535
            0x00, 0x08, // Length: 8
            0x00, 0x00 // Checksum
        ])

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.sourcePort, 65535)
        XCTAssertEqual(packet?.destinationPort, 65535)
    }

    func testParseUDPPacketCommonPorts() {
        // DNS query
        let dns = Data([
            0xC3, 0x5E, // Source port: 50014
            0x00, 0x35, // Destination port: 53 (DNS)
            0x00, 0x10, // Length: 16
            0x00, 0x00, // Checksum
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
        ])

        let packet = UDPParser.parse(dns)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.destinationPort, 53)
    }

    func testParseUDPPacketExtraDataIgnored() {
        // Packet has extra data beyond the length field
        var data = Data([
            0x00, 0x35,
            0x1F, 0x90,
            0x00, 0x0C, // Length: 12 (8 header + 4 payload)
            0x00, 0x00,
            0x01, 0x02, 0x03, 0x04 // 4 bytes of payload
        ])

        // Add extra data that should be ignored
        data.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.payload.count, 4)
        XCTAssertEqual(packet?.payload, Data([0x01, 0x02, 0x03, 0x04]))
    }

    // MARK: - Real-world Protocol Tests

    func testParseUDPDNSQuery() {
        // Simplified DNS query packet
        var data = Data([
            0xC3, 0x5E, // Source port: random
            0x00, 0x35, // Destination port: 53 (DNS)
            0x00, 0x20, // Length: 32
            0x00, 0x00 // Checksum
        ])

        // Add 24 bytes of DNS query data
        data.append(Data(repeating: 0xAB, count: 24))

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.destinationPort, 53)
        XCTAssertEqual(packet?.payload.count, 24)
    }

    func testParseUDPDHCPDiscover() {
        // DHCP uses ports 67/68
        var data = Data([
            0x00, 0x44, // Source port: 68 (DHCP client)
            0x00, 0x43, // Destination port: 67 (DHCP server)
            0x01, 0x00, // Length: 256
            0x00, 0x00 // Checksum
        ])

        // Add 248 bytes of DHCP payload
        data.append(Data(repeating: 0x00, count: 248))

        let packet = UDPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.sourcePort, 68)
        XCTAssertEqual(packet?.destinationPort, 67)
        XCTAssertEqual(packet?.length, 256)
    }
}
