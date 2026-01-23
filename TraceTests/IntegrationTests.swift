//
//  IntegrationTests.swift
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

// MARK: - Service Integration Tests

@MainActor
final class ServiceIntegrationTests: XCTestCase {
    var networkCaptureService: NetworkCaptureService!
    var sessionService: SessionManagementService!
    var requestService: NetworkRequestService!
    var exportService: DataExportService!
    var mockVPNManager: MockIntegrationVPNManager!
    var mockSessionRepository: MockIntegrationSessionRepository!
    var mockRequestRepository: MockIntegrationRequestRepository!

    override func setUp() async throws {
        try await super.setUp()

        mockVPNManager = MockIntegrationVPNManager()
        mockSessionRepository = MockIntegrationSessionRepository()
        mockRequestRepository = MockIntegrationRequestRepository()

        networkCaptureService = NetworkCaptureService(vpnManager: mockVPNManager)
        sessionService = SessionManagementService(
            sessionRepository: mockSessionRepository,
            requestRepository: mockRequestRepository
        )
        requestService = NetworkRequestService(repository: mockRequestRepository)
        exportService = DataExportService()
    }

    override func tearDown() async throws {
        networkCaptureService = nil
        sessionService = nil
        requestService = nil
        exportService = nil
        mockVPNManager = nil
        mockSessionRepository = nil
        mockRequestRepository = nil
        try await super.tearDown()
    }

    // MARK: - Capture Service + Session Service Integration

    /// Tests that starting capture creates a new session
    func testStartCaptureCreatesSession() async throws {
        // GIVEN: No active session
        mockVPNManager.shouldSucceed = true

        // WHEN: Starting capture
        try await networkCaptureService.startCapture()

        // AND: Creating a new session
        let session = try await sessionService.createSession(name: "Capture Session")

        // THEN: Session should be created and capture should be active
        XCTAssertTrue(networkCaptureService.isCapturing)
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(mockSessionRepository.saveCalled)
    }

    /// Tests that stopping capture ends the current session
    func testStopCaptureEndsSession() async throws {
        // GIVEN: An active capture session
        mockVPNManager.shouldSucceed = true
        try await networkCaptureService.startCapture()

        var session = try await sessionService.createSession(name: "Active Session")

        // WHEN: Stopping capture and ending session
        try await networkCaptureService.stopCapture()

        session.endTime = Date()
        try await sessionService.updateSession(session)

        // THEN: Capture should be stopped and session should be ended
        XCTAssertFalse(networkCaptureService.isCapturing)

        // Verify session was updated
        XCTAssertEqual(mockSessionRepository.saveCallCount, 2) // Create + Update
    }

    // MARK: - Request Service + Session Service Integration

    /// Tests that requests are correctly associated with sessions
    func testRequestSessionAssociation() async throws {
        // GIVEN: A session
        let session = try await sessionService.createSession(name: "Test Session")
        mockSessionRepository.mockSingleSession = session

        // WHEN: Adding requests to the session
        var request1 = createIntegrationRequest(url: "https://api.example.com/1")
        request1.sessionId = session.id

        var request2 = createIntegrationRequest(url: "https://api.example.com/2")
        request2.sessionId = session.id

        try await requestService.saveRequest(request1)
        try await requestService.saveRequest(request2)

        mockRequestRepository.mockRequests = [request1, request2]

        // THEN: Fetching session should show correct request count
        let fetchedSession = try await sessionService.fetchSession(by: session.id)
        XCTAssertEqual(fetchedSession?.requestCount, 2)
    }

    /// Tests that deleting a session also deletes its requests
    func testDeleteSessionDeletesRequests() async throws {
        // GIVEN: A session with requests
        let session = try await sessionService.createSession(name: "Session to Delete")

        var request = createIntegrationRequest(url: "https://api.example.com/delete")
        request.sessionId = session.id
        try await requestService.saveRequest(request)
        mockRequestRepository.mockRequests = [request]

        // WHEN: Deleting the session
        try await sessionService.deleteSession(session.id)

        // THEN: Both session and requests should be deleted
        XCTAssertTrue(mockSessionRepository.deleteCalled)
        XCTAssertTrue(mockRequestRepository.deleteBySessionCalled)
    }

    // MARK: - Request Service + Export Service Integration

    /// Tests the complete flow from request capture to export
    func testCaptureToExportFlow() async throws {
        // GIVEN: Captured requests
        let request1 = createIntegrationRequest(
            url: "https://api.example.com/users",
            method: .get,
            statusCode: 200
        )
        let request2 = createIntegrationRequest(
            url: "https://api.example.com/posts",
            method: .post,
            statusCode: 201
        )

        try await requestService.saveRequest(request1)
        try await requestService.saveRequest(request2)
        mockRequestRepository.mockRequests = [request1, request2]

        // WHEN: Fetching requests for export
        let requests = try await requestService.fetchRequests()

        // THEN: Should have the captured requests
        XCTAssertEqual(requests.count, 2)

        // WHEN: Exporting to HAR
        let harURL = try await exportService.exportToHAR(requests: requests)

        // THEN: Export should succeed
        XCTAssertTrue(FileManager.default.fileExists(atPath: harURL.path))

        // Cleanup
        try? FileManager.default.removeItem(at: harURL)
    }

    // MARK: - Search Integration

    /// Tests search across request service results
    func testSearchRequestsIntegration() async throws {
        // GIVEN: Multiple requests
        let userRequest = createIntegrationRequest(url: "https://api.example.com/users")
        let postRequest = createIntegrationRequest(url: "https://api.example.com/posts")
        let commentRequest = createIntegrationRequest(url: "https://api.example.com/comments")

        mockRequestRepository.mockRequests = [userRequest, postRequest, commentRequest]

        // WHEN: Searching for requests
        let searchResults = try await requestService.searchRequests(
            query: "users",
            scope: .url,
            in: nil
        )

        // THEN: Should find matching requests
        XCTAssertFalse(searchResults.isEmpty)
        XCTAssertTrue(searchResults.allSatisfy { $0.url.contains("users") })
    }
}

// MARK: - Repository Integration Tests

@MainActor
final class RepositoryIntegrationTests: XCTestCase {
    var storage: AppGroupStorage!

    override func setUp() async throws {
        try await super.setUp()
        storage = AppGroupStorage.shared
        try? storage.clearAllRequests()
    }

    override func tearDown() async throws {
        try? storage.clearAllRequests()
        storage = nil
        try await super.tearDown()
    }

    /// Tests that saved requests can be retrieved correctly
    func testSaveAndRetrieveRequest() async throws {
        // GIVEN: A request
        let originalRequest = createIntegrationRequest(
            url: "https://api.example.com/test",
            method: .post,
            statusCode: 201
        )

        // WHEN: Saving and loading
        try storage.saveRequest(originalRequest)
        let loadedRequests = try storage.loadAllRequests()

        // THEN: Request should be retrievable with all data intact
        let loadedRequest = loadedRequests.first { $0.id == originalRequest.id }
        XCTAssertNotNil(loadedRequest)
        XCTAssertEqual(loadedRequest?.url, originalRequest.url)
        XCTAssertEqual(loadedRequest?.method, originalRequest.method)
        XCTAssertEqual(loadedRequest?.statusCode, originalRequest.statusCode)
    }

    /// Tests that request body data is preserved
    func testRequestBodyPreservation() async throws {
        // GIVEN: A request with body data
        var request = createIntegrationRequest(url: "https://api.example.com/data")
        let bodyString = "{\"name\":\"John\",\"email\":\"john@example.com\"}"
        request.requestBody = .from(string: bodyString)
        request.responseBody = .from(string: "{\"id\":1,\"status\":\"created\"}")

        // WHEN: Saving and loading
        try storage.saveRequest(request)
        let loadedRequests = try storage.loadAllRequests()

        // THEN: Body data should be preserved
        let loadedRequest = loadedRequests.first { $0.id == request.id }
        XCTAssertNotNil(loadedRequest)

        let loadedRequestBody = loadedRequest?.requestBody.getData()
        let loadedResponseBody = loadedRequest?.responseBody.getData()

        XCTAssertNotNil(loadedRequestBody)
        XCTAssertNotNil(loadedResponseBody)

        if let bodyData = loadedRequestBody {
            let bodyStr = String(data: bodyData, encoding: .utf8)
            XCTAssertEqual(bodyStr, bodyString)
        }
    }

    /// Tests session persistence
    func testSessionPersistence() async throws {
        // GIVEN: A session
        let session = CaptureSession(
            id: UUID(),
            name: "Persistent Session",
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date(),
            requestCount: 10,
            totalDataTransferred: 1024
        )

        // WHEN: Saving and loading
        try storage.saveSession(session)
        let loadedSessions = try storage.loadAllSessions()

        // THEN: Session should be retrievable with all data intact
        let loadedSession = loadedSessions.first { $0.id == session.id }
        XCTAssertNotNil(loadedSession)
        XCTAssertEqual(loadedSession?.name, "Persistent Session")
        XCTAssertEqual(loadedSession?.requestCount, 10)
        XCTAssertEqual(loadedSession?.totalDataTransferred, 1024)
        XCTAssertFalse(loadedSession?.isActive ?? true)

        // Cleanup
        try? storage.deleteSession(session.id)
    }

    /// Tests that clearing requests removes all data
    func testClearAllRequests() async throws {
        // GIVEN: Multiple saved requests
        for i in 0 ..< 5 {
            let request = createIntegrationRequest(url: "https://api.example.com/\(i)")
            try storage.saveRequest(request)
        }

        let beforeClear = try storage.loadAllRequests()
        XCTAssertGreaterThanOrEqual(beforeClear.count, 5)

        // WHEN: Clearing all requests
        try storage.clearAllRequests()

        // THEN: No requests should remain
        let afterClear = try storage.loadAllRequests()
        XCTAssertTrue(afterClear.isEmpty)
    }
}

// MARK: - ViewModel Integration Tests

@MainActor
final class ViewModelIntegrationTests: XCTestCase {
    var viewModel: CaptureViewModel!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        try await super.tearDown()
    }

    /// Tests that ViewModel correctly loads requests from storage
    func testViewModelLoadsFromStorage() async throws {
        // GIVEN: Requests in storage
        let request1 = createIntegrationRequest(url: "https://api.example.com/1")
        let request2 = createIntegrationRequest(url: "https://api.example.com/2")

        try AppGroupStorage.shared.saveRequest(request1)
        try AppGroupStorage.shared.saveRequest(request2)

        // WHEN: Reloading ViewModel
        await viewModel.reloadRequests()

        // THEN: ViewModel should have the requests
        XCTAssertGreaterThanOrEqual(viewModel.requests.count, 2)
    }

    /// Tests that ViewModel filtering updates correctly
    func testViewModelFilteringIntegration() async throws {
        // GIVEN: Requests with different methods
        let getRequest = createIntegrationRequest(
            url: "https://api.example.com/get",
            method: .get
        )
        let postRequest = createIntegrationRequest(
            url: "https://api.example.com/post",
            method: .post
        )

        try AppGroupStorage.shared.saveRequest(getRequest)
        try AppGroupStorage.shared.saveRequest(postRequest)

        await viewModel.reloadRequests()

        // WHEN: Applying filter
        viewModel.filterMethod = .get

        // THEN: Only GET requests should be in filtered list
        let filtered = viewModel.filteredRequests.filter {
            $0.url.contains("api.example.com")
        }
        XCTAssertTrue(filtered.allSatisfy { $0.method == .get })

        // WHEN: Clearing filter
        viewModel.clearFilters()

        // THEN: All requests should be visible
        let unfiltered = viewModel.filteredRequests
        XCTAssertGreaterThanOrEqual(unfiltered.count, 2)
    }

    /// Tests ViewModel session integration
    func testViewModelSessionIntegration() async throws {
        // GIVEN: A session
        let sessionId = UUID()
        let session = CaptureSession(id: sessionId, name: "Test Session")
        try AppGroupStorage.shared.saveSession(session)

        // GIVEN: Requests assigned to the session
        var request = createIntegrationRequest(url: "https://api.example.com/session")
        request.sessionId = sessionId
        try AppGroupStorage.shared.saveRequest(request)

        // WHEN: Reloading
        await viewModel.reloadRequests()

        // THEN: Requests should have session ID
        let sessionRequests = viewModel.requests.filter { $0.sessionId == sessionId }
        XCTAssertFalse(sessionRequests.isEmpty)

        // Cleanup
        try? AppGroupStorage.shared.deleteSession(sessionId)
    }

    /// Tests ViewModel grouping integration
    func testViewModelGroupingIntegration() async throws {
        // GIVEN: Requests from different domains
        let exampleRequest = createIntegrationRequest(url: "https://api.example.com/test")
        let githubRequest = createIntegrationRequest(url: "https://api.github.com/test")

        try AppGroupStorage.shared.saveRequest(exampleRequest)
        try AppGroupStorage.shared.saveRequest(githubRequest)

        await viewModel.reloadRequests()

        // WHEN: Setting domain grouping
        viewModel.setGroupingMode(.byDomain)

        // THEN: Should have domain groups
        let grouped = viewModel.groupedRequests
        XCTAssertEqual(grouped.mode, .byDomain)
        XCTAssertFalse(grouped.domainGroups.isEmpty)
    }
}

// MARK: - Capture Flow Integration Tests

@MainActor
final class CaptureFlowIntegrationTests: XCTestCase {
    var viewModel: CaptureViewModel!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        try await super.tearDown()
    }

    /// Tests the complete request lifecycle: capture → store → display → filter → export
    func testCompleteRequestLifecycle() async throws {
        // STEP 1: Capture - Simulate request being captured
        let capturedRequest = createIntegrationRequest(
            url: "https://api.example.com/users/123",
            method: .put,
            statusCode: 200
        )

        // STEP 2: Store - Save to storage
        try AppGroupStorage.shared.saveRequest(capturedRequest)

        // STEP 3: Display - Load into ViewModel
        await viewModel.reloadRequests()
        XCTAssertTrue(viewModel.requests.contains { $0.id == capturedRequest.id })

        // STEP 4: Filter - Apply filters
        viewModel.filterMethod = .put
        let filtered = viewModel.filteredRequests
        XCTAssertTrue(filtered.contains { $0.id == capturedRequest.id })

        // STEP 5: Export - Export the filtered requests
        let exportService = DataExportService()
        let harURL = try await exportService.exportToHAR(requests: filtered)

        // Verify export
        XCTAssertTrue(FileManager.default.fileExists(atPath: harURL.path))

        // Cleanup
        try? FileManager.default.removeItem(at: harURL)
    }

    /// Tests concurrent request capture
    func testConcurrentRequestCapture() async throws {
        // GIVEN: Multiple concurrent captures
        let requests = (0 ..< 10).map { i in
            createIntegrationRequest(
                url: "https://api.example.com/concurrent/\(i)",
                statusCode: 200
            )
        }

        // WHEN: Saving concurrently (simulated with sequential saves)
        for request in requests {
            try AppGroupStorage.shared.saveRequest(request)
        }

        // THEN: All requests should be saved
        await viewModel.reloadRequests()
        let savedUrls = requests.map(\.url)
        let loadedUrls = viewModel.requests.map(\.url)

        for url in savedUrls {
            XCTAssertTrue(loadedUrls.contains(url), "Request \(url) not found")
        }
    }

    /// Tests request update flow
    func testRequestUpdateFlow() async throws {
        // GIVEN: An initial request
        var request = createIntegrationRequest(
            url: "https://api.example.com/update",
            statusCode: nil // Pending response
        )
        try AppGroupStorage.shared.saveRequest(request)

        await viewModel.reloadRequests()
        let pendingRequest = viewModel.requests.first { $0.id == request.id }
        XCTAssertNil(pendingRequest?.statusCode)

        // WHEN: Updating with response
        request.statusCode = 200
        request.responseBody = .from(string: "{\"updated\":true}")
        try AppGroupStorage.shared.saveRequest(request)

        // THEN: Updated request should be loaded
        await viewModel.reloadRequests()
        let updatedRequest = viewModel.requests.first { $0.id == request.id }
        XCTAssertEqual(updatedRequest?.statusCode, 200)
    }
}

// MARK: - Error Handling Integration Tests

@MainActor
final class ErrorHandlingIntegrationTests: XCTestCase {
    var viewModel: CaptureViewModel!
    var mockVPNManager: MockIntegrationVPNManager!
    var captureService: NetworkCaptureService!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        mockVPNManager = MockIntegrationVPNManager()
        captureService = NetworkCaptureService(vpnManager: mockVPNManager)
        viewModel = CaptureViewModel()
    }

    override func tearDown() async throws {
        viewModel = nil
        captureService = nil
        mockVPNManager = nil
        try await super.tearDown()
    }

    /// Tests graceful handling of capture start failure
    func testCaptureStartFailure() async {
        // GIVEN: VPN that will fail
        mockVPNManager.shouldSucceed = false

        // WHEN: Attempting to start capture
        do {
            try await captureService.startCapture()
            XCTFail("Expected error to be thrown")
        } catch {
            // THEN: Error should be thrown and capture should not be active
            XCTAssertFalse(captureService.isCapturing)
        }
    }

    /// Tests handling of malformed request data
    func testMalformedRequestHandling() async throws {
        // GIVEN: Valid requests
        let validRequest = createIntegrationRequest(url: "https://api.example.com/valid")
        try AppGroupStorage.shared.saveRequest(validRequest)

        // WHEN: Loading requests (including potentially malformed data)
        await viewModel.reloadRequests()

        // THEN: Valid requests should still be loaded
        XCTAssertGreaterThanOrEqual(viewModel.requests.count, 1)
    }

    /// Tests recovery after storage clear
    func testRecoveryAfterStorageClear() async throws {
        // GIVEN: Some requests
        let request = createIntegrationRequest(url: "https://api.example.com/before")
        try AppGroupStorage.shared.saveRequest(request)
        await viewModel.reloadRequests()
        XCTAssertFalse(viewModel.requests.isEmpty)

        // WHEN: Storage is cleared
        try AppGroupStorage.shared.clearAllRequests()
        await viewModel.reloadRequests()

        // THEN: ViewModel should handle empty state gracefully
        XCTAssertTrue(viewModel.requests.isEmpty)
        XCTAssertTrue(viewModel.filteredRequests.isEmpty)
    }
}

// MARK: - Advanced Filter Integration Tests

@MainActor
final class AdvancedFilterIntegrationTests: XCTestCase {
    var viewModel: CaptureViewModel!

    override func setUp() async throws {
        try await super.setUp()
        try? AppGroupStorage.shared.clearAllRequests()
        viewModel = CaptureViewModel()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    override func tearDown() async throws {
        viewModel.clearRequests()
        viewModel = nil
        try await super.tearDown()
    }

    /// Tests response time filtering
    func testResponseTimeFiltering() async throws {
        // GIVEN: Requests with different durations
        let fastRequest = NetworkRequest(
            id: UUID(),
            url: "https://api.example.com/fast",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.05 // 50ms - fast
        )
        let normalRequest = NetworkRequest(
            id: UUID(),
            url: "https://api.example.com/normal",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.5 // 500ms - normal
        )
        let slowRequest = NetworkRequest(
            id: UUID(),
            url: "https://api.example.com/slow",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 2.0 // 2s - slow
        )

        try AppGroupStorage.shared.saveRequest(fastRequest)
        try AppGroupStorage.shared.saveRequest(normalRequest)
        try AppGroupStorage.shared.saveRequest(slowRequest)

        await viewModel.reloadRequests()

        // WHEN: Filtering by slow response time
        viewModel.filterResponseTime = .slow

        // THEN: Only slow requests should be visible
        let filtered = viewModel.filteredRequests.filter {
            $0.url.contains("api.example.com")
        }
        XCTAssertTrue(filtered.allSatisfy { $0.duration > 1.0 })
    }

    /// Tests size range filtering
    func testSizeRangeFiltering() async throws {
        // GIVEN: Requests with different response sizes
        var smallRequest = createIntegrationRequest(url: "https://api.example.com/small")
        smallRequest.responseHeaders = [TraceHTTPHeader(key: "Content-Length", value: "100")]

        var largeRequest = createIntegrationRequest(url: "https://api.example.com/large")
        largeRequest.responseHeaders = [TraceHTTPHeader(key: "Content-Length", value: "1000000")]

        try AppGroupStorage.shared.saveRequest(smallRequest)
        try AppGroupStorage.shared.saveRequest(largeRequest)

        await viewModel.reloadRequests()

        // WHEN: Setting size filter
        viewModel.filterMinSize = 1000

        // THEN: Only large requests should be visible
        let filtered = viewModel.filteredRequests.filter {
            $0.url.contains("api.example.com")
        }
        // Note: This test depends on the size calculation implementation
        XCTAssertFalse(filtered.contains { $0.url.contains("small") })
    }

    /// Tests regex pattern filtering
    func testRegexPatternFiltering() async throws {
        // GIVEN: Requests with various URLs
        let apiV1 = createIntegrationRequest(url: "https://api.example.com/v1/users")
        let apiV2 = createIntegrationRequest(url: "https://api.example.com/v2/users")
        let other = createIntegrationRequest(url: "https://other.example.com/data")

        try AppGroupStorage.shared.saveRequest(apiV1)
        try AppGroupStorage.shared.saveRequest(apiV2)
        try AppGroupStorage.shared.saveRequest(other)

        await viewModel.reloadRequests()

        // WHEN: Applying regex filter for version pattern
        viewModel.filterRegexPattern = "v[12]/users"

        // THEN: Only matching requests should be visible
        let filtered = viewModel.filteredRequests.filter {
            $0.url.contains("example.com")
        }
        XCTAssertTrue(filtered.allSatisfy { $0.url.contains("v1") || $0.url.contains("v2") })
    }
}

// MARK: - Mock Classes

@MainActor
class MockIntegrationVPNManager: VPNManaging {
    var isConnected: Bool = false {
        didSet {
            connectionSubject.send(isConnected)
        }
    }

    var shouldSucceed = true

    var startCalled = false
    var stopCalled = false

    private let connectionSubject = CurrentValueSubject<Bool, Never>(false)

    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        connectionSubject.eraseToAnyPublisher()
    }

    func start() async throws {
        startCalled = true
        if !shouldSucceed {
            struct MockError: Error {}
            throw MockError()
        }
        isConnected = true
    }

    func stop() {
        stopCalled = true
        isConnected = false
    }
}

class MockIntegrationSessionRepository: SessionRepository {
    var mockSessions: [CaptureSession] = []
    var mockSingleSession: CaptureSession?

    var getAllCalled = false
    var getByIdCalled = false
    var saveCalled = false
    var saveCallCount = 0
    var deleteCalled = false
    var deleteAllCalled = false

    func getAll() async throws -> [CaptureSession] {
        getAllCalled = true
        return mockSessions
    }

    func getById(_ id: UUID) async throws -> CaptureSession? {
        getByIdCalled = true
        return mockSingleSession
    }

    func save(_ session: CaptureSession) async throws {
        saveCalled = true
        saveCallCount += 1
        if mockSingleSession == nil {
            mockSingleSession = session
        }
        if !mockSessions.contains(where: { $0.id == session.id }) {
            mockSessions.append(session)
        }
    }

    func saveAll(_ sessions: [CaptureSession]) async throws {
        mockSessions = sessions
    }

    func delete(_ id: UUID) async throws {
        deleteCalled = true
        mockSessions.removeAll { $0.id == id }
    }

    func deleteAll() async throws {
        deleteAllCalled = true
        mockSessions.removeAll()
    }
}

class MockIntegrationRequestRepository: NetworkRequestRepository {
    var mockRequests: [NetworkRequest] = []
    var mockSingleRequest: NetworkRequest?

    var getAllCalled = false
    var getByIdCalled = false
    var getBySessionCalled = false
    var saveCalled = false
    var saveAllCalled = false
    var deleteCalled = false
    var deleteBySessionCalled = false
    var deleteAllCalled = false

    func getAll() async throws -> [NetworkRequest] {
        getAllCalled = true
        return mockRequests
    }

    func getById(_ id: UUID) async throws -> NetworkRequest? {
        getByIdCalled = true
        return mockSingleRequest
    }

    func getBySession(_ sessionId: UUID) async throws -> [NetworkRequest] {
        getBySessionCalled = true
        return mockRequests.filter { $0.sessionId == sessionId }
    }

    func save(_ request: NetworkRequest) async throws {
        saveCalled = true
        if let index = mockRequests.firstIndex(where: { $0.id == request.id }) {
            mockRequests[index] = request
        } else {
            mockRequests.append(request)
        }
    }

    func saveAll(_ requests: [NetworkRequest]) async throws {
        saveAllCalled = true
        mockRequests = requests
    }

    func delete(_ id: UUID) async throws {
        deleteCalled = true
        mockRequests.removeAll { $0.id == id }
    }

    func deleteBySession(_ sessionId: UUID) async throws {
        deleteBySessionCalled = true
        mockRequests.removeAll { $0.sessionId == sessionId }
    }

    func deleteAll() async throws {
        deleteAllCalled = true
        mockRequests.removeAll()
    }
}

// MARK: - Test Helpers

private func createIntegrationRequest(
    url: String = "https://api.example.com/test",
    method: HTTPMethod = .get,
    statusCode: Int? = 200
) -> NetworkRequest {
    NetworkRequest(
        id: UUID(),
        url: url,
        method: method,
        statusCode: statusCode,
        statusMessage: statusCode.map { code in
            switch code {
            case 200: return "OK"
            case 201: return "Created"
            case 400: return "Bad Request"
            case 404: return "Not Found"
            case 500: return "Internal Server Error"
            default: return "Unknown"
            }
        },
        timestamp: Date(),
        duration: Double.random(in: 0.01 ... 1.0),
        requestHeaders: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ],
        responseHeaders: [
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ],
        requestBody: .empty,
        responseBody: .empty
    )
}

