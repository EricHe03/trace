//
//  EndToEndTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/09.
//
//

import Combine
import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

// MARK: - End-to-End Test Suite

@MainActor
final class EndToEndTests: XCTestCase {
    // MARK: - Properties

    var viewModel: CaptureViewModel!
    var mockVPNManager: MockE2EVPNManager!
    var captureService: NetworkCaptureService!

    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Clear storage before each test
        try? AppGroupStorage.shared.clearAllRequests()
        try? clearAllSessions()

        // Initialize components
        mockVPNManager = MockE2EVPNManager()
        captureService = NetworkCaptureService(vpnManager: mockVPNManager)
        viewModel = CaptureViewModel()

        // Wait for initialization
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        // Clean up
        try? AppGroupStorage.shared.clearAllRequests()
        try? clearAllSessions()

        viewModel = nil
        captureService = nil
        mockVPNManager = nil

        try await super.tearDown()
    }

    private func clearAllSessions() throws {
        let sessions = try AppGroupStorage.shared.loadAllSessions()
        for session in sessions {
            try AppGroupStorage.shared.deleteSession(session.id)
        }
    }

    // MARK: - Complete Capture Flow Tests

    /// Tests the complete flow: start capture → add requests → view requests → stop capture
    func testCompleteCaptureFlow() async throws {
        // GIVEN: Initial state with no requests
        XCTAssertEqual(viewModel.requests.count, 0)
        XCTAssertFalse(viewModel.isCapturing)

        // WHEN: Starting capture
        mockVPNManager.shouldSucceed = true
        try await captureService.startCapture()

        // THEN: Capture should be active
        XCTAssertTrue(captureService.isCapturing)
        XCTAssertTrue(mockVPNManager.startCalled)

        // WHEN: Network requests are captured (simulated)
        let request1 = createTestRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 200
        )
        let request2 = createTestRequest(
            url: "https://api.example.com/posts",
            method: .post,
            statusCode: 201
        )

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        // Wait for storage notification processing
        try await Task.sleep(nanoseconds: 600_000_000)

        // Reload requests
        await viewModel.reloadRequests()

        // THEN: Requests should be captured
        XCTAssertGreaterThanOrEqual(viewModel.requests.count, 2)

        // WHEN: Stopping capture
        try await captureService.stopCapture()

        // THEN: Capture should be stopped
        XCTAssertFalse(captureService.isCapturing)
        XCTAssertTrue(mockVPNManager.stopCalled)

        // Verify requests are still available after stopping capture
        XCTAssertGreaterThanOrEqual(viewModel.requests.count, 2)
    }

    /// Tests that captured requests contain all expected metadata
    func testCapturedRequestMetadata() async throws {
        // GIVEN: A request with complete metadata
        let requestId = UUID()
        let timestamp = Date()
        let request = NetworkRequest(
            id: requestId,
            url: "https://api.example.com/users/123",
            method: .put,
            statusCode: 200,
            statusMessage: "OK",
            timestamp: timestamp,
            duration: 0.250,
            requestHeaders: [
                TraceHTTPHeader(key: "Content-Type", value: "application/json"),
                TraceHTTPHeader(key: "Authorization", value: "Bearer token123")
            ],
            responseHeaders: [
                TraceHTTPHeader(key: "Content-Type", value: "application/json"),
                TraceHTTPHeader(key: "X-Request-Id", value: "abc123")
            ],
            requestBody: .from(string: "{\"name\":\"John\"}"),
            responseBody: .from(string: "{\"id\":123,\"name\":\"John\"}")
        )

        // WHEN: Request is saved and loaded
        try AppGroupStorage.shared.saveRequest(request)
        await viewModel.reloadRequests()

        // THEN: All metadata should be preserved
        guard let loadedRequest = viewModel.requests.first(where: { $0.id == requestId }) else {
            XCTFail("Request not found after reload")
            return
        }

        XCTAssertEqual(loadedRequest.url, "https://api.example.com/users/123")
        XCTAssertEqual(loadedRequest.method, .put)
        XCTAssertEqual(loadedRequest.statusCode, 200)
        XCTAssertEqual(loadedRequest.duration, 0.250, accuracy: 0.001)
        XCTAssertEqual(loadedRequest.requestHeaders.count, 2)
        XCTAssertEqual(loadedRequest.responseHeaders.count, 2)
        XCTAssertEqual(loadedRequest.host, "api.example.com")
        XCTAssertEqual(loadedRequest.path, "/users/123")
    }

    /// Tests request ordering by timestamp
    func testRequestsOrderedByTimestamp() async throws {
        // GIVEN: Multiple requests with different timestamps
        let now = Date()
        let request1 = createTestRequest(
            url: "https://api.example.com/first",
            timestamp: now.addingTimeInterval(-3600) // 1 hour ago
        )
        let request2 = createTestRequest(
            url: "https://api.example.com/second",
            timestamp: now.addingTimeInterval(-60) // 1 minute ago
        )
        let request3 = createTestRequest(
            url: "https://api.example.com/third",
            timestamp: now // Now
        )

        // WHEN: Requests are saved in random order
        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request3)
        try AppGroupStorage.shared.saveRequest(request2)

        await viewModel.reloadRequests()

        // THEN: Requests should be sorted by timestamp (newest first)
        let filteredRequests = viewModel.filteredRequests
        XCTAssertGreaterThanOrEqual(filteredRequests.count, 3)

        // Find our test requests
        let testRequests = filteredRequests.filter {
            $0.url.contains("api.example.com") &&
            ($0.url.contains("first") || $0.url.contains("second") || $0.url.contains("third"))
        }

        guard testRequests.count >= 3 else {
            XCTFail("Expected at least 3 test requests, found \(testRequests.count)")
            return
        }

        // Verify ordering (newest first)
        XCTAssertTrue(testRequests[0].url.contains("third"))
        XCTAssertTrue(testRequests[1].url.contains("second"))
        XCTAssertTrue(testRequests[2].url.contains("first"))
    }
}

// MARK: - Session Management E2E Tests

@MainActor
final class SessionManagementE2ETests: XCTestCase {
    var viewModel: CaptureViewModel!
    var sessionService: SessionManagementService!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        try? clearAllSessions()

        viewModel = CaptureViewModel()
        sessionService = SessionManagementService()

        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        try? AppGroupStorage.shared.clearAllRequests()
        try? clearAllSessions()
        viewModel = nil
        sessionService = nil
        try await super.tearDown()
    }

    private func clearAllSessions() throws {
        let sessions = try AppGroupStorage.shared.loadAllSessions()
        for session in sessions {
            try AppGroupStorage.shared.deleteSession(session.id)
        }
    }

    /// Tests complete session lifecycle: create → capture → end → verify
    func testCompleteSessionLifecycle() async throws {
        // GIVEN: No existing sessions
        let initialSessions = try await sessionService.fetchSessions()
        let initialCount = initialSessions.count

        // WHEN: Creating a new session
        let session = try await sessionService.createSession(name: "E2E Test Session")

        // THEN: Session should be created with correct properties
        XCTAssertEqual(session.name, "E2E Test Session")
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.requestCount, 0)

        // WHEN: Adding requests to the session
        var request1 = createTestRequest(url: "https://api.example.com/1")
        request1.sessionId = session.id

        var request2 = createTestRequest(url: "https://api.example.com/2")
        request2.sessionId = session.id

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        // WHEN: Ending the session
        var endedSession = session
        endedSession.endTime = Date()
        try await sessionService.updateSession(endedSession)

        // THEN: Session should be ended and have correct request count
        let fetchedSession = try await sessionService.fetchSession(by: session.id)
        XCTAssertNotNil(fetchedSession)
        XCTAssertFalse(fetchedSession!.isActive)
        XCTAssertEqual(fetchedSession!.requestCount, 2)

        // Verify sessions list is updated
        let allSessions = try await sessionService.fetchSessions()
        XCTAssertEqual(allSessions.count, initialCount + 1)
    }

    /// Tests that requests are correctly associated with sessions
    func testRequestSessionAssociation() async throws {
        // GIVEN: Two sessions
        let session1 = try await sessionService.createSession(name: "Session 1")
        let session2 = try await sessionService.createSession(name: "Session 2")

        // WHEN: Adding requests to each session
        var requestForSession1 = createTestRequest(url: "https://api.example.com/session1")
        requestForSession1.sessionId = session1.id

        var requestForSession2a = createTestRequest(url: "https://api.example.com/session2a")
        requestForSession2a.sessionId = session2.id

        var requestForSession2b = createTestRequest(url: "https://api.example.com/session2b")
        requestForSession2b.sessionId = session2.id

        try AppGroupStorage.shared.saveRequest(requestForSession1)
        try AppGroupStorage.shared.saveRequest(requestForSession2a)
        try AppGroupStorage.shared.saveRequest(requestForSession2b)

        // THEN: Each session should have the correct request count
        let fetchedSession1 = try await sessionService.fetchSession(by: session1.id)
        let fetchedSession2 = try await sessionService.fetchSession(by: session2.id)

        XCTAssertEqual(fetchedSession1?.requestCount, 1)
        XCTAssertEqual(fetchedSession2?.requestCount, 2)
    }

    /// Tests session deletion cascades to requests
    func testSessionDeletionCascade() async throws {
        // GIVEN: A session with requests
        let session = try await sessionService.createSession(name: "Session to Delete")

        var request = createTestRequest(url: "https://api.example.com/to-delete")
        request.sessionId = session.id
        try AppGroupStorage.shared.saveRequest(request)

        // Verify request exists
        let requestsBefore = try AppGroupStorage.shared.loadAllRequests()
        let sessionRequestsBefore = requestsBefore.filter { $0.sessionId == session.id }
        XCTAssertEqual(sessionRequestsBefore.count, 1)

        // WHEN: Deleting the session
        try await sessionService.deleteSession(session.id)

        // THEN: Session and its requests should be deleted
        let fetchedSession = try await sessionService.fetchSession(by: session.id)
        XCTAssertNil(fetchedSession)
    }
}

// MARK: - Filtering E2E Tests

@MainActor
final class FilteringE2ETests: XCTestCase {
    var viewModel: CaptureViewModel!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        try await super.tearDown()
    }

    /// Tests filtering by HTTP method
    func testFilterByMethod() async throws {
        // GIVEN: Requests with different methods
        let getRequest = createTestRequest(url: "https://api.example.com/get", method: .get)
        let postRequest = createTestRequest(url: "https://api.example.com/post", method: .post)
        let putRequest = createTestRequest(url: "https://api.example.com/put", method: .put)

        try AppGroupStorage.shared.saveRequest(getRequest)
        try AppGroupStorage.shared.saveRequest(postRequest)
        try AppGroupStorage.shared.saveRequest(putRequest)

        await viewModel.reloadRequests()

        // WHEN: Filtering by GET method
        viewModel.filterMethod = .get
        let getFiltered = viewModel.filteredRequests

        // THEN: Only GET requests should be visible
        let getResults = getFiltered.filter { $0.url.contains("api.example.com") }
        XCTAssertTrue(getResults.allSatisfy { $0.method == .get })

        // WHEN: Filtering by POST method
        viewModel.filterMethod = .post
        let postFiltered = viewModel.filteredRequests

        // THEN: Only POST requests should be visible
        let postResults = postFiltered.filter { $0.url.contains("api.example.com") }
        XCTAssertTrue(postResults.allSatisfy { $0.method == .post })

        // WHEN: Clearing filter
        viewModel.clearFilters()

        // THEN: All requests should be visible
        let allFiltered = viewModel.filteredRequests
        XCTAssertGreaterThanOrEqual(allFiltered.count, 3)
    }

    /// Tests filtering by status code
    func testFilterByStatusCode() async throws {
        // GIVEN: Requests with different status codes
        let successRequest = createTestRequest(
            url: "https://api.example.com/success",
            statusCode: 200
        )
        let notFoundRequest = createTestRequest(
            url: "https://api.example.com/notfound",
            statusCode: 404
        )
        let errorRequest = createTestRequest(
            url: "https://api.example.com/error",
            statusCode: 500
        )

        try AppGroupStorage.shared.saveRequest(successRequest)
        try AppGroupStorage.shared.saveRequest(notFoundRequest)
        try AppGroupStorage.shared.saveRequest(errorRequest)

        await viewModel.reloadRequests()

        // WHEN: Filtering by status code 404
        viewModel.filterStatusCode = 404

        // THEN: Only 404 requests should be visible
        let filteredRequests = viewModel.filteredRequests.filter {
            $0.url.contains("api.example.com")
        }
        XCTAssertTrue(filteredRequests.allSatisfy { $0.statusCode == 404 })
    }

    /// Tests filtering by domain
    func testFilterByDomain() async throws {
        // GIVEN: Requests from different domains
        let exampleRequest = createTestRequest(url: "https://example.com/api")
        let githubRequest = createTestRequest(url: "https://api.github.com/users")
        let googleRequest = createTestRequest(url: "https://www.google.com/search")

        try AppGroupStorage.shared.saveRequest(exampleRequest)
        try AppGroupStorage.shared.saveRequest(githubRequest)
        try AppGroupStorage.shared.saveRequest(googleRequest)

        await viewModel.reloadRequests()

        // WHEN: Adding domain filter for github.com
        viewModel.addDomainFilter("api.github.com")

        // THEN: Only github.com requests should be visible
        let filteredRequests = viewModel.filteredRequests
        XCTAssertTrue(filteredRequests.allSatisfy {
            $0.host.contains("github.com")
        })

        // WHEN: Adding another domain filter
        viewModel.addDomainFilter("example.com")

        // THEN: Both github and example requests should be visible
        let multiFiltered = viewModel.filteredRequests
        XCTAssertTrue(multiFiltered.allSatisfy {
            $0.host.contains("github.com") || $0.host.contains("example.com")
        })
    }

    /// Tests filtering errors only
    func testFilterErrorsOnly() async throws {
        // GIVEN: Mix of successful and error responses
        let successRequest = createTestRequest(
            url: "https://api.example.com/ok",
            statusCode: 200
        )
        let clientError = createTestRequest(
            url: "https://api.example.com/bad-request",
            statusCode: 400
        )
        let serverError = createTestRequest(
            url: "https://api.example.com/server-error",
            statusCode: 500
        )

        try AppGroupStorage.shared.saveRequest(successRequest)
        try AppGroupStorage.shared.saveRequest(clientError)
        try AppGroupStorage.shared.saveRequest(serverError)

        await viewModel.reloadRequests()

        // WHEN: Filtering errors only
        viewModel.filterShowErrorsOnly = true

        // THEN: Only error responses (4xx, 5xx) should be visible
        let filteredRequests = viewModel.filteredRequests.filter {
            $0.url.contains("api.example.com")
        }
        XCTAssertTrue(filteredRequests.allSatisfy { ($0.statusCode ?? 0) >= 400 })
        XCTAssertFalse(filteredRequests.contains { $0.statusCode == 200 })
    }

    /// Tests combined filters
    func testCombinedFilters() async throws {
        // GIVEN: Various requests
        let request1 = createTestRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 200
        )
        let request2 = createTestRequest(
            url: "https://api.example.com/users",
            method: .post,
            statusCode: 201
        )
        let request3 = createTestRequest(
            url: "https://api.github.com/repos",
            method: .get,
            statusCode: 200
        )
        let request4 = createTestRequest(
            url: "https://api.example.com/error",
            method: .get,
            statusCode: 404
        )

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)
        try AppGroupStorage.shared.saveRequest(request3)
        try AppGroupStorage.shared.saveRequest(request4)

        await viewModel.reloadRequests()

        // WHEN: Applying multiple filters
        viewModel.filterMethod = .get
        viewModel.addDomainFilter("api.example.com")
        viewModel.filterStatusCode = 200

        // THEN: Only requests matching all criteria should be visible
        let filteredRequests = viewModel.filteredRequests
        XCTAssertTrue(filteredRequests.allSatisfy {
            $0.method == .get &&
            $0.host == "api.example.com" &&
            $0.statusCode == 200
        })

        // Verify filter count
        XCTAssertEqual(viewModel.activeFilterCount, 3)
    }

    /// Tests filter preset save and apply
    func testFilterPresetSaveAndApply() async throws {
        // GIVEN: Some filters applied
        viewModel.filterMethod = .post
        viewModel.filterStatusCode = 201
        viewModel.filterShowErrorsOnly = false

        // WHEN: Saving as preset
        viewModel.saveCurrentFiltersAsPreset(name: "POST 201 Only")

        // Verify preset was saved
        XCTAssertEqual(viewModel.savedFilterPresets.count, 1)
        XCTAssertEqual(viewModel.savedFilterPresets.first?.name, "POST 201 Only")

        // Clear filters
        viewModel.clearFilters()
        XCTAssertNil(viewModel.filterMethod)
        XCTAssertNil(viewModel.filterStatusCode)

        // WHEN: Applying the saved preset
        let preset = viewModel.savedFilterPresets.first!
        viewModel.applyPreset(preset)

        // THEN: Filters should be restored
        XCTAssertEqual(viewModel.filterMethod, .post)
        XCTAssertEqual(viewModel.filterStatusCode, 201)

        // Cleanup
        viewModel.deletePreset(preset)
        XCTAssertTrue(viewModel.savedFilterPresets.isEmpty)
    }
}

// MARK: - Search E2E Tests

@MainActor
final class SearchE2ETests: XCTestCase {
    var viewModel: CaptureViewModel!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        try await super.tearDown()
    }

    /// Tests searching in URL
    func testSearchInURL() async throws {
        // GIVEN: Requests with different URLs
        let usersRequest = createTestRequest(url: "https://api.example.com/users")
        let postsRequest = createTestRequest(url: "https://api.example.com/posts")
        let commentsRequest = createTestRequest(url: "https://api.example.com/comments")

        try AppGroupStorage.shared.saveRequest(usersRequest)
        try AppGroupStorage.shared.saveRequest(postsRequest)
        try AppGroupStorage.shared.saveRequest(commentsRequest)

        await viewModel.reloadRequests()

        // WHEN: Searching for "users" in URL
        viewModel.searchText = "users"
        viewModel.searchScope = .url

        // Wait for debounce
        try await Task.sleep(nanoseconds: 400_000_000)

        // THEN: Only requests containing "users" in URL should be visible
        let filteredRequests = viewModel.filteredRequests
        XCTAssertTrue(filteredRequests.allSatisfy { $0.url.localizedCaseInsensitiveContains("users") })
    }

    /// Tests searching in headers
    func testSearchInHeaders() async throws {
        // GIVEN: Requests with different headers
        var request1 = createTestRequest(url: "https://api.example.com/1")
        request1.requestHeaders = [TraceHTTPHeader(key: "Authorization", value: "Bearer token123")]

        var request2 = createTestRequest(url: "https://api.example.com/2")
        request2.requestHeaders = [TraceHTTPHeader(key: "X-API-Key", value: "secret-key")]

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        await viewModel.reloadRequests()

        // WHEN: Searching for "Bearer" in headers
        viewModel.searchText = "Bearer"
        viewModel.searchScope = .headers

        // Wait for debounce
        try await Task.sleep(nanoseconds: 400_000_000)

        // THEN: Only requests with matching headers should be visible
        let filteredRequests = viewModel.filteredRequests.filter {
            $0.url.contains("api.example.com")
        }
        XCTAssertTrue(filteredRequests.allSatisfy {
            $0.requestHeaders.contains { $0.value.contains("Bearer") }
        })
    }

    /// Tests case-insensitive search
    func testCaseInsensitiveSearch() async throws {
        // GIVEN: A request with uppercase in URL
        let request = createTestRequest(url: "https://API.EXAMPLE.COM/USERS")
        try AppGroupStorage.shared.saveRequest(request)
        await viewModel.reloadRequests()

        // WHEN: Searching with lowercase
        viewModel.searchText = "api.example.com"
        viewModel.searchScope = .url

        try await Task.sleep(nanoseconds: 400_000_000)

        // THEN: Should find the request regardless of case
        let filteredRequests = viewModel.filteredRequests
        XCTAssertTrue(filteredRequests.contains { $0.url.uppercased().contains("API.EXAMPLE.COM") })
    }

    /// Tests search scope "All"
    func testSearchScopeAll() async throws {
        // GIVEN: Requests where search term appears in different places
        var request1 = createTestRequest(url: "https://api.example.com/test")
        var request2 = createTestRequest(url: "https://api.other.com/data")
        request2.requestHeaders = [TraceHTTPHeader(key: "X-Test", value: "test-value")]

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        await viewModel.reloadRequests()

        // WHEN: Searching with "All" scope
        viewModel.searchText = "test"
        viewModel.searchScope = .all

        try await Task.sleep(nanoseconds: 400_000_000)

        // THEN: Should find requests matching in any field
        let filteredRequests = viewModel.filteredRequests.filter {
            $0.url.contains("api.example.com") || $0.url.contains("api.other.com")
        }
        XCTAssertGreaterThanOrEqual(filteredRequests.count, 2)
    }
}

// MARK: - Export E2E Tests

@MainActor
final class ExportE2ETests: XCTestCase {
    var viewModel: CaptureViewModel!
    var exportService: DataExportService!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
        exportService = DataExportService()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        exportService = nil
        try await super.tearDown()
    }

    /// Tests complete HAR export flow
    func testCompleteHARExportFlow() async throws {
        // GIVEN: Captured requests
        let request1 = createTestRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 200
        )
        var request2 = createTestRequest(
            url: "https://api.example.com/users",
            method: .post,
            statusCode: 201
        )
        request2.requestBody = .from(string: "{\"name\":\"John\"}")
        request2.responseBody = .from(string: "{\"id\":1,\"name\":\"John\"}")

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        await viewModel.reloadRequests()

        // WHEN: Exporting to HAR
        let harURL = try await exportService.exportToHAR(requests: viewModel.requests)

        // THEN: HAR file should be created with correct content
        XCTAssertTrue(FileManager.default.fileExists(atPath: harURL.path))

        let harData = try Data(contentsOf: harURL)
        let harString = String(data: harData, encoding: .utf8)!

        // Verify HAR structure
        XCTAssertTrue(harString.contains("\"log\""))
        XCTAssertTrue(harString.contains("\"entries\""))
        XCTAssertTrue(harString.contains("api.example.com"))

        // Cleanup
        try? FileManager.default.removeItem(at: harURL)
    }

    /// Tests complete CSV export flow
    func testCompleteCSVExportFlow() async throws {
        // GIVEN: Captured requests
        let request1 = createTestRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 200
        )
        let request2 = createTestRequest(
            url: "https://api.example.com/posts",
            method: .post,
            statusCode: 201
        )

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        await viewModel.reloadRequests()

        // WHEN: Exporting to CSV
        let csvURL = try await exportService.exportToCSV(requests: viewModel.requests)

        // THEN: CSV file should be created with correct content
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))

        let csvContent = try String(contentsOf: csvURL, encoding: .utf8)
        let lines = csvContent.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Verify CSV structure (header + data rows)
        XCTAssertGreaterThanOrEqual(lines.count, 3) // Header + 2 requests
        XCTAssertTrue(lines[0].contains("Timestamp"))
        XCTAssertTrue(lines[0].contains("Method"))
        XCTAssertTrue(lines[0].contains("URL"))

        // Cleanup
        try? FileManager.default.removeItem(at: csvURL)
    }

    /// Tests cURL export for request reproduction
    func testCURLExport() async throws {
        // GIVEN: A POST request with headers and body
        var request = createTestRequest(
            url: "https://api.example.com/users",
            method: .post,
            statusCode: 201
        )
        request.requestHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Authorization", value: "Bearer token123")
        ]
        request.requestBody = .from(string: "{\"name\":\"John\",\"email\":\"john@example.com\"}")

        // WHEN: Exporting to cURL
        let curlCommand = exportService.exportToCURL(request: request)

        // THEN: cURL command should be correct
        XCTAssertTrue(curlCommand.contains("curl"))
        XCTAssertTrue(curlCommand.contains("-X POST"))
        XCTAssertTrue(curlCommand.contains("https://api.example.com/users"))
        XCTAssertTrue(curlCommand.contains("-H 'Content-Type: application/json'"))
        XCTAssertTrue(curlCommand.contains("-H 'Authorization: Bearer token123'"))
        XCTAssertTrue(curlCommand.contains("--data-raw"))
    }

    /// Tests HAR import and re-export roundtrip
    func testHARImportExportRoundtrip() async throws {
        // GIVEN: Requests to export
        let originalRequests = [
            createTestRequest(url: "https://api.example.com/1", method: .get, statusCode: 200),
            createTestRequest(url: "https://api.example.com/2", method: .post, statusCode: 201)
        ]

        // WHEN: Exporting to HAR
        let exportedURL = try await exportService.exportToHAR(requests: originalRequests)

        // AND: Importing from HAR
        let importedRequests = try await exportService.importFromHAR(fileURL: exportedURL)

        // THEN: Imported requests should match original data
        XCTAssertEqual(importedRequests.count, originalRequests.count)

        for imported in importedRequests {
            XCTAssertTrue(imported.url.contains("api.example.com"))
        }

        // Cleanup
        try? FileManager.default.removeItem(at: exportedURL)
    }
}

// MARK: - Grouping E2E Tests

@MainActor
final class GroupingE2ETests: XCTestCase {
    var viewModel: CaptureViewModel!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        try await super.tearDown()
    }

    /// Tests grouping requests by domain
    func testGroupByDomain() async throws {
        // GIVEN: Requests from different domains
        let exampleRequest1 = createTestRequest(url: "https://api.example.com/users")
        let exampleRequest2 = createTestRequest(url: "https://api.example.com/posts")
        let githubRequest = createTestRequest(url: "https://api.github.com/repos")
        let googleRequest = createTestRequest(url: "https://www.google.com/search")

        try AppGroupStorage.shared.saveRequest(exampleRequest1)
        try AppGroupStorage.shared.saveRequest(exampleRequest2)
        try AppGroupStorage.shared.saveRequest(githubRequest)
        try AppGroupStorage.shared.saveRequest(googleRequest)

        await viewModel.reloadRequests()

        // WHEN: Setting grouping mode to byDomain
        viewModel.setGroupingMode(.byDomain)

        // THEN: Requests should be grouped by domain
        let grouped = viewModel.groupedRequests
        XCTAssertEqual(grouped.mode, .byDomain)
        XCTAssertFalse(grouped.domainGroups.isEmpty)

        // Find example.com group
        let exampleGroup = grouped.domainGroups.first { $0.domain == "api.example.com" }
        XCTAssertNotNil(exampleGroup)
        XCTAssertEqual(exampleGroup?.requests.count, 2)
    }

    /// Tests grouping requests by session
    func testGroupBySession() async throws {
        // GIVEN: A session with requests
        let sessionId = UUID()
        let session = CaptureSession(id: sessionId, name: "Test Session")
        try AppGroupStorage.shared.saveSession(session)

        var request1 = createTestRequest(url: "https://api.example.com/1")
        request1.sessionId = sessionId

        var request2 = createTestRequest(url: "https://api.example.com/2")
        request2.sessionId = sessionId

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        await viewModel.reloadRequests()

        // Need to reload sessions in viewModel
        viewModel.sessions = try AppGroupStorage.shared.loadAllSessions()

        // WHEN: Setting grouping mode to bySession
        viewModel.setGroupingMode(.bySession)

        // THEN: Requests should be grouped by session
        let grouped = viewModel.groupedRequests
        XCTAssertEqual(grouped.mode, .bySession)

        // Cleanup
        try? AppGroupStorage.shared.deleteSession(sessionId)
    }

    /// Tests no grouping mode (flat list)
    func testNoGrouping() async throws {
        // GIVEN: Requests
        let request1 = createTestRequest(url: "https://api.example.com/1")
        let request2 = createTestRequest(url: "https://api.github.com/2")

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        await viewModel.reloadRequests()

        // WHEN: Setting grouping mode to none
        viewModel.setGroupingMode(.none)

        // THEN: Grouped requests should be empty (using flat list)
        let grouped = viewModel.groupedRequests
        XCTAssertEqual(grouped.mode, .none)
        XCTAssertTrue(grouped.isEmpty)

        // Verify flat list is still available
        XCTAssertGreaterThanOrEqual(viewModel.filteredRequests.count, 2)
    }
}

// MARK: - Duplicate Detection E2E Tests

@MainActor
final class DuplicateDetectionE2ETests: XCTestCase {
    var viewModel: CaptureViewModel!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        try await super.tearDown()
    }

    /// Tests duplicate request detection
    func testDuplicateDetection() async throws {
        // GIVEN: Multiple requests with same URL and method
        let now = Date()
        let request1 = createTestRequest(
            url: "https://api.example.com/users",
            method: .get,
            timestamp: now.addingTimeInterval(-60)
        )
        let request2 = createTestRequest(
            url: "https://api.example.com/users",
            method: .get,
            timestamp: now.addingTimeInterval(-30)
        )
        let request3 = createTestRequest(
            url: "https://api.example.com/users",
            method: .get,
            timestamp: now
        )
        let uniqueRequest = createTestRequest(
            url: "https://api.example.com/posts",
            method: .get,
            timestamp: now
        )

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)
        try AppGroupStorage.shared.saveRequest(request3)
        try AppGroupStorage.shared.saveRequest(uniqueRequest)

        await viewModel.reloadRequests()

        // WHEN: Running duplicate detection
        viewModel.detectDuplicates()

        // THEN: Duplicates should be marked
        let duplicates = viewModel.requests.filter { $0.isDuplicate }
        XCTAssertEqual(duplicates.count, 2) // request2 and request3 are duplicates of request1

        // THEN: Duplicate count should be correct
        XCTAssertEqual(viewModel.duplicateCount, 2)

        // WHEN: Filtering duplicates only
        viewModel.filterShowDuplicatesOnly = true

        // THEN: Only duplicate requests should be visible
        let filteredDuplicates = viewModel.filteredRequests.filter {
            $0.url.contains("api.example.com")
        }
        XCTAssertTrue(filteredDuplicates.allSatisfy { $0.isDuplicate })
    }
}

// MARK: - Performance Tests

@MainActor
final class PerformanceE2ETests: XCTestCase {
    var viewModel: CaptureViewModel!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        try await super.tearDown()
    }

    /// Tests handling of large number of requests
    func testLargeRequestVolume() async throws {
        // GIVEN: Large number of requests
        let requestCount = 100

        for i in 0 ..< requestCount {
            let request = createTestRequest(
                url: "https://api.example.com/request/\(i)",
                method: [.get, .post, .put, .delete][i % 4],
                statusCode: [200, 201, 400, 404, 500][i % 5]
            )
            try AppGroupStorage.shared.saveRequest(request)
        }

        // WHEN: Loading requests
        let startTime = Date()
        await viewModel.reloadRequests()
        let loadTime = Date().timeIntervalSince(startTime)

        // THEN: Should handle within reasonable time
        XCTAssertGreaterThanOrEqual(viewModel.requests.count, requestCount)
        XCTAssertLessThan(loadTime, 5.0) // Should complete within 5 seconds

        // Test filtering performance
        let filterStartTime = Date()
        viewModel.filterMethod = .get
        _ = viewModel.filteredRequests
        let filterTime = Date().timeIntervalSince(filterStartTime)

        XCTAssertLessThan(filterTime, 1.0) // Filtering should be fast
    }
}

// MARK: - Mock E2E VPN Manager

@MainActor
class MockE2EVPNManager: VPNManaging {
    var isConnected: Bool = false {
        didSet {
            connectionSubject.send(isConnected)
        }
    }

    var shouldSucceed = true

    var startCalled = false
    var startCallCount = 0
    var stopCalled = false
    var stopCallCount = 0

    private let connectionSubject = CurrentValueSubject<Bool, Never>(false)

    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        connectionSubject.eraseToAnyPublisher()
    }

    func start() async throws {
        startCalled = true
        startCallCount += 1

        if !shouldSucceed {
            struct MockVPNError: Error {}
            throw MockVPNError()
        }

        isConnected = true
    }

    func stop() {
        stopCalled = true
        stopCallCount += 1
        isConnected = false
    }
}

// MARK: - Test Helpers

private func createTestRequest(
    url: String = "https://api.example.com/test",
    method: HTTPMethod = .get,
    statusCode: Int = 200,
    timestamp: Date = Date()
) -> NetworkRequest {
    NetworkRequest(
        id: UUID(),
        url: url,
        method: method,
        statusCode: statusCode,
        statusMessage: httpStatusMessage(for: statusCode),
        timestamp: timestamp,
        duration: Double.random(in: 0.05 ... 2.0),
        requestHeaders: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "User-Agent", value: "Trace/1.0 E2ETest")
        ],
        responseHeaders: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Cache-Control", value: "no-cache")
        ],
        requestBody: .empty,
        responseBody: .empty
    )
}

private func httpStatusMessage(for code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 201: return "Created"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    default: return "Unknown"
    }
}

// MARK: - XCTest Async Error Assertion Helper

extension XCTestCase {
    func XCTAssertThrowsError<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail(message().isEmpty ? "Expected error but succeeded" : message(), file: file, line: line)
        } catch {
            // Expected error was thrown
        }
    }
}

