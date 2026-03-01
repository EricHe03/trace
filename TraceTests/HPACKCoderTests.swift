//
//  HPACKCoderTests.swift
//  TraceTests
//
//  Updated for HPACK model snapshots/events after parser migration.
//

import XCTest
@testable import TraceCore

final class HPACKCoderTests: XCTestCase {
    func testHPACKSampleSnapshotHasExpectedStructure() {
        let snapshot = HPACKTableSnapshot.sample()

        XCTAssertFalse(snapshot.staticEntries.isEmpty)
        XCTAssertFalse(snapshot.dynamicEntries.isEmpty)
        XCTAssertGreaterThan(snapshot.maxSize, 0)
        XCTAssertGreaterThanOrEqual(snapshot.currentSize, 0)
    }

    func testHPACKSampleEventsContainSupportedEventTypes() {
        let events = HPACKTableEvent.sampleEvents()
        XCTAssertFalse(events.isEmpty)

        for event in events {
            switch event.type {
            case .entryAdded, .entryEvicted, .tableSizeUpdated:
                XCTAssertNotNil(event.timestamp)
            }
        }
    }

    func testHPACKSnapshotCodableRoundTrip() throws {
        let snapshot = HPACKTableSnapshot.sample()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HPACKTableSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.staticEntries.count, snapshot.staticEntries.count)
        XCTAssertEqual(decoded.dynamicEntries.count, snapshot.dynamicEntries.count)
        XCTAssertEqual(decoded.currentSize, snapshot.currentSize)
        XCTAssertEqual(decoded.maxSize, snapshot.maxSize)
    }
}
