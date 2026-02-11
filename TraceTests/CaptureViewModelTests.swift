//
//  CaptureViewModelTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
import SwiftUI
@testable import Trace
@testable import TraceCore

@MainActor
final class CaptureViewModelTests: XCTestCase {

    var viewModel: CaptureViewModel!

    override func setUp() {
        super.setUp()
        viewModel = CaptureViewModel()
        // Clear storage before each test
        try? AppGroupStorage.shared.clearAllRequests()
    }

    override func tearDown() {
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertEqual(viewModel.requests.count, 0)
        XCTAssertFalse(viewModel.isCapturing)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.searchScope, .all)
        XCTAssertNil(viewModel.filterMethod)
        XCTAssertNil(viewModel.filterStatusCode)
        XCTAssertTrue(viewModel.filterDomains.isEmpty)
        XCTAssertFalse(viewModel.filterFavoritesOnly)
    }

    // MARK: - Search Scope Tests

    func testSearchScopeEnum() {
        XCTAssertEqual(SearchScope.all.rawValue, "All")
        XCTAssertEqual(SearchScope.url.rawValue, "URL")
        XCTAssertEqual(SearchScope.headers.rawValue, "Headers")
        XCTAssertEqual(SearchScope.body.rawValue, "Body")
    }

    func testSearchScopeAllCases() {
        let allCases = SearchScope.allCases
        XCTAssertEqual(allCases.count, 4)
    }

    // MARK: - Filter Tests

    func testHasActiveFiltersInitially() {
        XCTAssertFalse(viewModel.hasActiveFilters)
    }

    func testHasActiveFiltersWithMethod() {
        viewModel.filterMethod = .get
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    func testHasActiveFiltersWithStatusCode() {
        viewModel.filterStatusCode = 200
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    func testHasActiveFiltersWithDomains() {
        viewModel.filterDomains = ["example.com"]
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    func testHasActiveFiltersWithFavoritesOnly() {
        viewModel.filterFavoritesOnly = true
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    func testActiveFilterCount() {
        XCTAssertEqual(viewModel.activeFilterCount, 0)

        viewModel.filterMethod = .get
        XCTAssertEqual(viewModel.activeFilterCount, 1)

        viewModel.filterStatusCode = 200
        XCTAssertEqual(viewModel.activeFilterCount, 2)

        viewModel.filterDomains = ["example.com", "test.com"]
        XCTAssertEqual(viewModel.activeFilterCount, 4)

        viewModel.filterFavoritesOnly = true
        XCTAssertEqual(viewModel.activeFilterCount, 5)
    }

    func testClearFilters() {
        viewModel.filterMethod = .get
        viewModel.filterStatusCode = 200
        viewModel.filterDomains = ["example.com"]
        viewModel.filterFavoritesOnly = true

        viewModel.clearFilters()

        XCTAssertNil(viewModel.filterMethod)
        XCTAssertNil(viewModel.filterStatusCode)
        XCTAssertTrue(viewModel.filterDomains.isEmpty)
        XCTAssertFalse(viewModel.filterFavoritesOnly)
    }

    // MARK: - Domain Filter Tests

    func testAddDomainFilter() {
        viewModel.addDomainFilter("example.com")

        XCTAssertEqual(viewModel.filterDomains.count, 1)
        XCTAssertTrue(viewModel.filterDomains.contains("example.com"))
    }

    func testAddDomainFilterTrimsWhitespace() {
        viewModel.addDomainFilter("  example.com  ")

        XCTAssertTrue(viewModel.filterDomains.contains("example.com"))
    }

    func testAddDomainFilterLowercases() {
        viewModel.addDomainFilter("EXAMPLE.COM")

        XCTAssertTrue(viewModel.filterDomains.contains("example.com"))
    }

    func testAddDomainFilterPreventsDuplicates() {
        viewModel.addDomainFilter("example.com")
        viewModel.addDomainFilter("example.com")

        XCTAssertEqual(viewModel.filterDomains.count, 1)
    }

    func testAddEmptyDomainFilter() {
        viewModel.addDomainFilter("")
        viewModel.addDomainFilter("   ")

        XCTAssertEqual(viewModel.filterDomains.count, 0)
    }

    func testRemoveDomainFilter() {
        viewModel.addDomainFilter("example.com")
        viewModel.addDomainFilter("test.com")

        viewModel.removeDomainFilter("example.com")

        XCTAssertEqual(viewModel.filterDomains.count, 1)
        XCTAssertTrue(viewModel.filterDomains.contains("test.com"))
    }

    // MARK: - Capture Toggle Tests

    func testToggleCapture() {
        XCTAssertFalse(viewModel.isCapturing)

        viewModel.toggleCapture()
        XCTAssertTrue(viewModel.isCapturing)

        viewModel.toggleCapture()
        XCTAssertFalse(viewModel.isCapturing)
    }

    // MARK: - Clear Requests Tests

    func testClearRequests() {
        viewModel.clearRequests()
        XCTAssertEqual(viewModel.requests.count, 0)
    }

    // MARK: - Delete Request Tests

    func testDeleteRequest() {
        let request = createMockRequest()
        try? AppGroupStorage.shared.saveRequest(request)
        viewModel.requests = [request]

        viewModel.deleteRequest(request)

        XCTAssertEqual(viewModel.requests.count, 0)
    }

    // MARK: - Filtered Requests Tests

    func testFilteredRequestsInitiallyEmpty() {
        XCTAssertEqual(viewModel.filteredRequests.count, 0)
    }

    func testFilteredRequestsByMethod() {
        let getRequest = createMockRequest(url: "https://example.com/1", method: .get)
        let postRequest = createMockRequest(url: "https://example.com/2", method: .post)

        viewModel.requests = [getRequest, postRequest]
        viewModel.filterMethod = .get

        let filtered = viewModel.filteredRequests
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.method, .get)
    }

    func testFilteredRequestsByStatusCode() {
        let success = createMockRequest(url: "https://example.com/1", statusCode: 200)
        let notFound = createMockRequest(url: "https://example.com/2", statusCode: 404)

        viewModel.requests = [success, notFound]
        viewModel.filterStatusCode = 404

        let filtered = viewModel.filteredRequests
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.statusCode, 404)
    }

    func testFilteredRequestsSearchURL() {
        let request1 = createMockRequest(url: "https://api.example.com/users")
        let request2 = createMockRequest(url: "https://example.com/posts")

        viewModel.requests = [request1, request2]
        viewModel.searchText = "users"
        viewModel.searchScope = .url

        let filtered = viewModel.filteredRequests
        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered.first?.url.contains("users") ?? false)
    }

    func testFilteredRequestsSortedByTimestamp() {
        let oldRequest = createMockRequest(
            url: "https://example.com/old",
            timestamp: Date(timeIntervalSinceNow: -3600)
        )
        let newRequest = createMockRequest(
            url: "https://example.com/new",
            timestamp: Date()
        )

        viewModel.requests = [oldRequest, newRequest]

        let filtered = viewModel.filteredRequests
        XCTAssertEqual(filtered.first?.url, "https://example.com/new")
        XCTAssertEqual(filtered.last?.url, "https://example.com/old")
    }

    func testDuplicateDetectionRunsAutomaticallyWhenEnabled() async {
        let now = Date()
        let original = createMockRequest(
            url: "https://api.example.com/users",
            method: .get,
            timestamp: now.addingTimeInterval(-60)
        )
        let duplicate = createMockRequest(
            url: "https://api.example.com/users",
            method: .get,
            timestamp: now
        )

        viewModel.requests = [original, duplicate]
        viewModel.filterShowDuplicatesOnly = true
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(viewModel.duplicateCount, 1)
        XCTAssertEqual(viewModel.filteredRequests.count, 1)
        XCTAssertTrue(viewModel.filteredRequests.allSatisfy(\.isDuplicate))
    }

    // MARK: - App Theme Tests

    // MARK: - Helper Methods

    private func createMockRequest(
        url: String = "https://example.com",
        method: HTTPMethod = .get,
        statusCode: Int = 200,
        timestamp: Date = Date()
    ) -> NetworkRequest {
        return NetworkRequest(
            url: url,
            method: method,
            statusCode: statusCode,
            timestamp: timestamp,
            duration: 0.5,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            requestBody: .empty,
            responseBody: .empty
        )
    }
}
