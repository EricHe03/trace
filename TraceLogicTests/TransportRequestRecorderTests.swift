//
//  TransportRequestRecorderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/25.
//

import Foundation
import XCTest
@testable import TraceCore
@testable import TracePacket
@testable import TraceVPNKit

final class TransportRequestRecorderTests: XCTestCase {
    private var storage: AppGroupStorage!

    override func setUp() {
        super.setUp()
        storage = AppGroupStorage.shared
        try? storage.clearAllTransportRequests()
        storage.setTransportStoreBudgetBytesForTesting(nil)
        storage.resetStoredSettings()
    }

    override func tearDown() {
        try? storage.clearAllTransportRequests()
        storage.setTransportStoreBudgetBytesForTesting(nil)
        storage.resetStoredSettings()
        super.tearDown()
    }

    func testACKOnlyTCPPacketIsPersisted() throws {
        let recorder = TransportRequestRecorder()
        let packet = makeIPv4TCPPacket(
            sourceIP: [10, 0, 0, 10],
            destinationIP: [10, 0, 0, 11],
            sourcePort: 50000,
            destinationPort: 50001,
            sequenceNumber: 1234,
            acknowledgmentNumber: 5678,
            flags: 0x10,
            payload: Data()
        )
        guard let parsed = IPPacketParser.parse(packet) else {
            XCTFail("Failed to parse synthesized packet")
            return
        }

        recorder.process(ipPacket: parsed, rawPacket: packet)
        recorder.shutdown()

        let requests = try storage.loadAllTransportRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].payloadBytes, 0)
        XCTAssertEqual(requests[0].packetBytes, packet.count)
        XCTAssertEqual(requests[0].tcpFlags, 0x10)
        XCTAssertEqual(requests[0].packet?.getData(), packet)
    }

    func testRecorderPersistsMoreThanTwoPacketsPerTCPFlow() throws {
        let recorder = TransportRequestRecorder()
        let flowPackets = [
            makeIPv4TCPPacket(
                sourceIP: [192, 168, 1, 10],
                destinationIP: [93, 184, 216, 34],
                sourcePort: 41000,
                destinationPort: 80,
                sequenceNumber: 1,
                acknowledgmentNumber: 0,
                flags: 0x18,
                payload: Data("GET /one HTTP/1.1\r\n\r\n".utf8)
            ),
            makeIPv4TCPPacket(
                sourceIP: [192, 168, 1, 10],
                destinationIP: [93, 184, 216, 34],
                sourcePort: 41000,
                destinationPort: 80,
                sequenceNumber: 25,
                acknowledgmentNumber: 0,
                flags: 0x18,
                payload: Data("GET /two HTTP/1.1\r\n\r\n".utf8)
            ),
            makeIPv4TCPPacket(
                sourceIP: [192, 168, 1, 10],
                destinationIP: [93, 184, 216, 34],
                sourcePort: 41000,
                destinationPort: 80,
                sequenceNumber: 49,
                acknowledgmentNumber: 0,
                flags: 0x18,
                payload: Data("GET /three HTTP/1.1\r\n\r\n".utf8)
            )
        ]

        for packet in flowPackets {
            guard let parsed = IPPacketParser.parse(packet) else {
                XCTFail("Failed to parse synthesized packet")
                return
            }
            recorder.process(ipPacket: parsed, rawPacket: packet)
        }
        recorder.shutdown()

        let requests = try storage.loadAllTransportRequests()
        let flowRequests = requests.filter { $0.flowKey == "tcp|192.168.1.10:41000|93.184.216.34:80" }
        XCTAssertEqual(flowRequests.count, 3)
    }

    func testRecorderStoresRawPacketBytesAndTCPMetadata() throws {
        let recorder = TransportRequestRecorder()
        let packet = makeIPv4TCPPacket(
            sourceIP: [172, 16, 0, 2],
            destinationIP: [172, 16, 0, 3],
            sourcePort: 42000,
            destinationPort: 443,
            sequenceNumber: 0x0102_0304,
            acknowledgmentNumber: 0x0506_0708,
            flags: 0x12,
            windowSize: 4096,
            options: Data([
                0x02, 0x04, 0x05, 0xB4, // MSS 1460
                0x03, 0x03, 0x07, // Window scale 7
                0x04, 0x02, // SACK permitted
                0x08, 0x0A, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x65, // Timestamps
                0x01 // NOP for alignment (20 bytes total options)
            ]),
            payload: Data("payload".utf8)
        )
        guard let parsed = IPPacketParser.parse(packet) else {
            XCTFail("Failed to parse synthesized packet")
            return
        }

        recorder.process(ipPacket: parsed, rawPacket: packet)
        recorder.shutdown()

        let requests = try storage.loadAllTransportRequests()
        guard let request = requests.first else {
            XCTFail("Expected one request")
            return
        }

        XCTAssertEqual(request.packet?.getData(), packet)
        XCTAssertEqual(request.packetBytes, packet.count)
        XCTAssertEqual(request.tcpSequenceNumber, 0x0102_0304)
        XCTAssertEqual(request.tcpAcknowledgmentNumber, 0x0506_0708)
        XCTAssertEqual(request.tcpFlags, 0x12)
        XCTAssertEqual(request.tcpWindowSize, 4096)
        XCTAssertEqual(request.tcpDataOffset, 40)
        XCTAssertEqual(request.tcpOptions?.maximumSegmentSize, 1460)
        XCTAssertEqual(request.tcpOptions?.windowScale, 7)
        XCTAssertEqual(request.tcpOptions?.sackPermitted, true)
        XCTAssertEqual(request.tcpOptions?.timestamps?.value, 100)
        XCTAssertEqual(request.tcpOptions?.timestamps?.echoReply, 101)
    }
}

private extension TransportRequestRecorderTests {
    func makeIPv4TCPPacket(
        sourceIP: [UInt8],
        destinationIP: [UInt8],
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: UInt8,
        windowSize: UInt16 = 8192,
        options: Data = Data(),
        payload: Data
    ) -> Data {
        precondition(sourceIP.count == 4)
        precondition(destinationIP.count == 4)
        precondition(options.count % 4 == 0)

        let tcpHeaderLength = 20 + options.count
        let totalLength = 20 + tcpHeaderLength + payload.count
        let dataOffsetWords = UInt8(tcpHeaderLength / 4)

        var packet = Data([
            0x45, 0x00,
            UInt8((totalLength >> 8) & 0xFF), UInt8(totalLength & 0xFF),
            0x00, 0x00,
            0x00, 0x00,
            0x40, 0x06,
            0x00, 0x00
        ])
        packet.append(contentsOf: sourceIP)
        packet.append(contentsOf: destinationIP)

        packet.append(UInt8((sourcePort >> 8) & 0xFF))
        packet.append(UInt8(sourcePort & 0xFF))
        packet.append(UInt8((destinationPort >> 8) & 0xFF))
        packet.append(UInt8(destinationPort & 0xFF))
        packet.append(contentsOf: [
            UInt8((sequenceNumber >> 24) & 0xFF),
            UInt8((sequenceNumber >> 16) & 0xFF),
            UInt8((sequenceNumber >> 8) & 0xFF),
            UInt8(sequenceNumber & 0xFF)
        ])
        packet.append(contentsOf: [
            UInt8((acknowledgmentNumber >> 24) & 0xFF),
            UInt8((acknowledgmentNumber >> 16) & 0xFF),
            UInt8((acknowledgmentNumber >> 8) & 0xFF),
            UInt8(acknowledgmentNumber & 0xFF)
        ])
        packet.append(dataOffsetWords << 4)
        packet.append(flags)
        packet.append(UInt8((windowSize >> 8) & 0xFF))
        packet.append(UInt8(windowSize & 0xFF))
        packet.append(0x00)
        packet.append(0x00)
        packet.append(0x00)
        packet.append(0x00)
        packet.append(options)
        packet.append(payload)
        return packet
    }
}
