//
//  NetworkEventTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

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

    func testTransportEventUnknownDoesNotShowFallback() {
        let request = TransportRequest(
            timestamp: Date(),
            sourceIP: "192.168.1.10",
            destinationIP: "93.184.216.34",
            sourcePort: 53000,
            destinationPort: 443,
            transport: .tcp,
            applicationProtocol: .unknown,
            parserOutcome: .fallbackUnknown,
            payload: .inline(Data([0x16, 0x03, 0x01])),
            payloadBytes: 3,
            ipVersion: 4,
            protocolNumber: 6,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 60,
            fragmentOffset: 0,
            moreFragments: false,
            flowKey: "tcp|192.168.1.10:53000|93.184.216.34:443"
        )
        let event = NetworkEvent.transportRequest(request)

        XCTAssertTrue(event.subtitle.contains("TCP"))
        XCTAssertTrue(event.subtitle.contains("Unknown"))
        XCTAssertFalse(event.subtitle.localizedCaseInsensitiveContains("fallback"))
    }

    func testTransportEventSignatureFallbackShowsFallback() {
        let request = TransportRequest(
            timestamp: Date(),
            sourceIP: "192.168.1.10",
            destinationIP: "8.8.8.8",
            sourcePort: 53001,
            destinationPort: 53,
            transport: .tcp,
            applicationProtocol: .unknown,
            parserOutcome: .fallbackSignatureOnly,
            payload: .inline(Data([0x00, 0x20])),
            payloadBytes: 2,
            ipVersion: 4,
            protocolNumber: 6,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 60,
            fragmentOffset: 0,
            moreFragments: false,
            flowKey: "tcp|192.168.1.10:53001|8.8.8.8:53"
        )
        let event = NetworkEvent.transportRequest(request)

        XCTAssertTrue(event.subtitle.localizedCaseInsensitiveContains("fallback"))
    }

    func testTransportEventHTTPProtocolUsesHTTPLabelAndTCPType() {
        let request = TransportRequest(
            timestamp: Date(),
            sourceIP: "192.168.1.10",
            destinationIP: "93.184.216.34",
            sourcePort: 53002,
            destinationPort: 80,
            transport: .tcp,
            applicationProtocol: .http,
            parserOutcome: .parsed,
            payload: .inline(Data("GET / HTTP/1.1\r\n".utf8)),
            payloadBytes: 16,
            ipVersion: 4,
            protocolNumber: 6,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 76,
            fragmentOffset: 0,
            moreFragments: false,
            flowKey: "tcp|192.168.1.10:53002|93.184.216.34:80"
        )
        let event = NetworkEvent.transportRequest(request)

        XCTAssertEqual(event.type, .tcp)
        XCTAssertTrue(event.subtitle.contains("HTTP"))
    }

    func testTransportEventTLSProtocolUsesTLSLabelAndTCPType() {
        let request = TransportRequest(
            timestamp: Date(),
            sourceIP: "192.168.1.10",
            destinationIP: "93.184.216.34",
            sourcePort: 53003,
            destinationPort: 443,
            transport: .tcp,
            applicationProtocol: .tls,
            parserOutcome: .parsed,
            payload: .inline(Data([0x16, 0x03, 0x03, 0x00, 0x2A])),
            payloadBytes: 5,
            ipVersion: 4,
            protocolNumber: 6,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 65,
            fragmentOffset: 0,
            moreFragments: false,
            flowKey: "tcp|192.168.1.10:53003|93.184.216.34:443"
        )
        let event = NetworkEvent.transportRequest(request)

        XCTAssertEqual(event.type, .tcp)
        XCTAssertTrue(event.subtitle.contains("TLS"))
    }

    func testQUICTransportEventShowsH3BadgeInSubtitle() {
        let request = TransportRequest(
            timestamp: Date(),
            sourceIP: "192.168.1.10",
            destinationIP: "203.0.113.10",
            sourcePort: 53004,
            destinationPort: 443,
            transport: .udp,
            applicationProtocol: .quic,
            parserOutcome: .parsed,
            payload: .inline(Data([0x01, 0x02, 0x03])),
            payloadBytes: 3,
            ipVersion: 4,
            protocolNumber: 17,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 63,
            fragmentOffset: 0,
            moreFragments: false,
            udpDatagramLength: 43,
            flowKey: "udp|192.168.1.10:53004|203.0.113.10:443",
            applicationProtocolHint: "h3"
        )
        let event = NetworkEvent.transportRequest(request)

        XCTAssertEqual(request.protocolBadgeText, "H3")
        XCTAssertTrue(event.subtitle.contains("QUIC"))
        XCTAssertTrue(event.subtitle.contains("H3"))
    }

    func testQUICTransportRequestIgnoresNonHTTP3ALPNBadge() {
        let request = TransportRequest(
            timestamp: Date(),
            sourceIP: "192.168.1.10",
            destinationIP: "203.0.113.20",
            sourcePort: 53005,
            destinationPort: 443,
            transport: .udp,
            applicationProtocol: .quic,
            parserOutcome: .parsed,
            payload: .inline(Data([0x01])),
            payloadBytes: 1,
            ipVersion: 4,
            protocolNumber: 17,
            hopLimit: 64,
            ipHeaderLength: 20,
            totalLength: 61,
            fragmentOffset: 0,
            moreFragments: false,
            udpDatagramLength: 41,
            flowKey: "udp|192.168.1.10:53005|203.0.113.20:443",
            applicationProtocolHint: "doq"
        )

        XCTAssertNil(request.protocolBadgeText)
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
