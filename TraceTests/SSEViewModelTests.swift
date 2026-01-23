//
//  SSEViewModelTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
import Combine
@testable import Trace
@testable import TraceCore

@MainActor
final class SSEViewModelTests: XCTestCase {
    var sut: SSEViewModel!
    var mockStorage: MockSSEAppGroupStorage!

    override func setUp() {
        super.setUp()
        mockStorage = MockSSEAppGroupStorage()
        // Note: SSEViewModel uses AppGroupStorage.shared directly,
        // so tests would need dependency injection refactoring for full isolation
        sut = SSEViewModel()
    }

    override func tearDown() {
        sut = nil
        mockStorage = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInit_LoadsConnectionsFromStorage() {
        // Then - Connections are loaded on initialization
        // Note: This test is limited without DI, but we can verify the structure
        XCTAssertNotNil(sut.connections)
        XCTAssertEqual(sut.connections.count, 0) // Initial state
    }

    // MARK: - Filtered Connections Tests

    func testFilteredConnections_WithNoFilters_ReturnsAllConnections() {
        // Given
        let connection1 = createMockSSEConnection(url: "https://example.com/sse")
        let connection2 = createMockSSEConnection(url: "https://test.com/sse")
        sut.connections = [connection1, connection2]

        // When
        let filtered = sut.filteredConnections

        // Then
        XCTAssertEqual(filtered.count, 2)
    }

    func testFilteredConnections_WithStatusFilter_FiltersCorrectly() {
        // Given
        let activeConnection = createMockSSEConnection(
            url: "https://example.com/sse",
            status: .streaming
        )
        let closedConnection = createMockSSEConnection(
            url: "https://test.com/sse",
            status: .closed
        )
        sut.connections = [activeConnection, closedConnection]
        sut.filterStatus = .streaming

        // When
        let filtered = sut.filteredConnections

        // Then
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.status, .streaming)
    }

    func testFilteredConnections_WithSearchText_FiltersURL() {
        // Given
        let connection1 = createMockSSEConnection(url: "https://example.com/sse")
        let connection2 = createMockSSEConnection(url: "https://test.com/sse")
        sut.connections = [connection1, connection2]
        sut.searchText = "example"

        // When
        let filtered = sut.filteredConnections

        // Then
        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered.first?.url.contains("example") ?? false)
    }

    func testFilteredConnections_WithSearchText_FiltersHost() {
        // Given
        let connection1 = createMockSSEConnection(url: "https://example.com/sse")
        let connection2 = createMockSSEConnection(url: "https://test.com/sse")
        sut.connections = [connection1, connection2]
        sut.searchText = "example"

        // When
        let filtered = sut.filteredConnections

        // Then
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.host, "example.com")
    }

    func testFilteredConnections_CaseInsensitiveSearch() {
        // Given
        let connection = createMockSSEConnection(url: "https://Example.com/sse")
        sut.connections = [connection]
        sut.searchText = "EXAMPLE"

        // When
        let filtered = sut.filteredConnections

        // Then
        XCTAssertEqual(filtered.count, 1)
    }

    func testFilteredConnections_WithMultipleFilters_AppliesBoth() {
        // Given
        let activeExample = createMockSSEConnection(
            url: "https://example.com/sse",
            status: .streaming
        )
        let closedExample = createMockSSEConnection(
            url: "https://example.org/sse",
            status: .closed
        )
        let activeTest = createMockSSEConnection(
            url: "https://test.com/sse",
            status: .streaming
        )

        sut.connections = [activeExample, closedExample, activeTest]
        sut.searchText = "example"
        sut.filterStatus = .streaming

        // When
        let filtered = sut.filteredConnections

        // Then
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.url, "https://example.com/sse")
    }

    func testFilteredConnections_SortsByStartTimeDescending() {
        // Given
        let oldConnection = createMockSSEConnection(
            url: "https://old.com/sse",
            startTime: Date(timeIntervalSince1970: 1000)
        )
        let newConnection = createMockSSEConnection(
            url: "https://new.com/sse",
            startTime: Date(timeIntervalSince1970: 2000)
        )
        sut.connections = [oldConnection, newConnection]

        // When
        let filtered = sut.filteredConnections

        // Then
        XCTAssertEqual(filtered.first?.url, "https://new.com/sse")
        XCTAssertEqual(filtered.last?.url, "https://old.com/sse")
    }

    // MARK: - Clear Filters Tests

    func testClearFilters_ResetsStatusFilter() {
        // Given
        sut.filterStatus = .streaming

        // When
        sut.clearFilters()

        // Then
        XCTAssertNil(sut.filterStatus)
    }

    // MARK: - Has Active Filters Tests

    func testHasActiveFilters_WithNoFilters_ReturnsFalse() {
        // Given
        sut.filterStatus = nil

        // When
        let hasFilters = sut.hasActiveFilters

        // Then
        XCTAssertFalse(hasFilters)
    }

    func testHasActiveFilters_WithStatusFilter_ReturnsTrue() {
        // Given
        sut.filterStatus = .streaming

        // When
        let hasFilters = sut.hasActiveFilters

        // Then
        XCTAssertTrue(hasFilters)
    }

    // MARK: - Helper Methods

    private func createMockSSEConnection(
        url: String,
        status: SSEConnectionStatus = .streaming,
        startTime: Date = Date()
    ) -> SSEConnection {
        SSEConnection(
            id: UUID(),
            url: url,
            startTime: startTime,
            status: status
        )
    }
}

// MARK: - Mock SSE AppGroupStorage

class MockSSEAppGroupStorage: AppGroupStorage {
    override init() {
        super.init()
    }

    var mockConnections: [SSEConnection] = []

    var loadAllSSEConnectionsCalled = false
    var clearAllSSEConnectionsCalled = false
    var deleteSSEConnectionCalled = false

    override func loadAllSSEConnections() throws -> [SSEConnection] {
        loadAllSSEConnectionsCalled = true
        return mockConnections
    }

    override func clearAllSSEConnections() throws {
        clearAllSSEConnectionsCalled = true
        mockConnections = []
    }

    override func deleteSSEConnection(_ id: UUID) throws {
        deleteSSEConnectionCalled = true
        mockConnections.removeAll { $0.id == id }
    }
}
