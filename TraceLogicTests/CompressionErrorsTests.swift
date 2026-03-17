//
//  CompressionErrorsTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCompression
import XCTest

final class CompressionErrorsTests: XCTestCase {
    // MARK: - CompressionError Tests

    func testCompressionErrorInvalidInput() {
        let error = CompressionError.invalidInput("Test input error")

        XCTAssertEqual(error.errorDescription, "Test input error")
    }

    func testCompressionErrorInvalidFormat() {
        let error = CompressionError.invalidFormat("Test format error")

        XCTAssertEqual(error.errorDescription, "Test format error")
    }

    func testCompressionErrorInitializationFailed() {
        let error = CompressionError.initializationFailed("Test initialization error")

        XCTAssertEqual(error.errorDescription, "Test initialization error")
    }

    func testCompressionErrorDecompressionFailed() {
        let error = CompressionError.decompressionFailed("Test decompression error")

        XCTAssertEqual(error.errorDescription, "Test decompression error")
    }

    func testCompressionErrorNotInitialized() {
        let error = CompressionError.notInitialized("Test not initialized error")

        XCTAssertEqual(error.errorDescription, "Test not initialized error")
    }

    func testCompressionErrorBufferTooSmall() {
        let error = CompressionError.bufferTooSmall("Test buffer error")

        XCTAssertEqual(error.errorDescription, "Test buffer error")
    }

    func testCompressionErrorUnknownError() {
        let error = CompressionError.unknownError("Test unknown error")

        XCTAssertEqual(error.errorDescription, "Test unknown error")
    }

    func testCompressionErrorAsLocalizedError() {
        let error: LocalizedError = CompressionError.invalidInput("Custom message")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription, "Custom message")
    }

    func testCompressionErrorCanBeThrown() {
        func throwsError() throws {
            throw CompressionError.decompressionFailed("Decompression failed")
        }

        XCTAssertThrowsError(try throwsError()) { error in
            XCTAssertTrue(error is CompressionError)
            if let compError = error as? CompressionError {
                XCTAssertEqual(compError.errorDescription, "Decompression failed")
            }
        }
    }

    // MARK: - Error Matching Tests

    func testCompressionErrorMatchingInvalidInput() {
        let error = CompressionError.invalidInput("Test")

        switch error {
        case let .invalidInput(message):
            XCTAssertEqual(message, "Test")
        default:
            XCTFail("Expected invalidInput case")
        }
    }

    func testCompressionErrorMatchingInvalidFormat() {
        let error = CompressionError.invalidFormat("Test")

        switch error {
        case let .invalidFormat(message):
            XCTAssertEqual(message, "Test")
        default:
            XCTFail("Expected invalidFormat case")
        }
    }

    func testCompressionErrorMatchingInitializationFailed() {
        let error = CompressionError.initializationFailed("Test")

        switch error {
        case let .initializationFailed(message):
            XCTAssertEqual(message, "Test")
        default:
            XCTFail("Expected initializationFailed case")
        }
    }

    func testCompressionErrorMatchingDecompressionFailed() {
        let error = CompressionError.decompressionFailed("Test")

        switch error {
        case let .decompressionFailed(message):
            XCTAssertEqual(message, "Test")
        default:
            XCTFail("Expected decompressionFailed case")
        }
    }

    func testCompressionErrorMatchingNotInitialized() {
        let error = CompressionError.notInitialized("Test")

        switch error {
        case let .notInitialized(message):
            XCTAssertEqual(message, "Test")
        default:
            XCTFail("Expected notInitialized case")
        }
    }

    func testCompressionErrorMatchingBufferTooSmall() {
        let error = CompressionError.bufferTooSmall("Test")

        switch error {
        case let .bufferTooSmall(message):
            XCTAssertEqual(message, "Test")
        default:
            XCTFail("Expected bufferTooSmall case")
        }
    }

    func testCompressionErrorMatchingUnknownError() {
        let error = CompressionError.unknownError("Test")

        switch error {
        case let .unknownError(message):
            XCTAssertEqual(message, "Test")
        default:
            XCTFail("Expected unknownError case")
        }
    }

    // MARK: - Error Description Content Tests

    func testCompressionErrorDescriptionsAreNotEmpty() throws {
        let errors: [CompressionError] = [
            .invalidInput("message"),
            .invalidFormat("message"),
            .initializationFailed("message"),
            .decompressionFailed("message"),
            .notInitialized("message"),
            .bufferTooSmall("message"),
            .unknownError("message")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(try XCTUnwrap(error.errorDescription?.isEmpty))
        }
    }

    // MARK: - Error Usage Tests

    func testCompressionErrorWithDifferentMessages() {
        let error1 = CompressionError.invalidInput("First message")
        let error2 = CompressionError.invalidInput("Second message")

        XCTAssertNotEqual(error1.errorDescription, error2.errorDescription)
    }

    func testCompressionErrorInRealWorldScenario() {
        func processData() throws {
            throw CompressionError.bufferTooSmall("Output exceeded 10000 bytes")
        }

        do {
            try processData()
            XCTFail("Expected error to be thrown")
        } catch let error as CompressionError {
            switch error {
            case let .bufferTooSmall(message):
                XCTAssertTrue(message.contains("10000"))
                XCTAssertTrue(message.contains("bytes"))
            default:
                XCTFail("Expected bufferTooSmall error")
            }
        } catch {
            XCTFail("Expected CompressionError")
        }
    }
}
