//
//  HPACKHuffmanTests.swift
//  TraceTests
//
//  Updated for NetworkRequest HTTP/2 HPACK metadata round-trip.
//

import XCTest
@testable import TraceCore

final class HPACKHuffmanTests: XCTestCase {
    func testNetworkRequestCodableWithHPACKMetadata() throws {
        let snapshot = HPACKTableSnapshot.sample()
        let events = HPACKTableEvent.sampleEvents()

        var request = NetworkRequest(
            url: "https://api.example.com/v1",
            method: .get,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.3,
            requestHeaders: [TraceHTTPHeader(key: ":method", value: "GET")],
            responseHeaders: [TraceHTTPHeader(key: ":status", value: "200")],
            requestBody: .empty,
            responseBody: BodyStorage.from(string: "ok"),
            protocolVersion: .http2
        )

        request.http2ConnectionInfo = HTTP2ConnectionInfo(
            settingsReceived: ["headerTableSize": 4096],
            settingsSent: ["enablePush": 0],
            goAwayReceived: false,
            lastStreamId: 1,
            connectionStartTime: Date(),
            connectionEndTime: Date(),
            hpackTableSnapshot: snapshot,
            hpackTableEvents: events
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(NetworkRequest.self, from: encoded)

        XCTAssertEqual(decoded.protocolVersion, .http2)
        XCTAssertEqual(decoded.http2ConnectionInfo?.hpackTableSnapshot?.maxSize, snapshot.maxSize)
        XCTAssertEqual(decoded.http2ConnectionInfo?.hpackTableEvents?.count, events.count)
    }
}
