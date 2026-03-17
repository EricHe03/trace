//
//  IPAddressTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/21.
//

import XCTest
@testable import TracePacket

final class IPAddressTests: XCTestCase {
    // MARK: - IPv4 Tests

    func testIPv4Creation() {
        let ip = IPAddress.v4(0x7F000001) // 127.0.0.1
        if case let .v4(value) = ip {
            XCTAssertEqual(value, 0x7F000001)
        } else {
            XCTFail("Expected IPv4 address")
        }
    }

    func testIPv4Description() {
        let ip = IPAddress.v4(0x7F000001) // 127.0.0.1
        XCTAssertEqual(ip.description, "127.0.0.1")

        let ip2 = IPAddress.v4(0xC0A80001) // 192.168.0.1
        XCTAssertEqual(ip2.description, "192.168.0.1")

        let ip3 = IPAddress.v4(0x08080808) // 8.8.8.8
        XCTAssertEqual(ip3.description, "8.8.8.8")

        let ip4 = IPAddress.v4(0x00000000) // 0.0.0.0
        XCTAssertEqual(ip4.description, "0.0.0.0")

        let ip5 = IPAddress.v4(0xFFFFFFFF) // 255.255.255.255
        XCTAssertEqual(ip5.description, "255.255.255.255")
    }

    func testIPv4Equality() {
        let ip1 = IPAddress.v4(0x7F000001)
        let ip2 = IPAddress.v4(0x7F000001)
        let ip3 = IPAddress.v4(0xC0A80001)

        XCTAssertEqual(ip1, ip2)
        XCTAssertNotEqual(ip1, ip3)
    }

    func testIPv4Hashing() {
        let ip1 = IPAddress.v4(0x7F000001)
        let ip2 = IPAddress.v4(0x7F000001)
        let ip3 = IPAddress.v4(0xC0A80001)

        var hasher1 = Hasher()
        ip1.hash(into: &hasher1)
        let hash1 = hasher1.finalize()

        var hasher2 = Hasher()
        ip2.hash(into: &hasher2)
        let hash2 = hasher2.finalize()

        var hasher3 = Hasher()
        ip3.hash(into: &hasher3)
        let hash3 = hasher3.finalize()

        XCTAssertEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
    }

    // MARK: - IPv6 Tests

    func testIPv6Creation() {
        let ip = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        if case let .v6((hi, lo)) = ip {
            XCTAssertEqual(hi, 0x2001_0db8_0000_0000)
            XCTAssertEqual(lo, 0x0000_0000_0000_0001)
        } else {
            XCTFail("Expected IPv6 address")
        }
    }

    func testIPv6Description() {
        let ip = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        XCTAssertEqual(ip.description, "2001:0db8:0000:0000:0000:0000:0000:0001")

        let loopback = IPAddress.v6((0x0000_0000_0000_0000, 0x0000_0000_0000_0001))
        XCTAssertEqual(loopback.description, "0000:0000:0000:0000:0000:0000:0000:0001")

        let allZeros = IPAddress.v6((0x0000_0000_0000_0000, 0x0000_0000_0000_0000))
        XCTAssertEqual(allZeros.description, "0000:0000:0000:0000:0000:0000:0000:0000")

        let allOnes = IPAddress.v6((0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF))
        XCTAssertEqual(allOnes.description, "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")
    }

    func testIPv6Equality() {
        let ip1 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        let ip2 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        let ip3 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0002))
        let ip4 = IPAddress.v6((0x2001_0db8_0000_0001, 0x0000_0000_0000_0001))

        XCTAssertEqual(ip1, ip2)
        XCTAssertNotEqual(ip1, ip3)
        XCTAssertNotEqual(ip1, ip4)
    }

    func testIPv6Hashing() {
        let ip1 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        let ip2 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))
        let ip3 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0002))

        var hasher1 = Hasher()
        ip1.hash(into: &hasher1)
        let hash1 = hasher1.finalize()

        var hasher2 = Hasher()
        ip2.hash(into: &hasher2)
        let hash2 = hasher2.finalize()

        var hasher3 = Hasher()
        ip3.hash(into: &hasher3)
        let hash3 = hasher3.finalize()

        XCTAssertEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
    }

    // MARK: - Mixed Type Tests

    func testIPv4AndIPv6NotEqual() {
        let ipv4 = IPAddress.v4(0x7F000001)
        let ipv6 = IPAddress.v6((0x0000_0000_0000_0000, 0x0000_0000_7F00_0001))

        XCTAssertNotEqual(ipv4, ipv6)
    }

    func testHashableInSet() {
        let ip1 = IPAddress.v4(0x7F000001)
        let ip2 = IPAddress.v4(0xC0A80001)
        let ip3 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))

        var set = Set<IPAddress>()
        set.insert(ip1)
        set.insert(ip2)
        set.insert(ip3)
        set.insert(ip1) // duplicate

        XCTAssertEqual(set.count, 3)
        XCTAssertTrue(set.contains(ip1))
        XCTAssertTrue(set.contains(ip2))
        XCTAssertTrue(set.contains(ip3))
    }

    func testHashableInDictionary() {
        let ip1 = IPAddress.v4(0x7F000001)
        let ip2 = IPAddress.v6((0x2001_0db8_0000_0000, 0x0000_0000_0000_0001))

        var dict = [IPAddress: String]()
        dict[ip1] = "localhost"
        dict[ip2] = "example"

        XCTAssertEqual(dict[ip1], "localhost")
        XCTAssertEqual(dict[ip2], "example")
        XCTAssertEqual(dict.count, 2)
    }
}
