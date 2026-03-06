//
//  ConfigurationRepository.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

/// Protocol defining configuration data access operations
protocol ConfigurationRepository {
    // Rewrite Rules
    func getRewriteRules() async throws -> [RewriteRule]
    func saveRewriteRules(_ rules: [RewriteRule]) async throws

    // Request Maps
    func getRequestMaps() async throws -> [RequestMap]
    func saveRequestMaps(_ maps: [RequestMap]) async throws

    // Host Entries
    func getHostEntries() async throws -> [HostEntry]
    func saveHostEntries(_ entries: [HostEntry]) async throws

    // Scripts
    func getScripts() async throws -> [Script]
    func saveScripts(_ scripts: [Script]) async throws

    // Breakpoints
    func getBreakpoints() async throws -> [Breakpoint]
    func saveBreakpoints(_ breakpoints: [Breakpoint]) async throws

    // Favorites
    func getFavorites() async throws -> [Favorite]
    func saveFavorites(_ favorites: [Favorite]) async throws
}

/// Implementation of ConfigurationRepository using AppGroupStorage
@MainActor
class ConfigurationRepositoryImpl: ConfigurationRepository {
    private let store: ConfigurationDataStore

    // MARK: - Initialization

    init(storage: AppGroupStorage = .shared) {
        self.store = AppGroupConfigurationStore(storage: storage)
    }

    init(store: ConfigurationDataStore) {
        self.store = store
    }

    // MARK: - Rewrite Rules

    func getRewriteRules() async throws -> [RewriteRule] {
        try await store.loadRewriteRules()
    }

    func saveRewriteRules(_ rules: [RewriteRule]) async throws {
        try await store.saveRewriteRules(rules)
    }

    // MARK: - Request Maps

    func getRequestMaps() async throws -> [RequestMap] {
        try await store.loadRequestMaps()
    }

    func saveRequestMaps(_ maps: [RequestMap]) async throws {
        try await store.saveRequestMaps(maps)
    }

    // MARK: - Host Entries

    func getHostEntries() async throws -> [HostEntry] {
        try await store.loadHostEntries()
    }

    func saveHostEntries(_ entries: [HostEntry]) async throws {
        try await store.saveHostEntries(entries)
    }

    // MARK: - Scripts

    func getScripts() async throws -> [Script] {
        try await store.loadScripts()
    }

    func saveScripts(_ scripts: [Script]) async throws {
        try await store.saveScripts(scripts)
    }

    // MARK: - Breakpoints

    func getBreakpoints() async throws -> [Breakpoint] {
        try await store.loadBreakpoints()
    }

    func saveBreakpoints(_ breakpoints: [Breakpoint]) async throws {
        try await store.saveBreakpoints(breakpoints)
    }

    // MARK: - Favorites

    func getFavorites() async throws -> [Favorite] {
        try await store.loadFavorites()
    }

    func saveFavorites(_ favorites: [Favorite]) async throws {
        try await store.saveFavorites(favorites)
    }
}
