//
//  SessionManagementServiceTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

@MainActor
final class SessionManagementServiceTests: XCTestCase {
    var sut: SessionManagementService!
    var mockSessionRepository: MockSessionRepository!
    var mockRequestRepository: MockSessionNetworkRequestRepository!

    override func setUp() {
        super.setUp()
        mockSessionRepository = MockSessionRepository()
        mockRequestRepository = MockSessionNetworkRequestRepository()
        sut = SessionManagementService(
            sessionRepository: mockSessionRepository,
            requestRepository: mockRequestRepository
        )
    }

    override func tearDown() {
        sut = nil
        mockSessionRepository = nil
        mockRequestRepository = nil
        super.tearDown()
    }

    // MARK: - Create Session Tests

    func testCreateSession_WithName_CreatesSessionWithGivenName() async throws {
        // Given
        let sessionName = "Test Session"

        // When
        let session = try await sut.createSession(name: sessionName)

        // Then
        XCTAssertEqual(session.name, sessionName)
        XCTAssertTrue(mockSessionRepository.saveCalled)
    }

    func testCreateSession_WithoutName_CreatesSessionWithDefaultName() async throws {
        // When
        let session = try await sut.createSession()

        // Then
        XCTAssertNotNil(session.name)
        XCTAssertTrue(mockSessionRepository.saveCalled)
    }

    func testCreateSession_SetsCorrectTimestamp() async throws {
        // Given
        let beforeCreation = Date()

        // When
        let session = try await sut.createSession(name: "Test")

        // Then
        let afterCreation = Date()
        XCTAssertGreaterThanOrEqual(session.startTime, beforeCreation)
        XCTAssertLessThanOrEqual(session.startTime, afterCreation)
    }

    func testCreateSession_GeneratesUniqueId() async throws {
        // When
        let session1 = try await sut.createSession(name: "Session 1")
        let session2 = try await sut.createSession(name: "Session 2")

        // Then
        XCTAssertNotEqual(session1.id, session2.id)
    }

    // MARK: - Fetch Sessions Tests

    func testFetchSessions_ReturnsAllSessions() async throws {
        // Given
        let session1 = CaptureSession(name: "Session 1")
        let session2 = CaptureSession(name: "Session 2")
        mockSessionRepository.mockSessions = [session1, session2]

        // When
        let sessions = try await sut.fetchSessions()

        // Then
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(mockSessionRepository.getAllCalled)
    }

    func testFetchSessions_UpdatesRequestCounts() async throws {
        // Given
        let session = CaptureSession(name: "Test Session")
        mockSessionRepository.mockSessions = [session]

        let request1 = createMockNetworkRequest(sessionId: session.id)
        let request2 = createMockNetworkRequest(sessionId: session.id)
        mockRequestRepository.mockRequests = [request1, request2]

        // When
        let sessions = try await sut.fetchSessions()

        // Then
        XCTAssertEqual(sessions.first?.requestCount, 2)
    }

    func testFetchSessions_WithNoSessions_ReturnsEmptyArray() async throws {
        // Given
        mockSessionRepository.mockSessions = []

        // When
        let sessions = try await sut.fetchSessions()

        // Then
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Fetch Single Session Tests

    func testFetchSession_WithValidId_ReturnsSession() async throws {
        // Given
        let session = CaptureSession(name: "Test Session")
        mockSessionRepository.mockSingleSession = session

        // When
        let result = try await sut.fetchSession(by: session.id)

        // Then
        XCTAssertEqual(result?.id, session.id)
        XCTAssertTrue(mockSessionRepository.getByIdCalled)
    }

    func testFetchSession_UpdatesRequestCount() async throws {
        // Given
        let session = CaptureSession(name: "Test Session")
        mockSessionRepository.mockSingleSession = session

        let requests = [
            createMockNetworkRequest(sessionId: session.id),
            createMockNetworkRequest(sessionId: session.id),
            createMockNetworkRequest(sessionId: session.id)
        ]
        mockRequestRepository.mockRequests = requests

        // When
        let result = try await sut.fetchSession(by: session.id)

        // Then
        XCTAssertEqual(result?.requestCount, 3)
    }

    func testFetchSession_WithInvalidId_ReturnsNil() async throws {
        // Given
        let invalidId = UUID()
        mockSessionRepository.mockSingleSession = nil

        // When
        let result = try await sut.fetchSession(by: invalidId)

        // Then
        XCTAssertNil(result)
    }

    // MARK: - Update Session Tests

    func testUpdateSession_SavesSessionToRepository() async throws {
        // Given
        var session = CaptureSession(name: "Original Name")
        session.name = "Updated Name"

        // When
        try await sut.updateSession(session)

        // Then
        XCTAssertTrue(mockSessionRepository.saveCalled)
    }

    // MARK: - Delete Session Tests

    func testDeleteSession_DeletesSessionAndRequests() async throws {
        // Given
        let sessionId = UUID()

        // When
        try await sut.deleteSession(sessionId)

        // Then
        XCTAssertTrue(mockRequestRepository.deleteBySessionCalled)
        XCTAssertTrue(mockSessionRepository.deleteCalled)
    }

    func testDeleteSession_DeletesRequestsBeforeSession() async throws {
        // Given
        let sessionId = UUID()
        var callOrder: [String] = []

        mockRequestRepository.onDeleteBySession = {
            callOrder.append("deleteRequests")
        }
        mockSessionRepository.onDelete = {
            callOrder.append("deleteSession")
        }

        // When
        try await sut.deleteSession(sessionId)

        // Then
        XCTAssertEqual(callOrder, ["deleteRequests", "deleteSession"])
    }

    // MARK: - Delete All Sessions Tests

    func testDeleteAllSessions_ClearsAllRequestsAndSessions() async throws {
        // When
        try await sut.deleteAllSessions()

        // Then
        XCTAssertTrue(mockRequestRepository.deleteAllCalled)
        XCTAssertTrue(mockSessionRepository.deleteAllCalled)
    }

    func testDeleteAllSessions_ClearsRequestsBeforeSessions() async throws {
        // Given
        var callOrder: [String] = []

        mockRequestRepository.onDeleteAll = {
            callOrder.append("deleteAllRequests")
        }
        mockSessionRepository.onDeleteAll = {
            callOrder.append("deleteAllSessions")
        }

        // When
        try await sut.deleteAllSessions()

        // Then
        XCTAssertEqual(callOrder, ["deleteAllRequests", "deleteAllSessions"])
    }

    // MARK: - Helper Methods

    private func createMockNetworkRequest(sessionId: UUID) -> NetworkRequest {
        var request = NetworkRequest(
            url: "https://api.example.com/test",
            method: .get,
            timestamp: Date(),
            duration: 0.1
        )
        request.sessionId = sessionId
        return request
    }
}

// MARK: - Mock Session Repository

class MockSessionRepository: SessionRepository {
    var mockSessions: [CaptureSession] = []
    var mockSingleSession: CaptureSession?

    var getAllCalled = false
    var getByIdCalled = false
    var saveCalled = false
    var saveAllCalled = false
    var deleteCalled = false
    var deleteAllCalled = false

    var onDelete: (() -> Void)?
    var onDeleteAll: (() -> Void)?

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
    }

    func saveAll(_ sessions: [CaptureSession]) async throws {
        saveAllCalled = true
    }

    func delete(_ id: UUID) async throws {
        deleteCalled = true
        onDelete?()
    }

    func deleteAll() async throws {
        deleteAllCalled = true
        onDeleteAll?()
    }
}

// MARK: - Mock Network Request Repository (Extended)

class MockSessionNetworkRequestRepository: NetworkRequestRepository {
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

    var onDeleteBySession: (() -> Void)?
    var onDeleteAll: (() -> Void)?

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
        onDeleteBySession?()
    }

    func deleteAll() async throws {
        deleteAllCalled = true
        onDeleteAll?()
    }
}
