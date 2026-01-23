//
//  NetworkRequestServiceTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

@MainActor
final class NetworkRequestServiceTests: XCTestCase {
    var sut: NetworkRequestService!
    var mockRepository: MockNetworkRequestServiceRepository!

    override func setUp() {
        super.setUp()
        mockRepository = MockNetworkRequestServiceRepository()
        sut = NetworkRequestService(repository: mockRepository)
    }

    override func tearDown() {
        sut = nil
        mockRepository = nil
        super.tearDown()
    }

    // MARK: - Fetch Requests Tests

    func testFetchRequests_WithoutSession_FetchesAllRequests() async throws {
        // Given
        let request1 = createMockNetworkRequest()
        let request2 = createMockNetworkRequest()
        mockRepository.mockRequests = [request1, request2]

        // When
        let results = try await sut.fetchRequests()

        // Then
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(mockRepository.getallCalled)
    }

    func testFetchRequests_WithSession_FetchesSessionRequests() async throws {
        // Given
        let session = createMockCaptureSession()
        let request1 = createMockNetworkRequest(sessionId: session.id)
        let request2 = createMockNetworkRequest(sessionId: session.id)
        mockRepository.mockRequests = [request1, request2]

        // When
        let results = try await sut.fetchRequests(for: session)

        // Then
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(mockRepository.getBySessionCalled)
    }

    func testFetchRequests_WithEmptyResults_ReturnsEmptyArray() async throws {
        // Given
        mockRepository.mockRequests = []

        // When
        let results = try await sut.fetchRequests()

        // Then
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Fetch Single Request Tests

    func testFetchRequest_WithValidId_ReturnsRequest() async throws {
        // Given
        let request = createMockNetworkRequest()
        mockRepository.mockSingleRequest = request

        // When
        let result = try await sut.fetchRequest(by: request.id)

        // Then
        XCTAssertEqual(result?.id, request.id)
        XCTAssertTrue(mockRepository.getByIdCalled)
    }

    func testFetchRequest_WithInvalidId_ReturnsNil() async throws {
        // Given
        let invalidId = UUID()
        mockRepository.mockSingleRequest = nil

        // When
        let result = try await sut.fetchRequest(by: invalidId)

        // Then
        XCTAssertNil(result)
    }

    // MARK: - Save Request Tests

    func testSaveRequest_WithValidRequest_SavesRequest() async throws {
        // Given
        let request = createMockNetworkRequest()

        // When
        try await sut.saveRequest(request)

        // Then
        XCTAssertTrue(mockRepository.saveCalled)
    }

    // MARK: - Delete Request Tests

    func testDeleteRequest_WithValidId_DeletesRequest() async throws {
        // Given
        let requestId = UUID()

        // When
        try await sut.deleteRequest(requestId)

        // Then
        XCTAssertTrue(mockRepository.deleteCalled)
    }

    // MARK: - Delete Requests for Session Tests

    func testDeleteRequestsForSession_DeletesAllSessionRequests() async throws {
        // Given
        let session = createMockCaptureSession()

        // When
        try await sut.deleteRequests(for: session)

        // Then
        XCTAssertTrue(mockRepository.deleteBySessionCalled)
    }

    // MARK: - Search Tests

    func testSearchRequests_WithAllScope_SearchesAllFields() async throws {
        // Given
        let query = "example.com"
        let request = createMockNetworkRequest(url: "https://example.com/api")
        mockRepository.mockRequests = [request]

        // When
        let results = try await sut.searchRequests(query: query, scope: .all)

        // Then
        XCTAssertEqual(results.count, 1)
    }

    func testSearchRequests_WithURLScope_SearchesURLOnly() async throws {
        // Given
        let query = "example.com"
        let request1 = createMockNetworkRequest(url: "https://example.com/api")
        let request2 = createMockNetworkRequest(url: "https://other.com/api")
        mockRepository.mockRequests = [request1, request2]

        // When
        let results = try await sut.searchRequests(query: query, scope: .url)

        // Then
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://example.com/api")
    }

    func testSearchRequests_WithHeadersScope_SearchesHeaders() async throws {
        // Given
        let query = "Authorization"
        var request1 = createMockNetworkRequest()
        request1.requestHeaders = [TraceHTTPHeader(key: "Authorization", value: "Bearer token")]

        var request2 = createMockNetworkRequest()
        request2.requestHeaders = [TraceHTTPHeader(key: "Content-Type", value: "application/json")]

        mockRepository.mockRequests = [request1, request2]

        // When
        let results = try await sut.searchRequests(query: query, scope: .headers)

        // Then
        XCTAssertEqual(results.count, 1)
    }

    func testSearchRequests_WithBodyScope_SearchesRequestBody() async throws {
        // Given
        let query = "username"
        let bodyData = "{\"username\":\"john\"}".data(using: .utf8)!
        var request1 = createMockNetworkRequest()
        request1.requestBody = .inline(bodyData)

        var request2 = createMockNetworkRequest()
        request2.requestBody = .inline("{}".data(using: .utf8)!)

        mockRepository.mockRequests = [request1, request2]

        // When
        let results = try await sut.searchRequests(query: query, scope: .body)

        // Then
        XCTAssertEqual(results.count, 1)
    }

    func testSearchRequests_WithEmptyQuery_ReturnsAllRequests() async throws {
        // Given
        let request1 = createMockNetworkRequest()
        let request2 = createMockNetworkRequest()
        mockRepository.mockRequests = [request1, request2]

        // When
        let results = try await sut.searchRequests(query: "", scope: .all)

        // Then
        XCTAssertEqual(results.count, 2)
    }

    func testSearchRequests_CaseInsensitive() async throws {
        // Given
        let query = "EXAMPLE"
        let request = createMockNetworkRequest(url: "https://example.com/api")
        mockRepository.mockRequests = [request]

        // When
        let results = try await sut.searchRequests(query: query, scope: .url)

        // Then
        XCTAssertEqual(results.count, 1)
    }

    func testSearchRequests_WithSession_OnlySearchesSessionRequests() async throws {
        // Given
        let session = createMockCaptureSession()
        let sessionRequest = createMockNetworkRequest(
            url: "https://example.com/api",
            sessionId: session.id
        )
        let otherRequest = createMockNetworkRequest(url: "https://example.com/other")
        mockRepository.mockRequests = [sessionRequest, otherRequest]

        // When
        let results = try await sut.searchRequests(query: "example", scope: .all, in: session)

        // Then
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sessionId, session.id)
    }

    // MARK: - Helper Methods

    private func createMockNetworkRequest(
        url: String = "https://api.example.com/test",
        sessionId: UUID = UUID()
    ) -> NetworkRequest {
        var request = NetworkRequest(
            url: url,
            method: .get,
            timestamp: Date(),
            duration: 0.1
        )
        request.sessionId = sessionId
        return request
    }

    private func createMockCaptureSession() -> CaptureSession {
        CaptureSession(name: "Test Session")
    }
}

// MARK: - Mock Repository

class MockNetworkRequestServiceRepository: NetworkRequestRepository {
    var mockRequests: [NetworkRequest] = []
    var mockSingleRequest: NetworkRequest?

    var getallCalled = false
    var getByIdCalled = false
    var getBySessionCalled = false
    var saveCalled = false
    var saveAllCalled = false
    var deleteCalled = false
    var deleteBySessionCalled = false
    var deleteAllCalled = false

    func getAll() async throws -> [NetworkRequest] {
        getallCalled = true
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
    }

    func saveAll(_ requests: [NetworkRequest]) async throws {
        saveAllCalled = true
    }

    func delete(_ id: UUID) async throws {
        deleteCalled = true
    }

    func deleteBySession(_ sessionId: UUID) async throws {
        deleteBySessionCalled = true
    }

    func deleteAll() async throws {
        deleteAllCalled = true
    }
}
