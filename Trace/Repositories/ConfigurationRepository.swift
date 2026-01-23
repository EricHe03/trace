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
    // MARK: - Dependencies

    private let storage: AppGroupStorage

    // MARK: - Initialization

    init(storage: AppGroupStorage = .shared) {
        self.storage = storage
    }

    // MARK: - Rewrite Rules

    func getRewriteRules() async throws -> [RewriteRule] {
        try await storage.loadRewriteRules()
    }

    func saveRewriteRules(_ rules: [RewriteRule]) async throws {
        try await storage.saveRewriteRules(rules)
    }

    // MARK: - Request Maps

    func getRequestMaps() async throws -> [RequestMap] {
        try await storage.loadRequestMaps()
    }

    func saveRequestMaps(_ maps: [RequestMap]) async throws {
        try await storage.saveRequestMaps(maps)
    }

    // MARK: - Host Entries

    func getHostEntries() async throws -> [HostEntry] {
        try await storage.loadHostEntries()
    }

    func saveHostEntries(_ entries: [HostEntry]) async throws {
        try await storage.saveHostEntries(entries)
    }

    // MARK: - Scripts

    func getScripts() async throws -> [Script] {
        try await storage.loadScripts()
    }

    func saveScripts(_ scripts: [Script]) async throws {
        try await storage.saveScripts(scripts)
    }

    // MARK: - Breakpoints

    func getBreakpoints() async throws -> [Breakpoint] {
        try await storage.loadBreakpoints()
    }

    func saveBreakpoints(_ breakpoints: [Breakpoint]) async throws {
        try await storage.saveBreakpoints(breakpoints)
    }

    // MARK: - Favorites

    func getFavorites() async throws -> [Favorite] {
        try await storage.loadFavorites()
    }

    func saveFavorites(_ favorites: [Favorite]) async throws {
        try await storage.saveFavorites(favorites)
    }
}
