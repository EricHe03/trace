//
//  SessionRepository.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

/// Protocol defining session data access operations
protocol SessionRepository {
    func getAll() async throws -> [CaptureSession]
    func getById(_ id: UUID) async throws -> CaptureSession?
    func save(_ session: CaptureSession) async throws
    func saveAll(_ sessions: [CaptureSession]) async throws
    func delete(_ id: UUID) async throws
    func deleteAll() async throws
}

/// Implementation of SessionRepository using AppGroupStorage
@MainActor
class SessionRepositoryImpl: SessionRepository {
    // MARK: - Dependencies

    private let storage: AppGroupStorage

    // MARK: - Cache

    private var cachedSessions: [CaptureSession]?
    private var lastCacheTime: Date?
    private let cacheValidityDuration: TimeInterval = 5.0 // 5 seconds

    // MARK: - Initialization

    init(storage: AppGroupStorage = .shared) {
        self.storage = storage
    }

    // MARK: - Public Methods

    func getAll() async throws -> [CaptureSession] {
        // Return cached data if valid
        if let cached = cachedSessions,
           let cacheTime = lastCacheTime,
           Date().timeIntervalSince(cacheTime) < cacheValidityDuration {
            return cached
        }

        // Load from storage
        let sessions = try await storage.loadSessions()
        cachedSessions = sessions
        lastCacheTime = Date()

        return sessions
    }

    func getById(_ id: UUID) async throws -> CaptureSession? {
        let sessions = try await getAll()
        return sessions.first { $0.id == id }
    }

    func save(_ session: CaptureSession) async throws {
        var sessions = try await getAll()

        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0) // Insert at beginning
        }

        try await saveAll(sessions)
    }

    func saveAll(_ sessions: [CaptureSession]) async throws {
        try await storage.saveSessions(sessions)

        // Update cache
        cachedSessions = sessions
        lastCacheTime = Date()
    }

    func delete(_ id: UUID) async throws {
        var sessions = try await getAll()
        sessions.removeAll { $0.id == id }
        try await saveAll(sessions)
    }

    func deleteAll() async throws {
        try await saveAll([])
    }

    // MARK: - Cache Management

    func invalidateCache() {
        cachedSessions = nil
        lastCacheTime = nil
    }
}
