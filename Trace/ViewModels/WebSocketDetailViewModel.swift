//
//  WebSocketDetailViewModel.swift
//  Trace
//
//  Created by Justin on 2026/03/05.
//

import Combine
import Foundation
import os
import TraceCore
import TraceNetworking

@MainActor
final class WebSocketDetailViewModel: ObservableObject {
    private let storage = AppGroupStorage.shared
    private let connectionID: UUID
    private var loadTask: Task<Void, Never>?
    private var storageObserverToken: AppGroupStorageObserverToken?

    @Published private(set) var connection: WebSocketConnection

    init(connection: WebSocketConnection) {
        self.connection = connection
        connectionID = connection.id
        scheduleLoad()

        storageObserverToken = storage.observeNewWebSockets { [weak self] in
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
            await self?.loadConnection()
        }
    }

    func loadConnection() async {
        do {
            let loaded = try storage.loadAllWebSocketConnections()
            if let updated = loaded.first(where: { $0.id == self.connectionID }) {
                connection = updated
            }
        } catch {
            NetworkLog.webSocket.error(
                "event=websocket.detail_load outcome=failure connection_id=\(self.connectionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
