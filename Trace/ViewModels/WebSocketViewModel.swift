//
//  WebSocketViewModel.swift
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
class WebSocketViewModel: ObservableObject {
    private let storage = AppGroupStorage.shared

    @Published var connections: [WebSocketConnection] = []
    @Published var searchText: String = ""
    @Published var filterStatus: WebSocketConnectionStatus?

    init() {
        Task {
            await loadConnections()
        }

        // Observe new WebSocket connections from Network Extension
        storage.observeNewWebSockets { [weak self] in
            Task { @MainActor in
                await self?.loadConnections()
            }
        }
    }

    func loadConnections() async {
        do {
            connections = try storage.loadAllWebSocketConnections()
        } catch {
            NetworkLog.webSocket.error(
                "event=websocket.load outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            connections = []
        }
    }

    private func loadConnections() {
        do {
            connections = try storage.loadAllWebSocketConnections()
        } catch {
            NetworkLog.webSocket.error(
                "event=websocket.load outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            connections = []
        }
    }

    var filteredConnections: [WebSocketConnection] {
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
            try storage.clearAllWebSocketConnections()
            connections = []
        } catch {
            NetworkLog.webSocket.error(
                "event=websocket.clear outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func clearAllConnections() {
        clearConnections()
    }

    func deleteConnection(_ connection: WebSocketConnection) {
        do {
            try storage.deleteWebSocketConnection(connection.id)
            connections.removeAll { $0.id == connection.id }
        } catch {
            NetworkLog.webSocket.error(
                "event=websocket.delete outcome=failure connection_id=\(connection.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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
