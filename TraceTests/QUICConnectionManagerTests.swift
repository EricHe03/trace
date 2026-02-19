//
//  QUICConnectionManagerTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/18.
//

import XCTest
@testable import TraceQUIC

final class QUICConnectionManagerTests: XCTestCase {
    func testSnapshotTracksOutcomeCounters() async {
        let manager = QUICConnectionManager()

        await manager.recordPolicyPassThrough(reason: "quic_policy_pass_through_direct")
        await manager.recordFlowSeen()
        await manager.recordFlowSeen()
        await manager.recordIntercepted()
        await manager.recordBlocked()
        await manager.recordTunnelForwarded()
        await manager.recordPassThroughFallback(reason: "quic_mitm_engine_unavailable")
        await manager.recordFailure(reason: "handshake_failed")
        await manager.recordHTTP3RequestCaptured(isSSE: false)
        await manager.recordHTTP3RequestCaptured(isSSE: true)

        let snapshot = await manager.snapshot()

        XCTAssertEqual(snapshot.quicFlowsSeenTotal, 2)
        XCTAssertEqual(snapshot.quicFlowsInterceptedTotal, 1)
        XCTAssertEqual(snapshot.quicFlowsBlockedTotal, 1)
        XCTAssertEqual(snapshot.quicFlowsTunnelForwardedTotal, 1)
        XCTAssertEqual(snapshot.quicFlowsPassThroughTotal, 2)
        XCTAssertEqual(snapshot.totalPassThroughFallbacks, 1)
        XCTAssertEqual(snapshot.totalFailures, 1)
        XCTAssertEqual(snapshot.quicMitmFailuresTotal, 2)
        XCTAssertEqual(snapshot.http3RequestsCapturedTotal, 2)
        XCTAssertEqual(snapshot.http3SSEStreamsCapturedTotal, 1)
        XCTAssertEqual(snapshot.quicMitmFailuresByReason["quic_mitm_engine_unavailable"], 1)
        XCTAssertEqual(snapshot.quicMitmFailuresByReason["handshake_failed"], 1)
        XCTAssertEqual(snapshot.recentFallbackReasons.last, "handshake_failed")
    }
}
