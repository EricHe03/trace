//
//  TCPPacketTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TracePacket

final class TCPPacketTests: XCTestCase {

    // MARK: - Initialization Tests

    func testTCPPacketInitialization() {
        let packet = TCPPacket(
            sourcePort: 8080,
            destinationPort: 443,
            sequenceNumber: 1000,
            acknowledgmentNumber: 2000,
            dataOffset: 20,
            flags: [.syn],
            windowSize: 65535,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: Data([0x01, 0x02])
        )

        XCTAssertEqual(packet.sourcePort, 8080)
        XCTAssertEqual(packet.destinationPort, 443)
        XCTAssertEqual(packet.sequenceNumber, 1000)
        XCTAssertEqual(packet.acknowledgmentNumber, 2000)
        XCTAssertEqual(packet.dataOffset, 20)
        XCTAssertTrue(packet.flags.contains(.syn))
        XCTAssertEqual(packet.windowSize, 65535)
        XCTAssertEqual(packet.payload.count, 2)
    }

    // MARK: - TCP Flags Tests

    func testFINFlag() {
        let flags = TCPPacket.Flags.fin
        XCTAssertEqual(flags.rawValue, 0x01)
    }

    func testSYNFlag() {
        let flags = TCPPacket.Flags.syn
        XCTAssertEqual(flags.rawValue, 0x02)
    }

    func testRSTFlag() {
        let flags = TCPPacket.Flags.rst
        XCTAssertEqual(flags.rawValue, 0x04)
    }

    func testPSHFlag() {
        let flags = TCPPacket.Flags.psh
        XCTAssertEqual(flags.rawValue, 0x08)
    }

    func testACKFlag() {
        let flags = TCPPacket.Flags.ack
        XCTAssertEqual(flags.rawValue, 0x10)
    }

    func testURGFlag() {
        let flags = TCPPacket.Flags.urg
        XCTAssertEqual(flags.rawValue, 0x20)
    }

    func testMultipleFlags() {
        let flags: TCPPacket.Flags = [.syn, .ack]
        XCTAssertTrue(flags.contains(.syn))
        XCTAssertTrue(flags.contains(.ack))
        XCTAssertFalse(flags.contains(.fin))
        XCTAssertEqual(flags.rawValue, 0x12) // 0x02 | 0x10
    }

    func testAllFlags() {
        let flags: TCPPacket.Flags = [.fin, .syn, .rst, .psh, .ack, .urg]
        XCTAssertTrue(flags.contains(.fin))
        XCTAssertTrue(flags.contains(.syn))
        XCTAssertTrue(flags.contains(.rst))
        XCTAssertTrue(flags.contains(.psh))
        XCTAssertTrue(flags.contains(.ack))
        XCTAssertTrue(flags.contains(.urg))
        XCTAssertEqual(flags.rawValue, 0x3F)
    }

    func testNoFlags() {
        let flags = TCPPacket.Flags(rawValue: 0)
        XCTAssertFalse(flags.contains(.fin))
        XCTAssertFalse(flags.contains(.syn))
        XCTAssertFalse(flags.contains(.rst))
        XCTAssertFalse(flags.contains(.psh))
        XCTAssertFalse(flags.contains(.ack))
        XCTAssertFalse(flags.contains(.urg))
    }

    // MARK: - TCP Connection States Tests

    func testSYNPacket() {
        let packet = createTCPPacket(flags: [.syn])
        XCTAssertTrue(packet.flags.contains(.syn))
        XCTAssertFalse(packet.flags.contains(.ack))
    }

    func testSYNACKPacket() {
        let packet = createTCPPacket(flags: [.syn, .ack])
        XCTAssertTrue(packet.flags.contains(.syn))
        XCTAssertTrue(packet.flags.contains(.ack))
    }

    func testACKPacket() {
        let packet = createTCPPacket(flags: [.ack])
        XCTAssertTrue(packet.flags.contains(.ack))
        XCTAssertFalse(packet.flags.contains(.syn))
    }

    func testFINACKPacket() {
        let packet = createTCPPacket(flags: [.fin, .ack])
        XCTAssertTrue(packet.flags.contains(.fin))
        XCTAssertTrue(packet.flags.contains(.ack))
    }

    func testRSTPacket() {
        let packet = createTCPPacket(flags: [.rst])
        XCTAssertTrue(packet.flags.contains(.rst))
    }

    func testPSHACKPacket() {
        let packet = createTCPPacket(flags: [.psh, .ack])
        XCTAssertTrue(packet.flags.contains(.psh))
        XCTAssertTrue(packet.flags.contains(.ack))
    }

    // MARK: - Port Tests

    func testWellKnownPorts() {
        let ports: [UInt16] = [20, 21, 22, 23, 25, 53, 80, 110, 143, 443, 587, 993, 995, 3306, 5432, 8080]

        for port in ports {
            let packet = createTCPPacket(destinationPort: port)
            XCTAssertEqual(packet.destinationPort, port)
        }
    }

    func testEphemeralPorts() {
        let ports: [UInt16] = [49152, 50000, 55555, 60000, 65535]

        for port in ports {
            let packet = createTCPPacket(sourcePort: port)
            XCTAssertEqual(packet.sourcePort, port)
        }
    }

    func testPortZero() {
        let packet = createTCPPacket(sourcePort: 0)
        XCTAssertEqual(packet.sourcePort, 0)
    }

    func testMaxPort() {
        let packet = createTCPPacket(destinationPort: 65535)
        XCTAssertEqual(packet.destinationPort, 65535)
    }

    // MARK: - Sequence Number Tests

    func testInitialSequenceNumber() {
        let packet = createTCPPacket(sequenceNumber: 1000)
        XCTAssertEqual(packet.sequenceNumber, 1000)
    }

    func testZeroSequenceNumber() {
        let packet = createTCPPacket(sequenceNumber: 0)
        XCTAssertEqual(packet.sequenceNumber, 0)
    }

    func testMaxSequenceNumber() {
        let packet = createTCPPacket(sequenceNumber: UInt32.max)
        XCTAssertEqual(packet.sequenceNumber, UInt32.max)
    }

    func testSequenceNumberWrapAround() {
        let packet1 = createTCPPacket(sequenceNumber: UInt32.max - 10)
        let packet2 = createTCPPacket(sequenceNumber: 5)

        XCTAssertEqual(packet1.sequenceNumber, UInt32.max - 10)
        XCTAssertEqual(packet2.sequenceNumber, 5)
    }

    // MARK: - Acknowledgment Number Tests

    func testAcknowledgmentNumber() {
        let packet = createTCPPacket(acknowledgmentNumber: 5000)
        XCTAssertEqual(packet.acknowledgmentNumber, 5000)
    }

    func testZeroAcknowledgmentNumber() {
        let packet = createTCPPacket(acknowledgmentNumber: 0)
        XCTAssertEqual(packet.acknowledgmentNumber, 0)
    }

    func testMaxAcknowledgmentNumber() {
        let packet = createTCPPacket(acknowledgmentNumber: UInt32.max)
        XCTAssertEqual(packet.acknowledgmentNumber, UInt32.max)
    }

    // MARK: - Window Size Tests

    func testDefaultWindowSize() {
        let packet = createTCPPacket(windowSize: 65535)
        XCTAssertEqual(packet.windowSize, 65535)
    }

    func testZeroWindowSize() {
        let packet = createTCPPacket(windowSize: 0)
        XCTAssertEqual(packet.windowSize, 0)
    }

    func testSmallWindowSize() {
        let packet = createTCPPacket(windowSize: 1024)
        XCTAssertEqual(packet.windowSize, 1024)
    }

    func testMaxWindowSize() {
        let packet = createTCPPacket(windowSize: 65535)
        XCTAssertEqual(packet.windowSize, 65535)
    }

    // MARK: - Data Offset Tests

    func testMinimumDataOffset() {
        let packet = createTCPPacket(dataOffset: 20)
        XCTAssertEqual(packet.dataOffset, 20)
    }

    func testDataOffsetWithOptions() {
        let packet = createTCPPacket(dataOffset: 32)
        XCTAssertEqual(packet.dataOffset, 32)
    }

    func testMaximumDataOffset() {
        let packet = createTCPPacket(dataOffset: 60)
        XCTAssertEqual(packet.dataOffset, 60)
    }

    // MARK: - TCP Options Tests

    func testOptionsWithMSS() {
        let options = TCPPacket.Options(
            mss: 1460,
            windowScale: nil,
            sackPermitted: false,
            timestamps: nil
        )

        XCTAssertEqual(options.mss, 1460)
        XCTAssertNil(options.windowScale)
        XCTAssertFalse(options.sackPermitted)
        XCTAssertNil(options.timestamps)
    }

    func testOptionsWithWindowScale() {
        let options = TCPPacket.Options(
            mss: nil,
            windowScale: 7,
            sackPermitted: false,
            timestamps: nil
        )

        XCTAssertNil(options.mss)
        XCTAssertEqual(options.windowScale, 7)
        XCTAssertFalse(options.sackPermitted)
        XCTAssertNil(options.timestamps)
    }

    func testOptionsWithSACKPermitted() {
        let options = TCPPacket.Options(
            mss: nil,
            windowScale: nil,
            sackPermitted: true,
            timestamps: nil
        )

        XCTAssertNil(options.mss)
        XCTAssertNil(options.windowScale)
        XCTAssertTrue(options.sackPermitted)
        XCTAssertNil(options.timestamps)
    }

    func testOptionsWithTimestamps() {
        let timestamp = TCPPacket.TimestampOption(value: 1000, echo: 2000)
        let options = TCPPacket.Options(
            mss: nil,
            windowScale: nil,
            sackPermitted: false,
            timestamps: timestamp
        )

        XCTAssertNil(options.mss)
        XCTAssertNil(options.windowScale)
        XCTAssertFalse(options.sackPermitted)
        XCTAssertNotNil(options.timestamps)
        XCTAssertEqual(options.timestamps?.value, 1000)
        XCTAssertEqual(options.timestamps?.echo, 2000)
    }

    func testOptionsWithAllFields() {
        let timestamp = TCPPacket.TimestampOption(value: 1000, echo: 2000)
        let options = TCPPacket.Options(
            mss: 1460,
            windowScale: 7,
            sackPermitted: true,
            timestamps: timestamp
        )

        XCTAssertEqual(options.mss, 1460)
        XCTAssertEqual(options.windowScale, 7)
        XCTAssertTrue(options.sackPermitted)
        XCTAssertNotNil(options.timestamps)
    }

    func testOptionsNoFields() {
        let options = TCPPacket.Options(
            mss: nil,
            windowScale: nil,
            sackPermitted: false,
            timestamps: nil
        )

        XCTAssertNil(options.mss)
        XCTAssertNil(options.windowScale)
        XCTAssertFalse(options.sackPermitted)
        XCTAssertNil(options.timestamps)
    }

    // MARK: - Timestamp Option Tests

    func testTimestampOptionInitialization() {
        let timestamp = TCPPacket.TimestampOption(value: 12345, echo: 67890)

        XCTAssertEqual(timestamp.value, 12345)
        XCTAssertEqual(timestamp.echo, 67890)
    }

    func testTimestampOptionZeroValues() {
        let timestamp = TCPPacket.TimestampOption(value: 0, echo: 0)

        XCTAssertEqual(timestamp.value, 0)
        XCTAssertEqual(timestamp.echo, 0)
    }

    func testTimestampOptionMaxValues() {
        let timestamp = TCPPacket.TimestampOption(value: UInt32.max, echo: UInt32.max)

        XCTAssertEqual(timestamp.value, UInt32.max)
        XCTAssertEqual(timestamp.echo, UInt32.max)
    }

    // MARK: - Payload Tests

    func testEmptyPayload() {
        let packet = createTCPPacket(payload: Data())
        XCTAssertEqual(packet.payload.count, 0)
    }

    func testSmallPayload() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let packet = createTCPPacket(payload: payload)

        XCTAssertEqual(packet.payload, payload)
        XCTAssertEqual(packet.payload.count, 4)
    }

    func testLargePayload() {
        let payload = Data(repeating: 0xFF, count: 1460) // Typical MSS
        let packet = createTCPPacket(payload: payload)

        XCTAssertEqual(packet.payload.count, 1460)
    }

    func testMaximumPayload() {
        let payload = Data(repeating: 0xAA, count: 65495) // Max TCP payload
        let packet = createTCPPacket(payload: payload)

        XCTAssertEqual(packet.payload.count, 65495)
    }

    // MARK: - Sendable Conformance Tests

    func testTCPPacketIsSendable() {
        let packet = createTCPPacket()

        Task {
            let _ = packet.sourcePort // Should compile without warnings
        }
    }

    func testTCPFlagsIsSendable() {
        let flags = TCPPacket.Flags.syn

        Task {
            let _ = flags.rawValue // Should compile without warnings
        }
    }

    func testTCPOptionsIsSendable() {
        let options = TCPPacket.Options(mss: 1460, windowScale: 7, sackPermitted: true, timestamps: nil)

        Task {
            let _ = options.mss // Should compile without warnings
        }
    }

    func testTimestampOptionIsSendable() {
        let timestamp = TCPPacket.TimestampOption(value: 1000, echo: 2000)

        Task {
            let _ = timestamp.value // Should compile without warnings
        }
    }

    // MARK: - Edge Cases

    func testPacketWithAllFlagsSet() {
        let packet = createTCPPacket(flags: [.fin, .syn, .rst, .psh, .ack, .urg])

        XCTAssertTrue(packet.flags.contains(.fin))
        XCTAssertTrue(packet.flags.contains(.syn))
        XCTAssertTrue(packet.flags.contains(.rst))
        XCTAssertTrue(packet.flags.contains(.psh))
        XCTAssertTrue(packet.flags.contains(.ack))
        XCTAssertTrue(packet.flags.contains(.urg))
    }

    func testPacketWithNoFlagsSet() {
        let packet = createTCPPacket(flags: [])

        XCTAssertFalse(packet.flags.contains(.fin))
        XCTAssertFalse(packet.flags.contains(.syn))
        XCTAssertFalse(packet.flags.contains(.rst))
        XCTAssertFalse(packet.flags.contains(.psh))
        XCTAssertFalse(packet.flags.contains(.ack))
        XCTAssertFalse(packet.flags.contains(.urg))
    }

    // MARK: - Common MSS Values

    func testCommonMSSValues() {
        let mssValues: [UInt16] = [536, 1460, 1440, 1360, 1280]

        for mss in mssValues {
            let options = TCPPacket.Options(mss: mss, windowScale: nil, sackPermitted: false, timestamps: nil)
            XCTAssertEqual(options.mss, mss)
        }
    }

    // MARK: - Window Scale Values

    func testWindowScaleValues() {
        for scale: UInt8 in 0...14 {
            let options = TCPPacket.Options(mss: nil, windowScale: scale, sackPermitted: false, timestamps: nil)
            XCTAssertEqual(options.windowScale, scale)
        }
    }

    // MARK: - Real-World Scenarios

    func testHTTPSConnection() {
        let packet = createTCPPacket(
            sourcePort: 50000,
            destinationPort: 443,
            flags: [.syn]
        )

        XCTAssertEqual(packet.sourcePort, 50000)
        XCTAssertEqual(packet.destinationPort, 443)
        XCTAssertTrue(packet.flags.contains(.syn))
    }

    func testHTTPConnection() {
        let packet = createTCPPacket(
            sourcePort: 50001,
            destinationPort: 80,
            flags: [.ack, .psh]
        )

        XCTAssertEqual(packet.destinationPort, 80)
        XCTAssertTrue(packet.flags.contains(.ack))
        XCTAssertTrue(packet.flags.contains(.psh))
    }

    func testSSHConnection() {
        let packet = createTCPPacket(
            sourcePort: 50002,
            destinationPort: 22,
            flags: [.syn, .ack]
        )

        XCTAssertEqual(packet.destinationPort, 22)
        XCTAssertTrue(packet.flags.contains(.syn))
        XCTAssertTrue(packet.flags.contains(.ack))
    }

    // MARK: - Helper Methods

    private func createTCPPacket(
        sourcePort: UInt16 = 8080,
        destinationPort: UInt16 = 443,
        sequenceNumber: UInt32 = 1000,
        acknowledgmentNumber: UInt32 = 2000,
        dataOffset: Int = 20,
        flags: TCPPacket.Flags = [.ack],
        windowSize: UInt16 = 65535,
        payload: Data = Data([0x01, 0x02])
    ) -> TCPPacket {
        TCPPacket(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequenceNumber: sequenceNumber,
            acknowledgmentNumber: acknowledgmentNumber,
            dataOffset: dataOffset,
            flags: flags,
            windowSize: windowSize,
            options: TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil),
            payload: payload
        )
    }
}
