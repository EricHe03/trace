//
//  TCPParserTests.swift
//  TraceTests
//
//  Created by Claude Code on 2026/01/21.
//

import XCTest
@testable import TracePacket

final class TCPParserTests: XCTestCase {
    // MARK: - Basic Parsing Tests

    func testParseBasicTCPPacket() {
        // TCP packet without options
        let data = Data([
            0x00, 0x50, // Source port: 80
            0x1F, 0x90, // Destination port: 8080
            0x00, 0x00, 0x00, 0x01, // Sequence number: 1
            0x00, 0x00, 0x00, 0x02, // Acknowledgment number: 2
            0x50,       // Data offset: 5 (20 bytes)
            0x18,       // Flags: PSH + ACK
            0x20, 0x00, // Window size: 8192
            0x00, 0x00, // Checksum
            0x00, 0x00, // Urgent pointer
        ])

        let packet = TCPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.sourcePort, 80)
        XCTAssertEqual(packet?.destinationPort, 8080)
        XCTAssertEqual(packet?.sequenceNumber, 1)
        XCTAssertEqual(packet?.acknowledgmentNumber, 2)
        XCTAssertEqual(packet?.dataOffset, 20)
        XCTAssertTrue(packet?.flags.contains(.psh) ?? false)
        XCTAssertTrue(packet?.flags.contains(.ack) ?? false)
        XCTAssertEqual(packet?.windowSize, 8192)
        XCTAssertEqual(packet?.payload.count, 0)
    }

    func testParseTCPPacketWithPayload() {
        var data = Data([
            0x00, 0x50, // Source port: 80
            0x1F, 0x90, // Destination port: 8080
            0x00, 0x00, 0x00, 0x01, // Sequence number: 1
            0x00, 0x00, 0x00, 0x02, // Acknowledgment number: 2
            0x50,       // Data offset: 5 (20 bytes)
            0x18,       // Flags: PSH + ACK
            0x20, 0x00, // Window size: 8192
            0x00, 0x00, // Checksum
            0x00, 0x00, // Urgent pointer
        ])

        // Add payload
        let payload = Data("Hello, World!".utf8)
        data.append(payload)

        let packet = TCPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.payload, payload)
    }

    func testParseTCPPacketInvalidTooShort() {
        let data = Data([0x00, 0x50, 0x1F]) // Only 3 bytes
        let packet = TCPParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseTCPPacketInvalidDataOffset() {
        // Data offset too small (< 5)
        let data = Data([
            0x00, 0x50,
            0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x40,       // Data offset: 4 (16 bytes) - invalid!
            0x18,
            0x20, 0x00,
            0x00, 0x00,
            0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertNil(packet)
    }

    func testParseTCPPacketInvalidDataOffsetTooLarge() {
        // Data offset larger than available data
        let data = Data([
            0x00, 0x50,
            0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0xF0,       // Data offset: 15 (60 bytes) but we only have 20
            0x18,
            0x20, 0x00,
            0x00, 0x00,
            0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertNil(packet)
    }

    // MARK: - TCP Flags Tests

    func testTCPFlagsSYN() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x50, 0x02, // Flags: SYN
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertTrue(packet?.flags.contains(.syn) ?? false)
        XCTAssertFalse(packet?.flags.contains(.ack) ?? true)
        XCTAssertFalse(packet?.flags.contains(.fin) ?? true)
    }

    func testTCPFlagsSYNACK() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x50, 0x12, // Flags: SYN + ACK
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertTrue(packet?.flags.contains(.syn) ?? false)
        XCTAssertTrue(packet?.flags.contains(.ack) ?? false)
    }

    func testTCPFlagsFIN() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x50, 0x11, // Flags: FIN + ACK
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertTrue(packet?.flags.contains(.fin) ?? false)
        XCTAssertTrue(packet?.flags.contains(.ack) ?? false)
    }

    func testTCPFlagsRST() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x50, 0x04, // Flags: RST
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertTrue(packet?.flags.contains(.rst) ?? false)
    }

    func testTCPFlagsURG() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x50, 0x30, // Flags: URG + ACK
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertTrue(packet?.flags.contains(.urg) ?? false)
        XCTAssertTrue(packet?.flags.contains(.ack) ?? false)
    }

    func testTCPFlagsAllSet() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x50, 0x3F, // All flags set
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertTrue(packet?.flags.contains(.fin) ?? false)
        XCTAssertTrue(packet?.flags.contains(.syn) ?? false)
        XCTAssertTrue(packet?.flags.contains(.rst) ?? false)
        XCTAssertTrue(packet?.flags.contains(.psh) ?? false)
        XCTAssertTrue(packet?.flags.contains(.ack) ?? false)
        XCTAssertTrue(packet?.flags.contains(.urg) ?? false)
    }

    // MARK: - TCP Options Tests

    func testTCPOptionsNoOptions() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x50, 0x18, // Data offset: 5, Flags: PSH + ACK
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertNil(packet?.options.mss)
        XCTAssertNil(packet?.options.windowScale)
        XCTAssertFalse(packet?.options.sackPermitted ?? true)
    }

    func testTCPOptionsMSS() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x60, 0x02, // Data offset: 6 (24 bytes), Flags: SYN
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
            // Options: MSS
            0x02,       // Kind: MSS
            0x04,       // Length: 4
            0x05, 0xB4, // MSS value: 1460
        ])

        let packet = TCPParser.parse(data)
        XCTAssertEqual(packet?.options.mss, 1460)
    }

    func testTCPOptionsWindowScale() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x60, 0x02, // Data offset: 6 (24 bytes), Flags: SYN
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
            // Options: Window Scale
            0x03,       // Kind: Window Scale
            0x03,       // Length: 3
            0x07,       // Scale: 7
            0x00,       // Padding
        ])

        let packet = TCPParser.parse(data)
        XCTAssertEqual(packet?.options.windowScale, 7)
    }

    func testTCPOptionsSACKPermitted() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x60, 0x02, // Data offset: 6 (24 bytes), Flags: SYN
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
            // Options: SACK Permitted
            0x04,       // Kind: SACK Permitted
            0x02,       // Length: 2
            0x00, 0x00, // Padding
        ])

        let packet = TCPParser.parse(data)
        XCTAssertTrue(packet?.options.sackPermitted ?? false)
    }

    func testTCPOptionsMultiple() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x80, 0x02, // Data offset: 8 (32 bytes), Flags: SYN
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
            // Options: MSS
            0x02, 0x04, 0x05, 0xB4,
            // Options: Window Scale
            0x03, 0x03, 0x07,
            // Options: SACK Permitted
            0x04, 0x02,
            // Padding
            0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertEqual(packet?.options.mss, 1460)
        XCTAssertEqual(packet?.options.windowScale, 7)
        XCTAssertTrue(packet?.options.sackPermitted ?? false)
    }

    func testTCPOptionsWithNOP() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x70, 0x02, // Data offset: 7 (28 bytes), Flags: SYN
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
            // Options
            0x01,       // NOP
            0x01,       // NOP
            0x02, 0x04, 0x05, 0xB4, // MSS
            0x00, 0x00, // Padding
        ])

        let packet = TCPParser.parse(data)
        XCTAssertEqual(packet?.options.mss, 1460)
    }

    func testTCPOptionsWithEOL() {
        let data = Data([
            0x00, 0x50, 0x1F, 0x90,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x02,
            0x70, 0x02, // Data offset: 7 (28 bytes), Flags: SYN
            0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
            // Options
            0x02, 0x04, 0x05, 0xB4, // MSS
            0x00,       // EOL (should stop parsing)
            0x03, 0x03, 0x07, // Window Scale (should be ignored)
        ])

        let packet = TCPParser.parse(data)
        XCTAssertEqual(packet?.options.mss, 1460)
        XCTAssertNil(packet?.options.windowScale) // Should not be parsed after EOL
    }

    // MARK: - Edge Cases

    func testTCPPacketLargePorts() {
        let data = Data([
            0xFF, 0xFF, // Source port: 65535
            0xFF, 0xFF, // Destination port: 65535
            0xFF, 0xFF, 0xFF, 0xFF, // Sequence number: max
            0xFF, 0xFF, 0xFF, 0xFF, // Acknowledgment number: max
            0x50, 0x18,
            0xFF, 0xFF, // Window size: 65535
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertEqual(packet?.sourcePort, 65535)
        XCTAssertEqual(packet?.destinationPort, 65535)
        XCTAssertEqual(packet?.sequenceNumber, 0xFFFFFFFF)
        XCTAssertEqual(packet?.acknowledgmentNumber, 0xFFFFFFFF)
        XCTAssertEqual(packet?.windowSize, 65535)
    }

    func testTCPPacketZeroValues() {
        let data = Data([
            0x00, 0x00, // Source port: 0
            0x00, 0x00, // Destination port: 0
            0x00, 0x00, 0x00, 0x00, // Sequence number: 0
            0x00, 0x00, 0x00, 0x00, // Acknowledgment number: 0
            0x50, 0x00, // Data offset: 5, Flags: none
            0x00, 0x00, // Window size: 0
            0x00, 0x00, 0x00, 0x00,
        ])

        let packet = TCPParser.parse(data)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.sourcePort, 0)
        XCTAssertEqual(packet?.destinationPort, 0)
        XCTAssertEqual(packet?.sequenceNumber, 0)
        XCTAssertEqual(packet?.acknowledgmentNumber, 0)
        XCTAssertEqual(packet?.windowSize, 0)
    }
}
