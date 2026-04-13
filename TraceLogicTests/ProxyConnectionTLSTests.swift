//
//  ProxyConnectionTLSTests.swift
//  TraceTests
//
//  Updated for NIOMITM proxy behavior.
//

@testable import TraceCore
@testable import TraceProxy
import XCTest

final class ProxyConnectionTLSTests: XCTestCase {
    override func tearDownWithError() throws {
        try NIORuntime.shared.shutdown(reason: .tests)
        try super.tearDownWithError()
    }

    func testMITMServerCanStartWithMITMDisabled() throws {
        let server = MITMProxyServer(port: 0)
        server.setMitmEnabled(false)
        server.setMitmAllowlist(["example.com"])

        XCTAssertNoThrow(try server.start())
        XCTAssertGreaterThanOrEqual(server.activeConnectionCount(), 0)
        server.stop()
    }

    func testMITMServerCanStartWithMITMEnabledAndAllowlist() throws {
        let server = MITMProxyServer(port: 0)
        server.setMitmEnabled(true)
        server.setMitmAllowlist(["api.example.com", "cdn.example.com"])

        XCTAssertNoThrow(try server.start())
        XCTAssertGreaterThanOrEqual(server.activeConnectionCount(), 0)
        server.stop()
    }

    func testMITMServerRawCaptureUpdatesDoNotCrash() {
        let server = MITMProxyServer(port: 0)

        server.configureRawCapture(enabled: false, writer: nil, limit: 0)
        server.updateRawCaptureLimit(8 * 1024 * 1024)

        XCTAssertEqual(server.activeConnectionCount(), 0)
    }
}
