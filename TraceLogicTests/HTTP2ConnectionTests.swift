//
//  HTTP2ConnectionTests.swift
//  TraceTests
//
//  Updated for NIO-based HTTP/2 capture models.
//

@testable import TraceCore
import XCTest

final class HTTP2ConnectionTests: XCTestCase {
    func testHTTP2ConnectionInfoActiveAndDuration() throws {
        let start = Date()
        var info = HTTP2ConnectionInfo(
            settingsReceived: ["maxConcurrentStreams": 100],
            settingsSent: ["initialWindowSize": 65535],
            goAwayReceived: false,
            lastStreamId: 7,
            connectionStartTime: start,
            connectionEndTime: nil,
            hpackTableSnapshot: nil,
            hpackTableEvents: nil
        )

        XCTAssertTrue(info.isActive)
        XCTAssertNil(info.duration)

        info.connectionEndTime = start.addingTimeInterval(2.5)
        XCTAssertEqual(try XCTUnwrap(info.duration), 2.5, accuracy: 0.0001)
    }

    func testHTTP2ConnectionInfoGoAwayMarksInactive() {
        let info = HTTP2ConnectionInfo(
            settingsReceived: [:],
            settingsSent: [:],
            goAwayReceived: true,
            lastStreamId: 3,
            connectionStartTime: Date(),
            connectionEndTime: nil,
            hpackTableSnapshot: nil,
            hpackTableEvents: nil
        )

        XCTAssertFalse(info.isActive)
    }

    func testHTTP2ConnectionInfoCodableRoundTrip() throws {
        let original = HTTP2ConnectionInfo(
            settingsReceived: ["headerTableSize": 4096],
            settingsSent: ["enablePush": 0],
            goAwayReceived: false,
            lastStreamId: 11,
            connectionStartTime: Date(),
            connectionEndTime: Date().addingTimeInterval(1),
            hpackTableSnapshot: nil,
            hpackTableEvents: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(HTTP2ConnectionInfo.self, from: data)

        XCTAssertEqual(decoded.settingsReceived, original.settingsReceived)
        XCTAssertEqual(decoded.settingsSent, original.settingsSent)
        XCTAssertEqual(decoded.goAwayReceived, original.goAwayReceived)
        XCTAssertEqual(decoded.lastStreamId, original.lastStreamId)
    }
}
