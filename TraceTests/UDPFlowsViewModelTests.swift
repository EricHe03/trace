//
//  UDPFlowsViewModelTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore

@MainActor
final class UDPFlowsViewModelTests: XCTestCase {

    var viewModel: UDPFlowsViewModel!

    override func setUp() {
        super.setUp()
        viewModel = UDPFlowsViewModel()
        // Clear storage before each test
        try? AppGroupStorage.shared.clearAllUDPFlowMetadata()
    }

    override func tearDown() {
        try? AppGroupStorage.shared.clearAllUDPFlowMetadata()
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertTrue(viewModel.flows.isEmpty)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertFalse(viewModel.activeOnly)
        XCTAssertNil(viewModel.selectedProtocol)
        XCTAssertEqual(viewModel.portFilter, "")
        XCTAssertEqual(viewModel.sortOrder, .startTimeDescending)
        XCTAssertNil(viewModel.lastError)
    }

    // MARK: - Sort Order Tests

    func testSortOrderEnum() {
        let allCases = UDPFlowsViewModel.SortOrder.allCases

        XCTAssertEqual(allCases.count, 10)
        XCTAssertTrue(allCases.contains(.startTimeAscending))
        XCTAssertTrue(allCases.contains(.startTimeDescending))
        XCTAssertTrue(allCases.contains(.bytesAscending))
        XCTAssertTrue(allCases.contains(.bytesDescending))
        XCTAssertTrue(allCases.contains(.durationAscending))
        XCTAssertTrue(allCases.contains(.durationDescending))
        XCTAssertTrue(allCases.contains(.destinationPortAscending))
        XCTAssertTrue(allCases.contains(.destinationPortDescending))
        XCTAssertTrue(allCases.contains(.datagramsAscending))
        XCTAssertTrue(allCases.contains(.datagramsDescending))
    }

    func testSortOrderDisplayNames() {
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.startTimeAscending.displayName, "Start Time ↑")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.startTimeDescending.displayName, "Start Time ↓")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.bytesAscending.displayName, "Bytes ↑")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.bytesDescending.displayName, "Bytes ↓")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.durationAscending.displayName, "Duration ↑")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.durationDescending.displayName, "Duration ↓")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.destinationPortAscending.displayName, "Destination Port ↑")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.destinationPortDescending.displayName, "Destination Port ↓")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.datagramsAscending.displayName, "Datagrams ↑")
        XCTAssertEqual(UDPFlowsViewModel.SortOrder.datagramsDescending.displayName, "Datagrams ↓")
    }

    // MARK: - Statistics Tests

    func testStatisticsWithEmptyFlows() {
        let stats = viewModel.statistics

        XCTAssertEqual(stats.activeFlows, 0)
        XCTAssertEqual(stats.totalFlows, 0)
        XCTAssertEqual(stats.totalBytes, 0)
        XCTAssertEqual(stats.totalDatagrams, 0)
        XCTAssertTrue(stats.detectedProtocols.isEmpty)
    }

    func testStatisticsWithFlows() {
        let flow1 = createMockUDPFlow(
            sourceIP: "192.168.1.100",
            destinationPort: 53,
            bytesFromSource: 100,
            bytesToSource: 200,
            datagramsFromSource: 5,
            datagramsToSource: 10,
            isActive: true,
            detectedProtocol: .dns
        )

        let flow2 = createMockUDPFlow(
            sourceIP: "192.168.1.101",
            destinationPort: 123,
            bytesFromSource: 50,
            bytesToSource: 75,
            datagramsFromSource: 2,
            datagramsToSource: 3,
            isActive: false,
            detectedProtocol: .ntp
        )

        viewModel.flows = [flow1, flow2]

        let stats = viewModel.statistics
        XCTAssertEqual(stats.activeFlows, 1)
        XCTAssertEqual(stats.totalFlows, 2)
        XCTAssertEqual(stats.totalBytes, 425) // (100+200) + (50+75)
        XCTAssertEqual(stats.totalDatagrams, 20) // (5+10) + (2+3)
        XCTAssertEqual(stats.detectedProtocols.count, 2)
        XCTAssertTrue(stats.detectedProtocols.contains(.dns))
        XCTAssertTrue(stats.detectedProtocols.contains(.ntp))
    }

    // MARK: - Filter Tests

    func testFilteredFlowsWithSearchText() {
        let flow1 = createMockUDPFlow(sourceIP: "192.168.1.100", destinationPort: 53)
        let flow2 = createMockUDPFlow(sourceIP: "10.0.0.1", destinationPort: 80)

        viewModel.flows = [flow1, flow2]
        viewModel.searchText = "192.168"

        let filtered = viewModel.filteredFlows
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.sourceIP, "192.168.1.100")
    }

    func testFilteredFlowsWithActiveOnly() {
        let activeFlow = createMockUDPFlow(sourceIP: "192.168.1.100", isActive: true)
        let inactiveFlow = createMockUDPFlow(sourceIP: "192.168.1.101", isActive: false)

        viewModel.flows = [activeFlow, inactiveFlow]
        viewModel.activeOnly = true

        let filtered = viewModel.filteredFlows
        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered.first?.isActive ?? false)
    }

    func testFilteredFlowsWithProtocolFilter() {
        let dnsFlow = createMockUDPFlow(destinationPort: 53, detectedProtocol: .dns)
        let ntpFlow = createMockUDPFlow(destinationPort: 123, detectedProtocol: .ntp)

        viewModel.flows = [dnsFlow, ntpFlow]
        viewModel.selectedProtocol = .dns

        let filtered = viewModel.filteredFlows
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.detectedProtocol, .dns)
    }

    func testFilteredFlowsWithPortFilter() {
        let flow1 = createMockUDPFlow(sourcePort: 54321, destinationPort: 53)
        let flow2 = createMockUDPFlow(sourcePort: 12345, destinationPort: 80)

        viewModel.flows = [flow1, flow2]
        viewModel.portFilter = "53"

        let filtered = viewModel.filteredFlows
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.destinationPort, 53)
    }

    func testFilteredFlowsWithInvalidPortFilter() {
        let flow1 = createMockUDPFlow(destinationPort: 53)
        let flow2 = createMockUDPFlow(destinationPort: 80)

        viewModel.flows = [flow1, flow2]
        viewModel.portFilter = "invalid"

        let filtered = viewModel.filteredFlows
        XCTAssertEqual(filtered.count, 2) // Invalid filter should show all
    }

    // MARK: - Sorting Tests

    func testSortByStartTimeDescending() {
        let oldFlow = createMockUDPFlow(
            startTime: Date(timeIntervalSinceNow: -3600)
        )
        let newFlow = createMockUDPFlow(
            startTime: Date()
        )

        viewModel.flows = [oldFlow, newFlow]
        viewModel.sortOrder = .startTimeDescending

        let filtered = viewModel.filteredFlows
        XCTAssertTrue(filtered[0].startTime > filtered[1].startTime)
    }

    func testSortByBytesAscending() {
        let smallFlow = createMockUDPFlow(bytesFromSource: 100, bytesToSource: 50)
        let largeFlow = createMockUDPFlow(bytesFromSource: 1000, bytesToSource: 500)

        viewModel.flows = [largeFlow, smallFlow]
        viewModel.sortOrder = .bytesAscending

        let filtered = viewModel.filteredFlows
        XCTAssertTrue(filtered[0].totalBytes < filtered[1].totalBytes)
    }

    func testSortByDurationDescending() {
        let shortFlow = createMockUDPFlow(
            startTime: Date(timeIntervalSinceNow: -60),
            lastActivity: Date(timeIntervalSinceNow: -30)
        )
        let longFlow = createMockUDPFlow(
            startTime: Date(timeIntervalSinceNow: -3600),
            lastActivity: Date()
        )

        viewModel.flows = [shortFlow, longFlow]
        viewModel.sortOrder = .durationDescending

        let filtered = viewModel.filteredFlows
        XCTAssertTrue(filtered[0].duration > filtered[1].duration)
    }

    // MARK: - Export Tests

    func testFormatBytes() {
        XCTAssertEqual(viewModel.formatBytes(0), "0 B")
        XCTAssertEqual(viewModel.formatBytes(500), "500 B")
        XCTAssertEqual(viewModel.formatBytes(1024), "1.0 KB")
        XCTAssertEqual(viewModel.formatBytes(1048576), "1.0 MB")
    }

    func testFormatDuration() {
        let duration1 = viewModel.formatDuration(0.5)
        XCTAssertFalse(duration1.isEmpty)

        let duration2 = viewModel.formatDuration(60)
        XCTAssertFalse(duration2.isEmpty)
    }

    func testFormatThroughput() {
        XCTAssertEqual(viewModel.formatThroughput(500), "500 B/s")
        XCTAssertEqual(viewModel.formatThroughput(1024), "1.0 KB/s")
        XCTAssertEqual(viewModel.formatThroughput(1048576), "1.0 MB/s")
    }

    func testExportCSV() throws {
        let flow = createMockUDPFlow(sourceIP: "192.168.1.100", destinationPort: 53)
        viewModel.flows = [flow]

        let url = try viewModel.exportCSV()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.contains("udp_flows"))
        XCTAssertEqual(url.pathExtension, "csv")

        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }

    func testExportJSON() throws {
        let flow = createMockUDPFlow(sourceIP: "192.168.1.100", destinationPort: 53)
        viewModel.flows = [flow]

        let url = try viewModel.exportJSON()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.contains("udp_flows"))
        XCTAssertEqual(url.pathExtension, "json")

        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Clear Operations Tests

    func testClearAll() {
        let flow = createMockUDPFlow()
        viewModel.flows = [flow]

        viewModel.clearAll()

        XCTAssertTrue(viewModel.flows.isEmpty)
    }

    func testDeleteFlow() {
        let flow = createMockUDPFlow()
        viewModel.flows = [flow]

        viewModel.deleteFlow(flow)

        XCTAssertTrue(viewModel.flows.isEmpty)
    }

    func testDeleteOlderThan() {
        let oldFlow = createMockUDPFlow(
            startTime: Date(timeIntervalSinceNow: -86400 * 8),
            lastActivity: Date(timeIntervalSinceNow: -86400 * 8),
            endTime: Date(timeIntervalSinceNow: -86400 * 8)
        )
        let newFlow = createMockUDPFlow()

        viewModel.flows = [oldFlow, newFlow]
        viewModel.deleteOlderThan(days: 7)

        XCTAssertEqual(viewModel.flows.count, 1)
        XCTAssertEqual(viewModel.flows.first?.id, newFlow.id)
    }

    // MARK: - Helper Methods

    private func createMockUDPFlow(
        sourceIP: String = "192.168.1.100",
        sourcePort: UInt16 = 54321,
        destinationIP: String = "8.8.8.8",
        destinationPort: UInt16 = 53,
        bytesFromSource: UInt64 = 100,
        bytesToSource: UInt64 = 200,
        datagramsFromSource: UInt64 = 5,
        datagramsToSource: UInt64 = 10,
        startTime: Date = Date(),
        lastActivity: Date = Date(),
        endTime: Date? = nil,
        isActive: Bool = true,
        detectedProtocol: UDPFlowProtocol = .dns
    ) -> UDPFlowMetadata {
        return UDPFlowMetadata(
            id: UUID(),
            sourceIP: sourceIP,
            destinationIP: destinationIP,
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            bytesFromSource: bytesFromSource,
            bytesToSource: bytesToSource,
            datagramsFromSource: datagramsFromSource,
            datagramsToSource: datagramsToSource,
            startTime: startTime,
            lastActivity: lastActivity,
            endTime: endTime,
            termination: isActive ? .active : .timeout,
            detectedProtocol: detectedProtocol
        )
    }
}
