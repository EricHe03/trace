//
//  ConnectionDetailViewModelTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TracePacket

@MainActor
final class ConnectionDetailViewModelTests: XCTestCase {

    var viewModel: ConnectionDetailViewModel!
    var mockRecord: PacketFlowRecord!
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        let now = Date()
        mockRecord = PacketFlowRecord(
            id: UUID(),
            sourceIP: "192.168.1.100",
            destinationIP: "93.184.216.34",
            sourcePort: 54321,
            destinationPort: 443,
            transport: .tcp,
            bytesFromSource: 1500,
            bytesToSource: 2048,
            packetsFromSource: 10,
            packetsToSource: 12,
            startTime: now,
            lastSeen: now,
            isClosed: false,
            connectionState: .established,
            tcpHandshake: nil,
            tcpTermination: nil,
            tcpMetrics: nil
        )
        viewModel = ConnectionDetailViewModel(record: mockRecord)

        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        viewModel = nil
        mockRecord = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertEqual(viewModel.record.sourceIP, "192.168.1.100")
        XCTAssertEqual(viewModel.record.sourcePort, 54321)
        XCTAssertEqual(viewModel.record.destinationIP, "93.184.216.34")
        XCTAssertEqual(viewModel.record.destinationPort, 443)
        XCTAssertTrue(viewModel.pcapFiles.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.loadError)
        XCTAssertNil(viewModel.analysis)
    }

    // MARK: - PCAP File Tests

    func testPCAPFileItemInitialization() {
        let url = URL(fileURLWithPath: "/tmp/test.pcap")
        let size: UInt64 = 1024
        let modified = Date()

        let item = PCAPFileItem(url: url, size: size, modified: modified)

        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.size, size)
        XCTAssertEqual(item.modified, modified)
        XCTAssertEqual(item.displayName, "test.pcap")
    }

    func testPCAPFileItemHashable() {
        let url1 = URL(fileURLWithPath: "/tmp/test1.pcap")
        let url2 = URL(fileURLWithPath: "/tmp/test2.pcap")

        let item1 = PCAPFileItem(url: url1, size: 1024, modified: Date())
        let item2 = PCAPFileItem(url: url2, size: 2048, modified: Date())
        let item3 = PCAPFileItem(url: url1, size: 1024, modified: Date())

        XCTAssertNotEqual(item1, item2) // Different IDs
        XCTAssertNotEqual(item1, item3) // Different IDs even with same content
    }

    func testRefreshPCAPFilesWhenEmpty() {
        viewModel.refreshPCAPFiles()

        // Should return empty array when no files exist
        XCTAssertTrue(viewModel.pcapFiles.isEmpty)
    }

    // MARK: - TCP Packet Summary Tests

    func testTCPPacketSummaryInitialization() {
        let timestamp = Date()
        let flags = TCPPacket.Flags(rawValue: 0x02) // SYN flag

        let summary = TCPPacketSummary(
            timestamp: timestamp,
            direction: .clientToServer,
            sequence: 100,
            acknowledgment: 200,
            length: 1460,
            flags: flags,
            window: 65535,
            isRetransmission: false,
            isOutOfOrder: false,
            isDupAck: false
        )

        XCTAssertEqual(summary.timestamp, timestamp)
        XCTAssertEqual(summary.direction, .clientToServer)
        XCTAssertEqual(summary.sequence, 100)
        XCTAssertEqual(summary.acknowledgment, 200)
        XCTAssertEqual(summary.length, 1460)
        XCTAssertEqual(summary.flags.rawValue, 0x02)
        XCTAssertEqual(summary.window, 65535)
        XCTAssertFalse(summary.isRetransmission)
        XCTAssertFalse(summary.isOutOfOrder)
        XCTAssertFalse(summary.isDupAck)
    }

    // MARK: - Connection PCAP Analysis Tests

    func testConnectionPCAPAnalysisInitialization() {
        let clientEndpoint = FlowEndpoint(ip: "192.168.1.100", port: 54321)
        let serverEndpoint = FlowEndpoint(ip: "93.184.216.34", port: 443)
        let handshake = TCPHandshakeSummary()
        let termination = TCPTerminationSummary()
        let metrics = TCPFlowMetrics()
        let packets: [TCPPacketSummary] = []
        let streamC2S = Data([0x01, 0x02, 0x03])
        let streamS2C = Data([0x04, 0x05, 0x06])

        let analysis = ConnectionPCAPAnalysis(
            clientEndpoint: clientEndpoint,
            serverEndpoint: serverEndpoint,
            handshake: handshake,
            termination: termination,
            state: .established,
            metrics: metrics,
            packets: packets,
            streamClientToServer: streamC2S,
            streamServerToClient: streamS2C
        )

        XCTAssertEqual(analysis.clientEndpoint?.ip, "192.168.1.100")
        XCTAssertEqual(analysis.serverEndpoint?.ip, "93.184.216.34")
        XCTAssertEqual(analysis.state, .established)
        XCTAssertEqual(analysis.streamClientToServer.count, 3)
        XCTAssertEqual(analysis.streamServerToClient.count, 3)
    }

    // MARK: - Loading State Tests

    func testLoadFromPCAPSetsLoadingState() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent.pcap")
        let file = PCAPFileItem(url: url, size: 0, modified: Date())

        viewModel.loadFromPCAP(file)

        XCTAssertTrue(viewModel.isLoading)
    }

    func testLoadFromPCAPClearsAnalysis() {
        // Set initial analysis
        let analysis = ConnectionPCAPAnalysis(
            clientEndpoint: nil,
            serverEndpoint: nil,
            handshake: nil,
            termination: nil,
            state: .unknown,
            metrics: TCPFlowMetrics(),
            packets: [],
            streamClientToServer: Data(),
            streamServerToClient: Data()
        )
        viewModel.analysis = analysis

        let url = URL(fileURLWithPath: "/tmp/nonexistent.pcap")
        let file = PCAPFileItem(url: url, size: 0, modified: Date())

        viewModel.loadFromPCAP(file)

        XCTAssertNil(viewModel.loadError)
    }

    // MARK: - Record Property Tests

    func testRecordProperties() {
        XCTAssertEqual(viewModel.record.transport, .tcp)
        XCTAssertEqual(viewModel.record.bytesFromSource, 1500)
        XCTAssertEqual(viewModel.record.bytesToSource, 2048)
        XCTAssertEqual(viewModel.record.packetsFromSource, 10)
        XCTAssertEqual(viewModel.record.packetsToSource, 12)
        XCTAssertEqual(viewModel.record.connectionState, .established)
        XCTAssertFalse(viewModel.record.isClosed)
        XCTAssertNil(viewModel.record.tcpTermination)
    }

    // MARK: - Endpoint Tests

    func testClientAndServerEndpoints() {
        let clientEndpoint = FlowEndpoint(ip: "10.0.0.1", port: 49152)
        let serverEndpoint = FlowEndpoint(ip: "1.2.3.4", port: 80)

        XCTAssertEqual(clientEndpoint.ip, "10.0.0.1")
        XCTAssertEqual(clientEndpoint.port, 49152)
        XCTAssertEqual(serverEndpoint.ip, "1.2.3.4")
        XCTAssertEqual(serverEndpoint.port, 80)
    }

    // MARK: - Error Handling Tests

    func testLoadErrorInitiallyNil() {
        XCTAssertNil(viewModel.loadError)
    }

    // MARK: - PCAP Analysis Behavior

    func testLoadFromPCAPNoPacketsForFlowSetsError() async throws {
        let now = Date()
        let record = PacketFlowRecord(
            id: UUID(),
            sourceIP: "192.168.1.100",
            destinationIP: "93.184.216.34",
            sourcePort: 54321,
            destinationPort: 443,
            transport: .tcp,
            bytesFromSource: 0,
            bytesToSource: 0,
            packetsFromSource: 0,
            packetsToSource: 0,
            startTime: now,
            lastSeen: now,
            isClosed: false,
            connectionState: .unknown,
            tcpHandshake: nil,
            tcpTermination: nil,
            tcpMetrics: nil
        )
        let vm = ConnectionDetailViewModel(record: record)

        // Packet does NOT match the flow (different port).
        let nonMatchingPacket = makeIPv4TCPPacket(
            srcIP: "192.168.1.100",
            dstIP: "93.184.216.34",
            srcPort: 11111,
            dstPort: 443,
            flags: 0x02
        )
        let url = try createMockPCAPFile(
            withPackets: [(timestamp: now, data: nonMatchingPacket)]
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        let file = PCAPFileItem(url: url, size: size, modified: now)

        vm.loadFromPCAP(file)
        try await waitForLoadingToFinish(vm)

        XCTAssertNil(vm.analysis)
        XCTAssertEqual(vm.loadError, "No packets found for this connection in the selected PCAP.")
    }

    func testLoadFromPCAPTruncatedEOFStillReturnsAnalysis() async throws {
        let now = Date()
        let record = PacketFlowRecord(
            id: UUID(),
            sourceIP: "192.168.1.100",
            destinationIP: "93.184.216.34",
            sourcePort: 54321,
            destinationPort: 443,
            transport: .tcp,
            bytesFromSource: 0,
            bytesToSource: 0,
            packetsFromSource: 0,
            packetsToSource: 0,
            startTime: now,
            lastSeen: now,
            isClosed: false,
            connectionState: .unknown,
            tcpHandshake: nil,
            tcpTermination: nil,
            tcpMetrics: nil
        )
        let vm = ConnectionDetailViewModel(record: record)

        let matchingSyn = makeIPv4TCPPacket(
            srcIP: "192.168.1.100",
            dstIP: "93.184.216.34",
            srcPort: 54321,
            dstPort: 443,
            flags: 0x02
        )

        // Add a trailing truncated record after a valid packet.
        let url = try createMockPCAPFile(
            withPackets: [(timestamp: now, data: matchingSyn)],
            trailingTruncatedRecord: (timestamp: now, declaredLength: 60, actualData: Data(repeating: 0xAA, count: 8))
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        let file = PCAPFileItem(url: url, size: size, modified: now)

        vm.loadFromPCAP(file)
        try await waitForLoadingToFinish(vm)

        XCTAssertNil(vm.loadError)
        XCTAssertNotNil(vm.analysis)
        XCTAssertFalse(vm.analysis?.packets.isEmpty ?? true)
        XCTAssertNotNil(vm.analysis?.handshake?.synTime)
    }

    func testAutoLoadSkippedForUDPRecord() {
        let now = Date()
        let record = PacketFlowRecord(
            id: UUID(),
            sourceIP: "1.1.1.1",
            destinationIP: "8.8.8.8",
            sourcePort: 12345,
            destinationPort: 53,
            transport: .udp,
            startTime: now,
            lastSeen: now,
            isClosed: false,
            connectionState: .unknown,
            tcpHandshake: nil,
            tcpTermination: nil,
            tcpMetrics: nil
        )
        let vm = ConnectionDetailViewModel(record: record)

        vm.autoLoadPCAPIfPossible()

        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.analysis)
        XCTAssertNil(vm.loadError)
    }

    func testAutoLoadRespectsAutoAnalyzeMaxBytes() throws {
        // This test is only deterministic when there are no other eligible raw captures present.
        guard let container = AppGroupStorage.shared.containerURL else {
            XCTFail("Missing container URL")
            return
        }

        let maxBytes: UInt64 = 25 * 1_048_576
        let existingRaw = AppGroupStorage.shared.packetCaptureFiles(prefixes: ["capture_raw_packets"])
        let hasEligibleExistingCapture = existingRaw.contains { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .uint64Value ?? 0
            return size > 0 && size <= maxBytes
        }
        if hasEligibleExistingCapture {
            throw XCTSkip("Skipping: existing raw captures make auto-load nondeterministic in this environment.")
        }

        let bigURL = container.appendingPathComponent("capture_raw_packets_big.pcap")
        FileManager.default.createFile(atPath: bigURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bigURL)
        // 26 MB (auto limit is 25 MB).
        try handle.seek(toOffset: UInt64(26 * 1_048_576 - 1))
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: bigURL) }

        let now = Date()
        let record = PacketFlowRecord(
            id: UUID(),
            sourceIP: "192.168.1.100",
            destinationIP: "93.184.216.34",
            sourcePort: 54321,
            destinationPort: 443,
            transport: .tcp,
            startTime: now,
            lastSeen: now,
            isClosed: false,
            connectionState: .unknown,
            tcpHandshake: nil,
            tcpTermination: nil,
            tcpMetrics: nil
        )
        let vm = ConnectionDetailViewModel(record: record)

        vm.autoLoadPCAPIfPossible()

        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.analysis)
    }

    // MARK: - Multiple File Tests

    func testMultiplePCAPFiles() {
        let file1 = PCAPFileItem(
            url: URL(fileURLWithPath: "/tmp/capture1.pcap"),
            size: 1024,
            modified: Date()
        )
        let file2 = PCAPFileItem(
            url: URL(fileURLWithPath: "/tmp/capture2.pcap"),
            size: 2048,
            modified: Date()
        )

        viewModel.pcapFiles = [file1, file2]

        XCTAssertEqual(viewModel.pcapFiles.count, 2)
        XCTAssertEqual(viewModel.pcapFiles[0].size, 1024)
        XCTAssertEqual(viewModel.pcapFiles[1].size, 2048)
    }
}

// MARK: - Test Helpers

private extension ConnectionDetailViewModelTests {
    func waitForLoadingToFinish(_ vm: ConnectionDetailViewModel, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.isLoading {
            if Date() > deadline {
                XCTFail("Timed out waiting for PCAP analysis")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func createMockPCAPFile(
        withPackets packets: [(timestamp: Date, data: Data)],
        trailingTruncatedRecord: (timestamp: Date, declaredLength: Int, actualData: Data)? = nil
    ) throws -> URL {
        let url = tempDirectory.appendingPathComponent("test_\(UUID().uuidString).pcap")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        // Global header (little-endian, LINKTYPE_RAW).
        var header = Data()
        header.appendUInt32LE(0xA1B2_C3D4)
        header.appendUInt16LE(2)
        header.appendUInt16LE(4)
        header.appendUInt32LE(0)
        header.appendUInt32LE(0)
        header.appendUInt32LE(65535)
        header.appendUInt32LE(101)
        try handle.write(contentsOf: header)

        for packet in packets {
            try writeRecord(handle: handle, timestamp: packet.timestamp, declaredLength: packet.data.count, data: packet.data)
        }

        if let trailingTruncatedRecord {
            try writeRecord(
                handle: handle,
                timestamp: trailingTruncatedRecord.timestamp,
                declaredLength: trailingTruncatedRecord.declaredLength,
                data: trailingTruncatedRecord.actualData
            )
        }

        return url
    }

    func writeRecord(handle: FileHandle, timestamp: Date, declaredLength: Int, data: Data) throws {
        let seconds = UInt32(timestamp.timeIntervalSince1970)
        let usec = UInt32((timestamp.timeIntervalSince1970 - Double(seconds)) * 1_000_000.0)

        var recordHeader = Data()
        recordHeader.appendUInt32LE(seconds)
        recordHeader.appendUInt32LE(usec)
        recordHeader.appendUInt32LE(UInt32(declaredLength))
        recordHeader.appendUInt32LE(UInt32(declaredLength))
        try handle.write(contentsOf: recordHeader)
        try handle.write(contentsOf: data)
    }

    func makeIPv4TCPPacket(
        srcIP: String,
        dstIP: String,
        srcPort: UInt16,
        dstPort: UInt16,
        seq: UInt32 = 1,
        ack: UInt32 = 0,
        flags: UInt8,
        payload: Data = Data()
    ) -> Data {
        let src = ipv4Bytes(srcIP)
        let dst = ipv4Bytes(dstIP)

        let ipHeaderLen = 20
        let tcpHeaderLen = 20
        let totalLen = ipHeaderLen + tcpHeaderLen + payload.count

        var packet = Data()
        packet.reserveCapacity(totalLen)

        // IPv4 header
        var ipHeader = Data(count: ipHeaderLen)
        ipHeader[0] = 0x45 // v4, IHL=5
        ipHeader[1] = 0x00
        ipHeader[2] = UInt8((totalLen >> 8) & 0xFF)
        ipHeader[3] = UInt8(totalLen & 0xFF)
        ipHeader[4] = 0x00
        ipHeader[5] = 0x00
        ipHeader[6] = 0x40 // DF
        ipHeader[7] = 0x00
        ipHeader[8] = 64 // TTL
        ipHeader[9] = 6 // TCP
        ipHeader[10] = 0x00
        ipHeader[11] = 0x00
        ipHeader.replaceSubrange(12 ..< 16, with: src)
        ipHeader.replaceSubrange(16 ..< 20, with: dst)
        packet.append(ipHeader)

        // TCP header (minimal)
        var tcpHeader = Data(count: tcpHeaderLen)
        tcpHeader[0] = UInt8((srcPort >> 8) & 0xFF)
        tcpHeader[1] = UInt8(srcPort & 0xFF)
        tcpHeader[2] = UInt8((dstPort >> 8) & 0xFF)
        tcpHeader[3] = UInt8(dstPort & 0xFF)
        tcpHeader[4] = UInt8((seq >> 24) & 0xFF)
        tcpHeader[5] = UInt8((seq >> 16) & 0xFF)
        tcpHeader[6] = UInt8((seq >> 8) & 0xFF)
        tcpHeader[7] = UInt8(seq & 0xFF)
        tcpHeader[8] = UInt8((ack >> 24) & 0xFF)
        tcpHeader[9] = UInt8((ack >> 16) & 0xFF)
        tcpHeader[10] = UInt8((ack >> 8) & 0xFF)
        tcpHeader[11] = UInt8(ack & 0xFF)
        tcpHeader[12] = 0x50 // data offset=5 (20 bytes)
        tcpHeader[13] = flags & 0x3F
        tcpHeader[14] = 0xFF
        tcpHeader[15] = 0xFF
        tcpHeader[16] = 0x00
        tcpHeader[17] = 0x00
        tcpHeader[18] = 0x00
        tcpHeader[19] = 0x00
        packet.append(tcpHeader)

        packet.append(payload)
        return packet
    }

    func ipv4Bytes(_ ip: String) -> Data {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        precondition(parts.count == 4, "Invalid IPv4: \(ip)")
        return Data(parts)
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }
}
