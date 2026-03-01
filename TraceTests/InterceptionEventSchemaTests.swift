//
//  InterceptionEventSchemaTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

import XCTest
@testable import TraceCore

final class InterceptionEventSchemaTests: XCTestCase {
    func testEventCodableIncludesRequiredFields() throws {
        let event = InterceptionEvent(
            type: .flowRouteDecision,
            sessionID: "session-1",
            tunnelGeneration: 2,
            flowID: 12,
            captureMode: "fullTunnelDualMITM",
            dualMITMPolicy: "strictMITM",
            protocolName: InterceptionProtocol.tcpTransparent.rawValue,
            destinationHost: "example.com",
            destinationPort: 443,
            action: .mitm,
            decisionReason: "default"
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(InterceptionEvent.self, from: data)

        XCTAssertEqual(decoded.type, .flowRouteDecision)
        XCTAssertEqual(decoded.sessionID, "session-1")
        XCTAssertEqual(decoded.tunnelGeneration, 2)
        XCTAssertEqual(decoded.flowID, 12)
        XCTAssertEqual(decoded.captureMode, "fullTunnelDualMITM")
        XCTAssertEqual(decoded.dualMITMPolicy, "strictMITM")
        XCTAssertEqual(decoded.protocolName, InterceptionProtocol.tcpTransparent.rawValue)
    }
}
