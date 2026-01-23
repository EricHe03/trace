//
//  FavoritesManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class FavoritesManagerTests: XCTestCase {

    var manager: FavoritesManager!
    var testRequestID: UUID!

    override func setUp() {
        super.setUp()
        manager = FavoritesManager.shared
        testRequestID = UUID()

        // Clear all favorites before each test
        manager.clearAll()
    }

    override func tearDown() {
        manager.clearAll()
        manager = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let manager1 = FavoritesManager.shared
        let manager2 = FavoritesManager.shared

        XCTAssertTrue(manager1 === manager2, "FavoritesManager should be a singleton")
    }

    // MARK: - Add Favorite Tests

    func testAddFavorite() {
        manager.addFavorite(requestId: testRequestID, name: "Test Favorite")

        XCTAssertEqual(manager.favorites.count, 1)
        XCTAssertTrue(manager.isFavorited(requestId: testRequestID))
    }

    func testAddFavoriteWithDetails() {
        manager.addFavorite(
            requestId: testRequestID,
            name: "API Test",
            notes: "Testing user authentication endpoint"
        )

        let favorite = manager.getFavorite(for: testRequestID)
        XCTAssertNotNil(favorite)
        XCTAssertEqual(favorite?.name, "API Test")
        XCTAssertEqual(favorite?.notes, "Testing user authentication endpoint")
    }

    func testAddFavoriteWithoutName() {
        manager.addFavorite(requestId: testRequestID)

        XCTAssertTrue(manager.isFavorited(requestId: testRequestID))
        let favorite = manager.getFavorite(for: testRequestID)
        XCTAssertNil(favorite?.name)
    }

    func testAddDuplicateFavorite() {
        manager.addFavorite(requestId: testRequestID, name: "First")

        let countBefore = manager.favorites.count
        manager.addFavorite(requestId: testRequestID, name: "Duplicate")

        XCTAssertEqual(manager.favorites.count, countBefore, "Should not add duplicate favorite")
    }

    // MARK: - Remove Favorite Tests

    func testRemoveFavorite() {
        manager.addFavorite(requestId: testRequestID)
        XCTAssertTrue(manager.isFavorited(requestId: testRequestID))

        manager.removeFavorite(requestId: testRequestID)
        XCTAssertFalse(manager.isFavorited(requestId: testRequestID))
    }

    func testRemoveNonexistentFavorite() {
        let nonexistentID = UUID()

        manager.removeFavorite(requestId: nonexistentID)
        // Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Toggle Favorite Tests

    func testToggleFavoriteAdd() {
        XCTAssertFalse(manager.isFavorited(requestId: testRequestID))

        manager.toggleFavorite(requestId: testRequestID)

        XCTAssertTrue(manager.isFavorited(requestId: testRequestID))
    }

    func testToggleFavoriteRemove() {
        manager.addFavorite(requestId: testRequestID)
        XCTAssertTrue(manager.isFavorited(requestId: testRequestID))

        manager.toggleFavorite(requestId: testRequestID)

        XCTAssertFalse(manager.isFavorited(requestId: testRequestID))
    }

    // MARK: - Update Favorite Tests

    func testUpdateFavorite() {
        manager.addFavorite(requestId: testRequestID, name: "Original")

        guard var favorite = manager.getFavorite(for: testRequestID) else {
            XCTFail("Favorite not found")
            return
        }

        favorite.name = "Updated"
        favorite.notes = "Updated notes"
        manager.updateFavorite(favorite)

        let updated = manager.getFavorite(for: testRequestID)
        XCTAssertEqual(updated?.name, "Updated")
        XCTAssertEqual(updated?.notes, "Updated notes")
    }

    func testUpdateNonexistentFavorite() {
        let nonexistent = Favorite(requestId: UUID())

        manager.updateFavorite(nonexistent)
        // Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Delete Favorite Tests

    func testDeleteFavorite() {
        manager.addFavorite(requestId: testRequestID)

        guard let favorite = manager.getFavorite(for: testRequestID) else {
            XCTFail("Favorite not found")
            return
        }

        manager.deleteFavorite(favorite)

        XCTAssertFalse(manager.isFavorited(requestId: testRequestID))
    }

    // MARK: - Query Tests

    func testIsFavorited() {
        XCTAssertFalse(manager.isFavorited(requestId: testRequestID))

        manager.addFavorite(requestId: testRequestID)

        XCTAssertTrue(manager.isFavorited(requestId: testRequestID))
    }

    func testGetFavorite() {
        manager.addFavorite(requestId: testRequestID, name: "Test")

        let favorite = manager.getFavorite(for: testRequestID)

        XCTAssertNotNil(favorite)
        XCTAssertEqual(favorite?.requestId, testRequestID)
        XCTAssertEqual(favorite?.name, "Test")
    }

    func testGetNonexistentFavorite() {
        let favorite = manager.getFavorite(for: UUID())

        XCTAssertNil(favorite)
    }

    func testFavoritedRequestIds() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        manager.addFavorite(requestId: id1)
        manager.addFavorite(requestId: id2)
        manager.addFavorite(requestId: id3)

        let ids = manager.favoritedRequestIds

        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains(id1))
        XCTAssertTrue(ids.contains(id2))
        XCTAssertTrue(ids.contains(id3))
    }

    // MARK: - Clear All Tests

    func testClearAll() {
        manager.addFavorite(requestId: UUID())
        manager.addFavorite(requestId: UUID())
        manager.addFavorite(requestId: UUID())

        XCTAssertEqual(manager.favorites.count, 3)

        manager.clearAll()

        XCTAssertEqual(manager.favorites.count, 0)
    }

    // MARK: - Search Tests

    func testSearchFavoritesByName() {
        manager.addFavorite(requestId: UUID(), name: "Login API Test")
        manager.addFavorite(requestId: UUID(), name: "User Profile Test")
        manager.addFavorite(requestId: UUID(), name: "Payment Gateway")

        let results = manager.searchFavorites(query: "test")

        XCTAssertEqual(results.count, 2)
    }

    func testSearchFavoritesByNotes() {
        manager.addFavorite(requestId: UUID(), name: "Test 1", notes: "Important endpoint")
        manager.addFavorite(requestId: UUID(), name: "Test 2", notes: "Debug this later")
        manager.addFavorite(requestId: UUID(), name: "Test 3", notes: "Works fine")

        let results = manager.searchFavorites(query: "debug")

        XCTAssertEqual(results.count, 1)
    }

    func testSearchFavoritesEmptyQuery() {
        manager.addFavorite(requestId: UUID(), name: "Test 1")
        manager.addFavorite(requestId: UUID(), name: "Test 2")

        let results = manager.searchFavorites(query: "")

        XCTAssertEqual(results.count, manager.favorites.count)
    }

    func testSearchFavoritesCaseInsensitive() {
        manager.addFavorite(requestId: UUID(), name: "LOGIN Test")

        let results = manager.searchFavorites(query: "login")

        XCTAssertEqual(results.count, 1)
    }

    // MARK: - Import/Export Tests

    func testExportFavorites() {
        manager.addFavorite(requestId: UUID(), name: "Test 1")
        manager.addFavorite(requestId: UUID(), name: "Test 2")

        let data = manager.exportFavorites()

        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
    }

    func testImportFavoritesMerge() throws {
        // Add initial favorites
        manager.addFavorite(requestId: UUID(), name: "Existing")

        // Create favorites to import
        let favorite1 = Favorite(requestId: UUID(), name: "Imported 1")
        let favorite2 = Favorite(requestId: UUID(), name: "Imported 2")
        let importData = try JSONEncoder().encode([favorite1, favorite2])

        let countBefore = manager.favorites.count

        try manager.importFavorites(from: importData, merge: true)

        XCTAssertEqual(manager.favorites.count, countBefore + 2)
    }

    func testImportFavoritesReplace() throws {
        // Add initial favorites
        manager.addFavorite(requestId: UUID(), name: "To Be Replaced")
        manager.addFavorite(requestId: UUID(), name: "Also Replaced")

        // Create favorites to import
        let favorite = Favorite(requestId: UUID(), name: "New Favorite")
        let importData = try JSONEncoder().encode([favorite])

        try manager.importFavorites(from: importData, merge: false)

        XCTAssertEqual(manager.favorites.count, 1)
        XCTAssertEqual(manager.favorites.first?.name, "New Favorite")
    }

    // MARK: - Statistics Tests

    func testTotalCount() {
        XCTAssertEqual(manager.totalCount, 0)

        manager.addFavorite(requestId: UUID())
        XCTAssertEqual(manager.totalCount, 1)

        manager.addFavorite(requestId: UUID())
        XCTAssertEqual(manager.totalCount, 2)
    }

    // MARK: - Persistence Tests

    func testReloadFavorites() {
        manager.addFavorite(requestId: testRequestID, name: "Test")

        // This should reload from storage
        manager.reloadFavorites()

        // Verify favorite still exists after reload
        XCTAssertTrue(manager.isFavorited(requestId: testRequestID))
    }
}
