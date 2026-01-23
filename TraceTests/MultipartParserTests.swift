//
//  MultipartParserTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceFeatures

final class MultipartParserTests: XCTestCase {

    // MARK: - Boundary Extraction Tests

    func testExtractBoundarySimple() {
        let contentType = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW"
        let boundary = MultipartParser.extractBoundary(from: contentType)

        XCTAssertEqual(boundary, "----WebKitFormBoundary7MA4YWxkTrZu0gW")
    }

    func testExtractBoundaryWithQuotes() {
        let contentType = "multipart/form-data; boundary=\"----WebKitFormBoundary7MA4YWxkTrZu0gW\""
        let boundary = MultipartParser.extractBoundary(from: contentType)

        XCTAssertEqual(boundary, "----WebKitFormBoundary7MA4YWxkTrZu0gW")
    }

    func testExtractBoundaryWithCharset() {
        let contentType = "multipart/form-data; charset=utf-8; boundary=MyBoundary123"
        let boundary = MultipartParser.extractBoundary(from: contentType)

        XCTAssertEqual(boundary, "MyBoundary123")
    }

    func testExtractBoundaryNoBoundary() {
        let contentType = "multipart/form-data"
        let boundary = MultipartParser.extractBoundary(from: contentType)

        XCTAssertNil(boundary)
    }

    func testExtractBoundaryInvalidFormat() {
        let contentType = "application/json"
        let boundary = MultipartParser.extractBoundary(from: contentType)

        XCTAssertNil(boundary)
    }

    // MARK: - Single Part Parsing Tests

    func testParseSingleTextPart() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="username"\r
        \r
        john_doe\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].name, "username")
        XCTAssertEqual(parts[0].stringValue, "john_doe")
        XCTAssertNil(parts[0].filename)
        XCTAssertFalse(parts[0].isFile)
    }

    func testParseSingleFilePart() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="avatar"; filename="profile.jpg"\r
        Content-Type: image/jpeg\r
        \r
        [binary image data]\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].name, "avatar")
        XCTAssertEqual(parts[0].filename, "profile.jpg")
        XCTAssertEqual(parts[0].contentType, "image/jpeg")
        XCTAssertTrue(parts[0].isFile)
    }

    // MARK: - Multiple Parts Parsing Tests

    func testParseMultipleParts() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="name"\r
        \r
        John Doe\r
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="email"\r
        \r
        john@example.com\r
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="age"\r
        \r
        30\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].name, "name")
        XCTAssertEqual(parts[0].stringValue, "John Doe")
        XCTAssertEqual(parts[1].name, "email")
        XCTAssertEqual(parts[1].stringValue, "john@example.com")
        XCTAssertEqual(parts[2].name, "age")
        XCTAssertEqual(parts[2].stringValue, "30")
    }

    func testParseMixedTextAndFileParts() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="title"\r
        \r
        My Document\r
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="document"; filename="doc.pdf"\r
        Content-Type: application/pdf\r
        \r
        PDF content here\r
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="category"\r
        \r
        work\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 3)

        // Text part
        XCTAssertEqual(parts[0].name, "title")
        XCTAssertFalse(parts[0].isFile)

        // File part
        XCTAssertEqual(parts[1].name, "document")
        XCTAssertEqual(parts[1].filename, "doc.pdf")
        XCTAssertTrue(parts[1].isFile)

        // Another text part
        XCTAssertEqual(parts[2].name, "category")
        XCTAssertFalse(parts[2].isFile)
    }

    // MARK: - Part Property Tests

    func testPartName() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="fieldname"\r
        \r
        value\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts[0].name, "fieldname")
    }

    func testPartFilename() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="file"; filename="test.txt"\r
        \r
        content\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts[0].filename, "test.txt")
    }

    func testPartContentType() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="file"; filename="data.json"\r
        Content-Type: application/json\r
        \r
        {"key":"value"}\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts[0].contentType, "application/json")
    }

    func testPartStringValue() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="message"\r
        \r
        Hello, World!\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts[0].stringValue, "Hello, World!")
    }

    func testPartIsFile() {
        let boundary = "----WebKitFormBoundary"

        // Part with filename
        let bodyWithFile = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="upload"; filename="file.txt"\r
        \r
        content\r
        ------WebKitFormBoundary--
        """

        let dataWithFile = bodyWithFile.data(using: .utf8)!
        let partsWithFile = MultipartParser.parse(data: dataWithFile, boundary: boundary)
        XCTAssertTrue(partsWithFile[0].isFile)

        // Part without filename
        let bodyWithoutFile = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="text"\r
        \r
        content\r
        ------WebKitFormBoundary--
        """

        let dataWithoutFile = bodyWithoutFile.data(using: .utf8)!
        let partsWithoutFile = MultipartParser.parse(data: dataWithoutFile, boundary: boundary)
        XCTAssertFalse(partsWithoutFile[0].isFile)
    }

    // MARK: - Edge Cases Tests

    func testParseEmptyPart() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="empty"\r
        \r
        \r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].name, "empty")
        XCTAssertEqual(parts[0].stringValue, "")
    }

    func testParseNoBoundaryMatch() {
        let boundary = "----WebKitFormBoundary"
        let body = "No boundary here"

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 0)
    }

    func testParseWithPreamble() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        This is a preamble that should be ignored\r
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="field"\r
        \r
        value\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].name, "field")
    }

    func testParseWithEpilogue() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="field"\r
        \r
        value\r
        ------WebKitFormBoundary--\r
        This epilogue should be ignored
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].name, "field")
    }

    func testParseMultilineValue() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="description"\r
        \r
        Line 1\r
        Line 2\r
        Line 3\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts[0].stringValue?.contains("Line 1") ?? false)
        XCTAssertTrue(parts[0].stringValue?.contains("Line 2") ?? false)
        XCTAssertTrue(parts[0].stringValue?.contains("Line 3") ?? false)
    }

    // MARK: - Headers Parsing Tests

    func testParseMultipleHeaders() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="file"; filename="test.txt"\r
        Content-Type: text/plain\r
        Content-Transfer-Encoding: binary\r
        \r
        content\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].headers["Content-Disposition"], "form-data; name=\"file\"; filename=\"test.txt\"")
        XCTAssertEqual(parts[0].headers["Content-Type"], "text/plain")
        XCTAssertEqual(parts[0].headers["Content-Transfer-Encoding"], "binary")
    }

    func testParseHeaderWithSpaces() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition:    form-data; name="field"    \r
        \r
        value\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertNotNil(parts[0].headers["Content-Disposition"])
    }

    // MARK: - Binary Data Tests

    func testParseBinaryData() {
        let boundary = "----WebKitFormBoundary"

        // Create binary data with special bytes
        var binaryContent = Data()
        binaryContent.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xE0]) // JPEG magic bytes
        binaryContent.append(contentsOf: [0x00, 0x10, 0x4A, 0x46]) // More binary data

        let header = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="image"; filename="photo.jpg"\r
        Content-Type: image/jpeg\r
        \r

        """.data(using: .utf8)!

        let footer = "\r\n------WebKitFormBoundary--".data(using: .utf8)!

        var fullBody = Data()
        fullBody.append(header)
        fullBody.append(binaryContent)
        fullBody.append(footer)

        let parts = MultipartParser.parse(data: fullBody, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].name, "image")
        XCTAssertEqual(parts[0].filename, "photo.jpg")
        XCTAssertEqual(parts[0].data.count, binaryContent.count)
        XCTAssertEqual(parts[0].data, binaryContent)
    }

    // MARK: - Real-World Example Tests

    func testParseRealWorldFormData() {
        let boundary = "----WebKitFormBoundaryePkpFF7tjBAqx29L"
        let body = """
        ------WebKitFormBoundaryePkpFF7tjBAqx29L\r
        Content-Disposition: form-data; name="username"\r
        \r
        john_doe\r
        ------WebKitFormBoundaryePkpFF7tjBAqx29L\r
        Content-Disposition: form-data; name="email"\r
        \r
        john@example.com\r
        ------WebKitFormBoundaryePkpFF7tjBAqx29L\r
        Content-Disposition: form-data; name="profile_pic"; filename="avatar.png"\r
        Content-Type: image/png\r
        \r
        PNG_DATA_HERE\r
        ------WebKitFormBoundaryePkpFF7tjBAqx29L\r
        Content-Disposition: form-data; name="bio"\r
        \r
        Software engineer passionate about iOS development.\r
        ------WebKitFormBoundaryePkpFF7tjBAqx29L--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 4)

        // Username
        XCTAssertEqual(parts[0].name, "username")
        XCTAssertEqual(parts[0].stringValue, "john_doe")
        XCTAssertFalse(parts[0].isFile)

        // Email
        XCTAssertEqual(parts[1].name, "email")
        XCTAssertEqual(parts[1].stringValue, "john@example.com")

        // Profile picture
        XCTAssertEqual(parts[2].name, "profile_pic")
        XCTAssertEqual(parts[2].filename, "avatar.png")
        XCTAssertEqual(parts[2].contentType, "image/png")
        XCTAssertTrue(parts[2].isFile)

        // Bio
        XCTAssertEqual(parts[3].name, "bio")
        XCTAssertTrue(parts[3].stringValue?.contains("iOS development") ?? false)
    }

    // MARK: - Data Extension Tests

    func testDataRangeOfPattern() {
        let data = "Hello World".data(using: .utf8)!
        let pattern = "World".data(using: .utf8)!

        let range = data.range(of: pattern, in: 0..<data.count)

        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 6)
        XCTAssertEqual(range?.upperBound, 11)
    }

    func testDataRangeNotFound() {
        let data = "Hello World".data(using: .utf8)!
        let pattern = "Goodbye".data(using: .utf8)!

        let range = data.range(of: pattern, in: 0..<data.count)

        XCTAssertNil(range)
    }

    func testDataRangeOutOfBounds() {
        let data = "Hello".data(using: .utf8)!
        let pattern = "Hi".data(using: .utf8)!

        let range = data.range(of: pattern, in: 0..<100)

        XCTAssertNil(range)
    }

    func testDataRangeAtBeginning() {
        let data = "Hello World".data(using: .utf8)!
        let pattern = "Hello".data(using: .utf8)!

        let range = data.range(of: pattern, in: 0..<data.count)

        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 0)
    }

    func testDataRangeAtEnd() {
        let data = "Hello World".data(using: .utf8)!
        let pattern = "World".data(using: .utf8)!

        let range = data.range(of: pattern, in: 0..<data.count)

        XCTAssertNotNil(range)
        XCTAssertEqual(range?.upperBound, data.count)
    }

    // MARK: - Special Characters Tests

    func testParseValueWithSpecialCharacters() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="special"\r
        \r
        Value with special chars: @#$%^&*()_+-={}[]|:;"'<>,.?/\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts[0].stringValue?.contains("@#$%") ?? false)
    }

    func testParseFilenameWithSpaces() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="file"; filename="my document.pdf"\r
        \r
        content\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts[0].filename, "my document.pdf")
    }

    func testParseUnicodeContent() {
        let boundary = "----WebKitFormBoundary"
        let body = """
        ------WebKitFormBoundary\r
        Content-Disposition: form-data; name="message"\r
        \r
        Hello 世界! 🌍\r
        ------WebKitFormBoundary--
        """

        let data = body.data(using: .utf8)!
        let parts = MultipartParser.parse(data: data, boundary: boundary)

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].stringValue, "Hello 世界! 🌍")
    }
}
