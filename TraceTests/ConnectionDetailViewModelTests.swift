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
    }

    override func tearDown() {
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
