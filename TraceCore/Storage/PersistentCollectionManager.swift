//
//  PersistentCollectionManager.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
import OSLog

// MARK: - Protocols

/// Protocol for items that can be toggled on/off
public protocol Toggleable {
    var enabled: Bool { get set }
}

/// Protocol for items that can match URLs
public protocol URLMatchable {
    var enabled: Bool { get }
    func matches(_ url: String) -> Bool
}

/// Protocol for items with modification tracking
public protocol ModificationTrackable {
    var modifiedAt: Date { get set }
}

// MARK: - Base Manager

/// Generic base class for managing persistent collections with common CRUD operations
public final class PersistentCollectionManager<T: Codable & Identifiable & Equatable>: ObservableObject {
    // MARK: - Properties

    @Published public private(set) var items: [T] = []
    private let storage: AppGroupStorage
    private let fileName: String
    private let notificationName: Notification.Name
    private let logger: Logger
    private let itemName: String // "script", "rule", "map", etc.
    private var lastKnownFileModificationDate: Date?

    // MARK: - Initialization

    /// Initialize with a Logger instance (new logging system)
    ///
    /// - Parameters:
    ///   - fileName: The JSON file name for persistence
    ///   - notificationName: Notification name for cross-process updates
    ///   - logger: A Logger instance from CoreLog or module-specific logging
    ///   - itemName: Human-readable item name for log messages
    public init(
        fileName: String,
        notificationName: String,
        logger: Logger,
        itemName: String
    ) {
        self.storage = AppGroupStorage.shared
        self.fileName = fileName
        self.notificationName = Notification.Name(notificationName)
        self.logger = logger
        self.itemName = itemName
        loadItems()
    }

    // MARK: - CRUD Operations

    /// Add a new item
    public func add(_ item: T) {
        items.append(item)
        saveItems()
    }

    /// Update an existing item
    public func update(_ item: T) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = item
            updatedItem = updatingModifiedAtIfNeeded(updatedItem)

            items[index] = updatedItem
            saveItems()
        }
    }

    /// Delete an item
    public func delete(_ item: T) {
        items.removeAll { $0.id == item.id }
        saveItems()
    }

    /// Delete items at indices
    public func delete(at indices: IndexSet) {
        var newItems: [T] = []
        for (index, item) in items.enumerated() {
            if !indices.contains(index) {
                newItems.append(item)
            }
        }
        items = newItems
        saveItems()
    }

    /// Toggle item enabled state (for items that are Toggleable)
    public func toggle(_ item: T) where T: Toggleable {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = items[index]
            updatedItem.enabled.toggle()
            updatedItem = updatingModifiedAtIfNeeded(updatedItem)

            items[index] = updatedItem
            saveItems()
        }
    }

    // MARK: - Persistence

    private func loadItems() {
        do {
            let data = try storage.loadData(from: fileName)
            items = try JSONDecoder().decode([T].self, from: data)
            logger.info(
                "\(LogEvent.storage("load").success().with("item_type", value: self.itemName).count(self.items.count))"
            )
            lastKnownFileModificationDate = storage.configFileModificationDate(for: fileName)
        } catch {
            // Check if it's a file not found error (first launch)
            if let storageError = error as? StorageError, storageError == .fileNotFound {
                logger.info(
                    "\(LogEvent.storage("load").outcome(.skipped).with("item_type", value: self.itemName).with("reason", value: "first_launch"))"
                )
                items = []
                // Save empty array to create the file
                saveItems()
                return
            }

            logger.error(
                "\(LogEvent.storage("load").failure().with("item_type", value: self.itemName).error(error))"
            )
            // Leave items and backing file intact on load failures.
            return
        }
    }

    private func saveItems() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(items)
            try storage.saveData(data, to: fileName)
            lastKnownFileModificationDate = storage.configFileModificationDate(for: fileName)

            // Notify extension of changes
            NotificationCenter.default.post(name: notificationName, object: nil)

            logger.debug(
                "\(LogEvent.storage("save").success().with("item_type", value: self.itemName).count(self.items.count))"
            )
        } catch {
            logger.error(
                "\(LogEvent.storage("save").failure().with("item_type", value: self.itemName).error(error))"
            )
        }
    }

    /// Reload items if the backing file has changed
    public func reloadIfNeeded() {
        guard let fileDate = storage.configFileModificationDate(for: fileName) else {
            return
        }

        if let lastKnown = lastKnownFileModificationDate, fileDate <= lastKnown {
            return
        }

        loadItems()
    }

    private func updatingModifiedAtIfNeeded(_ item: T) -> T {
        guard var trackable = item as? ModificationTrackable else {
            return item
        }

        trackable.modifiedAt = Date()
        return trackable as? T ?? item
    }

    // MARK: - Import/Export

    /// Export items to JSON file
    public func exportItems() throws -> URL {
        let data = try JSONEncoder().encode(items)
        let timestamp = Date().timeIntervalSince1970
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(itemName.capitalized)s_\(timestamp).json")
        try data.write(to: tempURL)
        return tempURL
    }

    /// Import items from JSON file
    public func importItems(from url: URL, merge: Bool = true) throws {
        let data = try Data(contentsOf: url)
        let importedItems = try JSONDecoder().decode([T].self, from: data)
        importItems(importedItems, merge: merge)
    }

    /// Import items from decoded array
    public func importItems(_ importedItems: [T], merge: Bool = true) {
        if merge {
            // Merge with existing items, avoiding duplicates
            for item in importedItems {
                if !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                }
            }
        } else {
            // Replace all items
            items = importedItems
        }

        saveItems()
    }

    /// Export items to JSON data
    public func exportData() -> Data? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            return try encoder.encode(items)
        } catch {
            logger.error(
                "\(LogEvent.storage("export").failure().with("item_type", value: self.itemName).error(error))"
            )
            return nil
        }
    }

    /// Import items from JSON data
    public func importData(from data: Data, merge: Bool = true) throws {
        let importedItems = try JSONDecoder().decode([T].self, from: data)
        importItems(importedItems, merge: merge)
    }

    /// Clear all items
    public func clearAll() {
        items.removeAll()
        saveItems()
    }

    // MARK: - Queries

    /// Total number of items
    public var totalCount: Int {
        items.count
    }

    /// Find all enabled items that match a given URL (for items that are URLMatchable)
    public func matchingItems(for url: String) -> [T] where T: URLMatchable {
        items.filter { $0.enabled && $0.matches(url) }
    }

    /// Check if any enabled item matches the given URL (for items that are URLMatchable)
    public func hasMatch(for url: String) -> Bool where T: URLMatchable {
        items.contains { $0.enabled && $0.matches(url) }
    }

    /// Enable all items (for items that are Toggleable)
    public func enableAll() where T: Toggleable & ModificationTrackable {
        for index in items.indices {
            items[index].enabled = true
            items[index].modifiedAt = Date()
        }
        saveItems()
    }

    /// Disable all items (for items that are Toggleable)
    public func disableAll() where T: Toggleable & ModificationTrackable {
        for index in items.indices {
            items[index].enabled = false
            items[index].modifiedAt = Date()
        }
        saveItems()
    }
}

// MARK: - Toggleable Queries

public extension PersistentCollectionManager where T: Toggleable {
    /// Number of enabled items
    var enabledCount: Int {
        items.filter(\.enabled).count
    }

    /// Number of disabled items
    var disabledCount: Int {
        items.count(where: { !$0.enabled })
    }

    /// Get items filtered by enabled status
    func filteredItems(withStatus enabled: Bool?) -> [T] {
        guard let enabled else {
            return items
        }
        return items.filter { $0.enabled == enabled }
    }
}
