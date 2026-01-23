//
//  RequestMapManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class RequestMapManagerTests: XCTestCase {

    var manager: RequestMapManager!

    override func setUp() {
        super.setUp()
        manager = RequestMapManager.shared
        // Clear all maps before each test
        manager.clearAllMaps()
    }

    override func tearDown() {
        manager.clearAllMaps()
        manager = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let manager1 = RequestMapManager.shared
        let manager2 = RequestMapManager.shared

        XCTAssertTrue(manager1 === manager2, "RequestMapManager should be a singleton")
    }

    // MARK: - Map Management Tests

    func testAddMap() {
        let mockResponse = MockResponse(statusCode: 200, bodyContent: Data("Test".utf8))
        let map = RequestMap(name: "Test Map", matchPattern: "*example.com*", mockResponse: mockResponse)

        manager.addMap(map)

        XCTAssertEqual(manager.maps.count, 1)
        XCTAssertTrue(manager.maps.contains { $0.id == map.id })
    }

    func testUpdateMap() {
        let mockResponse = MockResponse(statusCode: 200)
        var map = RequestMap(name: "Original", matchPattern: "*test.com*", mockResponse: mockResponse)

        manager.addMap(map)

        map.name = "Updated"
        manager.updateMap(map)

        let updated = manager.maps.first { $0.id == map.id }
        XCTAssertEqual(updated?.name, "Updated")
        XCTAssertNotNil(updated?.modifiedAt)
    }

    func testDeleteMap() {
        let mockResponse = MockResponse(statusCode: 200)
        let map = RequestMap(name: "To Delete", matchPattern: "*delete.com*", mockResponse: mockResponse)

        manager.addMap(map)
        XCTAssertEqual(manager.maps.count, 1)

        manager.deleteMap(map)
        XCTAssertEqual(manager.maps.count, 0)
        XCTAssertFalse(manager.maps.contains { $0.id == map.id })
    }

    func testDeleteMapsAtIndices() {
        let mockResponse = MockResponse(statusCode: 200)
        let map1 = RequestMap(name: "Map 1", matchPattern: "*test1.com*", mockResponse: mockResponse)
        let map2 = RequestMap(name: "Map 2", matchPattern: "*test2.com*", mockResponse: mockResponse)
        let map3 = RequestMap(name: "Map 3", matchPattern: "*test3.com*", mockResponse: mockResponse)

        manager.addMap(map1)
        manager.addMap(map2)
        manager.addMap(map3)

        XCTAssertEqual(manager.maps.count, 3)

        manager.deleteMaps(at: IndexSet([0, 2]))

        XCTAssertEqual(manager.maps.count, 1)
        XCTAssertEqual(manager.maps.first?.name, "Map 2")
    }

    func testToggleMap() {
        let mockResponse = MockResponse(statusCode: 200)
        let map = RequestMap(name: "Toggle Test", enabled: true, matchPattern: "*toggle.com*", mockResponse: mockResponse)

        manager.addMap(map)

        XCTAssertTrue(manager.maps.first?.enabled ?? false)

        manager.toggleMap(map)
        XCTAssertFalse(manager.maps.first?.enabled ?? true)

        manager.toggleMap(map)
        XCTAssertTrue(manager.maps.first?.enabled ?? false)
    }

    func testIncrementHitCount() {
        let mockResponse = MockResponse(statusCode: 200)
        let map = RequestMap(name: "Hit Counter", matchPattern: "*hit.com*", mockResponse: mockResponse)

        manager.addMap(map)

        XCTAssertEqual(manager.maps.first?.hitCount, 0)

        manager.incrementHitCount(for: map.id)
        XCTAssertEqual(manager.maps.first?.hitCount, 1)

        manager.incrementHitCount(for: map.id)
        XCTAssertEqual(manager.maps.first?.hitCount, 2)
    }

    // MARK: - Map Matching Tests

    func testMatchingMapFindsEnabledMap() {
        let mockResponse = MockResponse(statusCode: 200)
        let map = RequestMap(name: "Match Test", enabled: true, matchPattern: "*example.com*", mockResponse: mockResponse)

        manager.addMap(map)

        let matched = manager.matchingMap(for: "https://api.example.com/users")
        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.id, map.id)
    }

    func testMatchingMapIgnoresDisabledMap() {
        let mockResponse = MockResponse(statusCode: 200)
        let map = RequestMap(name: "Disabled", enabled: false, matchPattern: "*example.com*", mockResponse: mockResponse)

        manager.addMap(map)

        let matched = manager.matchingMap(for: "https://api.example.com/users")
        XCTAssertNil(matched)
    }

    func testMatchingMapReturnsFirstMatch() {
        let mockResponse1 = MockResponse(statusCode: 200, bodyContent: Data("Response 1".utf8))
        let mockResponse2 = MockResponse(statusCode: 201, bodyContent: Data("Response 2".utf8))

        let map1 = RequestMap(name: "First", enabled: true, matchPattern: "*example.com*", mockResponse: mockResponse1)
        let map2 = RequestMap(name: "Second", enabled: true, matchPattern: "*example.com*", mockResponse: mockResponse2)

        manager.addMap(map1)
        manager.addMap(map2)

        let matched = manager.matchingMap(for: "https://api.example.com/users")
        XCTAssertEqual(matched?.id, map1.id, "Should return the first matching map")
    }

    func testHasMappingReturnsTrueWhenMatch() {
        let mockResponse = MockResponse(statusCode: 200)
        let map = RequestMap(name: "Test", enabled: true, matchPattern: "*example.com*", mockResponse: mockResponse)

        manager.addMap(map)

        XCTAssertTrue(manager.hasMapping(for: "https://api.example.com/users"))
    }

    func testHasMappingReturnsFalseWhenNoMatch() {
        XCTAssertFalse(manager.hasMapping(for: "https://api.example.com/users"))
    }

    // MARK: - Mock Response Generation Tests

    func testGetMockResponse() async throws {
        let mockBody = Data("Mock response body".utf8)
        let mockResponse = MockResponse(statusCode: 201, bodyContent: mockBody)
        let map = RequestMap(name: "Mock Test", enabled: true, matchPattern: "*example.com*", mockResponse: mockResponse)

        manager.addMap(map)

        let requestId = UUID()
        let result = try await manager.getMockResponse(
            for: "https://api.example.com/users",
            method: .get,
            requestId: requestId
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.statusCode, 201)
        XCTAssertEqual(result?.id, requestId)
        XCTAssertEqual(result?.url, "https://api.example.com/users")
    }

    func testGetMockResponseReturnsNilWhenNoMatch() async throws {
        let result = try await manager.getMockResponse(
            for: "https://nomatch.example.com/users",
            method: .get,
            requestId: UUID()
        )

        XCTAssertNil(result)
    }

    // MARK: - Create Map from Request Tests

    func testCreateMapFromRequest() {
        let request = createMockNetworkRequest()

        manager.createMapFromRequest(request, name: "From Request")

        XCTAssertEqual(manager.maps.count, 1)
        XCTAssertEqual(manager.maps.first?.name, "From Request")
        XCTAssertEqual(manager.maps.first?.matchPattern, request.url)
        XCTAssertEqual(manager.maps.first?.matchType, .exact)
    }

    func testCreateMapFromRequestWithDefaultName() {
        let request = createMockNetworkRequest()

        manager.createMapFromRequest(request)

        XCTAssertEqual(manager.maps.count, 1)
        XCTAssertTrue(manager.maps.first?.name.contains("Mock for") ?? false)
    }

    // MARK: - Statistics Tests

    func testEnabledMapsCount() {
        let mockResponse = MockResponse(statusCode: 200)
        let enabledMap = RequestMap(name: "Enabled", enabled: true, matchPattern: "*test1.com*", mockResponse: mockResponse)
        let disabledMap = RequestMap(name: "Disabled", enabled: false, matchPattern: "*test2.com*", mockResponse: mockResponse)

        manager.addMap(enabledMap)
        manager.addMap(disabledMap)

        XCTAssertEqual(manager.enabledMapsCount, 1)
    }

    func testTotalMapsCount() {
        let mockResponse = MockResponse(statusCode: 200)
        let map1 = RequestMap(name: "Map 1", matchPattern: "*test1.com*", mockResponse: mockResponse)
        let map2 = RequestMap(name: "Map 2", matchPattern: "*test2.com*", mockResponse: mockResponse)

        manager.addMap(map1)
        manager.addMap(map2)

        XCTAssertEqual(manager.totalMapsCount, 2)
    }

    func testTotalHits() {
        let mockResponse = MockResponse(statusCode: 200)
        let map1 = RequestMap(name: "Map 1", matchPattern: "*test1.com*", mockResponse: mockResponse)
        let map2 = RequestMap(name: "Map 2", matchPattern: "*test2.com*", mockResponse: mockResponse)

        manager.addMap(map1)
        manager.addMap(map2)

        manager.incrementHitCount(for: map1.id)
        manager.incrementHitCount(for: map1.id)
        manager.incrementHitCount(for: map2.id)

        XCTAssertEqual(manager.totalHits, 3)
    }

    func testMostUsedMaps() {
        let mockResponse = MockResponse(statusCode: 200)
        let map1 = RequestMap(name: "Map 1", matchPattern: "*test1.com*", mockResponse: mockResponse, hitCount: 5)
        let map2 = RequestMap(name: "Map 2", matchPattern: "*test2.com*", mockResponse: mockResponse, hitCount: 10)
        let map3 = RequestMap(name: "Map 3", matchPattern: "*test3.com*", mockResponse: mockResponse, hitCount: 3)

        manager.addMap(map1)
        manager.addMap(map2)
        manager.addMap(map3)

        let mostUsed = manager.mostUsedMaps(limit: 2)

        XCTAssertEqual(mostUsed.count, 2)
        XCTAssertEqual(mostUsed[0].name, "Map 2")
        XCTAssertEqual(mostUsed[1].name, "Map 1")
    }

    // MARK: - Import/Export Tests

    func testExportMaps() throws {
        let mockResponse = MockResponse(statusCode: 200, bodyContent: Data("Test".utf8))
        let map = RequestMap(name: "Export Test", matchPattern: "*test.com*", mockResponse: mockResponse)

        manager.addMap(map)

        let url = try manager.exportMaps()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.contains("RequestMaps"))

        // Clean up
        try? FileManager.default.removeItem(at: url)
    }

    func testImportMapsMerge() throws {
        let mockResponse1 = MockResponse(statusCode: 200)
        let mockResponse2 = MockResponse(statusCode: 201)

        let existingMap = RequestMap(name: "Existing", matchPattern: "*existing.com*", mockResponse: mockResponse1)
        let importedMap = RequestMap(name: "Imported", matchPattern: "*imported.com*", mockResponse: mockResponse2)

        manager.addMap(existingMap)

        let data = try JSONEncoder().encode([importedMap])
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_import.json")
        try data.write(to: tempURL)

        try manager.importMaps(from: tempURL, merge: true)

        XCTAssertEqual(manager.maps.count, 2)
        XCTAssertTrue(manager.maps.contains { $0.name == "Existing" })
        XCTAssertTrue(manager.maps.contains { $0.name == "Imported" })

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testImportMapsReplace() throws {
        let mockResponse1 = MockResponse(statusCode: 200)
        let mockResponse2 = MockResponse(statusCode: 201)

        let existingMap = RequestMap(name: "Existing", matchPattern: "*existing.com*", mockResponse: mockResponse1)
        let importedMap = RequestMap(name: "Imported", matchPattern: "*imported.com*", mockResponse: mockResponse2)

        manager.addMap(existingMap)

        let data = try JSONEncoder().encode([importedMap])
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_import.json")
        try data.write(to: tempURL)

        try manager.importMaps(from: tempURL, merge: false)

        XCTAssertEqual(manager.maps.count, 1)
        XCTAssertFalse(manager.maps.contains { $0.name == "Existing" })
        XCTAssertTrue(manager.maps.contains { $0.name == "Imported" })

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testClearAllMaps() {
        let mockResponse = MockResponse(statusCode: 200)
        let map1 = RequestMap(name: "Map 1", matchPattern: "*test1.com*", mockResponse: mockResponse)
        let map2 = RequestMap(name: "Map 2", matchPattern: "*test2.com*", mockResponse: mockResponse)

        manager.addMap(map1)
        manager.addMap(map2)

        XCTAssertEqual(manager.maps.count, 2)

        manager.clearAllMaps()

        XCTAssertEqual(manager.maps.count, 0)
    }

    // MARK: - Helper Methods

    private func createMockNetworkRequest() -> NetworkRequest {
        NetworkRequest(
            id: UUID(),
            url: "https://api.example.com/test",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.5,
            requestHeaders: [],
            responseHeaders: [],
            requestBody: .empty,
            responseBody: .empty
        )
    }
}
