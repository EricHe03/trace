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
class SSEViewModel: ObservableObject {
    private let storage = AppGroupStorage.shared

    @Published var connections: [SSEConnection] = []
    @Published var searchText: String = ""
    @Published var filterStatus: SSEConnectionStatus?

    init() {
        Task {
            await loadConnections()
        }

        // Observe new SSE connections from Network Extension
        storage.observeNewSSE { [weak self] in
            Task { @MainActor in
                await self?.loadConnections()
            }
        }
    }

    func loadConnections() async {
        do {
            connections = try storage.loadAllSSEConnections()
        } catch {
            NetworkLog.sse.error(
                "event=sse.load outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            connections = []
        }
    }

    private func loadConnections() {
        do {
            connections = try storage.loadAllSSEConnections()
        } catch {
            NetworkLog.sse.error(
                "event=sse.load outcome=failure error=\(error.localizedDescription, privacy: .public)"
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

        return filtered.sorted { $0.startTime > $1.startTime }
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
