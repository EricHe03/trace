//
//  RequestDetailBodyAnalyzerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/06.
//

import XCTest
@testable import Trace

final class RequestDetailBodyAnalyzerTests: XCTestCase {
    func testIsBinaryContentType() {
        XCTAssertTrue(RequestDetailBodyAnalyzer.isBinaryContentType("application/octet-stream"))
        XCTAssertTrue(RequestDetailBodyAnalyzer.isBinaryContentType("image/png"))
        XCTAssertFalse(RequestDetailBodyAnalyzer.isBinaryContentType("application/json"))
        XCTAssertFalse(RequestDetailBodyAnalyzer.isBinaryContentType("image/svg+xml"))
    }

    func testInferredContentTypeFromURL() {
        XCTAssertEqual(
            RequestDetailBodyAnalyzer.inferredContentType(from: "https://example.com/file.zip"),
            "application/zip"
        )
        XCTAssertEqual(
            RequestDetailBodyAnalyzer.inferredContentType(from: "https://example.com/app.js"),
            "application/javascript"
        )
        XCTAssertNil(RequestDetailBodyAnalyzer.inferredContentType(from: "https://example.com/no-extension"))
    }

    func testAttachmentFilenameParsing() {
        let plain = "attachment; filename=\"report.pdf\""
        XCTAssertEqual(RequestDetailBodyAnalyzer.attachmentFileName(from: plain), "report.pdf")

        let rfc5987 = "attachment; filename*=UTF-8''hello%20world.zip"
        XCTAssertEqual(RequestDetailBodyAnalyzer.attachmentFileName(from: rfc5987), "hello world.zip")
    }

    func testBinaryKindDetection() {
        let zipHeader = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])
        XCTAssertEqual(
            RequestDetailBodyAnalyzer.detectBinaryKind(
                data: zipHeader,
                contentType: nil,
                fileName: nil
            ),
            .zip
        )

        let pdfHeader = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31])
        XCTAssertEqual(
            RequestDetailBodyAnalyzer.detectBinaryKind(
                data: pdfHeader,
                contentType: nil,
                fileName: nil
            ),
            .pdf
        )
    }

    func testBinarySummaryTextIncludesPreviewDetails() {
        let summary = RequestDetailBodyAnalyzer.binarySummaryText(
            kind: .zip,
            fileName: "archive.zip",
            totalSize: 4096,
            previewSize: 1024,
            isPreview: true
        )

        XCTAssertTrue(summary.contains("ZIP body"))
        XCTAssertTrue(summary.contains("Filename: archive.zip"))
        XCTAssertTrue(summary.contains("Showing preview"))
    }
}

