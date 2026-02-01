//
//  PacketFlowRecordTests.swift
//  TraceTests
//
//  Created by Claude ​Code on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class PacketFlowRecordTests: XCTestCase {

    // MARK: - Enum Tests

    func testFlowTransportProtocolRawValues() {
        XCTAssertEqual(FlowTransportProtocol.tcp.rawValue, "tcp")
        XCTAssertEqual(FlowTransportProtocol.udp.rawValue, "udp")
        XCTAssertEqual(FlowTransportProtocol.unknown.rawValue, "unknown")
    }

    func testFlowProtocolHintRawValues() {
        XCTAssertEqual(FlowProtocolHint.http.rawValue, "http")
        XCTAssertEqual(FlowProtocolHint.tls.rawValue, "tls")
        XCTAssertEqual(FlowProtocolHint.quic.rawValue, "quic")
        XCTAssertEqual(FlowProtocolHint.unknown.rawValue, "unknown")
    }

    func testFlowConnectionStateRawValues() {
        XCTAssertEqual(FlowConnectionState.unknown.rawValue, "unknown")
        XCTAssertEqual(FlowConnectionState.connecting.rawValue, "connecting")
        XCTAssertEqual(FlowConnectionState.established.rawValue, "established")
        XCTAssertEqual(FlowConnectionState.closed.rawValue, "closed")
        XCTAssertEqual(FlowConnectionState.reset.rawValue, "reset")
        XCTAssertEqual(FlowConnectionState.halfOpen.rawValue, "halfOpen")
        XCTAssertEqual(FlowConnectionState.timedOut.rawValue, "timedOut")
    }

    func testFlowDirectionRawValues() {
        XCTAssertEqual(FlowDirection.clientToServer.rawValue, "clientToServer")
        XCTAssertEqual(FlowDirection.serverToClient.rawValue, "serverToClient")
        XCTAssertEqual(FlowDirection.sourceToDestination.rawValue, "sourceToDestination")
        XCTAssertEqual(FlowDirection.destinationToSource.rawValue, "destinationToSource")
    }

    // MARK: - FlowEndpoint Tests

    func testFlowEndpointInitialization() {
        let endpoint = FlowEndpoint(ip: "192.168.1.1", port: 443)
        XCTAssertEqual(endpoint.ip, "192.168.1.1")
        XCTAssertEqual(endpoint.port, 443)
    }

    func testFlowEndpointHashable() {
        let endpoint1 = FlowEndpoint(ip: "192.168.1.1", port: 443)
        let endpoint2 = FlowEndpoint(ip: "192.168.1.1", port: 443)
        let endpoint3 = FlowEndpoint(ip: "192.168.1.2", port: 443)

        XCTAssertEqual(endpoint1, endpoint2)
        XCTAssertNotEqual(endpoint1, endpoint3)

        var set = Set<FlowEndpoint>()
        set.insert(endpoint1)
        set.insert(endpoint2)
        XCTAssertEqual(set.count, 1)
    }

    func testFlowEndpointCodable() throws {
        let original = FlowEndpoint(ip: "10.0.0.1", port: 8080)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FlowEndpoint.self, from: data)

        XCTAssertEqual(decoded.ip, original.ip)
        XCTAssertEqual(decoded.port, original.port)
    }

    // MARK: - TCPOptionSummary Tests

    func testTCPOptionSummaryInitialization() {
        let summary = TCPOptionSummary()
        XCTAssertNil(summary.mss)
        XCTAssertNil(summary.windowScale)
        XCTAssertFalse(summary.sackPermitted)
        XCTAssertFalse(summary.timestampsPermitted)
    }

    func testTCPOptionSummaryWithValues() {
        let summary = TCPOptionSummary(
            mss: 1460,
            windowScale: 7,
            sackPermitted: true,
            timestampsPermitted: true
        )

        XCTAssertEqual(summary.mss, 1460)
        XCTAssertEqual(summary.windowScale, 7)
        XCTAssertTrue(summary.sackPermitted)
        XCTAssertTrue(summary.timestampsPermitted)
    }

    func testTCPOptionSummaryCodable() throws {
        let original = TCPOptionSummary(mss: 1460, windowScale: 8, sackPermitted: true, timestampsPermitted: false)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TCPOptionSummary.self, from: data)

        XCTAssertEqual(decoded.mss, original.mss)
        XCTAssertEqual(decoded.windowScale, original.windowScale)
        XCTAssertEqual(decoded.sackPermitted, original.sackPermitted)
        XCTAssertEqual(decoded.timestampsPermitted, original.timestampsPermitted)
    }

    // MARK: - FlowDirectionalStats Tests

    func testFlowDirectionalStatsInitialization() {
        let stats = FlowDirectionalStats()
        XCTAssertEqual(stats.bytes, 0)
        XCTAssertEqual(stats.packets, 0)
        XCTAssertEqual(stats.retransmissions, 0)
        XCTAssertEqual(stats.duplicateAcks, 0)
        XCTAssertEqual(stats.outOfOrder, 0)
        XCTAssertEqual(stats.zeroWindowEvents, 0)
        XCTAssertNil(stats.windowMin)
        XCTAssertNil(stats.windowMax)
    }

    func testFlowDirectionalStatsWindowAverage() {
        var stats = FlowDirectionalStats()
        XCTAssertNil(stats.windowAverage)

        stats.windowSum = 1000
        stats.windowSamples = 10
        XCTAssertEqual(stats.windowAverage, 100)

        stats.windowSamples = 0
        XCTAssertNil(stats.windowAverage)
    }

    func testFlowDirectionalStatsCodable() throws {
        let original = FlowDirectionalStats(
            bytes: 1024,
            packets: 10,
            retransmissions: 2,
            duplicateAcks: 1,
            outOfOrder: 0,
            zeroWindowEvents: 0,
            windowSum: 5000,
            windowSamples: 10,
            windowMin: 400,
            windowMax: 600
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FlowDirectionalStats.self, from: data)

        XCTAssertEqual(decoded.bytes, original.bytes)
        XCTAssertEqual(decoded.packets, original.packets)
        XCTAssertEqual(decoded.windowAverage, 500)
    }

    // MARK: - PacketFlowRecord Tests

    func testPacketFlowRecordInitialization() {
        let record = PacketFlowRecord(
            sourceIP: "192.168.1.100",
            destinationIP: "93.184.216.34",
            sourcePort: 54321,
            destinationPort: 443,
            transport: .tcp
        )

        XCTAssertEqual(record.sourceIP, "192.168.1.100")
        XCTAssertEqual(record.destinationIP, "93.184.216.34")
        XCTAssertEqual(record.sourcePort, 54321)
        XCTAssertEqual(record.destinationPort, 443)
        XCTAssertEqual(record.transport, .tcp)
        XCTAssertTrue(record.protocolHints.isEmpty)
        XCTAssertEqual(record.bytesFromSource, 0)
        XCTAssertEqual(record.bytesToSource, 0)
        XCTAssertFalse(record.isClosed)
        XCTAssertEqual(record.connectionState, .unknown)
    }

    func testPacketFlowRecordWithAllFields() {
        let clientEndpoint = FlowEndpoint(ip: "192.168.1.100", port: 54321)
        let serverEndpoint = FlowEndpoint(ip: "93.184.216.34", port: 443)
        let handshake = TCPHandshakeSummary(synTime: Date(), synAckTime: Date(), ackTime: Date())

        let record = PacketFlowRecord(
            sourceIP: "192.168.1.100",
            destinationIP: "93.184.216.34",
            sourcePort: 54321,
            destinationPort: 443,
            transport: .tcp,
            protocolHints: [.tls, .http],
            bytesFromSource: 1024,
            bytesToSource: 2048,
            packetsFromSource: 10,
            packetsToSource: 15,
            isClosed: false,
            tlsSNI: "example.com",
            alpn: ["h2", "http/1.1"],
            clientEndpoint: clientEndpoint,
            serverEndpoint: serverEndpoint,
            connectionState: .established,
            tcpHandshake: handshake
        )

        XCTAssertEqual(record.protocolHints.count, 2)
        XCTAssertEqual(record.bytesFromSource, 1024)
        XCTAssertEqual(record.bytesToSource, 2048)
        XCTAssertEqual(record.tlsSNI, "example.com")
        XCTAssertEqual(record.alpn?.count, 2)
        XCTAssertEqual(record.connectionState, .established)
    }

    func testPacketFlowRecordCodable() throws {
        let original = PacketFlowRecord(
            sourceIP: "10.0.0.1",
            destinationIP: "10.0.0.2",
            sourcePort: 1234,
            destinationPort: 5678,
            transport: .udp,
            protocolHints: [.quic],
            bytesFromSource: 512,
            bytesToSource: 1024
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PacketFlowRecord.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.sourceIP, original.sourceIP)
        XCTAssertEqual(decoded.destinationIP, original.destinationIP)
        XCTAssertEqual(decoded.sourcePort, original.sourcePort)
        XCTAssertEqual(decoded.destinationPort, original.destinationPort)
        XCTAssertEqual(decoded.transport, original.transport)
        XCTAssertEqual(decoded.protocolHints, original.protocolHints)
        XCTAssertEqual(decoded.bytesFromSource, original.bytesFromSource)
        XCTAssertEqual(decoded.bytesToSource, original.bytesToSource)
    }

    func testPacketFlowRecordCustomDecoder() throws {
        // Test that custom decoder provides default values for missing fields
        let minimalJSON = """
        {
            "id": "\(UUID().uuidString)",
            "sourceIP": "1.2.3.4",
            "destinationIP": "5.6.7.8",
            "sourcePort": 80,
            "destinationPort": 443,
            "transport": "tcp"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PacketFlowRecord.self, from: minimalJSON)

        XCTAssertEqual(decoded.protocolHints, [])
        XCTAssertEqual(decoded.bytesFromSource, 0)
        XCTAssertEqual(decoded.bytesToSource, 0)
        XCTAssertEqual(decoded.packetsFromSource, 0)
        XCTAssertEqual(decoded.packetsToSource, 0)
        XCTAssertFalse(decoded.isClosed)
        XCTAssertEqual(decoded.connectionState, .unknown)
    }

    // MARK: - Edge Cases

    func testPacketFlowRecordWithIPv6() throws {
        let record = PacketFlowRecord(
            sourceIP: "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
            destinationIP: "2001:0db8:85a3:0000:0000:8a2e:0370:7335",
            sourcePort: 443,
            destinationPort: 8080,
            transport: .tcp
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(PacketFlowRecord.self, from: data)

        XCTAssertEqual(decoded.sourceIP, record.sourceIP)
        XCTAssertEqual(decoded.destinationIP, record.destinationIP)
    }

    func testPacketFlowRecordWithMaxValues() {
        let record = PacketFlowRecord(
            sourceIP: "255.255.255.255",
            destinationIP: "255.255.255.255",
            sourcePort: UInt16.max,
            destinationPort: UInt16.max,
            transport: .tcp,
            bytesFromSource: UInt64.max,
            bytesToSource: UInt64.max,
            packetsFromSource: UInt64.max,
            packetsToSource: UInt64.max
        )

        XCTAssertEqual(record.sourcePort, UInt16.max)
        XCTAssertEqual(record.destinationPort, UInt16.max)
        XCTAssertEqual(record.bytesFromSource, UInt64.max)
    }

    func testFlowEndpointWithZeroPort() {
        let endpoint = FlowEndpoint(ip: "0.0.0.0", port: 0)
        XCTAssertEqual(endpoint.port, 0)
    }

    func testTCPOptionSummaryWithMaxValues() {
        let summary = TCPOptionSummary(
            mss: UInt16.max,
            windowScale: UInt8.max,
            sackPermitted: true,
            timestampsPermitted: true
        )

        XCTAssertEqual(summary.mss, UInt16.max)
        XCTAssertEqual(summary.windowScale, UInt8.max)
    }

    func testFlowDirectionalStatsWithZeroSamples() {
        let stats = FlowDirectionalStats(windowSum: 1000, windowSamples: 0)
        XCTAssertNil(stats.windowAverage)
    }

    func testPacketFlowRecordIdentifiable() {
        let record1 = PacketFlowRecord(sourceIP: "1.1.1.1", destinationIP: "2.2.2.2", sourcePort: 80, destinationPort: 443, transport: .tcp)
        let record2 = PacketFlowRecord(sourceIP: "1.1.1.1", destinationIP: "2.2.2.2", sourcePort: 80, destinationPort: 443, transport: .tcp)

        XCTAssertNotEqual(record1.id, record2.id)
    }
}
