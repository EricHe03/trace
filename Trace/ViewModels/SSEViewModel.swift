//
//  SSEViewModel.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
import os
import SwiftUI
import TraceCore
import TraceNetworking

@MainActor
final class SSEViewModel: ObservableObject {
    private let storage = AppGroupStorage.shared
    private var loadTask: Task<Void, Never>?
    private var storageObserverToken: AppGroupStorageObserverToken?

    @Published var connections: [SSEConnection] = []
    @Published var searchText: String = ""
    @Published var filterStatus: SSEConnectionStatus?

    init() {
        NetworkLog.sse.info("event=sse_viewmodel.init outcome=success")
        scheduleLoad()

        // Observe new SSE connections from Network Extension
        storageObserverToken = storage.observeNewSSE { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleLoad()
            }
        }
    }

    deinit {
        loadTask?.cancel()
        storageObserverToken?.cancel()
        storageObserverToken = nil
    }

    private func scheduleLoad() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadConnections()
        }
    }

    func loadConnections() async {
        NetworkLog.sse.info("event=sse_viewmodel.load_connections outcome=start")
        do {
            var loaded = try storage.loadAllSSEConnections()
            loaded.sort { $0.startTime > $1.startTime }
            connections = loaded
            NetworkLog.sse.info("event=sse_viewmodel.load_connections outcome=success count=\(loaded.count, privacy: .public)")
        } catch {
            NetworkLog.sse.error(
                "event=sse_viewmodel.load_connections outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            connections = []
        }
    }

    var filteredConnections: [SSEConnection] {
        var filtered = connections

        // Apply status filter
        if let status = filterStatus {
            filtered = filtered.filter { $0.status == status }
        }

        // Apply search filter
        if !searchText.isEmpty {
            filtered = filtered.filter { connection in
                connection.url.localizedCaseInsensitiveContains(searchText) ||
                    connection.host.localizedCaseInsensitiveContains(searchText)
            }
        }

        filtered.sort { $0.startTime > $1.startTime }
        return filtered
    }

    func clearConnections() {
        do {
            try storage.clearAllSSEConnections()
            connections = []
        } catch {
            NetworkLog.sse.error(
                "event=sse.clear outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func clearAllConnections() {
        clearConnections()
    }

    func deleteConnection(_ connection: SSEConnection) {
        do {
            try storage.deleteSSEConnection(connection.id)
            connections.removeAll { $0.id == connection.id }
        } catch {
            NetworkLog.sse.error(
                "event=sse.delete outcome=failure connection_id=\(connection.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func clearFilters() {
        filterStatus = nil
    }

    var hasActiveFilters: Bool {
        filterStatus != nil
    }
}
