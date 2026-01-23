//
//  HARExporterTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class HARExporterTests: XCTestCase {

    // MARK: - Export Tests

    func testExportEmptyRequests() {
        let data = HARExporter.export(requests: [])

        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data!.count, 0)
    }

    func testExportSingleRequest() {
        let request = createMockRequest()
        let data = HARExporter.export(requests: [request])

        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data!.count, 0)
    }

    func testExportMultipleRequests() {
        let requests = [
            createMockRequest(url: "https://example.com/1"),
            createMockRequest(url: "https://example.com/2"),
            createMockRequest(url: "https://example.com/3")
        ]

        let data = HARExporter.export(requests: requests)

        XCTAssertNotNil(data)
    }

    func testExportAsString() {
        let request = createMockRequest()
        let string = HARExporter.exportAsString(requests: [request])

        XCTAssertNotNil(string)
        XCTAssertTrue(string!.contains("log"))
        XCTAssertTrue(string!.contains("entries"))
    }

    func testExportToFile() throws {
        let request = createMockRequest()
        let fileURL = try HARExporter.exportToFile(requests: [request])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.lastPathComponent.hasSuffix(".har"))

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testExportToFileWithCustomFilename() throws {
        let request = createMockRequest()
        let filename = "custom-export.har"
        let fileURL = try HARExporter.exportToFile(requests: [request], filename: filename)

        XCTAssertTrue(fileURL.lastPathComponent == filename)

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Import Tests

    func testImportFromData() throws {
        let originalRequest = createMockRequest()
        let exportData = HARExporter.export(requests: [originalRequest])!

        let importedRequests = try HARExporter.import(from: exportData)

        XCTAssertEqual(importedRequests.count, 1)
        XCTAssertEqual(importedRequests.first?.url, originalRequest.url)
        XCTAssertEqual(importedRequests.first?.method, originalRequest.method)
    }

    func testImportMultipleRequests() throws {
        let originalRequests = [
            createMockRequest(url: "https://example.com/1", method: .get),
            createMockRequest(url: "https://example.com/2", method: .post),
            createMockRequest(url: "https://example.com/3", method: .put)
        ]

        let exportData = HARExporter.export(requests: originalRequests)!
        let importedRequests = try HARExporter.import(from: exportData)

        XCTAssertEqual(importedRequests.count, 3)
    }

    func testImportFromFile() throws {
        let request = createMockRequest()
        let fileURL = try HARExporter.exportToFile(requests: [request])

        let importedRequests = try HARExporter.importFromFile(fileURL)

        XCTAssertEqual(importedRequests.count, 1)

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testImportFromString() throws {
        let request = createMockRequest()
        let harString = HARExporter.exportAsString(requests: [request])!

        let importedRequests = try HARExporter.importFromString(harString)

        XCTAssertEqual(importedRequests.count, 1)
    }

    func testImportInvalidString() {
        let invalidString = "not valid json"

        do {
            _ = try HARExporter.importFromString(invalidString)
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected error
        }
    }

    // MARK: - Round Trip Tests

    func testRoundTripExportImport() throws {
        let originalRequest = createMockRequest(
            url: "https://api.example.com/users",
            method: .post,
            statusCode: 201
        )

        // Export
        let exportData = HARExporter.export(requests: [originalRequest])!

        // Import
        let importedRequests = try HARExporter.import(from: exportData)

        XCTAssertEqual(importedRequests.count, 1)

        let imported = importedRequests.first!
        XCTAssertEqual(imported.url, originalRequest.url)
        XCTAssertEqual(imported.method, originalRequest.method)
        XCTAssertEqual(imported.statusCode, originalRequest.statusCode)
    }

    func testRoundTripPreservesHeaders() throws {
        let request = createMockRequest()

        let exportData = HARExporter.export(requests: [request])!
        let importedRequests = try HARExporter.import(from: exportData)

        let imported = importedRequests.first!
        XCTAssertGreaterThan(imported.requestHeaders.count, 0)
        XCTAssertGreaterThan(imported.responseHeaders.count, 0)
    }

    func testRoundTripPreservesBody() throws {
        let bodyContent = "{\"test\": \"data\"}"
        var request = createMockRequest()
        request.requestBody = BodyStorage.from(string: bodyContent)

        let exportData = HARExporter.export(requests: [request])!
        let importedRequests = try HARExporter.import(from: exportData)

        let imported = importedRequests.first!
        XCTAssertEqual(imported.requestBody.getString(), bodyContent)
    }

    // MARK: - HAR Model Tests

    func testHARStructure() throws {
        let request = createMockRequest()
        let data = HARExporter.export(requests: [request])!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let har = try decoder.decode(HAR.self, from: data)

        XCTAssertEqual(har.log.version, "1.2")
        XCTAssertEqual(har.log.creator.name, "Trace")
        XCTAssertEqual(har.log.entries.count, 1)
    }

    func testHAREntryStructure() throws {
        let request = createMockRequest()
        let data = HARExporter.export(requests: [request])!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let har = try decoder.decode(HAR.self, from: data)
        let entry = har.log.entries.first!

        XCTAssertGreaterThan(entry.time, 0)
        XCTAssertNotNil(entry.request)
        XCTAssertNotNil(entry.response)
        XCTAssertNotNil(entry.timings)
    }

    func testHARRequestStructure() throws {
        let request = createMockRequest()
        let data = HARExporter.export(requests: [request])!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let har = try decoder.decode(HAR.self, from: data)
        let harRequest = har.log.entries.first!.request

        XCTAssertEqual(harRequest.method, request.method.rawValue)
        XCTAssertEqual(harRequest.url, request.url)
        XCTAssertEqual(harRequest.httpVersion, "HTTP/1.1")
    }

    func testHARResponseStructure() throws {
        let request = createMockRequest()
        let data = HARExporter.export(requests: [request])!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let har = try decoder.decode(HAR.self, from: data)
        let harResponse = har.log.entries.first!.response

        XCTAssertEqual(harResponse.status, request.statusCode)
        XCTAssertEqual(harResponse.httpVersion, "HTTP/1.1")
    }

    // MARK: - Error Tests

    func testHARErrorDescriptions() {
        let exportError = HARError.exportFailed("test")
        XCTAssertNotNil(exportError.errorDescription)
        XCTAssertTrue(exportError.errorDescription!.contains("export"))

        let importError = HARError.importFailed("test")
        XCTAssertNotNil(importError.errorDescription)
        XCTAssertTrue(importError.errorDescription!.contains("import"))
    }

    // MARK: - Query String Tests

    func testExportWithQueryString() throws {
        let request = createMockRequest(url: "https://example.com/api?key=value&foo=bar")

        let data = HARExporter.export(requests: [request])!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let har = try decoder.decode(HAR.self, from: data)

        let queryString = har.log.entries.first!.request.queryString
        XCTAssertEqual(queryString.count, 2)
        XCTAssertTrue(queryString.contains { $0.name == "key" && $0.value == "value" })
        XCTAssertTrue(queryString.contains { $0.name == "foo" && $0.value == "bar" })
    }

    // MARK: - Content Type Tests

    func testExportExtractsContentType() throws {
        var request = createMockRequest()
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ]

        let data = HARExporter.export(requests: [request])!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let har = try decoder.decode(HAR.self, from: data)

        let content = har.log.entries.first!.response.content
        XCTAssertEqual(content.mimeType, "application/json")
    }

    // MARK: - Helper Methods

    private func createMockRequest(
        url: String = "https://example.com",
        method: HTTPMethod = .get,
        statusCode: Int = 200
    ) -> NetworkRequest {
        return NetworkRequest(
            url: url,
            method: method,
            statusCode: statusCode,
            timestamp: Date(),
            duration: 0.5,
            requestHeaders: [
                TraceHTTPHeader(key: "Content-Type", value: "application/json"),
                TraceHTTPHeader(key: "User-Agent", value: "Trace/1.0")
            ],
            responseHeaders: [
                TraceHTTPHeader(key: "Content-Type", value: "application/json"),
                TraceHTTPHeader(key: "Server", value: "nginx")
            ],
            requestBody: .empty,
            responseBody: BodyStorage.from(string: "{\"status\": \"ok\"}")
        )
    }
}
