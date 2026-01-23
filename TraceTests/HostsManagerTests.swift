//
//  HostsManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class HostsManagerTests: XCTestCase {

    var manager: HostsManager!

    override func setUp() {
        super.setUp()
        manager = HostsManager.shared
        manager.clearAll()
    }

    override func tearDown() {
        manager.clearAll()
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let manager1 = HostsManager.shared
        let manager2 = HostsManager.shared

        XCTAssertTrue(manager1 === manager2, "HostsManager should be a singleton")
    }

    // MARK: - Add Entry Tests

    func testAddEntry() {
        let entry = HostEntry(
            name: "Test Entry",
            hostname: "example.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )

        manager.addEntry(entry)

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertTrue(manager.entries.contains { $0.id == entry.id })
    }

    func testAddEntryWithPort() {
        let entry = HostEntry(
            name: "API Entry",
            hostname: "api.example.com",
            targetIP: "192.168.1.100",
            targetPort: 8080
        )

        manager.addEntry(entry)

        let added = manager.entries.first
        XCTAssertEqual(added?.targetPort, 8080)
    }

    // MARK: - Update Entry Tests

    func testUpdateEntry() {
        var entry = HostEntry(
            name: "Update Test",
            hostname: "example.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )
        manager.addEntry(entry)

        entry.targetIP = "192.168.1.1"
        manager.updateEntry(entry)

        let updated = manager.entries.first { $0.id == entry.id }
        XCTAssertEqual(updated?.targetIP, "192.168.1.1")
    }

    func testUpdateNonexistentEntry() {
        let entry = HostEntry(
            name: "Nonexistent",
            hostname: "nonexistent.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )

        manager.updateEntry(entry)
        // Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Delete Entry Tests

    func testDeleteEntry() {
        let entry = HostEntry(
            name: "Delete Test",
            hostname: "example.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )
        manager.addEntry(entry)

        XCTAssertEqual(manager.entries.count, 1)

        manager.deleteEntry(entry)

        XCTAssertEqual(manager.entries.count, 0)
    }

    func testDeleteEntriesAtIndices() {
        let entry1 = HostEntry(name: "Entry 1", hostname: "example1.com", targetIP: "127.0.0.1", targetPort: nil)
        let entry2 = HostEntry(name: "Entry 2", hostname: "example2.com", targetIP: "127.0.0.2", targetPort: nil)
        let entry3 = HostEntry(name: "Entry 3", hostname: "example3.com", targetIP: "127.0.0.3", targetPort: nil)

        manager.addEntry(entry1)
        manager.addEntry(entry2)
        manager.addEntry(entry3)

        manager.deleteEntries(at: IndexSet([0, 2]))

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.hostname, "example2.com")
    }

    // MARK: - Toggle Entry Tests

    func testToggleEntry() {
        var entry = HostEntry(
            name: "Toggle Test",
            hostname: "example.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )
        manager.addEntry(entry)

        XCTAssertTrue(manager.entries.first?.enabled ?? false)

        manager.toggleEntry(entry)

        XCTAssertFalse(manager.entries.first?.enabled ?? true)
    }

    func testEnableAll() {
        let entry1 = HostEntry(name: "Entry 1", enabled: false, hostname: "example1.com", targetIP: "127.0.0.1", targetPort: nil)
        let entry2 = HostEntry(name: "Entry 2", enabled: false, hostname: "example2.com", targetIP: "127.0.0.2", targetPort: nil)

        manager.addEntry(entry1)
        manager.addEntry(entry2)

        manager.enableAll()

        XCTAssertTrue(manager.entries.allSatisfy { $0.enabled })
    }

    func testDisableAll() {
        let entry1 = HostEntry(name: "Entry 1", hostname: "example1.com", targetIP: "127.0.0.1", targetPort: nil)
        let entry2 = HostEntry(name: "Entry 2", hostname: "example2.com", targetIP: "127.0.0.2", targetPort: nil)

        manager.addEntry(entry1)
        manager.addEntry(entry2)

        manager.disableAll()

        XCTAssertTrue(manager.entries.allSatisfy { !$0.enabled })
    }

    // MARK: - Matching Tests

    func testMatchingEntryForURL() {
        let entry = HostEntry(
            name: "Match Test",
            hostname: "example.com",
            targetIP: "192.168.1.100",
            targetPort: 8080
        )
        manager.addEntry(entry)

        let match = manager.matchingEntry(for: "https://example.com/api")

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.targetIP, "192.168.1.100")
        XCTAssertEqual(match?.targetPort, 8080)
    }

    func testMatchingEntryNotFound() {
        let entry = HostEntry(
            name: "Not Found Test",
            hostname: "example.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )
        manager.addEntry(entry)

        let match = manager.matchingEntry(for: "https://other.com")

        XCTAssertNil(match)
    }

    func testHasMatch() {
        let entry = HostEntry(
            name: "Has Match Test",
            hostname: "example.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )
        manager.addEntry(entry)

        XCTAssertTrue(manager.hasMatch(for: "https://example.com"))
        XCTAssertFalse(manager.hasMatch(for: "https://other.com"))
    }

    // MARK: - Import/Export Tests

    func testExportEntries() {
        let entry = HostEntry(
            name: "Export Test",
            hostname: "example.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )
        manager.addEntry(entry)

        let data = manager.exportEntries()

        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data!.count, 0)
    }

    func testImportEntriesMerge() throws {
        let existing = HostEntry(name: "Existing", hostname: "existing.com", targetIP: "127.0.0.1", targetPort: nil)
        manager.addEntry(existing)

        let toImport = [
            HostEntry(name: "Imported", hostname: "imported.com", targetIP: "192.168.1.1", targetPort: nil)
        ]

        let data = try JSONEncoder().encode(toImport)
        try manager.importEntries(from: data, merge: true)

        XCTAssertEqual(manager.entries.count, 2)
    }

    func testImportEntriesReplace() throws {
        let existing = HostEntry(name: "Existing", hostname: "existing.com", targetIP: "127.0.0.1", targetPort: nil)
        manager.addEntry(existing)

        let toImport = [
            HostEntry(name: "New", hostname: "new.com", targetIP: "192.168.1.1", targetPort: nil)
        ]

        let data = try JSONEncoder().encode(toImport)
        try manager.importEntries(from: data, merge: false)

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries.first?.hostname, "new.com")
    }

    func testExportToFile() {
        let entry = HostEntry(name: "Export File Test", hostname: "example.com", targetIP: "127.0.0.1", targetPort: nil)
        manager.addEntry(entry)

        let fileURL = manager.exportToFile()

        XCTAssertNotNil(fileURL)
        if let url = fileURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Statistics Tests

    func testTotalCount() {
        XCTAssertEqual(manager.totalCount, 0)

        manager.addEntry(HostEntry(name: "Test 1", hostname: "test1.com", targetIP: "127.0.0.1", targetPort: nil))
        XCTAssertEqual(manager.totalCount, 1)

        manager.addEntry(HostEntry(name: "Test 2", hostname: "test2.com", targetIP: "127.0.0.2", targetPort: nil))
        XCTAssertEqual(manager.totalCount, 2)
    }

    func testEnabledCount() {
        manager.addEntry(HostEntry(name: "Enabled 1", hostname: "enabled1.com", targetIP: "127.0.0.1", targetPort: nil))
        manager.addEntry(HostEntry(name: "Enabled 2", hostname: "enabled2.com", targetIP: "127.0.0.2", targetPort: nil))
        manager.addEntry(HostEntry(name: "Disabled", enabled: false, hostname: "disabled.com", targetIP: "127.0.0.3", targetPort: nil))

        XCTAssertEqual(manager.enabledCount, 2)
    }

    func testDisabledCount() {
        manager.addEntry(HostEntry(name: "Enabled", hostname: "enabled.com", targetIP: "127.0.0.1", targetPort: nil))
        manager.addEntry(HostEntry(name: "Disabled 1", enabled: false, hostname: "disabled1.com", targetIP: "127.0.0.2", targetPort: nil))
        manager.addEntry(HostEntry(name: "Disabled 2", enabled: false, hostname: "disabled2.com", targetIP: "127.0.0.3", targetPort: nil))

        XCTAssertEqual(manager.disabledCount, 2)
    }

    // MARK: - Convenience Methods Tests

    func testClearAll() {
        manager.addEntry(HostEntry(name: "Test 1", hostname: "test1.com", targetIP: "127.0.0.1", targetPort: nil))
        manager.addEntry(HostEntry(name: "Test 2", hostname: "test2.com", targetIP: "127.0.0.2", targetPort: nil))

        XCTAssertEqual(manager.entries.count, 2)

        manager.clearAll()

        XCTAssertEqual(manager.entries.count, 0)
    }

    func testEntriesWithStatus() {
        manager.addEntry(HostEntry(name: "Enabled", hostname: "enabled.com", targetIP: "127.0.0.1", targetPort: nil))
        manager.addEntry(HostEntry(name: "Disabled", enabled: false, hostname: "disabled.com", targetIP: "127.0.0.2", targetPort: nil))

        let enabledEntries = manager.entries(withStatus: true)
        XCTAssertEqual(enabledEntries.count, 1)
        XCTAssertEqual(enabledEntries.first?.hostname, "enabled.com")

        let disabledEntries = manager.entries(withStatus: false)
        XCTAssertEqual(disabledEntries.count, 1)
        XCTAssertEqual(disabledEntries.first?.hostname, "disabled.com")

        let allEntries = manager.entries(withStatus: nil)
        XCTAssertEqual(allEntries.count, 2)
    }

    func testSearchEntries() {
        manager.addEntry(HostEntry(name: "Production API", enabled: true, hostname: "api.example.com", targetIP: "192.168.1.100", targetPort: nil))
        manager.addEntry(HostEntry(name: "Staging API", enabled: true, hostname: "staging.example.com", targetIP: "192.168.1.101", targetPort: nil))
        manager.addEntry(HostEntry(name: "Local Dev", enabled: true, hostname: "dev.example.com", targetIP: "127.0.0.1", targetPort: nil))

        let results = manager.searchEntries(query: "api")
        XCTAssertEqual(results.count, 2)

        let devResults = manager.searchEntries(query: "dev")
        XCTAssertEqual(devResults.count, 1)
    }

    func testSearchEntriesCaseInsensitive() {
        manager.addEntry(HostEntry(name: "Production", enabled: true, hostname: "PROD.EXAMPLE.COM", targetIP: "192.168.1.1", targetPort: nil))

        let results = manager.searchEntries(query: "prod")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchEntriesEmptyQuery() {
        manager.addEntry(HostEntry(name: "Test 1", enabled: true, hostname: "test1.com", targetIP: "127.0.0.1", targetPort: nil))
        manager.addEntry(HostEntry(name: "Test 2", enabled: true, hostname: "test2.com", targetIP: "127.0.0.2", targetPort: nil))

        let results = manager.searchEntries(query: "")
        XCTAssertEqual(results.count, manager.entries.count)
    }

    // MARK: - Persistence Tests

    func testReloadEntries() {
        let entry = HostEntry(name: "Reload Test", hostname: "test.com", targetIP: "127.0.0.1", targetPort: nil)
        manager.addEntry(entry)

        manager.reloadEntries()

        XCTAssertTrue(manager.entries.contains { $0.hostname == "test.com" })
    }
}
