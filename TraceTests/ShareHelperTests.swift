//
//  ShareHelperTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
import UIKit
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class ShareHelperTests: XCTestCase {
    var tempFiles: [URL] = []

    override func tearDown() {
        // Clean up temporary files
        for fileURL in tempFiles {
            try? FileManager.default.removeItem(at: fileURL)
        }
        tempFiles.removeAll()
        super.tearDown()
    }

    // MARK: - Share Items for Request Tests

    func testShareItems_ForRequest_WithoutFullDetails() {
        // Given
        let request = createTestRequest()

        // When
        let items = ShareHelper.shareItems(for: request, includeFullDetails: false)

        // Then
        XCTAssertEqual(items.count, 1) // Only cURL command
        if let curlCommand = items.first as? String {
            XCTAssertTrue(curlCommand.hasPrefix("curl"))
        } else {
            XCTFail("First item should be cURL command string")
        }
    }

    func testShareItems_ForRequest_WithFullDetails() {
        // Given
        let request = createTestRequest()

        // When
        let items = ShareHelper.shareItems(for: request, includeFullDetails: true)

        // Then
        XCTAssertEqual(items.count, 2) // Detailed text + cURL command
        if let detailedText = items.first as? String {
            XCTAssertTrue(detailedText.contains("Network Request"))
            XCTAssertTrue(detailedText.contains(request.url))
        }
    }

    // MARK: - Temporary File Creation Tests

    func testCreateTemporaryFile_WithValidContent() {
        // Given
        let content = "Test content"
        let fileName = "test.txt"

        // When
        guard let fileURL = ShareHelper.createTemporaryFile(content: content, fileName: fileName) else {
            XCTFail("Failed to create temporary file")
            return
        }
        tempFiles.append(fileURL)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let readContent = try? String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    func testCreateTemporaryFile_WithEmptyContent() {
        // Given
        let content = ""
        let fileName = "empty.txt"

        // When
        guard let fileURL = ShareHelper.createTemporaryFile(content: content, fileName: fileName) else {
            XCTFail("Failed to create temporary file")
            return
        }
        tempFiles.append(fileURL)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let readContent = try? String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(readContent, "")
    }

    func testCreateTemporaryFile_WithLargeContent() {
        // Given
        let content = String(repeating: "A", count: 100000)
        let fileName = "large.txt"

        // When
        guard let fileURL = ShareHelper.createTemporaryFile(content: content, fileName: fileName) else {
            XCTFail("Failed to create temporary file")
            return
        }
        tempFiles.append(fileURL)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCreateTemporaryFile_WithBinaryData() {
        // Given
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG header
        let fileName = "test.jpg"

        // When
        guard let fileURL = ShareHelper.createTemporaryFile(data: data, fileName: fileName) else {
            XCTFail("Failed to create temporary file")
            return
        }
        tempFiles.append(fileURL)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let readData = try? Data(contentsOf: fileURL)
        XCTAssertEqual(readData, data)
    }

    // MARK: - Share Items for CSV Tests

    func testShareItemsForCSV_WithValidContent() {
        // Given
        let csvContent = "Name,Age,City\nJohn,30,NYC\nJane,25,LA"
        let fileName = "data.csv"

        // When
        let items = ShareHelper.shareItemsForCSV(content: csvContent, fileName: fileName)

        // Then
        XCTAssertEqual(items.count, 1)
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testShareItemsForCSV_WithEmptyContent() {
        // Given
        let csvContent = ""

        // When
        let items = ShareHelper.shareItemsForCSV(content: csvContent, fileName: nil)

        // Then
        XCTAssertEqual(items.count, 1)
        if let content = items.first as? String {
            XCTAssertEqual(content, ShareHelper.fallbackShareMessage)
        }
    }

    func testShareItemsForCSV_WithDefaultFileName() {
        // Given
        let csvContent = "A,B,C"

        // When
        let items = ShareHelper.shareItemsForCSV(content: csvContent, fileName: nil)

        // Then
        XCTAssertEqual(items.count, 1)
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertTrue(fileURL.pathExtension == "csv")
        }
    }

    // MARK: - Share Items for JSON Tests

    func testShareItemsForJSON_WithValidContent() {
        // Given
        let jsonContent = "{\"name\": \"John\", \"age\": 30}"
        let fileName = "data.json"

        // When
        let items = ShareHelper.shareItemsForJSON(content: jsonContent, fileName: fileName)

        // Then
        XCTAssertEqual(items.count, 1)
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertEqual(fileURL.pathExtension, "json")
        }
    }

    func testShareItemsForJSON_WithEmptyContent() {
        // Given
        let jsonContent = ""

        // When
        let items = ShareHelper.shareItemsForJSON(content: jsonContent, fileName: nil)

        // Then
        XCTAssertEqual(items.count, 1)
        if let content = items.first as? String {
            XCTAssertEqual(content, ShareHelper.fallbackShareMessage)
        }
    }

    // MARK: - Share Items for Text Tests

    func testShareItemsForText_WithFileName() {
        // Given
        let textContent = "Hello, World!"
        let fileName = "hello.txt"

        // When
        let items = ShareHelper.shareItemsForText(content: textContent, fileName: fileName)

        // Then
        XCTAssertEqual(items.count, 1)
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testShareItemsForText_WithoutFileName() {
        // Given
        let textContent = "Hello, World!"

        // When
        let items = ShareHelper.shareItemsForText(content: textContent, fileName: nil)

        // Then
        XCTAssertEqual(items.count, 1)
        if let content = items.first as? String {
            XCTAssertEqual(content, textContent)
        }
    }

    func testShareItemsForText_WithEmptyContent() {
        // Given
        let textContent = ""

        // When
        let items = ShareHelper.shareItemsForText(content: textContent, fileName: nil)

        // Then
        XCTAssertEqual(items.count, 1)
        if let content = items.first as? String {
            XCTAssertEqual(content, ShareHelper.fallbackShareMessage)
        }
    }

    // MARK: - Share Items for Binary Tests

    func testShareItemsForBinary_WithValidData() {
        // Given
        let binaryData = Data([1, 2, 3, 4, 5])
        let fileName = "data.bin"

        // When
        let items = ShareHelper.shareItemsForBinary(data: binaryData, fileName: fileName)

        // Then
        XCTAssertEqual(items.count, 1)
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testShareItemsForBinary_WithEmptyData() {
        // Given
        let binaryData = Data()
        let fileName = "empty.bin"

        // When
        let items = ShareHelper.shareItemsForBinary(data: binaryData, fileName: fileName)

        // Then
        XCTAssertEqual(items.count, 1)
        if let content = items.first as? String {
            XCTAssertEqual(content, ShareHelper.fallbackShareMessage)
        }
    }

    // MARK: - File Extension Tests

    func testFileExtension_ForJSON() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "application/json")

        // Then
        XCTAssertEqual(ext, "json")
    }

    func testFileExtension_ForHTML() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "text/html")

        // Then
        XCTAssertEqual(ext, "html")
    }

    func testFileExtension_ForXML() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "application/xml")

        // Then
        XCTAssertEqual(ext, "xml")
    }

    func testFileExtension_ForJavaScript() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "application/javascript")

        // Then
        XCTAssertEqual(ext, "js")
    }

    func testFileExtension_ForCSS() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "text/css")

        // Then
        XCTAssertEqual(ext, "css")
    }

    func testFileExtension_ForCSV() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "text/csv")

        // Then
        XCTAssertEqual(ext, "csv")
    }

    func testFileExtension_ForPDF() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "application/pdf")

        // Then
        XCTAssertEqual(ext, "pdf")
    }

    func testFileExtension_ForPNG() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "image/png")

        // Then
        XCTAssertEqual(ext, "png")
    }

    func testFileExtension_ForJPEG() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "image/jpeg")

        // Then
        XCTAssertEqual(ext, "jpg")
    }

    func testFileExtension_ForZip() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "application/zip")

        // Then
        XCTAssertEqual(ext, "zip")
    }

    func testFileExtension_ForUnknownType() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: "application/unknown")

        // Then
        XCTAssertEqual(ext, "txt")
    }

    func testFileExtension_ForNilType() {
        // Given/When
        let ext = ShareHelper.fileExtension(for: nil)

        // Then
        XCTAssertEqual(ext, "txt")
    }

    // MARK: - Generate File Name Tests

    func testGenerateFileName_WithURL() {
        // Given
        let url = "https://example.com/data.json"
        let contentType = "application/json"
        let timestamp = Date()

        // When
        let fileName = ShareHelper.generateFileName(
            url: url,
            contentType: contentType,
            timestamp: timestamp
        )

        // Then
        XCTAssertEqual(fileName, "data.json")
    }

    func testGenerateFileName_WithoutExtension() {
        // Given
        let url = "https://example.com/api"
        let contentType = "application/json"
        let timestamp = Date()

        // When
        let fileName = ShareHelper.generateFileName(
            url: url,
            contentType: contentType,
            timestamp: timestamp
        )

        // Then
        XCTAssertTrue(fileName.hasSuffix(".json"))
    }

    func testGenerateFileName_WithPrefix() {
        // Given
        let url = "https://example.com/api"
        let contentType = "application/json"
        let timestamp = Date()

        // When
        let fileName = ShareHelper.generateFileName(
            url: url,
            contentType: contentType,
            timestamp: timestamp,
            prefix: "request"
        )

        // Then
        XCTAssertTrue(fileName.hasPrefix("request_"))
        XCTAssertTrue(fileName.hasSuffix(".json"))
    }

    // MARK: - Format Request for Sharing Tests

    func testFormatRequestForSharing_IncludesBasicInfo() {
        // Given
        let request = createTestRequest()

        // When
        let formatted = ShareHelper.formatRequestForSharing(request)

        // Then
        XCTAssertTrue(formatted.contains("Network Request"))
        XCTAssertTrue(formatted.contains("URL: \(request.url)"))
        XCTAssertTrue(formatted.contains("Method: \(request.method.rawValue)"))
    }

    func testFormatRequestForSharing_IncludesHeaders() {
        // Given
        var request = createTestRequest()
        request.requestHeaders = [
            HTTPHeader(key: "Content-Type", value: "application/json"),
            HTTPHeader(key: "Authorization", value: "Bearer token")
        ]

        // When
        let formatted = ShareHelper.formatRequestForSharing(request)

        // Then
        XCTAssertTrue(formatted.contains("Request Headers:"))
        XCTAssertTrue(formatted.contains("Content-Type: application/json"))
        XCTAssertTrue(formatted.contains("Authorization: Bearer token"))
    }

    func testFormatRequestForSharing_WithEmptyRequestBody() {
        // Given
        let request = createTestRequest()

        // When
        let formatted = ShareHelper.formatRequestForSharing(request)

        // Then
        XCTAssertFalse(formatted.contains("Request Body:"))
    }

    func testFormatRequestForSharing_WithTextRequestBody() {
        // Given
        var request = createTestRequest()
        request.requestBody = .text("Test body content")

        // When
        let formatted = ShareHelper.formatRequestForSharing(request)

        // Then
        XCTAssertTrue(formatted.contains("Request Body:"))
        XCTAssertTrue(formatted.contains("Test body content"))
    }

    func testFormatRequestForSharing_WithResponseHeaders() {
        // Given
        var request = createTestRequest()
        request.responseHeaders = [
            HTTPHeader(key: "Content-Type", value: "text/html"),
            HTTPHeader(key: "Cache-Control", value: "no-cache")
        ]

        // When
        let formatted = ShareHelper.formatRequestForSharing(request)

        // Then
        XCTAssertTrue(formatted.contains("Response Headers:"))
        XCTAssertTrue(formatted.contains("Content-Type: text/html"))
    }

    // MARK: - Generate cURL Command Tests

    func testGenerateCurlCommand_BasicRequest() {
        // Given
        let request = createTestRequest()

        // When
        let curlCommand = ShareHelper.generateCurlCommand(request)

        // Then
        XCTAssertTrue(curlCommand.hasPrefix("curl"))
        XCTAssertTrue(curlCommand.contains(request.url))
        XCTAssertTrue(curlCommand.contains("-X \(request.method.rawValue)"))
    }

    // MARK: - Sanitized File Name Tests

    func testSanitizedFileName_WithColons() {
        // Given
        let fileName = "file:name:with:colons.txt"

        // When
        let items = ShareHelper.shareItemsForText(content: "test", fileName: fileName)

        // Then
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertFalse(fileURL.lastPathComponent.contains(":"))
        }
    }

    func testSanitizedFileName_WithSlashes() {
        // Given
        let fileName = "file/name/with/slashes.txt"

        // When
        let items = ShareHelper.shareItemsForText(content: "test", fileName: fileName)

        // Then
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertFalse(fileURL.lastPathComponent.contains("/"))
        }
    }

    func testSanitizedFileName_WithWhitespace() {
        // Given
        let fileName = "  file name with spaces  .txt"

        // When
        let items = ShareHelper.shareItemsForText(content: "test", fileName: fileName)

        // Then
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            let name = fileURL.lastPathComponent
            XCTAssertFalse(name.hasPrefix(" "))
            XCTAssertFalse(name.hasSuffix(" "))
        }
    }

    func testSanitizedFileName_WithEmptyString() {
        // Given
        let fileName = ""

        // When
        let items = ShareHelper.shareItemsForText(content: "test", fileName: fileName)

        // Then
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertTrue(fileURL.lastPathComponent.hasPrefix("export_"))
        }
    }

    // MARK: - Share Items for Response Body Tests

    func testShareItemsForResponseBody_WithJSONContent() {
        // Given
        var request = createTestRequest()
        request.responseHeaders = [HTTPHeader(key: "Content-Type", value: "application/json")]
        request.responseBody = .text("{\"key\": \"value\"}")

        // When
        let items = ShareHelper.shareItemsForResponseBody(from: request)

        // Then
        XCTAssertEqual(items.count, 1)
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertEqual(fileURL.pathExtension, "json")
        }
    }

    func testShareItemsForResponseBody_WithHTMLContent() {
        // Given
        var request = createTestRequest()
        request.responseHeaders = [HTTPHeader(key: "Content-Type", value: "text/html")]
        request.responseBody = .text("<html></html>")

        // When
        let items = ShareHelper.shareItemsForResponseBody(from: request)

        // Then
        XCTAssertEqual(items.count, 1)
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertEqual(fileURL.pathExtension, "html")
        }
    }

    func testShareItemsForResponseBody_WithEmptyBody() {
        // Given
        let request = createTestRequest()

        // When
        let items = ShareHelper.shareItemsForResponseBody(from: request)

        // Then
        XCTAssertEqual(items.count, 1)
        if let message = items.first as? String {
            XCTAssertEqual(message, "Response body is empty")
        }
    }

    func testShareItemsForResponseBody_WithBinaryContent() {
        // Given
        var request = createTestRequest()
        request.responseHeaders = [HTTPHeader(key: "Content-Type", value: "image/png")]
        request.responseBody = .data(Data([0x89, 0x50, 0x4E, 0x47])) // PNG header
        request.isBinary = true

        // When
        let items = ShareHelper.shareItemsForResponseBody(from: request)

        // Then
        XCTAssertEqual(items.count, 1)
    }

    // MARK: - Share Items for Request Body Tests

    func testShareItemsForRequestBody_WithJSONContent() {
        // Given
        var request = createTestRequest()
        request.requestHeaders = [HTTPHeader(key: "Content-Type", value: "application/json")]
        request.requestBody = .text("{\"data\": \"test\"}")

        // When
        let items = ShareHelper.shareItemsForRequestBody(from: request)

        // Then
        XCTAssertEqual(items.count, 1)
        if let fileURL = items.first as? URL {
            tempFiles.append(fileURL)
            XCTAssertEqual(fileURL.pathExtension, "json")
        }
    }

    func testShareItemsForRequestBody_WithEmptyBody() {
        // Given
        let request = createTestRequest()

        // When
        let items = ShareHelper.shareItemsForRequestBody(from: request)

        // Then
        XCTAssertEqual(items.count, 1)
        if let message = items.first as? String {
            XCTAssertEqual(message, "Request body is empty")
        }
    }

    // MARK: - Temporary File Copy Tests

    func testCreateTemporaryFileCopy_WithValidFile() {
        // Given
        let sourceContent = "Source file content"
        let sourceFileName = "source.txt"
        guard let sourceURL = ShareHelper.createTemporaryFile(content: sourceContent, fileName: sourceFileName) else {
            XCTFail("Failed to create source file")
            return
        }
        tempFiles.append(sourceURL)

        // When
        guard let destURL = ShareHelper.createTemporaryFileCopy(from: sourceURL, fileName: "dest.txt") else {
            XCTFail("Failed to copy file")
            return
        }
        tempFiles.append(destURL)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        let copiedContent = try? String(contentsOf: destURL, encoding: .utf8)
        XCTAssertEqual(copiedContent, sourceContent)
    }

    func testCreateTemporaryFileCopy_OverwritesExisting() {
        // Given
        let sourceContent = "New content"
        let fileName = "overwrite.txt"

        guard let sourceURL = ShareHelper.createTemporaryFile(content: sourceContent, fileName: "source.txt") else {
            XCTFail("Failed to create source file")
            return
        }
        tempFiles.append(sourceURL)

        // Create existing destination file
        guard let existingURL = ShareHelper.createTemporaryFile(content: "Old content", fileName: fileName) else {
            XCTFail("Failed to create existing file")
            return
        }
        tempFiles.append(existingURL)

        // When - Copy should overwrite
        guard let copiedURL = ShareHelper.createTemporaryFileCopy(from: sourceURL, fileName: fileName) else {
            XCTFail("Failed to copy file")
            return
        }
        tempFiles.append(copiedURL)

        // Then
        let content = try? String(contentsOf: copiedURL, encoding: .utf8)
        XCTAssertEqual(content, sourceContent)
    }

    // MARK: - Edge Cases

    func testFallbackShareMessage_Value() {
        // Given/When
        let message = ShareHelper.fallbackShareMessage

        // Then
        XCTAssertEqual(message, "Nothing to share")
    }

    func testCreateTemporaryFile_WithSpecialCharacters() {
        // Given
        let content = "Test with special chars: \u{1F680} 中文 العربية"
        let fileName = "special.txt"

        // When
        guard let fileURL = ShareHelper.createTemporaryFile(content: content, fileName: fileName) else {
            XCTFail("Failed to create file")
            return
        }
        tempFiles.append(fileURL)

        // Then
        let readContent = try? String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(readContent, content)
    }

    func testFileExtension_CaseInsensitive() {
        // Given/When
        let ext1 = ShareHelper.fileExtension(for: "APPLICATION/JSON")
        let ext2 = ShareHelper.fileExtension(for: "application/json")

        // Then
        XCTAssertEqual(ext1, "json")
        XCTAssertEqual(ext2, "json")
    }

    // MARK: - Helper Methods

    private func createTestRequest() -> NetworkRequest {
        return NetworkRequest(
            id: UUID(),
            url: "https://example.com/api",
            method: .GET,
            timestamp: Date()
        )
    }
}
