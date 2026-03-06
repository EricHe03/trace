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
    private let store: CaptureDataStore

    // MARK: - Initialization

    init(storage: AppGroupStorage = .shared) {
        self.store = AppGroupCaptureStore(storage: storage)
    }

    init(store: CaptureDataStore) {
        self.store = store
    }

    // MARK: - Public Methods

    func getAll() async throws -> [NetworkRequest] {
        try await store.loadRequests()
    }

    func getById(_ id: UUID) async throws -> NetworkRequest? {
        try await store.loadRequest(id)
    }

    func getBySession(_ sessionId: UUID) async throws -> [NetworkRequest] {
        try await store.loadRequests(for: sessionId)
    }

    func save(_ request: NetworkRequest) async throws {
        try await store.saveRequest(request)
    }

    func saveAll(_ requests: [NetworkRequest]) async throws {
        try await store.saveRequests(requests)
    }

    func delete(_ id: UUID) async throws {
        try await store.deleteRequest(id)
    }

    func deleteBySession(_ sessionId: UUID) async throws {
        try await store.deleteRequests(for: sessionId)
    }

    func deleteAll() async throws {
        try await store.deleteAllRequests()
    }

    // MARK: - Cache Management

    func invalidateCache() {
        store.invalidateRequestCache()
    }
}
