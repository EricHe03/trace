//
//  PacketFlowLoopDecisionTests.swift
//  TraceTests
//
//  Created by Codex on 2026/01/28.
//

import XCTest
@testable import TraceVPN

final class PacketFlowLoopDecisionTests: XCTestCase {
    func testDecideUDPForwardingBlocksQUICWhenEnabled() {
        let result = PacketFlowLoop.decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .direct,
            sourcePort: 12345,
            destinationPort: 443,
            blockQUICEnabled: true
        )
        XCTAssertEqual(result.decision, .dropQUIC)
        XCTAssertTrue(result.isQUIC)
    }

    func testDecideUDPForwardingDirectMode() {
        let result = PacketFlowLoop.decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .direct,
            sourcePort: 12345,
            destinationPort: 53,
            blockQUICEnabled: false
        )
        XCTAssertEqual(result.decision, .forwardDirect)
        XCTAssertFalse(result.isQUIC)
    }

    func testDecideUDPForwardingSplitModeSendsQUICToTunnel() {
        let result = PacketFlowLoop.decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .split,
            sourcePort: 12345,
            destinationPort: 443,
            blockQUICEnabled: false
        )
        XCTAssertEqual(result.decision, .forwardTunnel)
        XCTAssertTrue(result.isQUIC)
    }

    func testDecideUDPForwardingSplitModeSendsNonQUICDirect() {
        let result = PacketFlowLoop.decideUDPForwarding(
            udpForwarderAvailable: true,
            mode: .split,
            sourcePort: 12345,
            destinationPort: 53,
            blockQUICEnabled: false
        )
        XCTAssertEqual(result.decision, .forwardDirect)
        XCTAssertFalse(result.isQUIC)
    }

    func testDecideUDPForwardingWithoutUDPForwarderAlwaysUsesTunnel() {
        let result = PacketFlowLoop.decideUDPForwarding(
            udpForwarderAvailable: false,
            mode: .direct,
            sourcePort: 12345,
            destinationPort: 53,
            blockQUICEnabled: false
        )
        XCTAssertEqual(result.decision, .forwardTunnel)
        XCTAssertFalse(result.isQUIC)
    }
}

