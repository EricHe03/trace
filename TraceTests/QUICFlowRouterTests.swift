//
//  QUICFlowRouterTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/18.
//

import XCTest
@testable import TraceCore
@testable import TracePacket
@testable import TraceQUIC
@testable import TraceVPN

final class QUICFlowRouterTests: XCTestCase {
    func testResolveInterceptRouteFirstAttemptConsumesForIntercept() {
        let router = QUICFlowRouter(
            engineStatusProvider: {
                QUICEngineStatus(
                    availability: .available,
                    version: "test",
                    usingQuicheFFI: true
                )
            }
        )
        let route = router.resolveInterceptRoute(
            ipPacket: makeIPPacket(),
            udpPacket: makeUDPPacket(),
            udpForwarderAvailable: true,
            tunnelUDPSupported: false,
            tunnelPolicyRequired: false
        )

        XCTAssertEqual(route.forwardingDecision, .forwardDirect)
        XCTAssertEqual(route.inspectionOutcome, .intercepted)
        XCTAssertEqual(route.metadata.handshakeOutcome, .negotiated)
        XCTAssertEqual(route.metadata.failureReason, "quic_mitm_session_establishing")
        XCTAssertEqual(route.metadata.version, "0x00000001")
        XCTAssertEqual(route.metadata.destinationConnectionIDLength, 8)
        XCTAssertEqual(route.metadata.sourceConnectionIDLength, 4)
        XCTAssertTrue(route.consumeOriginalDatagram)
    }

    func testResolveInterceptRoutePassesThroughWhenEngineUnavailable() {
        let router = QUICFlowRouter(
            engineStatusProvider: {
                QUICEngineStatus(
                    availability: .unavailable,
                    version: "ffi-not-linked",
                    usingQuicheFFI: false
                )
            }
        )

        let route = router.resolveInterceptRoute(
            ipPacket: makeIPPacket(),
            udpPacket: makeUDPPacket(),
            udpForwarderAvailable: true,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false
        )

        XCTAssertEqual(route.forwardingDecision, .forwardTunnel)
        XCTAssertEqual(route.inspectionOutcome, .passThroughMarked)
        XCTAssertEqual(route.metadata.handshakeOutcome, .passThrough)
        XCTAssertEqual(route.metadata.failureReason, QUICMitmFailureReason.engineUnavailable.rawValue)
        XCTAssertFalse(route.consumeOriginalDatagram)
    }

    func testResolveInterceptRouteRecordsBackendFailureAfterBootstrapAttempt() async throws {
        let router = QUICFlowRouter()
        let ipPacket = makeIPPacket()
        let udpPacket = makeUDPPacket()

        _ = router.resolveInterceptRoute(
            ipPacket: ipPacket,
            udpPacket: udpPacket,
            udpForwarderAvailable: true,
            tunnelUDPSupported: false,
            tunnelPolicyRequired: false
        )

        var failureReason: String?
        for _ in 0..<40 {
            let route = router.resolveInterceptRoute(
                ipPacket: ipPacket,
                udpPacket: udpPacket,
                udpForwarderAvailable: true,
                tunnelUDPSupported: false,
                tunnelPolicyRequired: false
            )
            if let reason = route.metadata.failureReason,
               reason == QUICMitmFailureReason.engineUnavailable.rawValue ||
               reason == QUICMitmFailureReason.sessionCreateFailed.rawValue {
                failureReason = route.metadata.failureReason
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertTrue(
            failureReason == QUICMitmFailureReason.engineUnavailable.rawValue ||
                failureReason == QUICMitmFailureReason.sessionCreateFailed.rawValue
        )
    }

    func testResolveInterceptRouteEnforcesStrictTunnelPolicyWhenTunnelUnavailable() {
        let router = QUICFlowRouter()
        let route = router.resolveInterceptRoute(
            ipPacket: makeIPPacket(),
            udpPacket: makeUDPPacket(),
            udpForwarderAvailable: true,
            tunnelUDPSupported: false,
            tunnelPolicyRequired: true
        )

        XCTAssertEqual(route.forwardingDecision, .forwardTunnel)
        XCTAssertEqual(route.inspectionOutcome, .passThroughMarked)
        XCTAssertEqual(route.metadata.handshakeOutcome, .passThrough)
        XCTAssertEqual(route.metadata.failureReason, "quic_tunnel_required_unavailable")
        XCTAssertFalse(route.consumeOriginalDatagram)
    }

    func testIngestUpstreamDatagramReturnsFalseWithoutKnownFlow() {
        let router = QUICFlowRouter()
        XCTAssertFalse(
            router.ingestUpstreamDatagram(
                ipPacket: makeReverseIPPacket(),
                udpPacket: makeReverseUDPPacket()
            )
        )
    }

    func testIngestUpstreamDatagramReturnsFalseWhileSessionEstablishing() {
        let router = QUICFlowRouter()
        _ = router.resolveInterceptRoute(
            ipPacket: makeIPPacket(),
            udpPacket: makeUDPPacket(),
            udpForwarderAvailable: true,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false
        )

        XCTAssertFalse(
            router.ingestUpstreamDatagram(
                ipPacket: makeReverseIPPacket(),
                udpPacket: makeReverseUDPPacket()
            )
        )
    }
}

private extension QUICFlowRouterTests {
    func makeIPPacket() -> IPPacket {
        IPPacket(
            version: 4,
            headerLength: 20,
            totalLength: 20 + 8 + 19,
            protocolNumber: 17,
            hopLimit: 64,
            fragmentOffset: 0,
            moreFragments: false,
            source: .v4(0x0A000001),
            destination: .v4(0xC0A80101),
            payload: Data()
        )
    }

    func makeUDPPacket() -> UDPPacket {
        let payload = Data([
            0xC0, // long header
            0x00, 0x00, 0x00, 0x01, // version
            0x08, // dcid len
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // dcid
            0x04, // scid len
            0x09, 0x0A, 0x0B, 0x0C // scid
        ])
        return UDPPacket(
            sourcePort: 50_000,
            destinationPort: 443,
            length: UInt16(8 + payload.count),
            payload: payload
        )
    }

    func makeReverseIPPacket() -> IPPacket {
        IPPacket(
            version: 4,
            headerLength: 20,
            totalLength: 20 + 8 + 19,
            protocolNumber: 17,
            hopLimit: 64,
            fragmentOffset: 0,
            moreFragments: false,
            source: .v4(0xC0A80101),
            destination: .v4(0x0A000001),
            payload: Data()
        )
    }

    func makeReverseUDPPacket() -> UDPPacket {
        let packet = makeUDPPacket()
        return UDPPacket(
            sourcePort: packet.destinationPort,
            destinationPort: packet.sourcePort,
            length: packet.length,
            payload: packet.payload
        )
    }
}
