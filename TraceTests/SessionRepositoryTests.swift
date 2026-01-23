//
//  SessionRepositoryTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

@MainActor
final class SessionRepositoryTests: XCTestCase {
    var sut: SessionRepositoryImpl!
    var mockStorage: MockSessionAppGroupStorage!

    override func setUp() {
        super.setUp()
        mockStorage = MockSessionAppGroupStorage()
        sut = SessionRepositoryImpl(storage: mockStorage)
    }

    override func tearDown() {
        sut = nil
        mockStorage = nil
        super.tearDown()
    }

    // MARK: - Get All Tests

    func testGetAll_LoadsFromStorage() async throws {
        // Given
        let session1 = CaptureSession(name: "Session 1")
        let session2 = CaptureSession(name: "Session 2")
        mockStorage.mockSessions = [session1, session2]

        // When
        let sessions = try await sut.getAll()

        // Then
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(mockStorage.loadSessionsCalled)
    }

    func testGetAll_ReturnsCachedData_WithinValidityWindow() async throws {
        // Given
        let session1 = CaptureSession(name: "Session 1")
        mockStorage.mockSessions = [session1]

        // When - First call
        _ = try await sut.getAll()
        mockStorage.loadSessionsCalled = false

        // When - Second call (within cache window)
        let sessions = try await sut.getAll()

        // Then - Storage not called again
        XCTAssertFalse(mockStorage.loadSessionsCalled)
        XCTAssertEqual(sessions.count, 1)
    }

    func testGetAll_ReloadsFromStorage_AfterCacheExpires() async throws {
        // Given
        let session1 = CaptureSession(name: "Session 1")
        mockStorage.mockSessions = [session1]

        // When - First call
        _ = try await sut.getAll()

        // Wait for cache to expire
        try await Task.sleep(nanoseconds: 6_000_000_000) // 6 seconds

        // Update storage with new data
        let session2 = CaptureSession(name: "Session 2")
        mockStorage.mockSessions = [session1, session2]
        mockStorage.loadSessionsCalled = false

        // When - Second call (after cache expires)
        let sessions = try await sut.getAll()

        // Then - Storage should be called again
        XCTAssertTrue(mockStorage.loadSessionsCalled)
        XCTAssertEqual(sessions.count, 2)
    }

    // MARK: - Get By ID Tests

    func testGetById_WithValidId_ReturnsSession() async throws {
        // Given
        let targetId = UUID()
        let session = CaptureSession(id: targetId, name: "Target Session")
        mockStorage.mockSessions = [
            session,
            CaptureSession(name: "Other Session")
        ]

        // When
        let result = try await sut.getById(targetId)

        // Then
        XCTAssertEqual(result?.id, targetId)
        XCTAssertEqual(result?.name, "Target Session")
    }

    func testGetById_WithInvalidId_ReturnsNil() async throws {
        // Given
        let session = CaptureSession(name: "Session 1")
        mockStorage.mockSessions = [session]
        let invalidId = UUID()

        // When
        let result = try await sut.getById(invalidId)

        // Then
        XCTAssertNil(result)
    }

    // MARK: - Save Tests

    func testSave_WithNewSession_AddsToStorage() async throws {
        // Given
        let newSession = CaptureSession(name: "New Session")
        mockStorage.mockSessions = []

        // When
        try await sut.save(newSession)

        // Then
        XCTAssertTrue(mockStorage.saveSessionsCalled)
        XCTAssertEqual(mockStorage.mockSessions.count, 1)
        XCTAssertEqual(mockStorage.mockSessions.first?.name, "New Session")
    }

    func testSave_WithNewSession_InsertsAtBeginning() async throws {
        // Given
        let existingSession = CaptureSession(name: "Existing Session")
        let newSession = CaptureSession(name: "New Session")
        mockStorage.mockSessions = [existingSession]

        // When
        try await sut.save(newSession)

        // Then
        XCTAssertTrue(mockStorage.saveSessionsCalled)
        XCTAssertEqual(mockStorage.mockSessions.count, 2)
        XCTAssertEqual(mockStorage.mockSessions.first?.name, "New Session")
        XCTAssertEqual(mockStorage.mockSessions.last?.name, "Existing Session")
    }

    func testSave_WithExistingSession_UpdatesInStorage() async throws {
        // Given
        let sessionId = UUID()
        var existingSession = CaptureSession(id: sessionId, name: "Original Name")
        mockStorage.mockSessions = [existingSession]

        var updatedSession = existingSession
        updatedSession.name = "Updated Name"

        // When
        try await sut.save(updatedSession)

        // Then
        XCTAssertTrue(mockStorage.saveSessionsCalled)
        XCTAssertEqual(mockStorage.mockSessions.first?.name, "Updated Name")
        XCTAssertEqual(mockStorage.mockSessions.count, 1)
    }

    // MARK: - Save All Tests

    func testSaveAll_SavesAllSessions() async throws {
        // Given
        let sessions = [
            CaptureSession(name: "Session 1"),
            CaptureSession(name: "Session 2"),
            CaptureSession(name: "Session 3")
        ]

        // When
        try await sut.saveAll(sessions)

        // Then
        XCTAssertTrue(mockStorage.saveSessionsCalled)
        XCTAssertEqual(mockStorage.mockSessions.count, 3)
    }

    func testSaveAll_InvalidatesAndUpdatesCache() async throws {
        // Given
        let session1 = CaptureSession(name: "Session 1")
        mockStorage.mockSessions = [session1]

        // Load to cache
        _ = try await sut.getAll()

        let session2 = CaptureSession(name: "Session 2")
        mockStorage.mockSessions = [session1, session2]

        // When - Save new sessions
        try await sut.saveAll([session1, session2])
        mockStorage.saveSessionsCalled = false

        // When - Get all (should use updated cache)
        let cached = try await sut.getAll()

        // Then - Should not load from storage again
        XCTAssertFalse(mockStorage.saveSessionsCalled)
        XCTAssertEqual(cached.count, 2)
    }

    // MARK: - Delete Tests

    func testDelete_WithValidId_RemovesSession() async throws {
        // Given
        let sessionId = UUID()
        let session1 = CaptureSession(id: sessionId, name: "Session to Delete")
        let session2 = CaptureSession(name: "Remaining Session")
        mockStorage.mockSessions = [session1, session2]

        // When
        try await sut.delete(sessionId)

        // Then
        XCTAssertTrue(mockStorage.saveSessionsCalled)
        XCTAssertEqual(mockStorage.mockSessions.count, 1)
        XCTAssertEqual(mockStorage.mockSessions.first?.id, session2.id)
    }

    func testDelete_WithInvalidId_DoesNothing() async throws {
        // Given
        let session = CaptureSession(name: "Session 1")
        mockStorage.mockSessions = [session]
        let invalidId = UUID()

        // When
        try await sut.delete(invalidId)

        // Then
        XCTAssertTrue(mockStorage.saveSessionsCalled)
        XCTAssertEqual(mockStorage.mockSessions.count, 1)
    }

    // MARK: - Delete All Tests

    func testDeleteAll_ClearsAllSessions() async throws {
        // Given
        mockStorage.mockSessions = [
            CaptureSession(name: "Session 1"),
            CaptureSession(name: "Session 2"),
            CaptureSession(name: "Session 3")
        ]

        // When
        try await sut.deleteAll()

        // Then
        XCTAssertTrue(mockStorage.saveSessionsCalled)
        XCTAssertTrue(mockStorage.mockSessions.isEmpty)
    }

    // MARK: - Cache Invalidation Tests

    func testInvalidateCache_ClearsCache() async throws {
        // Given
        let session = CaptureSession(name: "Session 1")
        mockStorage.mockSessions = [session]

        // Load to cache
        _ = try await sut.getAll()

        // When - Invalidate cache
        sut.invalidateCache()

        // Update storage
        let session2 = CaptureSession(name: "Session 2")
        mockStorage.mockSessions = [session, session2]
        mockStorage.loadSessionsCalled = false

        // When - Get all after invalidation
        let sessions = try await sut.getAll()

        // Then - Should reload from storage
        XCTAssertTrue(mockStorage.loadSessionsCalled)
        XCTAssertEqual(sessions.count, 2)
    }
}

// MARK: - Mock AppGroupStorage for Session Tests

class MockSessionAppGroupStorage: AppGroupStorage {
    override init() {
        super.init()
    }

    var mockSessions: [CaptureSession] = []

    var loadSessionsCalled = false
    var saveSessionsCalled = false

    override func loadSessions() async throws -> [CaptureSession] {
        loadSessionsCalled = true
        return mockSessions
    }

    override func saveSessions(_ sessions: [CaptureSession]) async throws {
        saveSessionsCalled = true
        mockSessions = sessions
    }

    // Stubs for other methods to avoid overriding non-existent methods
}
