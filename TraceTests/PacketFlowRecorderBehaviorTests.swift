//
//  PacketFlowRecorderBehaviorTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/17.
//

import XCTest
@testable import TraceCore
@testable import TracePacket
@testable import TraceVPN

final class PacketFlowRecorderBehaviorTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try AppGroupStorage.shared.clearAllPacketFlowRecords()
        try AppGroupStorage.shared.clearAllUDPFlowMetadata()
    }

    override func tearDownWithError() throws {
        try AppGroupStorage.shared.clearAllPacketFlowRecords()
        try AppGroupStorage.shared.clearAllUDPFlowMetadata()
        try super.tearDownWithError()
    }

    func testProcessReassembledFinalWithoutPayloadClosesFlow() throws {
        let recorder = PacketFlowRecorder(idleTimeout: 60, flushInterval: 60, maxFlows: 16)
        let sourceIP: UInt32 = 0x0A000001 // 10.0.0.1
        let destinationIP: UInt32 = 0x5DB8D822 // 93.184.216.34
        let sourcePort: UInt16 = 50_000
        let destinationPort: UInt16 = 443

        let initialPacket = makeTCPIPPacket(
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequence: 1_000,
            flags: 0x18,
            payload: Data("hello".utf8)
        )
        recorder.process(ipPacket: initialPacket)
        XCTAssertEqual(recorder.activeFlowCountForTesting(), 1)

        let flow = FlowKey(
            sourceIP: .v4(sourceIP),
            destinationIP: .v4(destinationIP),
            sourcePort: sourcePort,
            destinationPort: destinationPort
        )
        recorder.processReassembled(flow: flow, data: Data(), isFinal: true)
        XCTAssertEqual(recorder.activeFlowCountForTesting(), 0)

        let records = try AppGroupStorage.shared.loadAllPacketFlowRecords()
        let record = try XCTUnwrap(records.first { $0.transport == .tcp })
        XCTAssertTrue(record.isClosed)
    }

    func testMaxFlowsIsStrictlyEnforced() {
        let recorder = PacketFlowRecorder(idleTimeout: 3_600, flushInterval: 3_600, maxFlows: 1)

        let firstPacket = makeTCPIPPacket(
            sourceIP: 0x0A000001,
            destinationIP: 0x08080808,
            sourcePort: 40_001,
            destinationPort: 80,
            sequence: 1_000,
            flags: 0x18,
            payload: Data("flow-1".utf8)
        )
        let secondPacket = makeTCPIPPacket(
            sourceIP: 0x0A000002,
            destinationIP: 0x01010101,
            sourcePort: 40_002,
            destinationPort: 443,
            sequence: 2_000,
            flags: 0x18,
            payload: Data("flow-2".utf8)
        )

        recorder.process(ipPacket: firstPacket)
        recorder.process(ipPacket: secondPacket)

        XCTAssertEqual(recorder.activeFlowCountForTesting(), 1)
        recorder.shutdown()
    }

    func testUDP443DoesNotReceiveTLSProtocolHint() throws {
        let recorder = PacketFlowRecorder(idleTimeout: 60, flushInterval: 0, maxFlows: 16)
        let sourcePort: UInt16 = 56_000
        let destinationPort: UInt16 = 443
        let payload = Data([0xC0, 0x00, 0x00, 0x00])
        let udpPacket = makeUDPIPPacket(
            sourceIP: 0x0A000001,
            destinationIP: 0x08080808,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload
        )

        recorder.process(ipPacket: udpPacket)
        recorder.shutdown()

        let records = try AppGroupStorage.shared.loadAllPacketFlowRecords()
        let record = try XCTUnwrap(
            records.first {
                $0.transport == .udp &&
                    Set([$0.sourcePort, $0.destinationPort]) == Set([sourcePort, destinationPort])
            }
        )

        XCTAssertFalse(record.protocolHints.contains(.tls))
        XCTAssertTrue(record.protocolHints.contains(.quic))
    }

    private func makeUDPIPPacket(
        sourceIP: UInt32,
        destinationIP: UInt32,
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: Data
    ) -> IPPacket {
        let udpPayload = makeUDPPayload(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            payload: payload
        )

        return IPPacket(
            version: 4,
            headerLength: 20,
            totalLength: 20 + udpPayload.count,
            protocolNumber: 17,
            source: .v4(sourceIP),
            destination: .v4(destinationIP),
            payload: udpPayload
        )
    }

    private func makeTCPIPPacket(
        sourceIP: UInt32,
        destinationIP: UInt32,
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequence: UInt32,
        flags: UInt8,
        payload: Data
    ) -> IPPacket {
        let tcpPayload = makeTCPPayload(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequence: sequence,
            acknowledgment: 0,
            flags: flags,
            payload: payload
        )

        return IPPacket(
            version: 4,
            headerLength: 20,
            totalLength: 20 + tcpPayload.count,
            protocolNumber: 6,
            source: .v4(sourceIP),
            destination: .v4(destinationIP),
            payload: tcpPayload
        )
    }

    private func makeUDPPayload(sourcePort: UInt16, destinationPort: UInt16, payload: Data) -> Data {
        let length = UInt16(8 + payload.count)
        var data = Data(capacity: 8 + payload.count)
        data.append(UInt8(sourcePort >> 8))
        data.append(UInt8(sourcePort & 0xFF))
        data.append(UInt8(destinationPort >> 8))
        data.append(UInt8(destinationPort & 0xFF))
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(0)
        data.append(0)
        data.append(payload)
        return data
    }

    private func makeTCPPayload(
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequence: UInt32,
        acknowledgment: UInt32,
        flags: UInt8,
        payload: Data
    ) -> Data {
        var data = Data(capacity: 20 + payload.count)
        data.append(UInt8(sourcePort >> 8))
        data.append(UInt8(sourcePort & 0xFF))
        data.append(UInt8(destinationPort >> 8))
        data.append(UInt8(destinationPort & 0xFF))
        data.append(UInt8((sequence >> 24) & 0xFF))
        data.append(UInt8((sequence >> 16) & 0xFF))
        data.append(UInt8((sequence >> 8) & 0xFF))
        data.append(UInt8(sequence & 0xFF))
        data.append(UInt8((acknowledgment >> 24) & 0xFF))
        data.append(UInt8((acknowledgment >> 16) & 0xFF))
        data.append(UInt8((acknowledgment >> 8) & 0xFF))
        data.append(UInt8(acknowledgment & 0xFF))
        data.append(0x50) // Data offset 5 (20-byte header)
        data.append(flags)
        data.append(0x20) // Window size high byte
        data.append(0x00) // Window size low byte
        data.append(0x00) // Checksum high byte (ignored by parser)
        data.append(0x00) // Checksum low byte
        data.append(0x00) // Urgent pointer high byte
        data.append(0x00) // Urgent pointer low byte
        data.append(payload)
        return data
    }
}
