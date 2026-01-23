//
//  SessionManagementService.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import os
import TraceCore

/// Defines session management operations.
protocol SessionManagementServiceProtocol {
    func createSession(name: String?) async throws -> CaptureSession
    func fetchSessions() async throws -> [CaptureSession]
    func fetchSession(by id: UUID) async throws -> CaptureSession?
    func updateSession(_ session: CaptureSession) async throws
    func deleteSession(_ id: UUID) async throws
    func deleteAllSessions() async throws
}

/// Handles capture session lifecycle and persistence.
@MainActor
class SessionManagementService: SessionManagementServiceProtocol {
    // MARK: - Dependencies

    private let sessionRepository: SessionRepository
    private let requestRepository: NetworkRequestRepository

    // MARK: - Initialization

    nonisolated init(
        sessionRepository: SessionRepository,
        requestRepository: NetworkRequestRepository
    ) {
        self.sessionRepository = sessionRepository
        self.requestRepository = requestRepository
    }

    convenience init() {
        self.init(
            sessionRepository: SessionRepositoryImpl(),
            requestRepository: NetworkRequestRepositoryImpl()
        )
    }

    // MARK: - Public Methods

    func createSession(name: String? = nil) async throws -> CaptureSession {
        let session = CaptureSession(name: name ?? "")
        try await sessionRepository.save(session)

        CoreLog.storage.info(
            "event=storage.session_create outcome=success session_id=\(session.id.uuidString, privacy: .public) name=\(session.displayName, privacy: .private(mask: .hash))"
        )
        return session
    }

    func fetchSessions() async throws -> [CaptureSession] {
        (requestRepository as? NetworkRequestRepositoryImpl)?.invalidateCache()
        let sessions = try await sessionRepository.getAll()

        // Rule: Derive counts from stored requests to avoid stale session totals.
        let allRequests = try await requestRepository.getAll()
        var requestCounts: [UUID: Int] = [:]
        requestCounts.reserveCapacity(sessions.count)
        for request in allRequests {
            guard let sessionId = request.sessionId else { continue }
            requestCounts[sessionId, default: 0] += 1
        }

        return sessions.map { session in
            var updatedSession = session
            updatedSession.requestCount = requestCounts[session.id] ?? 0
            return updatedSession
        }
    }

    func fetchSession(by id: UUID) async throws -> CaptureSession? {
        (requestRepository as? NetworkRequestRepositoryImpl)?.invalidateCache()
        let session = try await sessionRepository.getById(id)

        guard var session else {
            return nil
        }

        // Rule: Derive the count from stored requests for consistency.
        let requests = try await requestRepository.getBySession(id)
        session.requestCount = requests.count

        return session
    }

    func updateSession(_ session: CaptureSession) async throws {
        try await sessionRepository.save(session)
        CoreLog.storage.info(
            "event=storage.session_update outcome=success session_id=\(session.id.uuidString, privacy: .public) name=\(session.displayName, privacy: .private(mask: .hash))"
        )
    }

    func deleteSession(_ id: UUID) async throws {
        // Rule: Delete associated requests before removing the session record.
        try await requestRepository.deleteBySession(id)

        try await sessionRepository.delete(id)

        CoreLog.storage.info(
            "event=storage.session_delete outcome=success session_id=\(id.uuidString, privacy: .public)"
        )
    }

    func deleteAllSessions() async throws {
        // Rule: Delete requests before deleting session records.
        try await requestRepository.deleteAll()

        try await sessionRepository.deleteAll()

        CoreLog.storage.info("event=storage.session_delete_all outcome=success")
    }
}
