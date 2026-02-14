//
//  HPACKHuffmanEncoderTests.swift
//  TraceTests
//
//  Updated for HPACK model event list behavior.
//

import XCTest
@testable import TraceCore

final class HPACKHuffmanEncoderTests: XCTestCase {
    func testHPACKTableEventArrayCodableRoundTrip() throws {
        let events = HPACKTableEvent.sampleEvents()

        let encoded = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([HPACKTableEvent].self, from: encoded)

        XCTAssertEqual(decoded.count, events.count)
    }

    func testHPACKEventsRetainTableSnapshotMetadata() throws {
        let events = HPACKTableEvent.sampleEvents()
        guard let first = events.first else {
            return XCTFail("Expected sample events")
        }

        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: encoded)

        XCTAssertEqual(decoded.tableSnapshot.maxSize, first.tableSnapshot.maxSize)
        XCTAssertEqual(decoded.tableSnapshot.staticEntries.count, first.tableSnapshot.staticEntries.count)
    }
}
