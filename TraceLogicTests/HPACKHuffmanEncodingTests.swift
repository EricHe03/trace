//
//  HPACKHuffmanEncodingTests.swift
//  TraceTests
//
//  Updated for HPACK integration with HTTP/2 connection info.
//

@testable import TraceCore
import XCTest

final class HPACKHuffmanEncodingTests: XCTestCase {
    func testHTTP2ConnectionInfoCarriesHPACKSnapshot() {
        let snapshot = HPACKTableSnapshot.sample()

        let info = HTTP2ConnectionInfo(
            settingsReceived: [:],
            settingsSent: [:],
            goAwayReceived: false,
            lastStreamId: nil,
            connectionStartTime: Date(),
            connectionEndTime: nil,
            hpackTableSnapshot: snapshot,
            hpackTableEvents: nil
        )

        XCTAssertNotNil(info.hpackTableSnapshot)
        XCTAssertEqual(info.hpackTableSnapshot?.maxSize, snapshot.maxSize)
    }

    func testHTTP2ConnectionInfoCarriesHPACKEvents() {
        let events = HPACKTableEvent.sampleEvents()

        let info = HTTP2ConnectionInfo(
            settingsReceived: [:],
            settingsSent: [:],
            goAwayReceived: false,
            lastStreamId: nil,
            connectionStartTime: Date(),
            connectionEndTime: nil,
            hpackTableSnapshot: nil,
            hpackTableEvents: events
        )

        XCTAssertEqual(info.hpackTableEvents?.count, events.count)
    }
}
