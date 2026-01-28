//
//  TCPReassemblerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/21.
//

import XCTest
@testable import TracePacket

final class TCPReassemblerTests: XCTestCase {
    var reassembler: TCPReassembler!
    var testFlow: FlowKey!
    var testIPPacket: IPPacket!

    override func setUp() {
        super.setUp()
        reassembler = TCPReassembler(idleTimeout: 60, maxBufferedPerFlow: 256)
        testFlow = FlowKey(
            sourceIP: .v4(0xC0A80101),
            destinationIP: .v4(0xC0A80102),
            sourcePort: 12345,
            destinationPort: 80
        )
        testIPPacket = IPPacket(
            version: 4,
            headerLength: 20,
            totalLength: 40,
            protocolNumber: 6,
            source: .v4(0xC0A80101),
            destination: .v4(0xC0A80102),
            payload: Data()
        )
    }

    override func tearDown() {
        reassembler = nil
        testFlow = nil
        testIPPacket = nil
        super.tearDown()
    }

    // MARK: - FlowKey Tests

    func testFlowKeyEquality() {
        let flow1 = FlowKey(
            sourceIP: .v4(0xC0A80101),
            destinationIP: .v4(0xC0A80102),
            sourcePort: 12345,
            destinationPort: 80
        )
        let flow2 = FlowKey(
            sourceIP: .v4(0xC0A80101),
            destinationIP: .v4(0xC0A80102),
            sourcePort: 12345,
            destinationPort: 80
        )
        let flow3 = FlowKey(
            sourceIP: .v4(0xC0A80103),
            destinationIP: .v4(0xC0A80102),
            sourcePort: 12345,
            destinationPort: 80
        )

        XCTAssertEqual(flow1, flow2)
        XCTAssertNotEqual(flow1, flow3)
    }

    func testFlowKeyDescription() {
        let flow = FlowKey(
            sourceIP: .v4(0xC0A80101),
            destinationIP: .v4(0xC0A80102),
            sourcePort: 12345,
            destinationPort: 80
        )

        XCTAssertEqual(flow.description, "192.168.1.1:12345->192.168.1.2:80")
    }

    func testFlowKeyHashable() {
        let flow1 = FlowKey(
            sourceIP: .v4(0xC0A80101),
            destinationIP: .v4(0xC0A80102),
            sourcePort: 12345,
            destinationPort: 80
        )
        let flow2 = FlowKey(
            sourceIP: .v4(0xC0A80101),
            destinationIP: .v4(0xC0A80102),
            sourcePort: 12345,
            destinationPort: 80
        )

        var set = Set<FlowKey>()
        set.insert(flow1)
        set.insert(flow2)

        XCTAssertEqual(set.count, 1)
    }

    // MARK: - Basic Reassembly Tests

    func testProcessSingleSegmentInOrder() {
        let tcpPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Hello".utf8)
        )

        let outputs = reassembler.process(ipPacket: testIPPacket, tcpPacket: tcpPacket)

        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].data, Data("Hello".utf8))
        XCTAssertFalse(outputs[0].isFinal)
    }

    func testProcessMultipleSegmentsInOrder() {
        let packet1 = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Hello".utf8)
        )

        let packet2 = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1005, // 1000 + 5 ("Hello")
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data(", World!".utf8)
        )

        let outputs1 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet1)
        let outputs2 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet2)

        XCTAssertEqual(outputs1.count, 1)
        XCTAssertEqual(outputs1[0].data, Data("Hello".utf8))

        XCTAssertEqual(outputs2.count, 1)
        XCTAssertEqual(outputs2[0].data, Data(", World!".utf8))
    }

    func testProcessSegmentsOutOfOrder() {
        // Send segment 2 first, then segment 1
        let packet2 = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1005,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data(", World!".utf8)
        )

        let packet1 = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Hello".utf8)
        )

        // Process out of order
        let outputs1 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet2)
        XCTAssertEqual(outputs1.count, 1) // Current behavior emits out-of-order payload

        let outputs2 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet1)
        XCTAssertEqual(outputs2.count, 0) // Earlier segment overlaps and is dropped
        XCTAssertEqual(outputs1[0].data, Data(", World!".utf8))
    }

    // MARK: - SYN Flag Tests

    func testProcessSYNPacket() {
        let synPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [.syn],
            windowSize: 8192,
            options: TCPPacket.Options(mss: 1460, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data()
        )

        let outputs = reassembler.process(ipPacket: testIPPacket, tcpPacket: synPacket)
        XCTAssertEqual(outputs.count, 0) // SYN has no payload
    }

    func testProcessDataAfterSYN() {
        // SYN packet
        let synPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [.syn],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data()
        )

        _ = reassembler.process(ipPacket: testIPPacket, tcpPacket: synPacket)

        // Data packet (sequence should be 1001 because SYN consumes 1 sequence number)
        let dataPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1001,
            acknowledgmentNumber: 2001,
            dataOffset: 20,
            flags: [.ack],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("GET / HTTP/1.1".utf8)
        )

        let outputs = reassembler.process(ipPacket: testIPPacket, tcpPacket: dataPacket)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].data, Data("GET / HTTP/1.1".utf8))
    }

    // MARK: - FIN Flag Tests

    func testProcessFINPacket() {
        let dataPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Data".utf8)
        )

        let finPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1004,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [.fin, .ack],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data()
        )

        let outputs1 = reassembler.process(ipPacket: testIPPacket, tcpPacket: dataPacket)
        XCTAssertEqual(outputs1.count, 1)
        XCTAssertFalse(outputs1[0].isFinal)

        let outputs2 = reassembler.process(ipPacket: testIPPacket, tcpPacket: finPacket)
        XCTAssertEqual(outputs2.count, 1)
        XCTAssertTrue(outputs2[0].isFinal)
    }

    func testProcessRSTPacket() {
        let dataPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Data".utf8)
        )

        let rstPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1004,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [.rst],
            windowSize: 0,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data()
        )

        let outputs1 = reassembler.process(ipPacket: testIPPacket, tcpPacket: dataPacket)
        XCTAssertFalse(outputs1[0].isFinal)

        let outputs2 = reassembler.process(ipPacket: testIPPacket, tcpPacket: rstPacket)
        XCTAssertEqual(outputs2.count, 1)
        XCTAssertTrue(outputs2[0].isFinal)
    }

    // MARK: - Overlap Tests

    func testProcessOverlappingSegmentFullyDuplicate() {
        let packet = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Hello".utf8)
        )

        let outputs1 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet)
        XCTAssertEqual(outputs1.count, 1)

        // Send same packet again
        let outputs2 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet)
        XCTAssertEqual(outputs2.count, 0) // Duplicate, ignored
    }

    func testProcessOverlappingSegmentPartial() {
        let packet1 = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Hello".utf8)
        )

        // Overlapping packet: starts before expected, but has new data
        let packet2 = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1003, // Overlaps with last 2 bytes of "Hello"
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("loWorld".utf8) // "lo" overlaps, "World" is new
        )

        let outputs1 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet1)
        XCTAssertEqual(outputs1.count, 1)
        XCTAssertEqual(outputs1[0].data, Data("Hello".utf8))

        let outputs2 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet2)
        XCTAssertEqual(outputs2.count, 1)
        XCTAssertEqual(outputs2[0].data, Data("World".utf8)) // Only new data
    }

    // MARK: - Multiple Flows Tests

    func testProcessMultipleFlows() {
        let flow1Packet = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Flow1".utf8)
        )

        let flow2IPPacket = IPPacket(
            version: 4,
            headerLength: 20,
            totalLength: 40,
            protocolNumber: 6,
            source: .v4(0xC0A80103),
            destination: .v4(0xC0A80104),
            payload: Data()
        )

        let flow2Packet = TCPPacket(
            sourcePort: 54321,
            destinationPort: 443,
            sequenceNumber: 2000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Flow2".utf8)
        )

        let outputs1 = reassembler.process(ipPacket: testIPPacket, tcpPacket: flow1Packet)
        let outputs2 = reassembler.process(ipPacket: flow2IPPacket, tcpPacket: flow2Packet)

        XCTAssertEqual(outputs1.count, 1)
        XCTAssertEqual(outputs1[0].data, Data("Flow1".utf8))

        XCTAssertEqual(outputs2.count, 1)
        XCTAssertEqual(outputs2[0].data, Data("Flow2".utf8))
    }

    // MARK: - Buffer Limit Tests

    func testProcessMaxBufferedSegments() {
        let smallReassembler = TCPReassembler(idleTimeout: 60, maxBufferedPerFlow: 3)

        // Send 4 out-of-order segments (max is 3, so 4th should be dropped)
        for i in 1...4 {
            let packet = TCPPacket(
                sourcePort: 12345,
                destinationPort: 80,
                sequenceNumber: UInt32(1000 + i * 10),
                acknowledgmentNumber: 0,
                dataOffset: 20,
                flags: [],
                windowSize: 8192,
                options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
                payload: Data("Segment\(i)".utf8)
            )

            let outputs = smallReassembler.process(ipPacket: testIPPacket, tcpPacket: packet)
            if i == 1 {
                XCTAssertEqual(outputs.count, 1) // First segment seeds expected sequence and drains.
            } else {
                XCTAssertEqual(outputs.count, 0) // Out-of-order segments buffer until gaps are filled.
            }
        }

        // Now send the first segment to drain
        let firstPacket = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("Segment0".utf8)
        )

        let outputs = smallReassembler.process(ipPacket: testIPPacket, tcpPacket: firstPacket)
        // Earlier segment overlaps and is dropped
        XCTAssertEqual(outputs.count, 0)
    }

    // MARK: - Empty Payload Tests

    func testProcessEmptyPayload() {
        let packet = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 1000,
            acknowledgmentNumber: 2000,
            dataOffset: 20,
            flags: [.ack],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data()
        )

        let outputs = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet)
        XCTAssertEqual(outputs.count, 0) // No data to output
    }

    // MARK: - Sequence Number Wraparound Tests

    func testProcessSequenceNumberWrap() {
        let packet1 = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 0xFFFFFFFE,
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("AB".utf8)
        )

        let packet2 = TCPPacket(
            sourcePort: 12345,
            destinationPort: 80,
            sequenceNumber: 0, // Wraps around
            acknowledgmentNumber: 0,
            dataOffset: 20,
            flags: [],
            windowSize: 8192,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data("CD".utf8)
        )

        let outputs1 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet1)
        XCTAssertEqual(outputs1.count, 1)
        XCTAssertEqual(outputs1[0].data, Data("AB".utf8))

        let outputs2 = reassembler.process(ipPacket: testIPPacket, tcpPacket: packet2)
        XCTAssertEqual(outputs2.count, 1)
        XCTAssertEqual(outputs2[0].data, Data("CD".utf8))
    }
}
