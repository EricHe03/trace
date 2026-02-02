//
//  PCAPReaderTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TracePacket

final class PCAPReaderTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createMockPCAPFile(withPackets packets: [(timestamp: Date, data: Data)]) throws -> URL {
        let url = tempDirectory.appendingPathComponent("test_\(UUID().uuidString).pcap")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "Test", code: 1, userInfo: nil)
        }

        // Write global header
        var header = Data()
        header.appendUInt32LE(0xA1B2_C3D4) // Magic
        header.appendUInt16LE(2) // Version major
        header.appendUInt16LE(4) // Version minor
        header.appendUInt32LE(0) // Timezone
        header.appendUInt32LE(0) // Sigfigs
        header.appendUInt32LE(65535) // Snaplen
        header.appendUInt32LE(101) // Network (RAW IP)

        try handle.write(contentsOf: header)

        // Write packet records
        for packet in packets {
            var recordHeader = Data()
            let seconds = UInt32(packet.timestamp.timeIntervalSince1970)
            let usec = UInt32((packet.timestamp.timeIntervalSince1970 - Double(seconds)) * 1_000_000.0)

            recordHeader.appendUInt32LE(seconds)
            recordHeader.appendUInt32LE(usec)
            recordHeader.appendUInt32LE(UInt32(packet.data.count))
            recordHeader.appendUInt32LE(UInt32(packet.data.count))

            try handle.write(contentsOf: recordHeader)
            try handle.write(contentsOf: packet.data)
        }

        try handle.close()
        return url
    }

    // MARK: - Basic Reading Tests

    func testReadEmptyPCAPFile() throws {
        let url = try createMockPCAPFile(withPackets: [])

        let reader = try PCAPReader(url: url)
        var packetCount = 0

        try reader.forEachPacket { _ in
            packetCount += 1
        }

        XCTAssertEqual(packetCount, 0)
    }

    func testReadSinglePacket() throws {
        let timestamp = Date()
        let data = Data([0x45, 0x00, 0x00, 0x28]) // Simple IP header start

        let url = try createMockPCAPFile(withPackets: [(timestamp, data)])

        let reader = try PCAPReader(url: url)
        var packets: [PCAPPacket] = []

        try reader.forEachPacket { packet in
            packets.append(packet)
        }

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].data, data)
        XCTAssertEqual(packets[0].timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testReadMultiplePackets() throws {
        let packets = [
            (Date(timeIntervalSince1970: 1000), Data([0x01, 0x02, 0x03])),
            (Date(timeIntervalSince1970: 1001), Data([0x04, 0x05, 0x06])),
            (Date(timeIntervalSince1970: 1002), Data([0x07, 0x08, 0x09]))
        ]

        let url = try createMockPCAPFile(withPackets: packets)

        let reader = try PCAPReader(url: url)
        var readPackets: [PCAPPacket] = []

        try reader.forEachPacket { packet in
            readPackets.append(packet)
        }

        XCTAssertEqual(readPackets.count, 3)
        XCTAssertEqual(readPackets[0].data, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(readPackets[1].data, Data([0x04, 0x05, 0x06]))
        XCTAssertEqual(readPackets[2].data, Data([0x07, 0x08, 0x09]))
    }

    // MARK: - Timestamp Tests

    func testTimestampAccuracy() throws {
        let timestamp = Date(timeIntervalSince1970: 1234567890.123456)
        let data = Data([0xFF])

        let url = try createMockPCAPFile(withPackets: [(timestamp, data)])

        let reader = try PCAPReader(url: url)
        var capturedTimestamp: Date?

        try reader.forEachPacket { packet in
            capturedTimestamp = packet.timestamp
        }

        XCTAssertNotNil(capturedTimestamp)
        XCTAssertEqual(capturedTimestamp!.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.000001)
    }

    // MARK: - Large Packet Tests

    func testReadLargePacket() throws {
        let timestamp = Date()
        let largeData = Data(repeating: 0x42, count: 65535)

        let url = try createMockPCAPFile(withPackets: [(timestamp, largeData)])

        let reader = try PCAPReader(url: url)
        var capturedData: Data?

        try reader.forEachPacket { packet in
            capturedData = packet.data
        }

        XCTAssertNotNil(capturedData)
        XCTAssertEqual(capturedData?.count, 65535)
        XCTAssertEqual(capturedData, largeData)
    }

    // MARK: - Error Handling Tests

    func testInvalidMagicNumber() throws {
        let url = tempDirectory.appendingPathComponent("invalid.pcap")
        var invalidHeader = Data()
        invalidHeader.appendUInt32LE(0xDEADBEEF) // Invalid magic
        try invalidHeader.write(to: url)

        let reader = try PCAPReader(url: url)

        XCTAssertThrowsError(try reader.forEachPacket { _ in }) { error in
            XCTAssertTrue(error is PCAPReaderError)
            if let pcapError = error as? PCAPReaderError {
                XCTAssertEqual(pcapError, PCAPReaderError.unsupportedFormat)
            }
        }
    }

    func testReadBigEndianPCAPFile() throws {
        let url = tempDirectory.appendingPathComponent("big_endian.pcap")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: url) else {
            XCTFail("Could not create file")
            return
        }

        // Write global header (big-endian).
        var header = Data()
        header.appendUInt32BE(0xA1B2_C3D4) // Magic (microsecond, big-endian)
        header.appendUInt16BE(2) // Version major
        header.appendUInt16BE(4) // Version minor
        header.appendUInt32BE(0) // Timezone
        header.appendUInt32BE(0) // Sigfigs
        header.appendUInt32BE(65535) // Snaplen
        header.appendUInt32BE(101) // Network (RAW IP)
        try handle.write(contentsOf: header)

        // Write one packet record (big-endian).
        let timestamp = Date(timeIntervalSince1970: 1_234_567_890.25)
        let data = Data([0x01, 0x02, 0x03])
        let seconds = UInt32(timestamp.timeIntervalSince1970)
        let usec = UInt32((timestamp.timeIntervalSince1970 - Double(seconds)) * 1_000_000.0)

        var recordHeader = Data()
        recordHeader.appendUInt32BE(seconds)
        recordHeader.appendUInt32BE(usec)
        recordHeader.appendUInt32BE(UInt32(data.count))
        recordHeader.appendUInt32BE(UInt32(data.count))
        try handle.write(contentsOf: recordHeader)
        try handle.write(contentsOf: data)

        try handle.close()

        let reader = try PCAPReader(url: url)
        var packets: [PCAPPacket] = []
        try reader.forEachPacket { packet in
            packets.append(packet)
        }

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].data, data)
        XCTAssertEqual(packets[0].timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testTruncatedHeader() throws {
        let url = tempDirectory.appendingPathComponent("truncated.pcap")
        let truncatedHeader = Data([0xD4, 0xC3, 0xB2, 0xA1, 0x02]) // Only 5 bytes
        try truncatedHeader.write(to: url)

        let reader = try PCAPReader(url: url)

        XCTAssertThrowsError(try reader.forEachPacket { _ in }) { error in
            XCTAssertTrue(error is PCAPReaderError)
            if let pcapError = error as? PCAPReaderError {
                XCTAssertEqual(pcapError, PCAPReaderError.invalidHeader)
            }
        }
    }

    func testTruncatedPacketRecord() throws {
        let url = tempDirectory.appendingPathComponent("truncated_record.pcap")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: url) else {
            XCTFail("Could not create file")
            return
        }

        // Write valid header
        var header = Data()
        header.appendUInt32LE(0xA1B2_C3D4)
        header.appendUInt16LE(2)
        header.appendUInt16LE(4)
        header.appendUInt32LE(0)
        header.appendUInt32LE(0)
        header.appendUInt32LE(65535)
        header.appendUInt32LE(101)
        try handle.write(contentsOf: header)

        // Write incomplete packet record (only 8 bytes instead of 16)
        let incomplete = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        try handle.write(contentsOf: incomplete)
        try handle.close()

        let reader = try PCAPReader(url: url)

        XCTAssertThrowsError(try reader.forEachPacket { _ in }) { error in
            XCTAssertTrue(error is PCAPReaderError)
        }
    }

    // MARK: - ForEachPacket with Throws Tests

    func testForEachPacketThrowingHandler() throws {
        let packets = [
            (Date(), Data([0x01])),
            (Date(), Data([0x02])),
            (Date(), Data([0x03]))
        ]

        let url = try createMockPCAPFile(withPackets: packets)
        let reader = try PCAPReader(url: url)

        var processedCount = 0

        XCTAssertThrowsError(try reader.forEachPacket(throwing: { _ in
            processedCount += 1
            if processedCount == 2 {
                throw NSError(domain: "Test", code: 123, userInfo: nil)
            }
        })) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 123)
        }

        XCTAssertEqual(processedCount, 2)
    }

    // MARK: - PCAPPacket Structure Tests

    func testPCAPPacketInitialization() {
        let timestamp = Date()
        let data = Data([0xAA, 0xBB, 0xCC])

        let packet = PCAPPacket(timestamp: timestamp, data: data)

        XCTAssertEqual(packet.timestamp, timestamp)
        XCTAssertEqual(packet.data, data)
    }

    // MARK: - Zero-Length Packet Tests

    func testZeroLengthPacket() throws {
        let url = tempDirectory.appendingPathComponent("zero_length.pcap")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: url) else {
            XCTFail("Could not create file")
            return
        }

        // Write valid header
        var header = Data()
        header.appendUInt32LE(0xA1B2_C3D4)
        header.appendUInt16LE(2)
        header.appendUInt16LE(4)
        header.appendUInt32LE(0)
        header.appendUInt32LE(0)
        header.appendUInt32LE(65535)
        header.appendUInt32LE(101)
        try handle.write(contentsOf: header)

        // Write packet record with zero length
        var recordHeader = Data()
        recordHeader.appendUInt32LE(0) // ts_sec
        recordHeader.appendUInt32LE(0) // ts_usec
        recordHeader.appendUInt32LE(0) // incl_len (zero)
        recordHeader.appendUInt32LE(0) // orig_len
        try handle.write(contentsOf: recordHeader)

        try handle.close()

        let reader = try PCAPReader(url: url)
        var packetCount = 0

        try reader.forEachPacket { _ in
            packetCount += 1
        }

        // Zero-length packets should be skipped
        XCTAssertEqual(packetCount, 0)
    }

    // MARK: - Multiple Read Tests

    func testMultipleReadsFromSameFile() throws {
        let packets = [
            (Date(), Data([0x01, 0x02])),
            (Date(), Data([0x03, 0x04]))
        ]

        let url = try createMockPCAPFile(withPackets: packets)

        // First read
        do {
            let reader1 = try PCAPReader(url: url)
            var count1 = 0
            try reader1.forEachPacket { _ in count1 += 1 }
            XCTAssertEqual(count1, 2)
        }

        // Second read
        do {
            let reader2 = try PCAPReader(url: url)
            var count2 = 0
            try reader2.forEachPacket { _ in count2 += 1 }
            XCTAssertEqual(count2, 2)
        }
    }

    // MARK: - Nonexistent File Tests

    func testNonexistentFile() {
        let url = tempDirectory.appendingPathComponent("nonexistent.pcap")

        XCTAssertThrowsError(try PCAPReader(url: url))
    }

    // MARK: - Error Type Tests

    func testPCAPReaderErrorTypes() {
        XCTAssertNotNil(PCAPReaderError.invalidHeader)
        XCTAssertNotNil(PCAPReaderError.unsupportedFormat)
        XCTAssertNotNil(PCAPReaderError.truncatedRecord)
    }
}

// MARK: - Data Extension Helpers

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var v = value.littleEndian
        self.append(UnsafeBufferPointer(start: &v, count: 1))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        self.append(UnsafeBufferPointer(start: &v, count: 1))
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        var v = value.bigEndian
        self.append(UnsafeBufferPointer(start: &v, count: 1))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        var v = value.bigEndian
        self.append(UnsafeBufferPointer(start: &v, count: 1))
    }
}
