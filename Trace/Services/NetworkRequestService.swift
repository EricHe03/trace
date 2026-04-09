//
//  NetworkRequestService.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import os
import TraceCore

/// Defines network request operations.
protocol NetworkRequestServiceProtocol {
    func fetchRequests(for session: CaptureSession?) async throws -> [NetworkRequest]
    func fetchRequest(by id: UUID) async throws -> NetworkRequest?
    func saveRequest(_ request: NetworkRequest) async throws
    func deleteRequest(_ id: UUID) async throws
    func deleteRequests(for session: CaptureSession) async throws
    func searchRequests(query: String, scope: SearchScope, in session: CaptureSession?) async throws -> [NetworkRequest]
}

/// Handles network request data operations.
@MainActor
class NetworkRequestService: NetworkRequestServiceProtocol {
    // MARK: - Dependencies

    private let repository: NetworkRequestRepository

    // MARK: - Initialization

    init(repository: NetworkRequestRepository) {
        self.repository = repository
    }

    convenience init() {
        self.init(store: AppGroupCaptureStore())
    }

    convenience init(store: CaptureDataStore) {
        self.init(repository: NetworkRequestRepositoryImpl(store: store))
    }

    // MARK: - Public Methods

    func fetchRequests(for session: CaptureSession? = nil) async throws -> [NetworkRequest] {
        if let session {
            try await repository.getBySession(session.id)
        } else {
            try await repository.getAll()
        }
    }

    func fetchRequest(by id: UUID) async throws -> NetworkRequest? {
        try await repository.getById(id)
    }

    func saveRequest(_ request: NetworkRequest) async throws {
        try await repository.save(request)
        CoreLog.storage.info(
            "event=storage.request_save outcome=success request_id=\(request.id.uuidString, privacy: .public) url=\(request.url, privacy: .private(mask: .hash))"
        )
    }

    func deleteRequest(_ id: UUID) async throws {
        try await repository.delete(id)
        CoreLog.storage.info(
            "event=storage.request_delete outcome=success request_id=\(id.uuidString, privacy: .public)"
        )
    }

    func deleteRequests(for session: CaptureSession) async throws {
        try await repository.deleteBySession(session.id)
        CoreLog.storage.info(
            "event=storage.request_delete_bulk outcome=success session_id=\(session.id.uuidString, privacy: .public)"
        )
    }

    func searchRequests(query: String, scope: SearchScope, in session: CaptureSession? = nil) async throws -> [NetworkRequest] {
        let requests = try await fetchRequests(for: session)

        guard !query.isEmpty else {
            return requests
        }

        // Performance: Filter off the MainActor to keep UI responsive.
        return await Task.detached(priority: .userInitiated) {
            requests.filter { request in
                switch scope {
                case .all:
                    Self.matchesInAll(request: request, query: query)
                case .url:
                    request.url.localizedCaseInsensitiveContains(query)
                case .headers:
                    Self.matchesInHeaders(request: request, query: query)
                case .body:
                    Self.matchesInBody(request: request, query: query)
                }
            }
        }.value
    }

    // MARK: - Private Helpers

    private nonisolated static func matchesInAll(request: NetworkRequest, query: String) -> Bool {
        request.url.localizedCaseInsensitiveContains(query) ||
            matchesInHeaders(request: request, query: query) ||
            matchesInBody(request: request, query: query)
    }

    private nonisolated static func matchesInHeaders(request: NetworkRequest, query: String) -> Bool {
        request.requestHeaders.contains { header in
            header.key.localizedCaseInsensitiveContains(query) ||
                header.value.localizedCaseInsensitiveContains(query)
        } ||
            request.responseHeaders.contains { header in
                header.key.localizedCaseInsensitiveContains(query) ||
                    header.value.localizedCaseInsensitiveContains(query)
            }
    }

    private nonisolated static func matchesInBody(request: NetworkRequest, query: String) -> Bool {
        if case .inline = request.requestBody,
           let data = request.requestBody.getData(),
           let bodyString = String(data: data, encoding: .utf8),
           bodyString.localizedCaseInsensitiveContains(query) {
            return true
        }

        if case .inline = request.responseBody,
           let data = request.responseBody.getData(),
           let bodyString = String(data: data, encoding: .utf8),
           bodyString.localizedCaseInsensitiveContains(query) {
            return true
        }

        return false
    }
}
