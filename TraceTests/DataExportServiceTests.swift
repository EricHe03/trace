//
//  DataExportServiceTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class DataExportServiceTests: XCTestCase {
    var sut: DataExportService!

    override func setUp() {
        super.setUp()
        sut = DataExportService()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Export to HAR Tests

    func testExportToHAR_WithValidRequests_CreatesHARFile() async throws {
        // Given
        let request = createMockNetworkRequest()
        let requests = [request]

        // When
        let result = try await sut.exportToHAR(requests: requests)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertTrue(result.path.contains("trace-export-"))
        XCTAssertTrue(result.pathExtension == "har")

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    func testExportToHAR_WithEmptyRequests_CreatesHARFile() async throws {
        // Given
        let requests: [NetworkRequest] = []

        // When
        let result = try await sut.exportToHAR(requests: requests)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    func testExportToHAR_WithMultipleRequests_CreatesHARFile() async throws {
        // Given
        let requests = [
            createMockNetworkRequest(url: "https://example.com/api/1"),
            createMockNetworkRequest(url: "https://example.com/api/2"),
            createMockNetworkRequest(url: "https://example.com/api/3")
        ]

        // When
        let result = try await sut.exportToHAR(requests: requests)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let data = try Data(contentsOf: result)
        XCTAssertFalse(data.isEmpty)

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    // MARK: - Export to CSV Tests

    func testExportToCSV_WithValidRequests_CreatesCSVFile() async throws {
        // Given
        let request = createMockNetworkRequest()
        let requests = [request]

        // When
        let result = try await sut.exportToCSV(requests: requests)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertTrue(result.path.contains("trace-export-"))
        XCTAssertTrue(result.pathExtension == "csv")

        let content = try String(contentsOf: result, encoding: .utf8)
        XCTAssertTrue(content.contains("Timestamp,Method,URL,Status,Duration (ms),Request Size,Response Size"))

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    func testExportToCSV_WithEmptyRequests_CreatesCSVHeaderOnly() async throws {
        // Given
        let requests: [NetworkRequest] = []

        // When
        let result = try await sut.exportToCSV(requests: requests)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))

        let content = try String(contentsOf: result, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2) // Header + empty line

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    func testExportToCSV_WithCommasInURL_EscapesCommas() async throws {
        // Given
        let request = createMockNetworkRequest(url: "https://example.com/api?param1=value1,value2")
        let requests = [request]

        // When
        let result = try await sut.exportToCSV(requests: requests)

        // Then
        let content = try String(contentsOf: result, encoding: .utf8)
        XCTAssertTrue(content.contains("\"https://example.com/api?param1=value1,value2\""))

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    func testExportToCSV_WithMultipleRequests_CreatesCorrectRows() async throws {
        // Given
        let requests = [
            createMockNetworkRequest(url: "https://example.com/api/1", statusCode: 200),
            createMockNetworkRequest(url: "https://example.com/api/2", statusCode: 404),
            createMockNetworkRequest(url: "https://example.com/api/3", statusCode: 500)
        ]

        // When
        let result = try await sut.exportToCSV(requests: requests)

        // Then
        let content = try String(contentsOf: result, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4) // Header + 3 requests

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    // MARK: - Import from HAR Tests

    func testImportFromHAR_WithValidFile_ReturnsRequests() async throws {
        // Given
        let mockRequests = [createMockNetworkRequest()]
        let harData = HARExporter.export(requests: mockRequests)!
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.har")
        try harData.write(to: tempURL)

        // When
        let result = try await sut.importFromHAR(fileURL: tempURL)

        // Then
        XCTAssertFalse(result.isEmpty)

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testImportFromHAR_WithInvalidFile_ThrowsError() async {
        // Given
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("invalid.har")
        try? "invalid json".write(to: tempURL, atomically: true, encoding: .utf8)

        // When/Then
        await XCTAssertThrowsError(try await sut.importFromHAR(fileURL: tempURL))

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Export to cURL Tests

    func testExportToCURL_WithSimpleGETRequest_GeneratesCorrectCommand() {
        // Given
        let request = createMockNetworkRequest(
            url: "https://api.example.com/users",
            method: .get
        )

        // When
        let curl = sut.exportToCURL(request: request)

        // Then
        XCTAssertTrue(curl.contains("curl -X GET"))
        XCTAssertTrue(curl.contains("https://api.example.com/users"))
    }

    func testExportToCURL_WithPOSTRequestAndBody_IncludesBody() {
        // Given
        let bodyData = "{\"name\":\"John\"}".data(using: .utf8)!
        var request = createMockNetworkRequest(
            url: "https://api.example.com/users",
            method: .post
        )
        request.requestBody = .inline(bodyData)

        // When
        let curl = sut.exportToCURL(request: request)

        // Then
        XCTAssertTrue(curl.contains("curl -X POST"))
        XCTAssertTrue(curl.contains("--data-raw"))
        XCTAssertTrue(curl.contains("name"))
        XCTAssertTrue(curl.contains("John"))
    }

    func testExportToCURL_WithHeaders_IncludesAllHeaders() {
        // Given
        var request = createMockNetworkRequest()
        request.requestHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json"),
            TraceHTTPHeader(key: "Authorization", value: "Bearer token123")
        ]

        // When
        let curl = sut.exportToCURL(request: request)

        // Then
        XCTAssertTrue(curl.contains("-H 'Content-Type: application/json'"))
        XCTAssertTrue(curl.contains("-H 'Authorization: Bearer token123'"))
    }

    func testExportToCURL_WithSingleQuotesInBody_EscapesQuotes() {
        // Given
        let bodyData = "{\"name\":\"John's Data\"}".data(using: .utf8)!
        var request = createMockNetworkRequest(method: .post)
        request.requestBody = .inline(bodyData)

        // When
        let curl = sut.exportToCURL(request: request)

        // Then
        XCTAssertTrue(curl.contains("'\\''"))
    }

    // MARK: - Helper Methods

    private func createMockNetworkRequest(
        url: String = "https://api.example.com/test",
        method: HTTPMethod = .get,
        statusCode: Int? = 200
    ) -> NetworkRequest {
        var request = NetworkRequest(
            url: url,
            method: method,
            timestamp: Date(),
            duration: 0.1
        )
        request.statusCode = statusCode
        return request
    }
}
