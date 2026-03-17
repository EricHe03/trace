//
//  PersistentCollectionManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import Combine
import OSLog
@testable import TraceCore
import XCTest

/// Test model conforming to required protocols
private struct TestItem: Codable, Identifiable, Equatable, Toggleable, URLMatchable, ModificationTrackable {
    let id: UUID
    var name: String
    var enabled: Bool
    var pattern: String
    var modifiedAt: Date
    var createdAt: Date

    init(id: UUID = UUID(), name: String, enabled: Bool = true, pattern: String = "", modifiedAt: Date = Date(), createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.pattern = pattern
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }

    func matches(_ url: String) -> Bool {
        enabled && url.contains(pattern)
    }
}

final class PersistentCollectionManagerTests: XCTestCase {
    private var manager: PersistentCollectionManager<TestItem>!
    private var testFileName: String!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        testFileName = "test-\(UUID().uuidString).json"
        let logger = Logger(subsystem: "com.trace.tests", category: "PersistentCollectionManagerTests")
        manager = PersistentCollectionManager(
            fileName: testFileName,
            notificationName: "test.notification.\(UUID().uuidString)",
            logger: logger,
            itemName: "testItem"
        )
        cancellables = []
    }

    override func tearDown() {
        // Clean up test file
        if let fileURL = AppGroupStorage.shared.configFileURL(for: testFileName) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        manager = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - CRUD Operation Tests

    func testAddItem() {
        let item = TestItem(name: "Test Item", pattern: "example.com")

        manager.add(item)

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.name, "Test Item")
    }

    func testUpdateItem() {
        var item = TestItem(name: "Original", pattern: "example.com")
        manager.add(item)

        item.name = "Updated"
        manager.update(item)

        XCTAssertEqual(manager.items.first?.name, "Updated")
    }

    func testDeleteItem() {
        let item = TestItem(name: "Test Item", pattern: "example.com")
        manager.add(item)

        XCTAssertEqual(manager.items.count, 1)

        manager.delete(item)

        XCTAssertEqual(manager.items.count, 0)
    }

    func testDeleteAtIndices() {
        manager.add(TestItem(name: "Item 1", pattern: "example1.com"))
        manager.add(TestItem(name: "Item 2", pattern: "example2.com"))
        manager.add(TestItem(name: "Item 3", pattern: "example3.com"))

        XCTAssertEqual(manager.items.count, 3)

        manager.delete(at: IndexSet([0, 2]))

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.name, "Item 2")
    }

    func testToggleItem() {
        let item = TestItem(name: "Test Item", enabled: true, pattern: "example.com")
        manager.add(item)

        XCTAssertTrue(manager.items.first?.enabled ?? false)

        manager.toggle(item)

        XCTAssertFalse(manager.items.first?.enabled ?? true)

        manager.toggle(item)

        XCTAssertTrue(manager.items.first?.enabled ?? false)
    }

    // MARK: - Persistence Tests

    func testPersistence() {
        let item = TestItem(name: "Test Item", pattern: "example.com")
        manager.add(item)

        // Create a new manager instance with the same file
        let logger = Logger(subsystem: "com.trace.tests", category: "PersistentCollectionManagerTests")
        let newManager = PersistentCollectionManager<TestItem>(
            fileName: testFileName,
            notificationName: "test.notification.new",
            logger: logger,
            itemName: "testItem"
        )

        XCTAssertEqual(newManager.items.count, 1)
        XCTAssertEqual(newManager.items.first?.name, "Test Item")
    }

    func testReloadIfNeeded() throws {
        let item1 = TestItem(name: "Item 1", pattern: "example.com")
        manager.add(item1)

        // Simulate external modification
        let item2 = TestItem(name: "Item 2", pattern: "other.com")
        let items = [item1, item2]
        let data = try JSONEncoder().encode(items)
        try AppGroupStorage.shared.saveData(data, to: testFileName)

        manager.reloadIfNeeded()

        XCTAssertEqual(manager.items.count, 2)
    }

    // MARK: - Import/Export Tests

    func testExportData() throws {
        manager.add(TestItem(name: "Item 1", pattern: "example1.com"))
        manager.add(TestItem(name: "Item 2", pattern: "example2.com"))

        let data = manager.exportData()

        XCTAssertNotNil(data)
        let decoded = try? JSONCoding.decode([TestItem].self, from: try XCTUnwrap(data))
        XCTAssertEqual(decoded?.count, 2)
    }

    func testImportDataMerge() throws {
        manager.add(TestItem(id: UUID(), name: "Existing", pattern: "existing.com"))

        let importItem = TestItem(id: UUID(), name: "Imported", pattern: "imported.com")
        let data = try JSONEncoder().encode([importItem])

        try manager.importData(from: data, merge: true)

        XCTAssertEqual(manager.items.count, 2)
    }

    func testImportDataReplace() throws {
        manager.add(TestItem(name: "Existing", pattern: "existing.com"))

        let importItem = TestItem(name: "Imported", pattern: "imported.com")
        let data = try JSONEncoder().encode([importItem])

        try manager.importData(from: data, merge: false)

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.name, "Imported")
    }

    func testImportItemsArray() {
        manager.add(TestItem(name: "Existing", pattern: "existing.com"))

        let importItems = [
            TestItem(name: "Imported 1", pattern: "imported1.com"),
            TestItem(name: "Imported 2", pattern: "imported2.com")
        ]

        manager.importItems(importItems, merge: true)

        XCTAssertEqual(manager.items.count, 3)
    }

    func testExportItems() throws {
        manager.add(TestItem(name: "Item 1", pattern: "example1.com"))
        manager.add(TestItem(name: "Item 2", pattern: "example2.com"))

        let url = try manager.exportItems()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let decoded = try JSONCoding.decode([TestItem].self, from: data)

        XCTAssertEqual(decoded.count, 2)

        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }

    func testImportItemsFromURL() throws {
        let items = [
            TestItem(name: "Item 1", pattern: "example1.com"),
            TestItem(name: "Item 2", pattern: "example2.com")
        ]
        let data = try JSONEncoder().encode(items)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).json")
        try data.write(to: tempURL)

        try manager.importItems(from: tempURL, merge: false)

        XCTAssertEqual(manager.items.count, 2)

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Query Tests

    func testTotalCount() {
        XCTAssertEqual(manager.totalCount, 0)

        manager.add(TestItem(name: "Item 1", pattern: "example.com"))
        XCTAssertEqual(manager.totalCount, 1)

        manager.add(TestItem(name: "Item 2", pattern: "other.com"))
        XCTAssertEqual(manager.totalCount, 2)
    }

    func testMatchingItems() {
        manager.add(TestItem(name: "Match 1", enabled: true, pattern: "example"))
        manager.add(TestItem(name: "Match 2", enabled: true, pattern: "test"))
        manager.add(TestItem(name: "Disabled", enabled: false, pattern: "example"))

        let matches = manager.matchingItems(for: "https://example.com/test")

        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.contains { $0.name == "Match 1" })
        XCTAssertTrue(matches.contains { $0.name == "Match 2" })
    }

    func testHasMatch() {
        manager.add(TestItem(name: "Match", enabled: true, pattern: "example"))

        XCTAssertTrue(manager.hasMatch(for: "https://example.com/test"))
        XCTAssertFalse(manager.hasMatch(for: "https://other.com/test"))
    }

    func testEnabledCount() {
        manager.add(TestItem(name: "Enabled 1", enabled: true, pattern: ""))
        manager.add(TestItem(name: "Enabled 2", enabled: true, pattern: ""))
        manager.add(TestItem(name: "Disabled", enabled: false, pattern: ""))

        XCTAssertEqual(manager.enabledCount, 2)
    }

    func testDisabledCount() {
        manager.add(TestItem(name: "Enabled 1", enabled: true, pattern: ""))
        manager.add(TestItem(name: "Enabled 2", enabled: true, pattern: ""))
        manager.add(TestItem(name: "Disabled", enabled: false, pattern: ""))

        XCTAssertEqual(manager.disabledCount, 1)
    }

    func testFilteredItems() {
        manager.add(TestItem(name: "Enabled", enabled: true, pattern: ""))
        manager.add(TestItem(name: "Disabled", enabled: false, pattern: ""))

        let enabledItems = manager.filteredItems(withStatus: true)
        XCTAssertEqual(enabledItems.count, 1)

        let disabledItems = manager.filteredItems(withStatus: false)
        XCTAssertEqual(disabledItems.count, 1)

        let allItems = manager.filteredItems(withStatus: nil)
        XCTAssertEqual(allItems.count, 2)
    }

    func testEnableAll() {
        manager.add(TestItem(name: "Item 1", enabled: false, pattern: ""))
        manager.add(TestItem(name: "Item 2", enabled: false, pattern: ""))

        manager.enableAll()

        XCTAssertEqual(manager.enabledCount, 2)
        XCTAssertEqual(manager.disabledCount, 0)
    }

    func testDisableAll() {
        manager.add(TestItem(name: "Item 1", enabled: true, pattern: ""))
        manager.add(TestItem(name: "Item 2", enabled: true, pattern: ""))

        manager.disableAll()

        XCTAssertEqual(manager.enabledCount, 0)
        XCTAssertEqual(manager.disabledCount, 2)
    }

    func testClearAll() {
        manager.add(TestItem(name: "Item 1", pattern: ""))
        manager.add(TestItem(name: "Item 2", pattern: ""))

        XCTAssertEqual(manager.items.count, 2)

        manager.clearAll()

        XCTAssertEqual(manager.items.count, 0)
    }

    // MARK: - ObservableObject Tests

    func testPublishedItemsChanges() {
        let expectation = expectation(description: "Items published")
        var receivedCount = 0

        manager.$items
            .dropFirst() // Skip initial value
            .sink { items in
                receivedCount = items.count
                expectation.fulfill()
            }
            .store(in: &cancellables)

        manager.add(TestItem(name: "Test", pattern: ""))

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(receivedCount, 1)
    }

    // MARK: - Modification Tracking Tests

    func testModificationTracking() throws {
        var item = TestItem(name: "Original", pattern: "example.com")
        let originalModifiedAt = item.modifiedAt
        manager.add(item)

        // Wait a bit to ensure time difference
        Thread.sleep(forTimeInterval: 0.01)

        item.name = "Updated"
        manager.update(item)

        let updatedItem = try XCTUnwrap(manager.items.first)
        XCTAssertNotEqual(updatedItem.modifiedAt, originalModifiedAt)
        XCTAssertGreaterThan(updatedItem.modifiedAt, originalModifiedAt)
    }

    // MARK: - Edge Cases Tests

    func testUpdateNonexistentItem() {
        let item = TestItem(name: "Nonexistent", pattern: "example.com")

        manager.update(item)

        XCTAssertEqual(manager.items.count, 0)
    }

    func testDeleteNonexistentItem() {
        let item = TestItem(name: "Nonexistent", pattern: "example.com")

        manager.delete(item)

        XCTAssertEqual(manager.items.count, 0)
    }

    func testToggleNonexistentItem() {
        let item = TestItem(name: "Nonexistent", enabled: true, pattern: "example.com")

        manager.toggle(item)

        XCTAssertEqual(manager.items.count, 0)
    }

    func testImportDuplicateItems() {
        let id = UUID()
        let item = TestItem(id: id, name: "Item", pattern: "example.com")
        manager.add(item)

        let duplicateItem = TestItem(id: id, name: "Duplicate", pattern: "example.com")
        manager.importItems([duplicateItem], merge: true)

        // Should not add duplicate
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.name, "Item")
    }

    func testEmptyCollection() {
        XCTAssertEqual(manager.items.count, 0)
        XCTAssertEqual(manager.totalCount, 0)
        XCTAssertEqual(manager.enabledCount, 0)
        XCTAssertEqual(manager.disabledCount, 0)

        let matches = manager.matchingItems(for: "https://example.com")
        XCTAssertEqual(matches.count, 0)
    }
}
