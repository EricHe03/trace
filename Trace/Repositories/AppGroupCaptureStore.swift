//
//  AppGroupCaptureStore.swift
//  Trace
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import TraceCore

@MainActor
protocol CaptureDataStore: AnyObject {
    func loadRequests() async throws -> [NetworkRequest]
    func loadRequest(_ id: UUID) async throws -> NetworkRequest?
    func loadRequests(for sessionId: UUID) async throws -> [NetworkRequest]
    func saveRequest(_ request: NetworkRequest) async throws
    func saveRequests(_ requests: [NetworkRequest]) async throws
    func deleteRequest(_ id: UUID) async throws
    func deleteRequests(for sessionId: UUID) async throws
    func deleteAllRequests() async throws
    func invalidateRequestCache()

    func loadSessions() async throws -> [CaptureSession]
    func loadSession(_ id: UUID) async throws -> CaptureSession?
    func saveSession(_ session: CaptureSession) async throws
    func saveSessions(_ sessions: [CaptureSession]) async throws
    func deleteSession(_ id: UUID) async throws
    func deleteAllSessions() async throws
    func invalidateSessionCache()
}

@MainActor
final class AppGroupCaptureStore: CaptureDataStore {
    private let storage: AppGroupStorage

    private var cachedRequests: [NetworkRequest]?
    private var lastRequestCacheTime: Date?
    private var cachedSessions: [CaptureSession]?
    private var lastSessionCacheTime: Date?

    private let cacheValidityDuration: TimeInterval = 5.0

    init(storage: AppGroupStorage = .shared) {
        self.storage = storage
    }

    func loadRequests() async throws -> [NetworkRequest] {
        if let cachedRequests,
           let lastRequestCacheTime,
           Date().timeIntervalSince(lastRequestCacheTime) < cacheValidityDuration {
            return cachedRequests
        }

        let requests = try await storage.loadRequests()
        cachedRequests = requests
        lastRequestCacheTime = Date()
        return requests
    }

    func loadRequest(_ id: UUID) async throws -> NetworkRequest? {
        let requests = try await loadRequests()
        return requests.first { $0.id == id }
    }

    func loadRequests(for sessionId: UUID) async throws -> [NetworkRequest] {
        let requests = try await loadRequests()
        return requests.filter { $0.sessionId == sessionId }
    }

    func saveRequest(_ request: NetworkRequest) async throws {
        var requests = try await loadRequests()

        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
        } else {
            requests.append(request)
        }

        try await saveRequests(requests)
    }

    func saveRequests(_ requests: [NetworkRequest]) async throws {
        try await storage.saveRequests(requests)
        cachedRequests = requests
        lastRequestCacheTime = Date()
    }

    func deleteRequest(_ id: UUID) async throws {
        var requests = try await loadRequests()
        requests.removeAll { $0.id == id }
        try await saveRequests(requests)
    }

    func deleteRequests(for sessionId: UUID) async throws {
        var requests = try await loadRequests()
        requests.removeAll { $0.sessionId == sessionId }
        try await saveRequests(requests)
    }

    func deleteAllRequests() async throws {
        try await saveRequests([])
    }

    func invalidateRequestCache() {
        cachedRequests = nil
        lastRequestCacheTime = nil
    }

    func loadSessions() async throws -> [CaptureSession] {
        if let cachedSessions,
           let lastSessionCacheTime,
           Date().timeIntervalSince(lastSessionCacheTime) < cacheValidityDuration {
            return cachedSessions
        }

        let sessions = try await storage.loadSessions()
        cachedSessions = sessions
        lastSessionCacheTime = Date()
        return sessions
    }

    func loadSession(_ id: UUID) async throws -> CaptureSession? {
        let sessions = try await loadSessions()
        return sessions.first { $0.id == id }
    }

    func saveSession(_ session: CaptureSession) async throws {
        var sessions = try await loadSessions()

        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }

        try await saveSessions(sessions)
    }

    func saveSessions(_ sessions: [CaptureSession]) async throws {
        try await storage.saveSessions(sessions)
        cachedSessions = sessions
        lastSessionCacheTime = Date()
    }

    func deleteSession(_ id: UUID) async throws {
        var sessions = try await loadSessions()
        sessions.removeAll { $0.id == id }
        try await saveSessions(sessions)
    }

    func deleteAllSessions() async throws {
        try await saveSessions([])
    }

    func invalidateSessionCache() {
        cachedSessions = nil
        lastSessionCacheTime = nil
    }
}
