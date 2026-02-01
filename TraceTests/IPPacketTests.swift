//
//  IPPacketTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TracePacket

final class IPPacketTests: XCTestCase {

    // MARK: - Initialization Tests

    func testIPv4PacketInitialization() {
        let source = IPAddress.v4(0xC0A80001) // 192.168.0.1
        let destination = IPAddress.v4(0xC0A80002) // 192.168.0.2
        let payload = Data([0x01, 0x02, 0x03, 0x04])

        let packet = IPPacket(
            version: 4,
            headerLength: 20,
            totalLength: 24,
            protocolNumber: TransportProtocol.tcp.rawValue,
            source: source,
            destination: destination,
            payload: payload
        )

        XCTAssertEqual(packet.version, 4)
        XCTAssertEqual(packet.headerLength, 20)
        XCTAssertEqual(packet.totalLength, 24)
        XCTAssertEqual(packet.protocolNumber, 6)
        XCTAssertEqual(packet.source, source)
        XCTAssertEqual(packet.destination, destination)
        XCTAssertEqual(packet.payload, payload)
    }

    func testIPv6PacketInitialization() {
        let source = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        let destination = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0002))
        let payload = Data([0xFF, 0xFE])

        let packet = IPPacket(
            version: 6,
            headerLength: 40,
            totalLength: 42,
            protocolNumber: TransportProtocol.udp.rawValue,
            source: source,
            destination: destination,
            payload: payload
        )

        XCTAssertEqual(packet.version, 6)
        XCTAssertEqual(packet.headerLength, 40)
        XCTAssertEqual(packet.totalLength, 42)
        XCTAssertEqual(packet.protocolNumber, 17)
        XCTAssertEqual(packet.source, source)
        XCTAssertEqual(packet.destination, destination)
        XCTAssertEqual(packet.payload, payload)
    }

    // MARK: - Transport Protocol Tests

    func testTransportProtocolTCP() {
        let packet = createIPv4Packet(protocolNumber: TransportProtocol.tcp.rawValue)

        XCTAssertEqual(packet.transport, .tcp)
    }

    func testTransportProtocolUDP() {
        let packet = createIPv4Packet(protocolNumber: TransportProtocol.udp.rawValue)

        XCTAssertEqual(packet.transport, .udp)
    }

    func testTransportProtocolUnknown() {
        let packet = createIPv4Packet(protocolNumber: 99)

        XCTAssertNil(packet.transport)
    }

    func testTransportProtocolRawValues() {
        XCTAssertEqual(TransportProtocol.tcp.rawValue, 6)
        XCTAssertEqual(TransportProtocol.udp.rawValue, 17)
    }

    // MARK: - IPv4 Address Tests

    func testIPv4AddressCreation() {
        let address = IPAddress.v4(0xC0A80001) // 192.168.0.1

        if case let .v4(value) = address {
            XCTAssertEqual(value, 0xC0A80001)
        } else {
            XCTFail("Expected IPv4 address")
        }
    }

    func testIPv4AddressDescription() {
        let address = IPAddress.v4(0xC0A80001) // 192.168.0.1
        XCTAssertEqual(address.description, "192.168.0.1")
    }

    func testIPv4AddressLocalhostDescription() {
        let address = IPAddress.v4(0x7F000001) // 127.0.0.1
        XCTAssertEqual(address.description, "127.0.0.1")
    }

    func testIPv4AddressBroadcastDescription() {
        let address = IPAddress.v4(0xFFFFFFFF) // 255.255.255.255
        XCTAssertEqual(address.description, "255.255.255.255")
    }

    func testIPv4AddressZeroDescription() {
        let address = IPAddress.v4(0x00000000) // 0.0.0.0
        XCTAssertEqual(address.description, "0.0.0.0")
    }

    // MARK: - IPv6 Address Tests

    func testIPv6AddressCreation() {
        let address = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))

        if case let .v6((hi, lo)) = address {
            XCTAssertEqual(hi, 0x2001_0db8_0000_0000)
            XCTAssertEqual(lo, 0x0000_0000_0000_0001)
        } else {
            XCTFail("Expected IPv6 address")
        }
    }

    func testIPv6AddressDescription() {
        let address = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        XCTAssertEqual(address.description, "2001:0db8:0000:0000:0000:0000:0000:0001")
    }

    func testIPv6LoopbackDescription() {
        let address = IPAddress.v6((0x0000_0000_0000_0000, 0x0000_0000_0000_0001)) // ::1
        XCTAssertEqual(address.description, "0000:0000:0000:0000:0000:0000:0000:0001")
    }

    func testIPv6AllZerosDescription() {
        let address = IPAddress.v6((0x0000_0000_0000_0000, 0x0000_0000_0000_0000)) // ::
        XCTAssertEqual(address.description, "0000:0000:0000:0000:0000:0000:0000:0000")
    }

    // MARK: - IP Address Equality Tests

    func testIPv4AddressEquality() {
        let address1 = IPAddress.v4(0xC0A80001)
        let address2 = IPAddress.v4(0xC0A80001)

        XCTAssertEqual(address1, address2)
    }

    func testIPv4AddressInequality() {
        let address1 = IPAddress.v4(0xC0A80001)
        let address2 = IPAddress.v4(0xC0A80002)

        XCTAssertNotEqual(address1, address2)
    }

    func testIPv6AddressEquality() {
        let address1 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        let address2 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))

        XCTAssertEqual(address1, address2)
    }

    func testIPv6AddressInequality() {
        let address1 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        let address2 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0002))

        XCTAssertNotEqual(address1, address2)
    }

    func testIPv4AndIPv6AddressInequality() {
        let address1 = IPAddress.v4(0xC0A80001)
        let address2 = IPAddress.v6((0x0000_0000_0000_0000, 0x0000_0000_C0A8_0001))

        XCTAssertNotEqual(address1, address2)
    }

    // MARK: - IP Address Hashing Tests

    func testIPv4AddressHashing() {
        let address = IPAddress.v4(0xC0A80001)
        var hasher = Hasher()
        address.hash(into: &hasher)

        // Just verify it doesn't crash
        _ = hasher.finalize()
    }

    func testIPv6AddressHashing() {
        let address = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        var hasher = Hasher()
        address.hash(into: &hasher)

        _ = hasher.finalize()
    }

    func testIPAddressHashConsistency() {
        let address1 = IPAddress.v4(0xC0A80001)
        let address2 = IPAddress.v4(0xC0A80001)

        var hasher1 = Hasher()
        var hasher2 = Hasher()

        address1.hash(into: &hasher1)
        address2.hash(into: &hasher2)

        XCTAssertEqual(hasher1.finalize(), hasher2.finalize())
    }

    // MARK: - Packet Property Tests

    func testPacketVersion() {
        let packet = createIPv4Packet()
        XCTAssertEqual(packet.version, 4)

        let packetV6 = createIPv6Packet()
        XCTAssertEqual(packetV6.version, 6)
    }

    func testPacketHeaderLength() {
        let packet = createIPv4Packet(headerLength: 20)
        XCTAssertEqual(packet.headerLength, 20)

        let packet2 = createIPv4Packet(headerLength: 60)
        XCTAssertEqual(packet2.headerLength, 60)
    }

    func testPacketTotalLength() {
        let packet = createIPv4Packet(totalLength: 100)
        XCTAssertEqual(packet.totalLength, 100)
    }

    func testPacketProtocolNumber() {
        let packet = createIPv4Packet(protocolNumber: 6)
        XCTAssertEqual(packet.protocolNumber, 6)
    }

    func testPacketPayload() {
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let packet = createIPv4Packet(payload: payload)

        XCTAssertEqual(packet.payload, payload)
        XCTAssertEqual(packet.payload.count, 5)
    }

    func testPacketEmptyPayload() {
        let packet = createIPv4Packet(payload: Data())
        XCTAssertEqual(packet.payload.count, 0)
    }

    func testPacketLargePayload() {
        let payload = Data(repeating: 0xFF, count: 1500)
        let packet = createIPv4Packet(payload: payload)
        XCTAssertEqual(packet.payload.count, 1500)
    }

    // MARK: - Sendable Conformance Tests

    func testIPPacketIsSendable() {
        let packet = createIPv4Packet()

        Task {
            let _ = packet.version // Should compile without warnings
        }
    }

    func testIPAddressIsSendable() {
        let address = IPAddress.v4(0xC0A80001)

        Task {
            let _ = address.description // Should compile without warnings
        }
    }

    func testTransportProtocolIsSendable() {
        let proto = TransportProtocol.tcp

        Task {
            let _ = proto.rawValue // Should compile without warnings
        }
    }

    // MARK: - Edge Cases

    func testPacketWithZeroHeaderLength() {
        let packet = createIPv4Packet(headerLength: 0)
        XCTAssertEqual(packet.headerLength, 0)
    }

    func testPacketWithMaxHeaderLength() {
        let packet = createIPv4Packet(headerLength: 60)
        XCTAssertEqual(packet.headerLength, 60)
    }

    func testPacketWithMinimumTotalLength() {
        let packet = createIPv4Packet(totalLength: 20)
        XCTAssertEqual(packet.totalLength, 20)
    }

    func testPacketWithMaximumTotalLength() {
        let packet = createIPv4Packet(totalLength: 65535)
        XCTAssertEqual(packet.totalLength, 65535)
    }

    // MARK: - Common Protocol Numbers

    func testICMPProtocol() {
        let packet = createIPv4Packet(protocolNumber: 1)
        XCTAssertEqual(packet.protocolNumber, 1)
        XCTAssertNil(packet.transport)
    }

    func testIGMPProtocol() {
        let packet = createIPv4Packet(protocolNumber: 2)
        XCTAssertEqual(packet.protocolNumber, 2)
        XCTAssertNil(packet.transport)
    }

    // MARK: - Common IP Addresses

    func testPrivateNetworkAddresses() {
        let addresses = [
            IPAddress.v4(0x0A000001),    // 10.0.0.1
            IPAddress.v4(0xAC100001),    // 172.16.0.1
            IPAddress.v4(0xC0A80001)     // 192.168.0.1
        ]

        for address in addresses {
            let packet = IPPacket(
                version: 4,
                headerLength: 20,
                totalLength: 20,
                protocolNumber: 6,
                source: address,
                destination: IPAddress.v4(0x08080808),
                payload: Data()
            )

            XCTAssertEqual(packet.source, address)
        }
    }

    func testPublicIPAddresses() {
        let addresses = [
            IPAddress.v4(0x08080808),    // 8.8.8.8 (Google DNS)
            IPAddress.v4(0x01010101)     // 1.1.1.1 (Cloudflare DNS)
        ]

        for address in addresses {
            let packet = createIPv4Packet()
            XCTAssertNotEqual(packet.source, address)
        }
    }

    // MARK: - Helper Methods

    private func createIPv4Packet(
        headerLength: Int = 20,
        totalLength: Int = 40,
        protocolNumber: UInt8 = 6,
        payload: Data = Data([0x01, 0x02])
    ) -> IPPacket {
        IPPacket(
            version: 4,
            headerLength: headerLength,
            totalLength: totalLength,
            protocolNumber: protocolNumber,
            source: IPAddress.v4(0xC0A80001),
            destination: IPAddress.v4(0xC0A80002),
            payload: payload
        )
    }

    private func createIPv6Packet(
        headerLength: Int = 40,
        totalLength: Int = 60,
        protocolNumber: UInt8 = 17,
        payload: Data = Data([0xFF, 0xFE])
    ) -> IPPacket {
        IPPacket(
            version: 6,
            headerLength: headerLength,
            totalLength: totalLength,
            protocolNumber: protocolNumber,
            source: IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001)),
            destination: IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0002)),
            payload: payload
        )
    }
}
