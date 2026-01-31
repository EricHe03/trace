//
//  HostsManager.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/10.
//

import Combine
import Foundation
#if canImport(TraceCore)
import TraceCore
#endif

/// Manager for host entries that override DNS resolution
public final class HostsManager: ObservableObject {
    public nonisolated(unsafe) static let shared = HostsManager()

    // Use composition with the base manager
    private let baseManager: PersistentCollectionManager<HostEntry>
    private var cancellables: Set<AnyCancellable> = []

    public let objectWillChange = ObservableObjectPublisher()

    /// Expose items through computed property
    public var entries: [HostEntry] {
        baseManager.items
    }

    /// Notification for cross-process updates
    private let hostsUpdatedNotificationName = Notification.Name("com.trace.hostsUpdated")

    private init() {
        self.baseManager = PersistentCollectionManager(
            fileName: "HostEntries.json",
            notificationName: "com.trace.hostsUpdated",
            logger: FeatureLog.storage,
            itemName: "entry"
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

    // MARK: - Entry Management (Delegate to Base Manager)

    /// Add a new host entry
    public func addEntry(_ entry: HostEntry) {
        guard entry.isValid else {
            FeatureLog.hosts.warning("event=hosts.entry_add outcome=failure reason=invalid_entry errors=\(entry.validationErrors.joined(separator: ", "), privacy: .public) id=\(entry.id.uuidString, privacy: .public)")
            return
        }

        baseManager.add(entry)
    }

    /// Update an existing host entry
    public func updateEntry(_ entry: HostEntry) {
        guard entry.isValid else {
            FeatureLog.hosts.warning("event=hosts.entry_update outcome=failure reason=invalid_entry errors=\(entry.validationErrors.joined(separator: ", "), privacy: .public) id=\(entry.id.uuidString, privacy: .public)")
            return
        }

        baseManager.update(entry)
    }

    /// Delete a host entry
    public func deleteEntry(_ entry: HostEntry) {
        baseManager.delete(entry)
    }

    /// Delete entries at indices
    public func deleteEntries(at indices: IndexSet) {
        baseManager.delete(at: indices)
    }

    /// Toggle entry enabled state
    public func toggleEntry(_ entry: HostEntry) {
        baseManager.toggle(entry)
    }

    /// Enable all entries
    public func enableAll() {
        baseManager.enableAll()
    }

    /// Disable all entries
    public func disableAll() {
        baseManager.disableAll()
    }

    // MARK: - Entry Matching

    /// Find the first enabled entry that matches the given URL or hostname
    /// Returns the entry and the resolved target
    public func matchingEntry(for url: String) -> (entry: HostEntry, targetIP: String, targetPort: Int?)? {
        // Find first matching entry (order matters - first match wins)
        guard let entry = baseManager.matchingItems(for: url).first else {
            return nil
        }

        return (entry: entry, targetIP: entry.targetIP, targetPort: entry.targetPort)
    }

    /// Check if any enabled entry matches the given URL or hostname
    public func hasMatch(for url: String) -> Bool {
        baseManager.hasMatch(for: url)
    }

    // MARK: - Persistence (Delegate to Base Manager)

    /// Reload entries from disk (for cross-process sync)
    public func reloadEntries() {
        baseManager.reloadIfNeeded()
    }

    // MARK: - Import/Export (Delegate to Base Manager)

    /// Export entries to JSON data
    public func exportEntries() -> Data? {
        baseManager.exportData()
    }

    /// Import entries from JSON data
    /// - Parameter data: JSON data containing host entries
    /// - Parameter merge: If true, merge with existing entries. If false, replace all entries.
    public func importEntries(from data: Data, merge: Bool = true) throws {
        try baseManager.importData(from: data, merge: merge)
    }

    /// Export entries as a JSON file URL
    public func exportToFile() -> URL? {
        guard let data = exportEntries() else { return nil }

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let fileName = "trace-hosts-\(Date().timeIntervalSince1970).json"
        let fileURL = temporaryDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            FeatureLog.hosts.error("event=hosts.export outcome=failure error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Statistics (Delegate to Base Manager)

    /// Total number of host entries
    public var totalCount: Int {
        baseManager.totalCount
    }

    /// Number of enabled entries
    public var enabledCount: Int {
        baseManager.enabledCount
    }

    /// Number of disabled entries
    public var disabledCount: Int {
        baseManager.disabledCount
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: hostsUpdatedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadEntries()
        }
    }
}

// MARK: - Convenience Methods

public extension HostsManager {
    /// Clear all host entries
    func clearAll() {
        baseManager.clearAll()
    }

    /// Create sample entries for testing
    func loadSampleEntries() {
        baseManager.importItems(HostEntry.samples, merge: false)
    }

    /// Get entries filtered by status
    func entries(withStatus enabled: Bool?) -> [HostEntry] {
        baseManager.filteredItems(withStatus: enabled)
    }

    /// Search entries by name or hostname
    func searchEntries(query: String) -> [HostEntry] {
        guard !query.isEmpty else {
            return entries
        }

        let lowercasedQuery = query.lowercased()
        return entries.filter {
            $0.name.lowercased().contains(lowercasedQuery) ||
                $0.hostname.lowercased().contains(lowercasedQuery) ||
                $0.targetIP.lowercased().contains(lowercasedQuery)
        }
    }
}
