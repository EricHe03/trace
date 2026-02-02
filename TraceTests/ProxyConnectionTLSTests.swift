//
//  ProxyConnectionTLSTests.swift
//  TraceTests
//
//  Created by Claude on 2026-02-01.
//

import XCTest
import Network
@testable import TraceProxy
@testable import TraceSecurity
@testable import TraceCore

final class ProxyConnectionTLSTests: XCTestCase {
    // MARK: - Properties

    var sut: MockProxyConnection!

    // MARK: - Setup & Teardown

    override func setUp() {
        super.setUp()
        sut = MockProxyConnection()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Connection Creation Tests

    func testCreateTLSServerConnectionReturnsConnection() {
        // Given
        let host = "api.example.com"
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithDifferentPorts() {
        // Given
        let host = "example.com"
        let ports: [UInt16] = [443, 8443, 9443, 10443]

        for port in ports {
            // When
            let connection = sut.createTLSServerConnection(to: host, port: port)

            // Then
            XCTAssertNotNil(connection, "Failed to create connection for port \(port)")
        }
    }

    func testCreateTLSServerConnectionWithDifferentHosts() {
        // Given
        let hosts = ["api.example.com", "cdn.example.com", "static.example.com"]
        let port: UInt16 = 443

        for host in hosts {
            // When
            let connection = sut.createTLSServerConnection(to: host, port: port)

            // Then
            XCTAssertNotNil(connection, "Failed to create connection for host \(host)")
        }
    }

    // MARK: - Port Validation Tests

    func testCreateTLSServerConnectionWithPort80() {
        // Given
        let host = "example.com"
        let port: UInt16 = 80

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithPort1() {
        // Given
        let host = "example.com"
        let port: UInt16 = 1

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithMaxPort() {
        // Given
        let host = "example.com"
        let port: UInt16 = 65535

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    // MARK: - Host Validation Tests

    func testCreateTLSServerConnectionWithIPv4Address() {
        // Given
        let host = "192.168.1.1"
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithIPv6Address() {
        // Given
        let host = "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithLocalhost() {
        // Given
        let host = "localhost"
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithWildcardDomain() {
        // Given
        let host = "*.example.com"
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    // MARK: - Edge Cases

    func testCreateTLSServerConnectionWithEmptyHost() {
        // Given
        let host = ""
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithVeryLongHostname() {
        // Given
        let host = String(repeating: "a", count: 253) + ".com"
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithUnicodeHost() {
        // Given
        let host = "例え.jp"
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    func testCreateTLSServerConnectionWithPunycodeDomain() {
        // Given
        let host = "xn--r8jz45g.jp" // 例え.jp in punycode
        let port: UInt16 = 443

        // When
        let connection = sut.createTLSServerConnection(to: host, port: port)

        // Then
        XCTAssertNotNil(connection)
    }

    // MARK: - Multiple Connections Tests

    func testCreateMultipleTLSConnections() {
        // Given
        let host = "example.com"
        let port: UInt16 = 443
        let count = 10

        var connections: [NWConnection] = []

        // When
        for _ in 0 ..< count {
            if let connection = sut.createTLSServerConnection(to: host, port: port) {
                connections.append(connection)
            }
        }

        // Then
        XCTAssertEqual(connections.count, count)
    }

    func testCreateConnectionsToDifferentHostsSimultaneously() {
        // Given
        let hosts = [
            "api.example.com",
            "cdn.example.com",
            "static.example.com",
            "auth.example.com"
        ]
        let port: UInt16 = 443

        var connections: [String: NWConnection] = [:]

        // When
        for host in hosts {
            if let connection = sut.createTLSServerConnection(to: host, port: port) {
                connections[host] = connection
            }
        }

        // Then
        XCTAssertEqual(connections.count, hosts.count)
    }

    // MARK: - Special Port Cases

    func testCreateTLSServerConnectionWithNonStandardTLSPorts() {
        // Given
        let host = "example.com"
        let ports: [UInt16] = [8443, 9443, 10443, 4443]

        for port in ports {
            // When
            let connection = sut.createTLSServerConnection(to: host, port: port)

            // Then
            XCTAssertNotNil(connection, "Failed to create connection for port \(port)")
        }
    }
}

// MARK: - Mock Proxy Connection

class MockProxyConnection: ProxyConnection {
    init() {
        let connection = NWConnection(host: "127.0.0.1", port: 80, using: .tcp)
        super.init(
            connection: connection,
            mitmAllowlist: [],
            mitmEnabled: true,
            transparentTLSModeEnabled: false,
            eventLog: nil,
            throttler: PacketThrottler(),
            captureConfig: .default
        )
    }
}
