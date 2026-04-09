//
//  HPACKEncoderTests.swift
//  TraceTests
//
//  Updated for HPACK event encoding semantics.
//

@testable import TraceCore
import XCTest

final class HPACKEncoderTests: XCTestCase {
    func testHPACKTableEventEntryAddedCodableRoundTrip() throws {
        let snapshot = HPACKTableSnapshot.sample()
        let event = HPACKTableEvent(
            type: .entryAdded(name: "authorization", value: "Bearer token", index: 62),
            tableSnapshot: snapshot
        )

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: encoded)

        switch decoded.type {
        case let .entryAdded(name, value, index):
            XCTAssertEqual(name, "authorization")
            XCTAssertEqual(value, "Bearer token")
            XCTAssertEqual(index, 62)
        default:
            XCTFail("Expected entryAdded event")
        }
    }

    func testHPACKTableEventEntryEvictedCodableRoundTrip() throws {
        let snapshot = HPACKTableSnapshot.sample()
        let event = HPACKTableEvent(
            type: .entryEvicted(name: "cookie", value: "session=abc", index: 63),
            tableSnapshot: snapshot
        )

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: encoded)

        switch decoded.type {
        case let .entryEvicted(name, value, index):
            XCTAssertEqual(name, "cookie")
            XCTAssertEqual(value, "session=abc")
            XCTAssertEqual(index, 63)
        default:
            XCTFail("Expected entryEvicted event")
        }
    }

    func testHPACKTableEventSizeUpdateCodableRoundTrip() throws {
        let snapshot = HPACKTableSnapshot.sample()
        let event = HPACKTableEvent(
            type: .tableSizeUpdated(newSize: 8192),
            tableSnapshot: snapshot
        )

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: encoded)

        switch decoded.type {
        case let .tableSizeUpdated(newSize):
            XCTAssertEqual(newSize, 8192)
        default:
            XCTFail("Expected tableSizeUpdated event")
        }
    }
}
