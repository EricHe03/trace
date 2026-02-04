//
//  FavoritesManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

/// Manager for favorited network requests
@MainActor
public final class FavoritesManager: ObservableObject {
    public static let shared = FavoritesManager()

    // Use composition with the base manager
    private let baseManager: PersistentCollectionManager<Favorite>
    private var cancellables: Set<AnyCancellable> = []

    public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

    /// Expose items through computed property
    public var favorites: [Favorite] {
        baseManager.items
    }

    /// Notification for cross-process updates
    private let favoritesUpdatedNotificationName = Notification.Name.favoritesUpdated

    private init() {
        self.baseManager = PersistentCollectionManager(
            fileName: "Favorites.json",
            notificationName: Notification.Name.favoritesUpdated.rawValue,
            logger: FeatureLog.storage,
            itemName: "favorite"
        )

        // Forward changes from the underlying store for SwiftUI observation.
        baseManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        setupNotifications()
    }

    // MARK: - Favorite Management

    /// Add a request to favorites
    public func addFavorite(requestId: UUID, name: String? = nil, notes: String? = nil) {
        // Check if already favorited
        guard !isFavorited(requestId: requestId) else {
            return
        }

        let favorite = Favorite(
            requestId: requestId,
            name: name,
            notes: notes
        )

        baseManager.add(favorite)
    }

    /// Remove a request from favorites
    public func removeFavorite(requestId: UUID) {
        if let favorite = favorites.first(where: { $0.requestId == requestId }) {
            baseManager.delete(favorite)
        }
    }

    /// Toggle favorite status for a request
    public func toggleFavorite(requestId: UUID) {
        if isFavorited(requestId: requestId) {
            removeFavorite(requestId: requestId)
        } else {
            addFavorite(requestId: requestId)
        }
    }

    /// Update an existing favorite
    public func updateFavorite(_ favorite: Favorite) {
        baseManager.update(favorite)
    }

    /// Delete a favorite by ID
    public func deleteFavorite(_ favorite: Favorite) {
        baseManager.delete(favorite)
    }

    // MARK: - Queries

    /// Check if a request is favorited
    public func isFavorited(requestId: UUID) -> Bool {
        favorites.contains { $0.requestId == requestId }
    }

    /// Get favorite for a specific request
    public func getFavorite(for requestId: UUID) -> Favorite? {
        favorites.first { $0.requestId == requestId }
    }

    /// Get all favorited request IDs
    public var favoritedRequestIds: Set<UUID> {
        Set(favorites.map(\.requestId))
    }

    // MARK: - Persistence (Delegate to Base Manager)

    /// Reload favorites from disk (for cross-process sync)
    public func reloadFavorites() {
        baseManager.reloadIfNeeded()
    }

    // MARK: - Import/Export (Delegate to Base Manager)

    /// Export favorites to JSON data
    public func exportFavorites() -> Data? {
        baseManager.exportData()
    }

    /// Import favorites from JSON data
    public func importFavorites(from data: Data, merge: Bool = true) throws {
        try baseManager.importData(from: data, merge: merge)
    }

    // MARK: - Statistics (Delegate to Base Manager)

    /// Total number of favorites
    public var totalCount: Int {
        baseManager.totalCount
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: favoritesUpdatedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFavorites()
        }
    }
}

// MARK: - Convenience Methods

public extension FavoritesManager {
    /// Clear all favorites
    func clearAll() {
        baseManager.clearAll()
    }

    /// Search favorites by name or notes
    func searchFavorites(query: String) -> [Favorite] {
        guard !query.isEmpty else {
            return favorites
        }

        let lowercasedQuery = query.lowercased()
        return favorites.filter {
            ($0.name?.lowercased().contains(lowercasedQuery) ?? false) ||
                ($0.notes?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }
}
