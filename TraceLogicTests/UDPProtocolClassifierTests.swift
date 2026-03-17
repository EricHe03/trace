//
//  UDPProtocolClassifierTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

@testable import TraceCore
@testable import TraceVPNKit
import XCTest

final class UDPProtocolClassifierTests: XCTestCase {
    func testDNSClassification_ValidPayload() {
        let payload = makeDNSQuery()
        let result = UDPProtocolClassifier.classify(
            sourcePort: 53530,
            destinationPort: 53,
            payload: payload,
            sourceIP: "192.168.1.10",
            destinationIP: "8.8.8.8"
        )

        XCTAssertEqual(result.applicationProtocol, .dns)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testDNSClassification_InvalidPayloadFallsBack() {
        let result = UDPProtocolClassifier.classify(
            sourcePort: 53530,
            destinationPort: 53,
            payload: Data([0x00, 0x01]),
            sourceIP: "192.168.1.10",
            destinationIP: "8.8.8.8"
        )

        XCTAssertEqual(result.applicationProtocol, .unknown)
        XCTAssertEqual(result.parserOutcome, .fallbackSignatureOnly)
    }

    func testMDNSClassification_ValidPayload() {
        let payload = makeDNSQuery()
        let result = UDPProtocolClassifier.classify(
            sourcePort: 5353,
            destinationPort: 5353,
            payload: payload,
            sourceIP: "192.168.1.10",
            destinationIP: "224.0.0.251"
        )

        XCTAssertEqual(result.applicationProtocol, .mdns)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testNTPClassification_ValidHeader() {
        var payload = Data(repeating: 0, count: 48)
        payload[0] = 0x23 // LI=0, VN=4, Mode=3 (client)
        payload[1] = 2 // stratum

        let result = UDPProtocolClassifier.classify(
            sourcePort: 50000,
            destinationPort: 123,
            payload: payload,
            sourceIP: "192.168.1.10",
            destinationIP: "129.6.15.28"
        )

        XCTAssertEqual(result.applicationProtocol, .ntp)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testNTPClassification_InvalidHeaderFallsBack() {
        var payload = Data(repeating: 0, count: 48)
        payload[0] = 0x43 // VN=0x08 masked to invalid version 0
        payload[1] = 20 // invalid stratum

        let result = UDPProtocolClassifier.classify(
            sourcePort: 50000,
            destinationPort: 123,
            payload: payload,
            sourceIP: "192.168.1.10",
            destinationIP: "129.6.15.28"
        )

        XCTAssertEqual(result.applicationProtocol, .unknown)
        XCTAssertEqual(result.parserOutcome, .fallbackSignatureOnly)
    }

    func testDHCPv4Classification_ValidPacket() {
        let payload = makeDHCPv4Packet()
        let result = UDPProtocolClassifier.classify(
            sourcePort: 68,
            destinationPort: 67,
            payload: payload,
            sourceIP: "0.0.0.0",
            destinationIP: "255.255.255.255"
        )

        XCTAssertEqual(result.applicationProtocol, .dhcpv4)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testDHCPv4Classification_InvalidPacketFallsBack() {
        var payload = makeDHCPv4Packet()
        payload[236] = 0x00 // break magic cookie

        let result = UDPProtocolClassifier.classify(
            sourcePort: 68,
            destinationPort: 67,
            payload: payload,
            sourceIP: "0.0.0.0",
            destinationIP: "255.255.255.255"
        )

        XCTAssertEqual(result.applicationProtocol, .unknown)
        XCTAssertEqual(result.parserOutcome, .fallbackSignatureOnly)
    }

    func testDHCPv6Classification_StandardMessage() {
        let payload = Data([0x01, 0x00, 0x00, 0x01]) // SOLICIT + txid
        let result = UDPProtocolClassifier.classify(
            sourcePort: 546,
            destinationPort: 547,
            payload: payload,
            sourceIP: "fe80::1",
            destinationIP: "ff02::1:2"
        )

        XCTAssertEqual(result.applicationProtocol, .dhcpv6)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testDHCPv6Classification_RelayMessage() {
        var payload = Data(repeating: 0, count: 34)
        payload[0] = 12 // RELAY-FORW
        payload[1] = 1 // hop-count

        let result = UDPProtocolClassifier.classify(
            sourcePort: 547,
            destinationPort: 547,
            payload: payload,
            sourceIP: "fe80::1",
            destinationIP: "fe80::2"
        )

        XCTAssertEqual(result.applicationProtocol, .dhcpv6)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testDHCPv6Classification_ExtendedTypeAcceptedForForwardCompatibility() {
        let payload = Data([0x20, 0x00, 0x00, 0x01]) // non-zero extension type + txid
        let result = UDPProtocolClassifier.classify(
            sourcePort: 546,
            destinationPort: 547,
            payload: payload,
            sourceIP: "fe80::1",
            destinationIP: "ff02::1:2"
        )

        XCTAssertEqual(result.applicationProtocol, .dhcpv6)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testDHCPv6Classification_ZeroTypeFallsBack() {
        let payload = Data([0x00, 0x00, 0x00, 0x01])
        let result = UDPProtocolClassifier.classify(
            sourcePort: 546,
            destinationPort: 547,
            payload: payload,
            sourceIP: "fe80::1",
            destinationIP: "ff02::1:2"
        )

        XCTAssertEqual(result.applicationProtocol, .unknown)
        XCTAssertEqual(result.parserOutcome, .fallbackSignatureOnly)
    }

    func testSNMPClassification_ValidEnvelope() {
        let payload = Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x04, 0x01, 0x61])
        let result = UDPProtocolClassifier.classify(
            sourcePort: 50000,
            destinationPort: 161,
            payload: payload,
            sourceIP: "192.168.1.10",
            destinationIP: "192.168.1.20"
        )

        XCTAssertEqual(result.applicationProtocol, .snmp)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testSNMPClassification_InvalidVersionFallsBack() {
        let payload = Data([0x30, 0x06, 0x02, 0x01, 0x08, 0x04, 0x01, 0x61])
        let result = UDPProtocolClassifier.classify(
            sourcePort: 50000,
            destinationPort: 161,
            payload: payload,
            sourceIP: "192.168.1.10",
            destinationIP: "192.168.1.20"
        )

        XCTAssertEqual(result.applicationProtocol, .unknown)
        XCTAssertEqual(result.parserOutcome, .fallbackSignatureOnly)
    }

    func testQUICClassification_Port443Heuristic() {
        let payload = Data([0xC0, 0x00, 0x00, 0x01])
        let result = UDPProtocolClassifier.classify(
            sourcePort: 56000,
            destinationPort: 443,
            payload: payload,
            sourceIP: "192.168.1.10",
            destinationIP: "142.250.72.14"
        )

        XCTAssertEqual(result.applicationProtocol, .quic)
        XCTAssertEqual(result.parserOutcome, .parsed)
    }

    func testUnknownClassification_DefaultFallback() {
        let result = UDPProtocolClassifier.classify(
            sourcePort: 40000,
            destinationPort: 40001,
            payload: Data([0x01, 0x02, 0x03]),
            sourceIP: "10.0.0.1",
            destinationIP: "10.0.0.2"
        )

        XCTAssertEqual(result.applicationProtocol, .unknown)
        XCTAssertEqual(result.parserOutcome, .fallbackUnknown)
    }

    private func makeDNSQuery() -> Data {
        var data = Data()
        data.append(contentsOf: [0x12, 0x34]) // transaction id
        data.append(contentsOf: [0x01, 0x00]) // flags
        data.append(contentsOf: [0x00, 0x01]) // qdcount
        data.append(contentsOf: [0x00, 0x00]) // ancount
        data.append(contentsOf: [0x00, 0x00]) // nscount
        data.append(contentsOf: [0x00, 0x00]) // arcount
        data.append(0x07)
        data.append("example".data(using: .utf8)!)
        data.append(0x03)
        data.append("com".data(using: .utf8)!)
        data.append(0x00)
        data.append(contentsOf: [0x00, 0x01]) // type A
        data.append(contentsOf: [0x00, 0x01]) // class IN
        return data
    }

    private func makeDHCPv4Packet() -> Data {
        var data = Data(repeating: 0, count: 240)
        data[0] = 1 // op BOOTREQUEST
        data[1] = 1 // htype ethernet
        data[2] = 6 // hlen
        data[236] = 0x63
        data[237] = 0x82
        data[238] = 0x53
        data[239] = 0x63
        return data
    }
}
