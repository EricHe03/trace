//
//  ContentSafetyTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

final class ContentSafetyTests: XCTestCase {
    // MARK: - isBinary Tests - Empty Data

    func testIsBinaryWithEmptyData() {
        let emptyData = Data()
        XCTAssertFalse(ContentSafety.isBinary(emptyData), "Empty data should not be considered binary")
    }

    // MARK: - isBinary Tests - Null Byte Detection

    func testIsBinaryWithNullByte() {
        let dataWithNull = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x57, 0x6F, 0x72, 0x6C, 0x64])
        XCTAssertTrue(ContentSafety.isBinary(dataWithNull), "Data with null byte should be considered binary")
    }

    func testIsBinaryWithMultipleNullBytes() {
        let dataWithNulls = Data([0x00, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F])
        XCTAssertTrue(ContentSafety.isBinary(dataWithNulls), "Data with multiple null bytes should be considered binary")
    }

    func testIsBinaryWithNullByteAtEnd() {
        let dataWithNullAtEnd = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00])
        XCTAssertTrue(ContentSafety.isBinary(dataWithNullAtEnd), "Data with null byte at end should be considered binary")
    }

    // MARK: - isBinary Tests - Text Data

    func testIsBinaryWithPlainTextASCII() {
        let plainText = "Hello, World!".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.isBinary(plainText), "Plain ASCII text should not be considered binary")
    }

    func testIsBinaryWithMultilineText() {
        let multilineText = "Line 1\nLine 2\nLine 3".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.isBinary(multilineText), "Multiline text should not be considered binary")
    }

    func testIsBinaryWithTabCharacters() {
        let textWithTabs = "Column1\tColumn2\tColumn3".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.isBinary(textWithTabs), "Text with tabs should not be considered binary")
    }

    func testIsBinaryWithCarriageReturn() {
        let textWithCR = "Line 1\r\nLine 2\r\nLine 3".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.isBinary(textWithCR), "Text with carriage returns should not be considered binary")
    }

    func testIsBinaryWithJSONData() {
        let json = """
        {
            "key": "value",
            "number": 42,
            "array": [1, 2, 3]
        }
        """.data(using: .utf8)!
        XCTAssertFalse(ContentSafety.isBinary(json), "JSON data should not be considered binary")
    }

    func testIsBinaryWithXMLData() {
        let xml = """
        <?xml version="1.0"?>
        <root>
            <element>value</element>
        </root>
        """.data(using: .utf8)!
        XCTAssertFalse(ContentSafety.isBinary(xml), "XML data should not be considered binary")
    }

    // MARK: - isBinary Tests - Binary Data

    func testIsBinaryWithImageData() {
        // PNG header
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertTrue(ContentSafety.isBinary(pngHeader), "PNG data should be considered binary")
    }

    func testIsBinaryWithJPEGData() {
        // JPEG header
        let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertTrue(ContentSafety.isBinary(jpegHeader), "JPEG data should be considered binary")
    }

    func testIsBinaryWithPDFData() {
        // PDF header
        let pdfHeader = "%PDF-1.4\n".data(using: .utf8)!
        // This might be false since PDF headers are text-like
        // But actual PDF content is binary
        let binaryPDF = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF, 0xFE])
        XCTAssertTrue(ContentSafety.isBinary(binaryPDF), "PDF with binary content should be considered binary")
    }

    func testIsBinaryWithRandomBinaryData() {
        let binaryData = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8])
        XCTAssertTrue(ContentSafety.isBinary(binaryData), "Random binary data should be considered binary")
    }

    // MARK: - isBinary Tests - Ratio Threshold

    func testIsBinaryWithHighNonTextRatio() {
        // Create data with >30% non-text characters
        var mixedData = Data()
        for _ in 0 ..< 70 {
            mixedData.append(0x41) // 'A'
        }
        for _ in 0 ..< 30 {
            mixedData.append(0xFF) // Binary byte
        }
        XCTAssertFalse(ContentSafety.isBinary(mixedData), "30% non-text should be at threshold")

        // Now test with 31% non-text
        var moreBinary = Data()
        for _ in 0 ..< 69 {
            moreBinary.append(0x41) // 'A'
        }
        for _ in 0 ..< 31 {
            moreBinary.append(0xFF) // Binary byte
        }
        XCTAssertTrue(ContentSafety.isBinary(moreBinary), "31% non-text should be considered binary")
    }

    func testIsBinaryWithLargeTextData() throws {
        // Create large text data (>4096 bytes) to test sampling
        let largeText = try XCTUnwrap(String(repeating: "Hello, World! ", count: 1000).data(using: .utf8))
        XCTAssertFalse(ContentSafety.isBinary(largeText), "Large text data should not be considered binary")
    }

    func testIsBinaryWithLargeBinaryData() {
        // Create large binary data (>4096 bytes) to test sampling
        var largeBinary = Data(count: 5000)
        for i in 0 ..< 5000 {
            largeBinary[i] = UInt8.random(in: 128 ... 255)
        }
        XCTAssertTrue(ContentSafety.isBinary(largeBinary), "Large binary data should be considered binary")
    }

    // MARK: - isBinary Tests - Special Characters

    func testIsBinaryWithUTF8Emoji() {
        let emojiText = "Hello 👋 World 🌍".data(using: .utf8)!
        // UTF-8 encoded emoji might have bytes outside ASCII range
        // This could be considered binary depending on the ratio
        let result = ContentSafety.isBinary(emojiText)
        // We don't assert a specific result, just verify it doesn't crash
        XCTAssertNotNil(result)
    }

    func testIsBinaryWithUnicodeText() {
        let unicodeText = "Hello 世界 Мир".data(using: .utf8)!
        // UTF-8 encoded unicode might have bytes outside ASCII range
        let result = ContentSafety.isBinary(unicodeText)
        XCTAssertNotNil(result)
    }

    // MARK: - shouldSkipTextOperation Tests - Content Type

    func testShouldSkipWithImageContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "image/png"), "Should skip for image content type")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "image/jpeg"), "Should skip for image content type")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "IMAGE/GIF"), "Should skip for image content type (case insensitive)")
    }

    func testShouldSkipWithVideoContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "video/mp4"), "Should skip for video content type")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "video/mpeg"), "Should skip for video content type")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "VIDEO/AVI"), "Should skip for video content type (case insensitive)")
    }

    func testShouldSkipWithAudioContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "audio/mp3"), "Should skip for audio content type")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "audio/wav"), "Should skip for audio content type")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "AUDIO/OGG"), "Should skip for audio content type (case insensitive)")
    }

    func testShouldNotSkipWithTextContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: "text/plain"), "Should not skip for text content type")
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: "text/html"), "Should not skip for text content type")
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: "TEXT/XML"), "Should not skip for text content type")
    }

    func testShouldNotSkipWithApplicationContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: "application/json"), "Should not skip for JSON content type")
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: "application/xml"), "Should not skip for XML content type")
    }

    // MARK: - shouldSkipTextOperation Tests - Nil Content Type

    func testShouldSkipWithNilContentTypeAndTextData() {
        let textData = "Hello, World!".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: nil), "Should not skip text data with nil content type")
    }

    func testShouldSkipWithNilContentTypeAndBinaryData() {
        let binaryData = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8])
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(binaryData, contentType: nil), "Should skip binary data with nil content type")
    }

    // MARK: - shouldSkipTextOperation Tests - Binary Data Override

    func testShouldSkipWithTextContentTypeButBinaryData() {
        let binaryData = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8])
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(binaryData, contentType: "text/plain"), "Should skip even with text content type if data is binary")
    }

    func testShouldSkipWithApplicationContentTypeButBinaryData() {
        let binaryData = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8])
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(binaryData, contentType: "application/json"), "Should skip even with JSON content type if data is binary")
    }

    // MARK: - shouldSkipTextOperation Tests - Edge Cases

    func testShouldSkipWithEmptyData() {
        let emptyData = Data()
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(emptyData, contentType: nil), "Should not skip empty data")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(emptyData, contentType: "image/png"), "Should skip empty data with image content type")
    }

    func testShouldSkipWithEmptyContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: ""), "Should not skip with empty content type string")
    }

    func testShouldSkipWithWhitespaceContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: "   "), "Should not skip with whitespace content type")
    }

    func testShouldSkipWithPartialContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "image"), "Should skip with partial image content type")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "video"), "Should skip with partial video content type")
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "audio"), "Should skip with partial audio content type")
    }

    func testShouldSkipWithComplexContentType() {
        let textData = "Hello".data(using: .utf8)!
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(textData, contentType: "image/png; charset=utf-8"), "Should skip with complex image content type")
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(textData, contentType: "text/plain; charset=utf-8"), "Should not skip with complex text content type")
    }

    // MARK: - Integration Tests

    func testRealWorldScenarios() {
        // HTML content
        let htmlData = "<html><body>Hello</body></html>".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(htmlData, contentType: "text/html"))

        // CSS content
        let cssData = "body { color: red; }".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(cssData, contentType: "text/css"))

        // JavaScript content
        let jsData = "function test() { return 42; }".data(using: .utf8)!
        XCTAssertFalse(ContentSafety.shouldSkipTextOperation(jsData, contentType: "application/javascript"))

        // Binary image marked as image
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(ContentSafety.shouldSkipTextOperation(imageData, contentType: "image/png"))
    }
}
