//
//  NetworkEventTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class NetworkEventTests: XCTestCase {

    // MARK: - NetworkEvent Tests

    func testHTTPRequestEvent() {
        let request = NetworkRequest.sample
        let event = NetworkEvent.httpRequest(request)

        XCTAssertEqual(event.id, request.id)
        XCTAssertEqual(event.timestamp, request.timestamp)
        XCTAssertEqual(event.type, .http)
        XCTAssertFalse(event.isActive)
        XCTAssertEqual(event.displayTitle, request.url)
    }

    func testWebSocketEvent() {
        let connection = WebSocketConnection.sample
        let event = NetworkEvent.webSocket(connection)

        XCTAssertEqual(event.id, connection.id)
        XCTAssertEqual(event.timestamp, connection.startTime)
        XCTAssertEqual(event.type, .webSocket)
        XCTAssertTrue(event.subtitle.contains("WebSocket"))
    }

    func testSSEEvent() {
        let connection = SSEConnection.sample
        let event = NetworkEvent.sse(connection)

        XCTAssertEqual(event.id, connection.id)
        XCTAssertEqual(event.timestamp, connection.startTime)
        XCTAssertEqual(event.type, .sse)
        XCTAssertTrue(event.subtitle.contains("SSE"))
    }

    func testTransportEvent() {
        let request = TransportRequest(
            timestamp: Date(),
            sourceIP: "192.168.1.10",
            destinationIP: "8.8.8.8",
            sourcePort: 53530,
            destinationPort: 53,
            transport: .udp,
            applicationProtocol: .dns,
            parserOutcome: .parsed,
            payload: .inline(Data([0x12, 0x34])),
            payloadBytes: 2,
            ipVersion: 4,
            protocolNumber: 17,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 48,
            fragmentOffset: 0,
            moreFragments: false,
            flowKey: "udp|192.168.1.10:53530|8.8.8.8:53"
        )
        let event = NetworkEvent.transportRequest(request)

        XCTAssertEqual(event.id, request.id)
        XCTAssertEqual(event.type, .dns)
        XCTAssertEqual(event.displayTitle, request.endpointSummary)
        XCTAssertTrue(event.subtitle.contains("DNS"))
    }

    func testDomain() {
        let request = NetworkRequest.sample
        let event = NetworkEvent.httpRequest(request)

        if let domain = event.domain {
            XCTAssertFalse(domain.isEmpty)
        }
    }

    func testSubtitle() {
        let request = NetworkRequest.sample
        let event = NetworkEvent.httpRequest(request)

        let subtitle = event.subtitle
        XCTAssertTrue(subtitle.contains(request.method.rawValue))
    }

    // MARK: - NetworkEventType Tests

    func testNetworkEventTypeIcon() {
        XCTAssertEqual(NetworkEventType.http.icon, "network")
        XCTAssertEqual(NetworkEventType.webSocket.icon, "cable.connector")
        XCTAssertEqual(NetworkEventType.sse.icon, "antenna.radiowaves.left.and.right")
        XCTAssertEqual(NetworkEventType.tcp.icon, "arrow.left.and.right.square")
        XCTAssertEqual(NetworkEventType.udp.icon, "arrow.triangle.2.circlepath")
        XCTAssertEqual(NetworkEventType.dns.icon, "globe")
    }

    func testNetworkEventTypeColor() {
        XCTAssertEqual(NetworkEventType.http.color, "blue")
        XCTAssertEqual(NetworkEventType.webSocket.color, "purple")
        XCTAssertEqual(NetworkEventType.sse.color, "orange")
        XCTAssertEqual(NetworkEventType.tcp.color, "teal")
        XCTAssertEqual(NetworkEventType.udp.color, "cyan")
        XCTAssertEqual(NetworkEventType.dns.color, "indigo")
    }

    func testNetworkEventTypeId() {
        XCTAssertEqual(NetworkEventType.http.id, "HTTP/HTTPS")
        XCTAssertEqual(NetworkEventType.webSocket.id, "WebSocket")
        XCTAssertEqual(NetworkEventType.sse.id, "SSE")
        XCTAssertEqual(NetworkEventType.dns.id, "DNS")
    }

    func testNetworkEventTypeAllCases() {
        let allCases = NetworkEventType.allCases
        XCTAssertEqual(allCases.count, 13)
        XCTAssertTrue(allCases.contains(.http))
        XCTAssertTrue(allCases.contains(.webSocket))
        XCTAssertTrue(allCases.contains(.sse))
        XCTAssertTrue(allCases.contains(.tcp))
        XCTAssertTrue(allCases.contains(.udp))
        XCTAssertTrue(allCases.contains(.dns))
        XCTAssertTrue(allCases.contains(.mdns))
        XCTAssertTrue(allCases.contains(.ntp))
        XCTAssertTrue(allCases.contains(.dhcpv4))
        XCTAssertTrue(allCases.contains(.dhcpv6))
        XCTAssertTrue(allCases.contains(.snmp))
        XCTAssertTrue(allCases.contains(.quic))
        XCTAssertTrue(allCases.contains(.transport))
    }

    // MARK: - Comparable Tests

    func testComparable() {
        let now = Date()
        let earlier = now.addingTimeInterval(-60)

        let request1 = NetworkRequest.sample(timestamp: earlier)
        let request2 = NetworkRequest.sample(timestamp: now)

        let event1 = NetworkEvent.httpRequest(request1)
        let event2 = NetworkEvent.httpRequest(request2)

        XCTAssertLessThan(event1, event2)
    }

    // MARK: - Equatable Tests

    func testEquatable() {
        let request = NetworkRequest.sample
        let event1 = NetworkEvent.httpRequest(request)
        let event2 = NetworkEvent.httpRequest(request)

        XCTAssertEqual(event1, event2)

        let otherRequest = NetworkRequest.sample
        let event3 = NetworkEvent.httpRequest(otherRequest)

        XCTAssertNotEqual(event1, event3)
    }
}
