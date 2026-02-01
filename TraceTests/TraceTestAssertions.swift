//
//  TraceTestAssertions.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import Trace
@testable import TraceCore

// MARK: - Network Assertions

/// Asserts that a URL string is valid
func XCTAssertValidURL(
    _ url: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNotNil(
        URL(string: url),
        "Expected valid URL, got: '\(url)'",
        file: file,
        line: line
    )
}

/// Asserts that an HTTP status code is in the success range (200-299)
func XCTAssertHTTPSuccess(
    _ statusCode: Int?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let code = statusCode else {
        XCTFail("Status code is nil", file: file, line: line)
        return
    }
    XCTAssertTrue(
        (200 ... 299).contains(code),
        "Expected HTTP success status (200-299), got: \(code)",
        file: file,
        line: line
    )
}

/// Asserts that an HTTP status code is in the client error range (400-499)
func XCTAssertHTTPClientError(
    _ statusCode: Int?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let code = statusCode else {
        XCTFail("Status code is nil", file: file, line: line)
        return
    }
    XCTAssertTrue(
        (400 ... 499).contains(code),
        "Expected HTTP client error status (400-499), got: \(code)",
        file: file,
        line: line
    )
}

/// Asserts that an HTTP status code is in the server error range (500-599)
func XCTAssertHTTPServerError(
    _ statusCode: Int?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let code = statusCode else {
        XCTFail("Status code is nil", file: file, line: line)
        return
    }
    XCTAssertTrue(
        (500 ... 599).contains(code),
        "Expected HTTP server error status (500-599), got: \(code)",
        file: file,
        line: line
    )
}

/// Asserts that headers contain a specific key-value pair
func XCTAssertHeaderContains(
    _ headers: [TraceHTTPHeader],
    key: String,
    value: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let header = headers.first { $0.key.lowercased() == key.lowercased() }
    XCTAssertNotNil(header, "Header '\(key)' not found", file: file, line: line)
    XCTAssertEqual(
        header?.value,
        value,
        "Header '\(key)' has wrong value. Expected: '\(value)', got: '\(header?.value ?? "nil")'",
        file: file,
        line: line
    )
}

/// Asserts that headers contain a specific key (regardless of value)
func XCTAssertHeaderExists(
    _ headers: [TraceHTTPHeader],
    key: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let exists = headers.contains { $0.key.lowercased() == key.lowercased() }
    XCTAssertTrue(
        exists,
        "Expected header '\(key)' to exist",
        file: file,
        line: line
    )
}

// MARK: - Body Storage Assertions

/// Asserts that body storage contains expected string content
func XCTAssertBodyContains(
    _ bodyStorage: BodyStorage,
    expectedString: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let bodyString = bodyStorage.getString() else {
        XCTFail("Body storage returned nil string", file: file, line: line)
        return
    }
    XCTAssertTrue(
        bodyString.contains(expectedString),
        "Body does not contain expected string '\(expectedString)'",
        file: file,
        line: line
    )
}

/// Asserts that body storage is empty
func XCTAssertBodyEmpty(
    _ bodyStorage: BodyStorage,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(
        bodyStorage.isEmpty,
        "Expected empty body storage",
        file: file,
        line: line
    )
}

// MARK: - Timing Assertions

/// Asserts that execution time is within expected bounds
func XCTAssertExecutionTimeWithin(
    _ duration: TimeInterval,
    min: TimeInterval = 0,
    max: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertGreaterThanOrEqual(
        duration,
        min,
        "Execution time \(duration)s is less than minimum \(min)s",
        file: file,
        line: line
    )
    XCTAssertLessThanOrEqual(
        duration,
        max,
        "Execution time \(duration)s exceeds maximum \(max)s",
        file: file,
        line: line
    )
}

/// Asserts that throttling was applied (delay is within expected range)
func XCTAssertThrottlingApplied(
    expectedDelay: TimeInterval,
    actualDelay: TimeInterval,
    tolerance: TimeInterval = 0.1,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let difference = abs(actualDelay - expectedDelay)
    XCTAssertLessThanOrEqual(
        difference,
        tolerance,
        "Throttling delay \(actualDelay)s differs from expected \(expectedDelay)s by \(difference)s (tolerance: \(tolerance)s)",
        file: file,
        line: line
    )
}

// MARK: - Async Assertions

func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: ((Error) -> Void)? = nil
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "Expected error to be thrown" : message, file: file, line: line)
    } catch {
        errorHandler?(error)
    }
}

// MARK: - Memory Assertions

/// Asserts that memory usage is within a limit
func XCTAssertMemoryWithin(
    _ actualBytes: Int,
    limit: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertLessThanOrEqual(
        actualBytes,
        limit,
        "Memory usage \(actualBytes) bytes exceeds limit \(limit) bytes",
        file: file,
        line: line
    )
}

// MARK: - Data Assertions

/// Asserts that data starts with expected prefix
func XCTAssertDataHasPrefix(
    _ data: Data,
    prefix: Data,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertGreaterThanOrEqual(
        data.count,
        prefix.count,
        "Data length \(data.count) is less than prefix length \(prefix.count)",
        file: file,
        line: line
    )

    let actualPrefix = data.prefix(prefix.count)
    XCTAssertEqual(
        actualPrefix,
        prefix,
        "Data does not start with expected prefix",
        file: file,
        line: line
    )
}

/// Asserts that data contains expected bytes at offset
func XCTAssertDataContainsBytesAtOffset(
    _ data: Data,
    bytes: [UInt8],
    offset: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertGreaterThanOrEqual(
        data.count,
        offset + bytes.count,
        "Data length \(data.count) is insufficient for bytes at offset \(offset)",
        file: file,
        line: line
    )

    for (index, expectedByte) in bytes.enumerated() {
        let actualByte = data[offset + index]
        XCTAssertEqual(
            actualByte,
            expectedByte,
            "Byte at offset \(offset + index) is \(actualByte), expected \(expectedByte)",
            file: file,
            line: line
        )
    }
}

// MARK: - Protocol Assertions

/// Asserts that HTTP request data is valid
func XCTAssertValidHTTPRequest(
    _ data: Data,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Bool {
    guard let requestString = String(data: data, encoding: .utf8) else {
        XCTFail("Could not decode request data as UTF-8", file: file, line: line)
        return false
    }

    // Check for request line (METHOD PATH HTTP/VERSION)
    let lines = requestString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
        XCTFail("Missing request line", file: file, line: line)
        return false
    }

    let components = requestLine.split(separator: " ")
    guard components.count >= 3 else {
        XCTFail("Invalid request line format: \(requestLine)", file: file, line: line)
        return false
    }

    // Verify HTTP version
    let version = String(components[2])
    XCTAssertTrue(
        version.hasPrefix("HTTP/"),
        "Invalid HTTP version: \(version)",
        file: file,
        line: line
    )

    return true
}

/// Asserts that HTTP response data is valid
func XCTAssertValidHTTPResponse(
    _ data: Data,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Bool {
    guard let responseString = String(data: data, encoding: .utf8) else {
        XCTFail("Could not decode response data as UTF-8", file: file, line: line)
        return false
    }

    // Check for status line (HTTP/VERSION CODE MESSAGE)
    let lines = responseString.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else {
        XCTFail("Missing status line", file: file, line: line)
        return false
    }

    let components = statusLine.split(separator: " ")
    guard components.count >= 3 else {
        XCTFail("Invalid status line format: \(statusLine)", file: file, line: line)
        return false
    }

    // Verify HTTP version
    let version = String(components[0])
    XCTAssertTrue(
        version.hasPrefix("HTTP/"),
        "Invalid HTTP version: \(version)",
        file: file,
        line: line
    )

    // Verify status code is numeric
    let statusCode = String(components[1])
    XCTAssertNotNil(
        Int(statusCode),
        "Status code is not numeric: \(statusCode)",
        file: file,
        line: line
    )

    return true
}

// MARK: - Collection Assertions

/// Asserts that collection is not empty
func XCTAssertNotEmpty<T: Collection>(
    _ collection: T,
    _ message: String = "Collection should not be empty",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(
        collection.isEmpty,
        message,
        file: file,
        line: line
    )
}

/// Asserts that collection contains exactly N elements
func XCTAssertCount<T: Collection>(
    _ collection: T,
    equals expectedCount: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        collection.count,
        expectedCount,
        "Collection has \(collection.count) elements, expected \(expectedCount)",
        file: file,
        line: line
    )
}

// MARK: - Interception Assertions

/// Asserts that redirect count is within safe limits
func XCTAssertNoRedirectLoop(
    _ redirectCount: Int,
    maxRedirects: Int = 10,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertLessThanOrEqual(
        redirectCount,
        maxRedirects,
        "Redirect count \(redirectCount) exceeds maximum \(maxRedirects), possible redirect loop",
        file: file,
        line: line
    )
}

/// Asserts that size is within specified limit
func XCTAssertWithinLimit(
    _ size: Int,
    limit: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertLessThanOrEqual(
        size,
        limit,
        "Size \(size) bytes exceeds limit \(limit) bytes",
        file: file,
        line: line
    )
}

/// Asserts that an async expression executes successfully on an actor
@discardableResult
func XCTAssertActorIsolated<T>(
    _ expression: @escaping () async -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> T? {
    await expression()
}

/// Asserts that an async throwing expression executes successfully on an actor
@discardableResult
func XCTAssertActorIsolated<T>(
    _ expression: @escaping () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> T? {
    do {
        return try await expression()
    } catch {
        XCTFail("Actor isolated expression threw error: \(error)", file: file, line: line)
        return nil
    }
}
