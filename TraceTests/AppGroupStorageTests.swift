//
//  AppGroupStorageTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class AppGroupStorageTests: XCTestCase {

    var storage: AppGroupStorage!
    var testRequestID: UUID!

    override func setUp() {
        super.setUp()
        storage = AppGroupStorage.shared
        testRequestID = UUID()

        // Clean up any existing test data
        try? storage.clearAllRequests()
    }

    override func tearDown() {
        // Clean up test data
        try? storage.clearAllRequests()
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let storage1 = AppGroupStorage.shared
        let storage2 = AppGroupStorage.shared

        XCTAssertTrue(storage1 === storage2, "AppGroupStorage should be a singleton")
    }

    // MARK: - Container URL Tests

    func testContainerURLExists() {
        XCTAssertNotNil(storage.containerURL, "Container URL should exist")
    }

    func testContainerURLIsDirectory() {
        guard let containerURL = storage.containerURL else {
            XCTFail("Container URL should exist")
            return
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: containerURL.path, isDirectory: &isDirectory)

        XCTAssertTrue(exists, "Container path should exist")
        XCTAssertTrue(isDirectory.boolValue, "Container path should be a directory")
    }

    // MARK: - Request Storage Tests

    func testSaveRequest() throws {
        let request = createMockRequest()

        XCTAssertNoThrow(try storage.saveRequest(request))
    }

    func testLoadAllRequests() throws {
        // Save multiple requests
        let request1 = createMockRequest(url: "https://example.com/1")
        let request2 = createMockRequest(url: "https://example.com/2")

        try storage.saveRequest(request1)
        try storage.saveRequest(request2)

        // Load all requests
        let loaded = try storage.loadAllRequests()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains { $0.url == "https://example.com/1" })
        XCTAssertTrue(loaded.contains { $0.url == "https://example.com/2" })
    }

    func testLoadAllRequestsSorting() throws {
        // Create requests with different timestamps
        let oldRequest = createMockRequest(
            url: "https://example.com/old",
            timestamp: Date(timeIntervalSinceNow: -3600)
        )
        let recentRequest = createMockRequest(
            url: "https://example.com/recent",
            timestamp: Date()
        )

        try storage.saveRequest(oldRequest)
        try storage.saveRequest(recentRequest)

        let loaded = try storage.loadAllRequests()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.url, "https://example.com/recent", "Most recent request should be first")
        XCTAssertEqual(loaded.last?.url, "https://example.com/old", "Oldest request should be last")
    }

    func testDeleteRequest() throws {
        let request = createMockRequest()
        try storage.saveRequest(request)

        // Verify it was saved
        var loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 1)

        // Delete it
        try storage.deleteRequest(request.id)

        // Verify it was deleted
        loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 0)
    }

    func testDeleteRequestConvenience() throws {
        let request = createMockRequest()
        try storage.saveRequest(request)

        // Delete using convenience method
        try storage.deleteRequest(request)

        // Verify it was deleted
        let loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 0)
    }

    func testClearAllRequests() throws {
        // Save multiple requests
        try storage.saveRequest(createMockRequest(url: "https://example.com/1"))
        try storage.saveRequest(createMockRequest(url: "https://example.com/2"))
        try storage.saveRequest(createMockRequest(url: "https://example.com/3"))

        // Verify they were saved
        var loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 3)

        // Clear all
        try storage.clearAllRequests()

        // Verify all were deleted
        loaded = try storage.loadAllRequests()
        XCTAssertEqual(loaded.count, 0)
    }

    // MARK: - Configuration Tests

    func testSaveAndLoadConfiguration() throws {
        let config = CaptureConfiguration(
            isEnabled: true,
            filterMode: .whitelist,
            domainFilters: ["example.com", "test.com"],
            captureHeaders: true,
            captureBody: false,
            maxBodySize: 2048,
            captureMode: .proxyOnly,
            fullTunnelDNSServers: ["1.1.1.1"],
            fullTunnelSearchDomains: ["example.local"],
            fullTunnelIPv6Enabled: false,
            fullTunnelSocks5Host: "127.0.0.1",
            fullTunnelSocks5Port: 1080,
            fullTunnelUDPForwardingMode: .split
        )

        try storage.saveConfiguration(config)

        let loaded = storage.loadConfiguration()

        XCTAssertEqual(loaded.isEnabled, config.isEnabled)
        XCTAssertEqual(loaded.filterMode, config.filterMode)
        XCTAssertEqual(loaded.domainFilters, config.domainFilters)
        XCTAssertEqual(loaded.captureHeaders, config.captureHeaders)
        XCTAssertEqual(loaded.captureBody, config.captureBody)
        XCTAssertEqual(loaded.maxBodySize, config.maxBodySize)
        XCTAssertEqual(loaded.captureMode, config.captureMode)
        XCTAssertEqual(loaded.fullTunnelDNSServers, config.fullTunnelDNSServers)
        XCTAssertEqual(loaded.fullTunnelSearchDomains, config.fullTunnelSearchDomains)
        XCTAssertEqual(loaded.fullTunnelIPv6Enabled, config.fullTunnelIPv6Enabled)
        XCTAssertEqual(loaded.fullTunnelSocks5Host, config.fullTunnelSocks5Host)
        XCTAssertEqual(loaded.fullTunnelSocks5Port, config.fullTunnelSocks5Port)
        XCTAssertEqual(loaded.fullTunnelUDPForwardingMode, config.fullTunnelUDPForwardingMode)
    }

    func testLoadConfigurationWithNoFile() {
        // This should return default configuration without throwing
        let config = storage.loadConfiguration()

        XCTAssertNotNil(config)
        XCTAssertEqual(config.isEnabled, CaptureConfiguration.default.isEnabled)
    }

    func testSaveAndLoadThrottlingState() throws {
        let state = NetworkThrottlingState(
            enabled: true,
            condition: .custom(download: 1500, upload: 600, latency: 120, packetLoss: 0.02)
        )

        try storage.saveThrottlingState(state)

        let loaded = storage.loadThrottlingState()

        XCTAssertEqual(loaded.enabled, state.enabled)
        XCTAssertEqual(loaded.condition, state.condition)
    }

    // MARK: - Generic Storage Tests

    func testSaveAndLoadData() throws {
        let testData = "Hello, World!".data(using: .utf8)!
        let fileName = "test-file.txt"

        try storage.saveData(testData, to: fileName)

        let loaded = try storage.loadData(from: fileName)

        XCTAssertEqual(loaded, testData)
    }

    func testLoadDataFileNotFound() {
        do {
            _ = try storage.loadData(from: "nonexistent.txt")
            XCTFail("Expected error to be thrown")
        } catch let storageError as StorageError {
            XCTAssertEqual(storageError, .fileNotFound)
        } catch {
            XCTFail("Expected StorageError, got \(error)")
        }
    }

    // MARK: - Storage Stats Tests

    func testStorageStatsEmpty() {
        try? storage.clearAllRequests()

        let stats = storage.getStorageStats()

        XCTAssertEqual(stats.totalRequests, 0)
        XCTAssertEqual(stats.totalSize, 0)
    }

    func testStorageStatsWithData() throws {
        try storage.saveRequest(createMockRequest())

        let stats = storage.getStorageStats()

        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertGreaterThan(stats.totalSize, 0)
    }

    func testStorageStatsFormattedSize() {
        let stats = StorageStats(totalRequests: 5, totalSize: 1024)

        XCTAssertFalse(stats.formattedSize.isEmpty)
        XCTAssertTrue(stats.formattedSize.contains("KB") || stats.formattedSize.contains("bytes"))
    }

    // MARK: - CaptureConfiguration Tests

    func testCaptureConfigurationDefault() {
        let config = CaptureConfiguration.default

        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.filterMode, .all)
        XCTAssertTrue(config.domainFilters.isEmpty)
        XCTAssertTrue(config.captureHeaders)
        XCTAssertTrue(config.captureBody)
        XCTAssertEqual(config.maxBodySize, 10 * 1024 * 1024)
    }

    func testFilterModeEnum() {
        XCTAssertEqual(FilterMode.all.rawValue, "all")
        XCTAssertEqual(FilterMode.whitelist.rawValue, "whitelist")
        XCTAssertEqual(FilterMode.blacklist.rawValue, "blacklist")
    }

    // MARK: - StorageError Tests

    func testStorageErrorDescriptions() {
        XCTAssertNotNil(StorageError.containerNotFound.errorDescription)
        XCTAssertNotNil(StorageError.encodingFailed.errorDescription)
        XCTAssertNotNil(StorageError.decodingFailed.errorDescription)
        XCTAssertNotNil(StorageError.fileNotFound.errorDescription)
    }

    // MARK: - Helper Methods

    private func createMockRequest(
        url: String = "https://example.com",
        timestamp: Date = Date()
    ) -> NetworkRequest {
        return NetworkRequest(
            url: url,
            method: .get,
            statusCode: 200,
            timestamp: timestamp,
            duration: 0.5,
            requestHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "application/json")],
            requestBody: .empty,
            responseBody: .empty
        )
    }
}
