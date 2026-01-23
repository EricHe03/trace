//
//  NetworkRequestRepository.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

/// Protocol defining network request data access operations
protocol NetworkRequestRepository {
    func getAll() async throws -> [NetworkRequest]
    func getById(_ id: UUID) async throws -> NetworkRequest?
    func getBySession(_ sessionId: UUID) async throws -> [NetworkRequest]
    func save(_ request: NetworkRequest) async throws
    func saveAll(_ requests: [NetworkRequest]) async throws
    func delete(_ id: UUID) async throws
    func deleteBySession(_ sessionId: UUID) async throws
    func deleteAll() async throws
}

/// Implementation of NetworkRequestRepository using AppGroupStorage
@MainActor
class NetworkRequestRepositoryImpl: NetworkRequestRepository {
    // MARK: - Dependencies

    private let storage: AppGroupStorage

    // MARK: - Cache

    private var cachedRequests: [NetworkRequest]?
    private var lastCacheTime: Date?
    private let cacheValidityDuration: TimeInterval = 5.0 // 5 seconds

    // MARK: - Initialization

    init(storage: AppGroupStorage = .shared) {
        self.storage = storage
    }

    // MARK: - Public Methods

    func getAll() async throws -> [NetworkRequest] {
        // Return cached data if valid
        if let cached = cachedRequests,
           let cacheTime = lastCacheTime,
           Date().timeIntervalSince(cacheTime) < cacheValidityDuration {
            return cached
        }

        // Load from storage
        let requests = try await storage.loadRequests()
        cachedRequests = requests
        lastCacheTime = Date()

        return requests
    }

    func getById(_ id: UUID) async throws -> NetworkRequest? {
        let requests = try await getAll()
        return requests.first { $0.id == id }
    }

    func getBySession(_ sessionId: UUID) async throws -> [NetworkRequest] {
        let requests = try await getAll()
        return requests.filter { $0.sessionId == sessionId }
    }

    func save(_ request: NetworkRequest) async throws {
        var requests = try await getAll()

        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
        } else {
            requests.append(request)
        }

        try await saveAll(requests)
    }

    func saveAll(_ requests: [NetworkRequest]) async throws {
        try await storage.saveRequests(requests)

        // Invalidate cache
        cachedRequests = requests
        lastCacheTime = Date()
    }

    func delete(_ id: UUID) async throws {
        var requests = try await getAll()
        requests.removeAll { $0.id == id }
        try await saveAll(requests)
    }

    func deleteBySession(_ sessionId: UUID) async throws {
        var requests = try await getAll()
        requests.removeAll { $0.sessionId == sessionId }
        try await saveAll(requests)
    }

    func deleteAll() async throws {
        try await saveAll([])
    }

    // MARK: - Cache Management

    func invalidateCache() {
        cachedRequests = nil
        lastCacheTime = nil
    }
}
