//
//  AppGroupConfigurationStore.swift
//  Trace
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import TraceCore

@MainActor
protocol ConfigurationDataStore: AnyObject {
    func loadRewriteRules() async throws -> [RewriteRule]
    func saveRewriteRules(_ rules: [RewriteRule]) async throws
    func loadRequestMaps() async throws -> [RequestMap]
    func saveRequestMaps(_ maps: [RequestMap]) async throws
    func loadHostEntries() async throws -> [HostEntry]
    func saveHostEntries(_ entries: [HostEntry]) async throws
    func loadScripts() async throws -> [Script]
    func saveScripts(_ scripts: [Script]) async throws
    func loadBreakpoints() async throws -> [Breakpoint]
    func saveBreakpoints(_ breakpoints: [Breakpoint]) async throws
    func loadFavorites() async throws -> [Favorite]
    func saveFavorites(_ favorites: [Favorite]) async throws
}

@MainActor
final class AppGroupConfigurationStore: ConfigurationDataStore {
    private let storage: AppGroupStorage

    init(storage: AppGroupStorage = .shared) {
        self.storage = storage
    }

    func loadRewriteRules() async throws -> [RewriteRule] {
        try await storage.loadRewriteRules()
    }

    func saveRewriteRules(_ rules: [RewriteRule]) async throws {
        try await storage.saveRewriteRules(rules)
    }

    func loadRequestMaps() async throws -> [RequestMap] {
        try await storage.loadRequestMaps()
    }

    func saveRequestMaps(_ maps: [RequestMap]) async throws {
        try await storage.saveRequestMaps(maps)
    }

    func loadHostEntries() async throws -> [HostEntry] {
        try await storage.loadHostEntries()
    }

    func saveHostEntries(_ entries: [HostEntry]) async throws {
        try await storage.saveHostEntries(entries)
    }

    func loadScripts() async throws -> [Script] {
        try await storage.loadScripts()
    }

    func saveScripts(_ scripts: [Script]) async throws {
        try await storage.saveScripts(scripts)
    }

    func loadBreakpoints() async throws -> [Breakpoint] {
        try await storage.loadBreakpoints()
    }

    func saveBreakpoints(_ breakpoints: [Breakpoint]) async throws {
        try await storage.saveBreakpoints(breakpoints)
    }

    func loadFavorites() async throws -> [Favorite] {
        try await storage.loadFavorites()
    }

    func saveFavorites(_ favorites: [Favorite]) async throws {
        try await storage.saveFavorites(favorites)
    }
}
