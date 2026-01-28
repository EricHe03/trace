//
//  HPACKCoderTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceNetworking
@testable import TraceVPN

final class HPACKCoderTests: XCTestCase {

    var coder: HPACKCoder!

    override func setUp() {
        super.setUp()
        coder = HPACKCoder()
    }

    override func tearDown() {
        coder = nil
        super.tearDown()
    }

    // MARK: - Basic Encode/Decode Round-Trip Tests

    func testEncodeDecodeSimpleHeader() throws {
        let headers = [TraceHTTPHeader(key: "content-type", value: "application/json")]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "content-type")
        XCTAssertEqual(decoded[0].value, "application/json")
    }

    func testEncodeDecodeMultipleHeaders() throws {
        let headers = [
            TraceHTTPHeader(key: "content-type", value: "application/json"),
            TraceHTTPHeader(key: "user-agent", value: "Trace/1.0"),
            TraceHTTPHeader(key: "accept", value: "*/*")
        ]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].key, "content-type")
        XCTAssertEqual(decoded[1].key, "user-agent")
        XCTAssertEqual(decoded[2].key, "accept")
    }

    func testEncodeDecodeCustomHeader() throws {
        let headers = [TraceHTTPHeader(key: "x-custom-header", value: "custom-value")]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "x-custom-header")
        XCTAssertEqual(decoded[0].value, "custom-value")
    }

    func testEncodeDecodeEmptyValue() throws {
        let headers = [TraceHTTPHeader(key: "accept", value: "")]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "accept")
        XCTAssertEqual(decoded[0].value, "")
    }

    func testEncodeDecodeLongValue() throws {
        let longValue = String(repeating: "a", count: 1000)
        let headers = [TraceHTTPHeader(key: "x-long-header", value: longValue)]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "x-long-header")
        XCTAssertEqual(decoded[0].value, longValue)
    }

    func testEncodeDecodeSpecialCharacters() throws {
        let headers = [TraceHTTPHeader(key: "x-special", value: "value with spaces and symbols: @#$%")]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "x-special")
        XCTAssertEqual(decoded[0].value, "value with spaces and symbols: @#$%")
    }

    func testEncodeDecodeUnicodeValue() throws {
        let headers = [TraceHTTPHeader(key: "x-unicode", value: "Hello 世界")]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "x-unicode")
        XCTAssertEqual(decoded[0].value, "Hello 世界")
    }

    func testEncodeNeverIndexedEmitsNeverIndexed() throws {
        let headers = [TraceHTTPHeader(key: "x-test", value: "value", indexingPolicy: .neverIndexed)]

        let encoded = try coder.encode(headers)

        XCTAssertEqual(encoded.first, 0x10)
    }

    // MARK: - Static Table Tests

    func testDecodeIndexedHeaderFromStaticTable() throws {
        // Index 2 in static table is ":method GET"
        let data = Data([0x82]) // 10000010 = indexed header field with index 2

        let decoded = try coder.decode(data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, ":method")
        XCTAssertEqual(decoded[0].value, "GET")
    }

    func testDecodeMultipleIndexedHeaders() throws {
        // Index 2 = :method GET, Index 7 = :scheme https
        let data = Data([0x82, 0x87])

        let decoded = try coder.decode(data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].key, ":method")
        XCTAssertEqual(decoded[0].value, "GET")
        XCTAssertEqual(decoded[1].key, ":scheme")
        XCTAssertEqual(decoded[1].value, "https")
    }

    func testDecodeInvalidIndexThrowsError() {
        // Index 255 is way beyond the static table
        let data = Data([0xFF, 0x7E]) // Large index

        do {
            _ = try coder.decode(data)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is HPACKError)
        }
    }

    func testDecodeNeverIndexedPreserved() throws {
        // Literal never indexed, new name "a", value "b"
        let data = Data([0x10, 0x01, 0x61, 0x01, 0x62])

        let decoded = try coder.decode(data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "a")
        XCTAssertEqual(decoded[0].value, "b")
        XCTAssertEqual(decoded[0].indexingPolicy, .neverIndexed)
    }

    func testDynamicTableSizeUpdateAfterHeaderThrows() {
        // Literal with incremental indexing, then size update mid-block (invalid)
        let data = Data([0x40, 0x01, 0x61, 0x01, 0x62, 0x20])

        do {
            _ = try coder.decode(data)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is HPACKError)
        }
    }

    // MARK: - Dynamic Table Tests

    func testDynamicTableAddition() throws {
        let headers = [TraceHTTPHeader(key: "x-custom", value: "value1")]

        // First encoding adds to dynamic table
        _ = try coder.encode(headers)

        // Second encoding should use indexed representation (smaller)
        let encoded2 = try coder.encode(headers)

        // Should be smaller due to indexing
        XCTAssertTrue(encoded2.count < 30) // Very small due to indexed lookup
    }

    func testDynamicTableEviction() throws {
        coder.recordEvents = true

        // Add many headers to fill the dynamic table
        var headers: [TraceHTTPHeader] = []
        for i in 0 ..< 100 {
            headers.append(TraceHTTPHeader(key: "x-header-\(i)", value: "value-\(i)"))
        }

        _ = try coder.encode(headers)

        let snapshot = coder.captureSnapshot()
        // Dynamic table should not grow indefinitely
        XCTAssertTrue(snapshot.currentSize <= snapshot.maxSize)
    }

    // MARK: - Integer Encoding/Decoding Tests

    func testDecodeSmallInteger() throws {
        // Small integers (< 2^prefix - 1) are encoded in first byte
        let coder = HPACKCoder()
        // Index 1 is encoded as 0x81 (10000001)
        let data = Data([0x81])

        let decoded = try coder.decode(data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, ":authority")
    }

    func testDecodeLargeInteger() throws {
        // For testing multi-byte integer decoding
        // Create a literal header with a very long value
        let longValue = String(repeating: "x", count: 200)
        let headers = [TraceHTTPHeader(key: "x-test", value: longValue)]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].value.count, 200)
    }

    // MARK: - String Encoding/Decoding Tests

    func testDecodeEmptyString() throws {
        // Literal header with empty value
        // 0x40 = literal with incremental indexing
        // 0x00 = index 0 (new name)
        // 0x01 = name length 1
        // 'a' = name
        // 0x00 = value length 0 (empty)
        let data = Data([0x40, 0x01, 0x61, 0x00])

        let decoded = try coder.decode(data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "a")
        XCTAssertEqual(decoded[0].value, "")
    }

    func testDecodeStringWithSpaces() throws {
        let headers = [TraceHTTPHeader(key: "x-test", value: "hello world")]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].value, "hello world")
    }

    // MARK: - Error Handling Tests

    func testDecodeIncompleteDataThrowsError() {
        // Start of a literal header but truncated
        let data = Data([0x40, 0x01])

        do {
            _ = try coder.decode(data)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is HPACKError)
        }
    }

    func testDecodeTruncatedStringThrowsError() {
        // Literal header claiming 100 byte string but only 5 bytes
        let data = Data([0x40, 0x01, 0x61, 0x64]) // Claims length 100 but data ends

        do {
            _ = try coder.decode(data)
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected error
        }
    }

    // MARK: - Table Snapshot Tests

    func testCaptureSnapshot() {
        let snapshot = coder.captureSnapshot()

        XCTAssertEqual(snapshot.staticEntries.count, 61) // HPACK static table has 61 entries
        XCTAssertEqual(snapshot.dynamicEntries.count, 0) // Initially empty
        XCTAssertEqual(snapshot.currentSize, 0)
        XCTAssertEqual(snapshot.maxSize, 4096) // Default size
    }

    func testCaptureSnapshotAfterEncoding() throws {
        let headers = [TraceHTTPHeader(key: "x-custom", value: "test")]
        _ = try coder.encode(headers)

        let snapshot = coder.captureSnapshot()

        XCTAssertEqual(snapshot.dynamicEntries.count, 1)
        XCTAssertGreaterThan(snapshot.currentSize, 0)
    }

    // MARK: - Table Event Recording Tests

    func testEventRecordingDisabledByDefault() throws {
        let headers = [TraceHTTPHeader(key: "x-test", value: "value")]
        _ = try coder.encode(headers)

        let events = coder.getTableEvents()
        XCTAssertEqual(events.count, 0) // Recording disabled by default
    }

    func testEventRecordingEntryAdded() throws {
        coder.recordEvents = true

        let headers = [TraceHTTPHeader(key: "x-custom", value: "value")]
        _ = try coder.encode(headers)

        let events = coder.getTableEvents()
        XCTAssertGreaterThan(events.count, 0)

        // Check that an entry was added
        let hasAddEvent = events.contains { event in
            if case .entryAdded = event.type {
                return true
            }
            return false
        }
        XCTAssertTrue(hasAddEvent)
    }

    func testClearEvents() throws {
        coder.recordEvents = true

        let headers = [TraceHTTPHeader(key: "x-test", value: "value")]
        _ = try coder.encode(headers)

        XCTAssertGreaterThan(coder.getTableEvents().count, 0)

        coder.clearEvents()
        XCTAssertEqual(coder.getTableEvents().count, 0)
    }

    func testMaxEventHistoryLimit() throws {
        coder.recordEvents = true
        coder.maxEventHistory = 5

        // Generate many events
        for i in 0 ..< 20 {
            let headers = [TraceHTTPHeader(key: "x-header-\(i)", value: "value-\(i)")]
            _ = try coder.encode(headers)
        }

        let events = coder.getTableEvents()
        XCTAssertLessThanOrEqual(events.count, 5)
    }

    // MARK: - HTTP/2 Pseudo-Headers Tests

    func testEncodePseudoHeaders() throws {
        let headers = [
            TraceHTTPHeader(key: ":method", value: "GET"),
            TraceHTTPHeader(key: ":scheme", value: "https"),
            TraceHTTPHeader(key: ":path", value: "/"),
            TraceHTTPHeader(key: ":authority", value: "example.com")
        ]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 4)
        XCTAssertTrue(decoded.contains { $0.key == ":method" && $0.value == "GET" })
        XCTAssertTrue(decoded.contains { $0.key == ":scheme" && $0.value == "https" })
        XCTAssertTrue(decoded.contains { $0.key == ":path" && $0.value == "/" })
    }

    // MARK: - Compression Efficiency Tests

    func testCompressionWithRepeatedHeaders() throws {
        let headers1 = [
            TraceHTTPHeader(key: "user-agent", value: "Trace/1.0"),
            TraceHTTPHeader(key: "accept", value: "*/*")
        ]

        let encoded1 = try coder.encode(headers1)
        let size1 = encoded1.count

        // Encode same headers again - should be more efficient due to dynamic table
        let headers2 = [
            TraceHTTPHeader(key: "user-agent", value: "Trace/1.0"),
            TraceHTTPHeader(key: "accept", value: "*/*")
        ]

        let encoded2 = try coder.encode(headers2)
        let size2 = encoded2.count

        // Second encoding should be smaller or equal
        XCTAssertLessThanOrEqual(size2, size1)
    }

    // MARK: - Edge Cases

    func testEncodeEmptyHeaderList() throws {
        let headers: [TraceHTTPHeader] = []

        let encoded = try coder.encode(headers)

        XCTAssertEqual(encoded.count, 0)
    }

    func testDecodeEmptyData() throws {
        let data = Data()

        let decoded = try coder.decode(data)

        XCTAssertEqual(decoded.count, 0)
    }

    func testEncodeHeaderWithMixedCase() throws {
        // HPACK requires lowercase header names
        let headers = [TraceHTTPHeader(key: "Content-Type", value: "application/json")]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        // Should be lowercased
        XCTAssertEqual(decoded[0].key, "content-type")
        XCTAssertEqual(decoded[0].value, "application/json")
    }
}

// MARK: - HPACKHeader Tests

final class HPACKHeaderTests: XCTestCase {

    func testHeaderSize() {
        let header = HPACKHeader(name: "test", value: "value")

        // Size = name.utf8.count + value.utf8.count + 32
        // "test" = 4, "value" = 5, total = 4 + 5 + 32 = 41
        XCTAssertEqual(header.size, 41)
    }

    func testHeaderSizeWithEmptyValue() {
        let header = HPACKHeader(name: "accept", value: "")

        // "accept" = 6, "" = 0, total = 6 + 0 + 32 = 38
        XCTAssertEqual(header.size, 38)
    }

    func testHeaderSizeWithUnicode() {
        let header = HPACKHeader(name: "x-test", value: "世界")

        // "x-test" = 6, "世界" = 6 bytes in UTF-8, total = 6 + 6 + 32 = 44
        XCTAssertEqual(header.size, 44)
    }

    func testHeaderEquality() {
        let header1 = HPACKHeader(name: "content-type", value: "application/json")
        let header2 = HPACKHeader(name: "content-type", value: "application/json")
        let header3 = HPACKHeader(name: "content-type", value: "text/html")

        XCTAssertEqual(header1, header2)
        XCTAssertNotEqual(header1, header3)
    }
}

// MARK: - HPACKError Tests

final class HPACKErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertEqual(HPACKError.invalidData.errorDescription, "Invalid HPACK data")
        XCTAssertEqual(HPACKError.invalidIndex.errorDescription, "Invalid table index")
        XCTAssertEqual(HPACKError.invalidString.errorDescription, "Invalid string encoding")
        XCTAssertEqual(HPACKError.invalidTableSize.errorDescription, "Invalid dynamic table size")
        XCTAssertEqual(HPACKError.integerOverflow.errorDescription, "Integer overflow in HPACK decoding")
    }
}
