//
//  NetworkRequestRepositoryTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

@MainActor
final class NetworkRequestRepositoryTests: XCTestCase {
    var sut: NetworkRequestRepositoryImpl!
    var mockStorage: MockRepositoryAppGroupStorage!

    override func setUp() {
        super.setUp()
        mockStorage = MockRepositoryAppGroupStorage()
        sut = NetworkRequestRepositoryImpl(storage: mockStorage)
    }

    override func tearDown() {
        sut = nil
        mockStorage = nil
        super.tearDown()
    }

    // MARK: - Get All Tests

    func testGetAll_LoadsFromStorage() async throws {
        // Given
        let request1 = createMockNetworkRequest()
        let request2 = createMockNetworkRequest()
        mockStorage.mockRequests = [request1, request2]

        // When
        let requests = try await sut.getAll()

        // Then
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(mockStorage.loadRequestsCalled)
    }

    func testGetAll_ReturnsCachedData_WithinValidityWindow() async throws {
        // Given
        let request1 = createMockNetworkRequest()
        mockStorage.mockRequests = [request1]

        // When - First call
        _ = try await sut.getAll()
        mockStorage.loadRequestsCalled = false

        // When - Second call (within cache window)
        let requests = try await sut.getAll()

        // Then - Storage not called again
        XCTAssertFalse(mockStorage.loadRequestsCalled)
        XCTAssertEqual(requests.count, 1)
    }

    func testGetAll_ReloadsFromStorage_AfterCacheExpires() async throws {
        // Given
        let request1 = createMockNetworkRequest()
        mockStorage.mockRequests = [request1]

        // When - First call
        _ = try await sut.getAll()

        // Wait for cache to expire
        try await Task.sleep(nanoseconds: 6_000_000_000) // 6 seconds

        // Update storage with new data
        let request2 = createMockNetworkRequest()
        mockStorage.mockRequests = [request1, request2]
        mockStorage.loadRequestsCalled = false

        // When - Second call (after cache expires)
        let requests = try await sut.getAll()

        // Then - Storage should be called again
        XCTAssertTrue(mockStorage.loadRequestsCalled)
        XCTAssertEqual(requests.count, 2)
    }

    // MARK: - Get By ID Tests

    func testGetById_WithValidId_ReturnsRequest() async throws {
        // Given
        let targetId = UUID()
        let request = createMockNetworkRequest(id: targetId)
        mockStorage.mockRequests = [
            request,
            createMockNetworkRequest()
        ]

        // When
        let result = try await sut.getById(targetId)

        // Then
        XCTAssertEqual(result?.id, targetId)
    }

    func testGetById_WithInvalidId_ReturnsNil() async throws {
        // Given
        let request = createMockNetworkRequest()
        mockStorage.mockRequests = [request]
        let invalidId = UUID()

        // When
        let result = try await sut.getById(invalidId)

        // Then
        XCTAssertNil(result)
    }

    // MARK: - Get By Session Tests

    func testGetBySession_FiltersRequestsBySessionId() async throws {
        // Given
        let sessionId = UUID()
        let request1 = createMockNetworkRequest(sessionId: sessionId)
        let request2 = createMockNetworkRequest(sessionId: sessionId)
        let request3 = createMockNetworkRequest(sessionId: UUID())

        mockStorage.mockRequests = [request1, request2, request3]

        // When
        let results = try await sut.getBySession(sessionId)

        // Then
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.sessionId == sessionId })
    }

    // MARK: - Save Tests

    func testSave_WithNewRequest_AddsToStorage() async throws {
        // Given
        let newRequest = createMockNetworkRequest()
        mockStorage.mockRequests = []

        // When
        try await sut.save(newRequest)

        // Then
        XCTAssertTrue(mockStorage.saveRequestsCalled)
        XCTAssertEqual(mockStorage.mockRequests.count, 1)
    }

    func testSave_WithExistingRequest_UpdatesInStorage() async throws {
        // Given
        let requestId = UUID()
        var existingRequest = createMockNetworkRequest(id: requestId)
        existingRequest.statusCode = 200

        mockStorage.mockRequests = [existingRequest]

        var updatedRequest = existingRequest
        updatedRequest.statusCode = 404

        // When
        try await sut.save(updatedRequest)

        // Then
        XCTAssertTrue(mockStorage.saveRequestsCalled)
        XCTAssertEqual(mockStorage.mockRequests.first?.statusCode, 404)
    }

    // MARK: - Save All Tests

    func testSaveAll_SavesAllRequests() async throws {
        // Given
        let requests = [
            createMockNetworkRequest(),
            createMockNetworkRequest(),
            createMockNetworkRequest()
        ]

        // When
        try await sut.saveAll(requests)

        // Then
        XCTAssertTrue(mockStorage.saveRequestsCalled)
        XCTAssertEqual(mockStorage.mockRequests.count, 3)
    }

    func testSaveAll_InvalidatesAndUpdatesCache() async throws {
        // Given
        let request1 = createMockNetworkRequest()
        mockStorage.mockRequests = [request1]

        // Load to cache
        _ = try await sut.getAll()

        let request2 = createMockNetworkRequest()
        mockStorage.mockRequests = [request1, request2]

        // When - Save new requests
        try await sut.saveAll([request1, request2])
        mockStorage.saveRequestsCalled = false

        // When - Get all (should use updated cache)
        let cached = try await sut.getAll()

        // Then - Should not load from storage again
        XCTAssertFalse(mockStorage.saveRequestsCalled)
        XCTAssertEqual(cached.count, 2)
    }

    // MARK: - Delete Tests

    func testDelete_WithValidId_RemovesRequest() async throws {
        // Given
        let requestId = UUID()
        let request1 = createMockNetworkRequest(id: requestId)
        let request2 = createMockNetworkRequest()
        mockStorage.mockRequests = [request1, request2]

        // When
        try await sut.delete(requestId)

        // Then
        XCTAssertTrue(mockStorage.saveRequestsCalled)
        XCTAssertEqual(mockStorage.mockRequests.count, 1)
        XCTAssertEqual(mockStorage.mockRequests.first?.id, request2.id)
    }

    // MARK: - Delete By Session Tests

    func testDeleteBySession_RemovesAllSessionRequests() async throws {
        // Given
        let sessionId = UUID()
        let request1 = createMockNetworkRequest(sessionId: sessionId)
        let request2 = createMockNetworkRequest(sessionId: sessionId)
        let request3 = createMockNetworkRequest(sessionId: UUID())

        mockStorage.mockRequests = [request1, request2, request3]

        // When
        try await sut.deleteBySession(sessionId)

        // Then
        XCTAssertTrue(mockStorage.saveRequestsCalled)
        XCTAssertEqual(mockStorage.mockRequests.count, 1)
        XCTAssertEqual(mockStorage.mockRequests.first?.id, request3.id)
    }

    // MARK: - Delete All Tests

    func testDeleteAll_ClearsAllRequests() async throws {
        // Given
        mockStorage.mockRequests = [
            createMockNetworkRequest(),
            createMockNetworkRequest(),
            createMockNetworkRequest()
        ]

        // When
        try await sut.deleteAll()

        // Then
        XCTAssertTrue(mockStorage.saveRequestsCalled)
        XCTAssertTrue(mockStorage.mockRequests.isEmpty)
    }

    // MARK: - Helper Methods

    private func createMockNetworkRequest(
        id: UUID = UUID(),
        sessionId: UUID = UUID()
    ) -> NetworkRequest {
        var request = NetworkRequest(
            id: id,
            url: "https://api.example.com/test",
            method: .get,
            timestamp: Date(),
            duration: 0.1
        )
        request.sessionId = sessionId
        return request
    }
}

// MARK: - Mock AppGroupStorage for Repository Tests

class MockRepositoryAppGroupStorage: AppGroupStorage {
    override init() {
        super.init()
    }

    var mockRequests: [NetworkRequest] = []

    var loadRequestsCalled = false
    var saveRequestsCalled = false

    override func loadRequests() async throws -> [NetworkRequest] {
        loadRequestsCalled = true
        return mockRequests
    }

    override func saveRequests(_ requests: [NetworkRequest]) async throws {
        saveRequestsCalled = true
        mockRequests = requests
    }

    // Stubs for other methods to avoid overriding non-existent methods
}
