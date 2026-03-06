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
    private let store: CaptureDataStore

    // MARK: - Initialization

    init(storage: AppGroupStorage = .shared) {
        self.store = AppGroupCaptureStore(storage: storage)
    }

    init(store: CaptureDataStore) {
        self.store = store
    }

    // MARK: - Public Methods

    func getAll() async throws -> [CaptureSession] {
        try await store.loadSessions()
    }

    func getById(_ id: UUID) async throws -> CaptureSession? {
        try await store.loadSession(id)
    }

    func save(_ session: CaptureSession) async throws {
        try await store.saveSession(session)
    }

    func saveAll(_ sessions: [CaptureSession]) async throws {
        try await store.saveSessions(sessions)
    }

    func delete(_ id: UUID) async throws {
        try await store.deleteSession(id)
    }

    func deleteAll() async throws {
        try await store.deleteAllSessions()
    }

    // MARK: - Cache Management

    func invalidateCache() {
        store.invalidateSessionCache()
    }
}
