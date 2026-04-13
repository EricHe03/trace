//
//  GRPCViewModel.swift
//  Trace
//

import Combine
import Foundation
import SwiftUI
import TraceCore

@MainActor
final class GRPCViewModel: ObservableObject {
    private let storage = AppGroupStorage.shared
    private var loadTask: Task<Void, Never>?
    private var storageObserverToken: AppGroupStorageObserverToken?

    @Published var sessions: [StreamSession] = []
    @Published var searchText: String = ""

    init() {
        scheduleLoad()
        storageObserverToken = storage.observeNewGRPC { [weak self] in
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
            await self?.loadSessions()
        }
    }

    func loadSessions() async {
        do {
            let loaded = try storage.loadStreamSessions(protocolType: .grpc)
            sessions = loaded.sorted { $0.startTime > $1.startTime }
        } catch {
            sessions = []
        }
    }

    var filteredSessions: [StreamSession] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.url.localizedCaseInsensitiveContains(searchText) }
    }

    func clearSessions() {
        do {
            _ = try storage.deleteStreamSessions(olderThan: Date(), protocolType: .grpc)
            sessions = []
        } catch {}
    }
}
