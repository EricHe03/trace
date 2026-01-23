//
//  WebSocketViewModelTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

@MainActor
final class WebSocketViewModelTests: XCTestCase {

    var viewModel: WebSocketViewModel!

    override func setUp() {
        super.setUp()
        viewModel = WebSocketViewModel()
        // Clear storage before each test
        try? AppGroupStorage.shared.clearAllWebSocketConnections()
    }

    override func tearDown() {
        try? AppGroupStorage.shared.clearAllWebSocketConnections()
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertEqual(viewModel.connections.count, 0)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertNil(viewModel.filterStatus)
    }

    // MARK: - Filter Tests

    func testHasActiveFiltersInitially() {
        XCTAssertFalse(viewModel.hasActiveFilters)
    }

    func testHasActiveFiltersWithStatus() {
        viewModel.filterStatus = .open
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    func testClearFilters() {
        viewModel.filterStatus = .open

        viewModel.clearFilters()

        XCTAssertNil(viewModel.filterStatus)
        XCTAssertFalse(viewModel.hasActiveFilters)
    }

    // MARK: - Filtered Connections Tests

    func testFilteredConnectionsInitiallyEmpty() {
        XCTAssertEqual(viewModel.filteredConnections.count, 0)
    }

    func testFilteredConnectionsByStatus() {
        let openConnection = createMockConnection(
            url: "wss://example.com/1",
            status: .open
        )
        let closedConnection = createMockConnection(
            url: "wss://example.com/2",
            status: .closed
        )

        viewModel.connections = [openConnection, closedConnection]
        viewModel.filterStatus = .open

        let filtered = viewModel.filteredConnections
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.status, .open)
    }

    func testFilteredConnectionsSearchURL() {
        let connection1 = createMockConnection(url: "wss://api.example.com/chat")
        let connection2 = createMockConnection(url: "wss://example.com/notifications")

        viewModel.connections = [connection1, connection2]
        viewModel.searchText = "chat"

        let filtered = viewModel.filteredConnections
        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered.first?.url.contains("chat") ?? false)
    }

    func testFilteredConnectionsSearchHost() {
        let connection1 = createMockConnection(url: "wss://api.example.com/ws")
        let connection2 = createMockConnection(url: "wss://other.com/ws")

        viewModel.connections = [connection1, connection2]
        viewModel.searchText = "api.example"

        let filtered = viewModel.filteredConnections
        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered.first?.host.contains("api.example") ?? false)
    }

    func testFilteredConnectionsSearchCaseInsensitive() {
        let connection = createMockConnection(url: "wss://API.EXAMPLE.COM/ws")

        viewModel.connections = [connection]
        viewModel.searchText = "api"

        let filtered = viewModel.filteredConnections
        XCTAssertEqual(filtered.count, 1)
    }

    func testFilteredConnectionsSortedByStartTime() {
        let oldConnection = createMockConnection(
            url: "wss://example.com/old",
            startTime: Date(timeIntervalSinceNow: -3600)
        )
        let newConnection = createMockConnection(
            url: "wss://example.com/new",
            startTime: Date()
        )

        viewModel.connections = [oldConnection, newConnection]

        let filtered = viewModel.filteredConnections
        XCTAssertEqual(filtered.first?.url, "wss://example.com/new")
        XCTAssertEqual(filtered.last?.url, "wss://example.com/old")
    }

    func testFilteredConnectionsWithMultipleFilters() {
        let match = createMockConnection(
            url: "wss://api.example.com/chat",
            status: .open
        )
        let wrongStatus = createMockConnection(
            url: "wss://api.example.com/other",
            status: .closed
        )
        let wrongURL = createMockConnection(
            url: "wss://other.com/chat",
            status: .open
        )

        viewModel.connections = [match, wrongStatus, wrongURL]
        viewModel.filterStatus = .open
        viewModel.searchText = "example"

        let filtered = viewModel.filteredConnections
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.url, match.url)
    }

    // MARK: - Clear Connections Tests

    func testClearConnections() {
        viewModel.clearConnections()
        XCTAssertEqual(viewModel.connections.count, 0)
    }

    // MARK: - Delete Connection Tests

    func testDeleteConnection() {
        let connection = createMockConnection()
        try? AppGroupStorage.shared.saveWebSocketConnection(connection)
        viewModel.connections = [connection]

        viewModel.deleteConnection(connection)

        XCTAssertEqual(viewModel.connections.count, 0)
    }

    // MARK: - Search Tests

    func testSearchEmptyString() {
        let connection = createMockConnection()
        viewModel.connections = [connection]
        viewModel.searchText = ""

        let filtered = viewModel.filteredConnections
        XCTAssertEqual(filtered.count, 1)
    }

    func testSearchWithNoResults() {
        let connection = createMockConnection(url: "wss://example.com")
        viewModel.connections = [connection]
        viewModel.searchText = "nonexistent"

        let filtered = viewModel.filteredConnections
        XCTAssertEqual(filtered.count, 0)
    }

    // MARK: - Helper Methods

    private func createMockConnection(
        url: String = "wss://example.com",
        status: WebSocketConnectionStatus = .open,
        startTime: Date = Date()
    ) -> WebSocketConnection {
        return WebSocketConnection(
            url: url,
            startTime: startTime,
            endTime: nil,
            messages: [],
            status: status
        )
    }
}
