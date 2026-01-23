//
//  ConfigurationRepositoryTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class ConfigurationRepositoryTests: XCTestCase {
    var sut: ConfigurationRepositoryImpl!
    var mockStorage: MockAppGroupStorage!

    override func setUp() {
        super.setUp()
        mockStorage = MockAppGroupStorage()
        sut = ConfigurationRepositoryImpl(storage: mockStorage)
    }

    override func tearDown() {
        sut = nil
        mockStorage = nil
        super.tearDown()
    }

    // MARK: - Rewrite Rules Tests

    func testGetRewriteRules_LoadsFromStorage() async throws {
        // Given
        let rule = RewriteRule(
            name: "Test Rule",
            ruleType: .modifyRequest,
            matchType: .contains,
            matchPattern: "example.com",
            actions: [.setHeader(key: "Host", value: "test.com")]
        )
        mockStorage.mockRewriteRules = [rule]

        // When
        let rules = try await sut.getRewriteRules()

        // Then
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.name, "Test Rule")
        XCTAssertTrue(mockStorage.loadRewriteRulesCalled)
    }

    func testSaveRewriteRules_SavesToStorage() async throws {
        // Given
        let rules = [
            RewriteRule(
                name: "Rule 1",
                ruleType: .modifyRequest,
                matchType: .contains,
                matchPattern: "example.com",
                actions: [.setHeader(key: "Host", value: "test.com")]
            )
        ]

        // When
        try await sut.saveRewriteRules(rules)

        // Then
        XCTAssertTrue(mockStorage.saveRewriteRulesCalled)
    }

    // MARK: - Request Maps Tests

    func testGetRequestMaps_LoadsFromStorage() async throws {
        // Given
        let map = RequestMap(
            name: "Test Map",
            matchType: .contains,
            matchPattern: "example.com",
            mockResponse: MockResponse(
                statusCode: 200,
                headers: [],
                bodySource: .inline,
                bodyContent: "test".data(using: .utf8),
                delay: 0
            )
        )
        mockStorage.mockRequestMaps = [map]

        // When
        let maps = try await sut.getRequestMaps()

        // Then
        XCTAssertEqual(maps.count, 1)
        XCTAssertTrue(mockStorage.loadRequestMapsCalled)
    }

    func testSaveRequestMaps_SavesToStorage() async throws {
        // Given
        let maps = [
            RequestMap(
                name: "Map 1",
                matchType: .contains,
                matchPattern: "test.com",
                mockResponse: MockResponse(
                    statusCode: 404,
                    headers: [],
                    bodySource: .inline,
                    bodyContent: "Not found".data(using: .utf8),
                    delay: 0
                )
            )
        ]

        // When
        try await sut.saveRequestMaps(maps)

        // Then
        XCTAssertTrue(mockStorage.saveRequestMapsCalled)
    }

    // MARK: - Host Entries Tests

    func testGetHostEntries_LoadsFromStorage() async throws {
        // Given
        let entry = HostEntry(
            name: "Test Entry",
            enabled: true,
            hostname: "example.com",
            targetIP: "127.0.0.1",
            targetPort: nil
        )
        mockStorage.mockHostEntries = [entry]

        // When
        let entries = try await sut.getHostEntries()

        // Then
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.hostname, "example.com")
        XCTAssertTrue(mockStorage.loadHostEntriesCalled)
    }

    func testSaveHostEntries_SavesToStorage() async throws {
        // Given
        let entries = [
            HostEntry(
                name: "Test Entry",
                enabled: true,
                hostname: "test.com",
                targetIP: "192.168.1.1",
                targetPort: 8080
            )
        ]

        // When
        try await sut.saveHostEntries(entries)

        // Then
        XCTAssertTrue(mockStorage.saveHostEntriesCalled)
    }

    // MARK: - Scripts Tests

    func testGetScripts_LoadsFromStorage() async throws {
        // Given
        let script = Script(
            name: "Test Script",
            scriptType: .request,
            matchType: .contains,
            matchPattern: "example.com",
            code: "console.log('test');"
        )
        mockStorage.mockScripts = [script]

        // When
        let scripts = try await sut.getScripts()

        // Then
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts.first?.name, "Test Script")
        XCTAssertTrue(mockStorage.loadScriptsCalled)
    }

    func testSaveScripts_SavesToStorage() async throws {
        // Given
        let scripts = [
            Script(
                name: "Script 1",
                scriptType: .response,
                matchType: .contains,
                matchPattern: "api.example.com",
                code: "return response;"
            )
        ]

        // When
        try await sut.saveScripts(scripts)

        // Then
        XCTAssertTrue(mockStorage.saveScriptsCalled)
    }

    // MARK: - Breakpoints Tests

    func testGetBreakpoints_LoadsFromStorage() async throws {
        // Given
        let breakpoint = Breakpoint(
            name: "Test Breakpoint",
            configuration: BreakpointConfiguration(
                enabled: true,
                breakpointType: .request,
                matchType: .contains,
                matchPattern: "example.com"
            )
        )
        mockStorage.mockBreakpoints = [breakpoint]

        // When
        let breakpoints = try await sut.getBreakpoints()

        // Then
        XCTAssertEqual(breakpoints.count, 1)
        XCTAssertEqual(breakpoints.first?.name, "Test Breakpoint")
        XCTAssertTrue(mockStorage.loadBreakpointsCalled)
    }

    func testSaveBreakpoints_SavesToStorage() async throws {
        // Given
        let breakpoints = [
            Breakpoint(
                name: "BP 1",
                configuration: BreakpointConfiguration(
                    enabled: true,
                    breakpointType: .response,
                    matchType: .contains,
                    matchPattern: "test.com"
                )
            )
        ]

        // When
        try await sut.saveBreakpoints(breakpoints)

        // Then
        XCTAssertTrue(mockStorage.saveBreakpointsCalled)
    }

    // MARK: - Favorites Tests

    func testGetFavorites_LoadsFromStorage() async throws {
        // Given
        let favorite = Favorite(
            requestId: UUID(),
            name: "Test Favorite",
            notes: "Test notes"
        )
        mockStorage.mockFavorites = [favorite]

        // When
        let favorites = try await sut.getFavorites()

        // Then
        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(favorites.first?.name, "Test Favorite")
        XCTAssertTrue(mockStorage.loadFavoritesCalled)
    }

    func testSaveFavorites_SavesToStorage() async throws {
        // Given
        let favorites = [
            Favorite(
                requestId: UUID(),
                name: "Fav 1",
                notes: nil
            )
        ]

        // When
        try await sut.saveFavorites(favorites)

        // Then
        XCTAssertTrue(mockStorage.saveFavoritesCalled)
    }
}

// MARK: - Mock AppGroupStorage

class MockAppGroupStorage: AppGroupStorage {
    override init() {
        super.init()
    }

    var mockRewriteRules: [RewriteRule] = []
    var mockRequestMaps: [RequestMap] = []
    var mockHostEntries: [HostEntry] = []
    var mockScripts: [Script] = []
    var mockBreakpoints: [Breakpoint] = []
    var mockFavorites: [Favorite] = []

    var loadRewriteRulesCalled = false
    var saveRewriteRulesCalled = false
    var loadRequestMapsCalled = false
    var saveRequestMapsCalled = false
    var loadHostEntriesCalled = false
    var saveHostEntriesCalled = false
    var loadScriptsCalled = false
    var saveScriptsCalled = false
    var loadBreakpointsCalled = false
    var saveBreakpointsCalled = false
    var loadFavoritesCalled = false
    var saveFavoritesCalled = false

    override func loadRewriteRules() async throws -> [RewriteRule] {
        loadRewriteRulesCalled = true
        return mockRewriteRules
    }

    override func saveRewriteRules(_ rules: [RewriteRule]) async throws {
        saveRewriteRulesCalled = true
        mockRewriteRules = rules
    }

    override func loadRequestMaps() async throws -> [RequestMap] {
        loadRequestMapsCalled = true
        return mockRequestMaps
    }

    override func saveRequestMaps(_ maps: [RequestMap]) async throws {
        saveRequestMapsCalled = true
        mockRequestMaps = maps
    }

    override func loadHostEntries() async throws -> [HostEntry] {
        loadHostEntriesCalled = true
        return mockHostEntries
    }

    override func saveHostEntries(_ entries: [HostEntry]) async throws {
        saveHostEntriesCalled = true
        mockHostEntries = entries
    }

    override func loadScripts() async throws -> [Script] {
        loadScriptsCalled = true
        return mockScripts
    }

    override func saveScripts(_ scripts: [Script]) async throws {
        saveScriptsCalled = true
        mockScripts = scripts
    }

    override func loadBreakpoints() async throws -> [Breakpoint] {
        loadBreakpointsCalled = true
        return mockBreakpoints
    }

    override func saveBreakpoints(_ breakpoints: [Breakpoint]) async throws {
        saveBreakpointsCalled = true
        mockBreakpoints = breakpoints
    }

    override func loadFavorites() async throws -> [Favorite] {
        loadFavoritesCalled = true
        return mockFavorites
    }

    override func saveFavorites(_ favorites: [Favorite]) async throws {
        saveFavoritesCalled = true
        mockFavorites = favorites
    }
}
