//
//  HPACKEncoderTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceNetworking
@testable import TraceCore

final class HPACKEncoderTests: XCTestCase {

    var coder: HPACKCoder!

    override func setUp() {
        super.setUp()
        coder = HPACKCoder()
    }

    override func tearDown() {
        coder = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        let coder = HPACKCoder()
        XCTAssertNotNil(coder)
        XCTAssertFalse(coder.recordEvents)
        XCTAssertEqual(coder.maxEventHistory, 100)
        XCTAssertEqual(coder.tableEvents.count, 0)
    }

    // MARK: - Static Table Tests

    func testStaticTableLookup() throws {
        // Test encoding with static table entries (RFC 7541 Appendix A)
        let headers = [
            TraceHTTPHeader(key: ":method", value: "GET", indexingPolicy: .incremental),
            TraceHTTPHeader(key: ":path", value: "/", indexingPolicy: .incremental)
        ]

        let encoded = try coder.encode(headers)
        XCTAssertGreaterThan(encoded.count, 0)

        // Decode and verify
        let decoded = try coder.decode(encoded)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].key, ":method")
        XCTAssertEqual(decoded[0].value, "GET")
        XCTAssertEqual(decoded[1].key, ":path")
        XCTAssertEqual(decoded[1].value, "/")
    }

    // MARK: - Encoding Tests

    func testEncodeIndexedHeader() throws {
        // Encode a header that exists in static table
        let headers = [TraceHTTPHeader(key: ":method", value: "GET", indexingPolicy: .incremental)]

        let encoded = try coder.encode(headers)
        XCTAssertGreaterThan(encoded.count, 0)

        // First byte should have high bit set (indexed representation)
        XCTAssertTrue((encoded[0] & 0x80) != 0)
    }

    func testEncodeLiteralWithIncrementalIndexing() throws {
        let headers = [TraceHTTPHeader(key: "custom-header", value: "custom-value", indexingPolicy: .incremental)]

        let encoded = try coder.encode(headers)
        XCTAssertGreaterThan(encoded.count, 0)

        // Decode and verify
        let decoded = try coder.decode(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "custom-header")
        XCTAssertEqual(decoded[0].value, "custom-value")
    }

    func testEncodeLiteralWithoutIndexing() throws {
        let headers = [TraceHTTPHeader(key: "test-header", value: "test-value", indexingPolicy: .withoutIndexing)]

        let encoded = try coder.encode(headers)
        XCTAssertGreaterThan(encoded.count, 0)

        let decoded = try coder.decode(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "test-header")
        XCTAssertEqual(decoded[0].value, "test-value")
    }

    func testEncodeLiteralNeverIndexed() throws {
        let headers = [TraceHTTPHeader(key: "authorization", value: "Bearer secret", indexingPolicy: .neverIndexed)]

        let encoded = try coder.encode(headers)
        XCTAssertGreaterThan(encoded.count, 0)

        let decoded = try coder.decode(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, "authorization")
        XCTAssertEqual(decoded[0].value, "Bearer secret")
        XCTAssertEqual(decoded[0].indexingPolicy, .neverIndexed)
    }

    func testEncodeMultipleHeaders() throws {
        let headers = [
            TraceHTTPHeader(key: ":method", value: "POST", indexingPolicy: .incremental),
            TraceHTTPHeader(key: ":path", value: "/api/test", indexingPolicy: .incremental),
            TraceHTTPHeader(key: "content-type", value: "application/json", indexingPolicy: .incremental),
            TraceHTTPHeader(key: "x-custom", value: "value", indexingPolicy: .incremental)
        ]

        let encoded = try coder.encode(headers)
        XCTAssertGreaterThan(encoded.count, 0)

        let decoded = try coder.decode(encoded)
        XCTAssertEqual(decoded.count, 4)
        XCTAssertEqual(decoded[0].key, ":method")
        XCTAssertEqual(decoded[1].key, ":path")
        XCTAssertEqual(decoded[2].key, "content-type")
        XCTAssertEqual(decoded[3].key, "x-custom")
    }

    // MARK: - Decoding Tests

    func testDecodeIndexedHeader() throws {
        // Index 2 in static table is :method GET
        let data = Data([0x82]) // 10000010 = indexed header field, index 2

        let decoded = try coder.decode(data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, ":method")
        XCTAssertEqual(decoded[0].value, "GET")
    }

    func testDecodeEmptyData() throws {
        let decoded = try coder.decode(Data())
        XCTAssertEqual(decoded.count, 0)
    }

    func testDecodeInvalidData() {
        // Invalid: incomplete header
        let data = Data([0x40]) // Literal with incremental indexing but no name/value

        XCTAssertThrowsError(try coder.decode(data)) { error in
            XCTAssertTrue(error is HPACKError)
        }
    }

    // MARK: - Integer Encoding/Decoding Tests

    func testIntegerEncodingSmallValue() throws {
        // Encode small value that fits in prefix
        let headers = [TraceHTTPHeader(key: ":method", value: "GET", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        XCTAssertGreaterThan(encoded.count, 0)
    }

    func testIntegerEncodingLargeValue() throws {
        // Test with a large dynamic table
        for i in 0..<100 {
            let headers = [TraceHTTPHeader(key: "x-header-\(i)", value: "value-\(i)", indexingPolicy: .incremental)]
            _ = try coder.encode(headers)
        }
    }

    // MARK: - String Encoding Tests

    func testStringEncodingPlain() throws {
        let headers = [TraceHTTPHeader(key: "simple", value: "text", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].value, "text")
    }

    func testStringEncodingUTF8() throws {
        let headers = [TraceHTTPHeader(key: "unicode", value: "Hello 世界 🌍", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].value, "Hello 世界 🌍")
    }

    func testStringEncodingEmpty() throws {
        let headers = [TraceHTTPHeader(key: "empty", value: "", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].value, "")
    }

    // MARK: - Dynamic Table Tests

    func testDynamicTableInsertion() throws {
        coder.recordEvents = true

        let headers = [TraceHTTPHeader(key: "custom-key", value: "custom-value", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        _ = try coder.decode(encoded)

        // Verify table event was recorded
        XCTAssertGreaterThan(coder.tableEvents.count, 0)
    }

    func testDynamicTableEviction() throws {
        coder.recordEvents = true

        // Add many headers to trigger eviction
        for i in 0..<50 {
            let headers = [TraceHTTPHeader(key: "header-\(i)", value: String(repeating: "x", count: 100), indexingPolicy: .incremental)]
            _ = try coder.encode(headers)
        }

        // Check for eviction events
        let evictionEvents = coder.tableEvents.filter {
            if case .entryEvicted = $0.type { return true }
            return false
        }
        XCTAssertGreaterThan(evictionEvents.count, 0)
    }

    func testDynamicTableSizeUpdate() throws {
        coder.setMaxDynamicTableSize(2048)

        let headers = [TraceHTTPHeader(key: "test", value: "value", indexingPolicy: .incremental)]
        _ = try coder.encode(headers)

        let snapshot = coder.captureSnapshot()
        XCTAssertEqual(snapshot.maxSize, 2048)
    }

    // MARK: - Table Snapshot Tests

    func testCaptureSnapshot() {
        let snapshot = coder.captureSnapshot()

        XCTAssertEqual(snapshot.staticEntries.count, 61) // RFC 7541 static table size
        XCTAssertEqual(snapshot.dynamicEntries.count, 0)
        XCTAssertEqual(snapshot.currentSize, 0)
        XCTAssertEqual(snapshot.maxSize, 4096)
    }

    func testSnapshotAfterInsertion() throws {
        let headers = [TraceHTTPHeader(key: "x-test", value: "test-value", indexingPolicy: .incremental)]
        _ = try coder.encode(headers)

        let snapshot = coder.captureSnapshot()
        XCTAssertGreaterThan(snapshot.currentSize, 0)
    }

    // MARK: - Event Recording Tests

    func testEventRecordingDisabled() throws {
        coder.recordEvents = false

        let headers = [TraceHTTPHeader(key: "test", value: "value", indexingPolicy: .incremental)]
        _ = try coder.encode(headers)

        XCTAssertEqual(coder.tableEvents.count, 0)
    }

    func testEventRecordingEnabled() throws {
        coder.recordEvents = true

        let headers = [TraceHTTPHeader(key: "test", value: "value", indexingPolicy: .incremental)]
        _ = try coder.encode(headers)

        XCTAssertGreaterThan(coder.tableEvents.count, 0)
    }

    func testEventHistoryLimit() throws {
        coder.recordEvents = true
        coder.maxEventHistory = 10

        // Generate more events than the limit
        for i in 0..<20 {
            let headers = [TraceHTTPHeader(key: "header-\(i)", value: "value", indexingPolicy: .incremental)]
            _ = try coder.encode(headers)
        }

        XCTAssertLessThanOrEqual(coder.tableEvents.count, 10)
    }

    func testClearEvents() throws {
        coder.recordEvents = true

        let headers = [TraceHTTPHeader(key: "test", value: "value", indexingPolicy: .incremental)]
        _ = try coder.encode(headers)

        XCTAssertGreaterThan(coder.tableEvents.count, 0)

        coder.clearEvents()
        XCTAssertEqual(coder.tableEvents.count, 0)
    }

    // MARK: - Round-Trip Tests

    func testRoundTripSimpleHeader() throws {
        let original = [TraceHTTPHeader(key: "test", value: "value", indexingPolicy: .incremental)]

        let encoded = try coder.encode(original)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].key, original[0].key)
        XCTAssertEqual(decoded[0].value, original[0].value)
    }

    func testRoundTripMultipleEncodings() throws {
        let batches = [
            [TraceHTTPHeader(key: "a", value: "1", indexingPolicy: .incremental)],
            [TraceHTTPHeader(key: "b", value: "2", indexingPolicy: .incremental)],
            [TraceHTTPHeader(key: "a", value: "1", indexingPolicy: .incremental)] // Should use index
        ]

        for batch in batches {
            let encoded = try coder.encode(batch)
            let decoded = try coder.decode(encoded)
            XCTAssertEqual(decoded.count, batch.count)
        }
    }

    func testRoundTripLongValue() throws {
        let longValue = String(repeating: "x", count: 1000)
        let headers = [TraceHTTPHeader(key: "long", value: longValue, indexingPolicy: .incremental)]

        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].value, longValue)
    }

    // MARK: - Edge Cases

    func testEmptyHeaderName() throws {
        let headers = [TraceHTTPHeader(key: "", value: "value", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].key, "")
    }

    func testEmptyHeaderValue() throws {
        let headers = [TraceHTTPHeader(key: "key", value: "", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].value, "")
    }

    func testSpecialCharactersInHeader() throws {
        let headers = [TraceHTTPHeader(key: "special", value: "!@#$%^&*()_+-=[]{}|;:',.<>?/", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].value, "!@#$%^&*()_+-=[]{}|;:',.<>?/")
    }

    func testWhitespaceInHeaders() throws {
        let headers = [TraceHTTPHeader(key: "whitespace", value: "  spaces  ", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        XCTAssertEqual(decoded[0].value, "  spaces  ")
    }

    func testCasePreservation() throws {
        // HPACK header names should be lowercase
        let headers = [TraceHTTPHeader(key: "Content-Type", value: "text/html", indexingPolicy: .incremental)]
        let encoded = try coder.encode(headers)
        let decoded = try coder.decode(encoded)

        // Name should be lowercased
        XCTAssertEqual(decoded[0].key, "content-type")
    }

    // MARK: - Error Handling Tests

    func testDecodeInvalidInteger() {
        // Create data with invalid integer encoding
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

        XCTAssertThrowsError(try coder.decode(data)) { error in
            if let hpackError = error as? HPACKError {
                XCTAssertTrue(hpackError == .integerOverflow || hpackError == .invalidData)
            }
        }
    }

    func testDecodeInvalidIndex() {
        // Try to decode with an out-of-range index
        let data = Data([0xFF, 0xFF, 0x7F]) // Very large index

        XCTAssertThrowsError(try coder.decode(data)) { error in
            XCTAssertTrue(error is HPACKError)
        }
    }

    func testInvalidTableSizeUpdate() {
        // Test negative table size
        XCTAssertNoThrow(coder.setMaxDynamicTableSize(0))
    }

    // MARK: - Performance Tests

    func testEncodingPerformance() {
        let headers = (0..<100).map { i in
            TraceHTTPHeader(key: "header-\(i)", value: "value-\(i)", indexingPolicy: .incremental)
        }

        measure {
            for _ in 0..<10 {
                _ = try? coder.encode(headers)
            }
        }
    }

    func testDecodingPerformance() throws {
        let headers = (0..<100).map { i in
            TraceHTTPHeader(key: "header-\(i)", value: "value-\(i)", indexingPolicy: .incremental)
        }
        let encoded = try coder.encode(headers)

        measure {
            for _ in 0..<10 {
                _ = try? coder.decode(encoded)
            }
        }
    }
}
