//
//  MITMProxyServerTests.swift
//  TraceTests
//
//  Updated for NIO MITM server lifecycle.
//

import XCTest
@testable import TraceCore
@testable import TraceProxy

final class MITMProxyServerTests: XCTestCase {
    override func tearDownWithError() throws {
        try NIORuntime.shared.shutdown(reason: .tests)
        try super.tearDownWithError()
    }

    func testStartStopIsIdempotent() throws {
        let server = MITMProxyServer(port: 0)

        XCTAssertNoThrow(try server.start())
        XCTAssertNoThrow(try server.start())

        XCTAssertGreaterThanOrEqual(server.activeConnectionCount(), 0)

        server.stop()
        server.stop()
    }

    func testConfigurationAndTogglesCanBeUpdatedBeforeStart() {
        let server = MITMProxyServer(port: 0)

        server.updateConfiguration([
            "transparentTLSModeEnabled": true,
            "proxyTransportBackend": "legacy"
        ])
        server.setMitmAllowlist([" Example.com ", "", "api.example.com"])
        server.setMitmEnabled(true)
        server.updateThrottlingState(.disabled)
        server.updateRawCaptureLimit(16 * 1024 * 1024)
        server.configureRawCapture(enabled: false, writer: nil, limit: 0)

        XCTAssertEqual(server.activeConnectionCount(), 0)
    }

    func testLegacyTransparentTLSConfigKeyAccepted() {
        let server = MITMProxyServer(port: 0)

        server.updateConfiguration([
            "enableTransparentTLSMode": true
        ])

        XCTAssertEqual(server.activeConnectionCount(), 0)
    }

    func testTransparentTLSModeConfigCanToggleWithoutCrash() {
        let server = MITMProxyServer(port: 0)

        server.updateConfiguration([
            "transparentTLSModeEnabled": true
        ])
        server.updateConfiguration([
            "transparentTLSModeEnabled": false
        ])
        server.updateConfiguration([
            "enableTransparentTLSMode": true
        ])

        XCTAssertEqual(server.activeConnectionCount(), 0)
    }
}
