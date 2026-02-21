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

    func testResolveInterceptRouteSuppressesDuplicatePassThroughLogsForSameFlowReason() {
        final class EventStore: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [String] = []

            func append(_ value: String) {
                lock.lock()
                events.append(value)
                lock.unlock()
            }

            func snapshot() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return events
            }
        }
        let eventStore = EventStore()

        let router = QUICFlowRouter(
            engineStatusProvider: {
                QUICEngineStatus(
                    availability: .unavailable,
                    version: "ffi-not-linked",
                    usingQuicheFFI: false
                )
            },
            eventLogHandler: { type, message in
                guard type == "quic_intercept" else { return }
                eventStore.append(message)
            }
        )

        let ipPacket = makeIPPacket()
        let udpPacket = makeUDPPacket()

        _ = router.resolveInterceptRoute(
            ipPacket: ipPacket,
            udpPacket: udpPacket,
            udpForwarderAvailable: true,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false
        )
        _ = router.resolveInterceptRoute(
            ipPacket: ipPacket,
            udpPacket: udpPacket,
            udpForwarderAvailable: true,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false
        )

        let passThroughLogs = eventStore.snapshot().filter { $0.contains("outcome=pass_through") }
        XCTAssertEqual(passThroughLogs.count, 1)
    }

    func testResolveInterceptRoutePassesThroughWhenDualMITMCircuitBreakerIsDegraded() {
        DualMITMCircuitBreaker.shared.resetForTesting()
        defer {
            DualMITMCircuitBreaker.shared.configure(enabled: false)
            DualMITMCircuitBreaker.shared.resetForTesting()
        }

        DualMITMCircuitBreaker.shared.configure(
            enabled: true,
            cooldownSeconds: 300,
            quicWindowSeconds: 60
        )
        DualMITMCircuitBreaker.shared.recordQUICInterceptSample(failed: true)
        DualMITMCircuitBreaker.shared.recordQUICInterceptSample(failed: true)
        DualMITMCircuitBreaker.shared.recordQUICInterceptSample(failed: true)
        DualMITMCircuitBreaker.shared.recordQUICInterceptSample(failed: false)
        DualMITMCircuitBreaker.shared.recordQUICInterceptSample(failed: false)

        let router = QUICFlowRouter(
            dualMITMPolicy: .adaptiveFailOpen,
            dualMITMCircuitBreakerEnabled: true
        )

        let route = router.resolveInterceptRoute(
            ipPacket: makeIPPacket(),
            udpPacket: makeUDPPacket(),
            udpForwarderAvailable: true,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false
        )

        XCTAssertEqual(route.inspectionOutcome, .passThroughMarked)
        XCTAssertEqual(route.metadata.handshakeOutcome, .passThrough)
        XCTAssertEqual(route.metadata.failureReason, "dual_mitm_circuit_breaker")
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

    func testResolveInterceptRouteFallsBackToDirectWhenTunnelUnavailable() {
        let router = QUICFlowRouter()
        let route = router.resolveInterceptRoute(
            ipPacket: makeIPPacket(),
            udpPacket: makeUDPPacket(),
            udpForwarderAvailable: true,
            tunnelUDPSupported: false,
            tunnelPolicyRequired: true
        )

        XCTAssertEqual(route.forwardingDecision, .forwardDirect)
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

    func testNormalizeAuthorityStripsPortTrailingDotAndBrackets() {
        let router = QUICFlowRouter()

        XCTAssertEqual(router.normalizeAuthority(" Example.COM.:443 "), "example.com")
        XCTAssertEqual(router.normalizeAuthority("[2001:db8::1]"), "2001:db8::1")
        XCTAssertEqual(router.normalizeAuthority("host.test."), "host.test")
    }

    func testNormalizeAuthorityRemovesIPv6ScopeIdentifier() {
        let router = QUICFlowRouter()

        XCTAssertEqual(router.normalizeAuthority("fe80::1%en0"), "fe80::1")
    }

    func testShouldIssueCertificateRejectsWhitespaceOnlyAuthority() {
        let router = QUICFlowRouter()

        XCTAssertFalse(router.shouldIssueCertificate(for: ""))
        XCTAssertFalse(router.shouldIssueCertificate(for: " "))
        XCTAssertTrue(router.shouldIssueCertificate(for: "192.0.2.10"))
        XCTAssertTrue(router.shouldIssueCertificate(for: "example.com"))
    }

    func testMITMAutoBypassReasonForNoProgressFailOpenIsIgnored() {
        let reason = QUICFlowRouter.mitmAutoBypassReason(forQUICFailure: "quic_no_progress_fail_open")
        XCTAssertNil(reason)
    }

    func testMITMAutoBypassReasonForHandshakeFailureIsIgnored() {
        let reason = QUICFlowRouter.mitmAutoBypassReason(forQUICFailure: "handshakeFailed")
        XCTAssertNil(reason)
    }

    func testMITMAutoBypassReasonIgnoresNonBypassFailures() {
        let reason = QUICFlowRouter.mitmAutoBypassReason(forQUICFailure: "quic_retry_with_authority_failed")
        XCTAssertNil(reason)
    }

    func testShouldEnableHostFailOpenForNoProgressReason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "quic_no_progress_fail_open"))
    }

    func testShouldEnableHostFailOpenForHandshakeFailedReason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "handshakeFailed"))
    }

    func testShouldEnableHostFailOpenForCertificatePinningReason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "certificatePinning"))
    }

    func testShouldEnableHostFailOpenForClosedBeforeHTTP3Reason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "quic_closed_before_http3_handshakeFailed"))
    }

    func testShouldEnableHostFailOpenSkipsUnrelatedReason() {
        XCTAssertFalse(QUICFlowRouter.shouldEnableHostFailOpen(for: "quic_mitm_ingest_failed"))
    }

    func testPrefersDirectFailOpenForwardingForNoProgressReason() {
        XCTAssertTrue(QUICFlowRouter.prefersDirectFailOpenForwarding(for: "quic_no_progress_fail_open"))
    }

    func testPrefersDirectFailOpenForwardingForCircuitBreakerReason() {
        XCTAssertTrue(QUICFlowRouter.prefersDirectFailOpenForwarding(for: "dual_mitm_circuit_breaker"))
    }

    func testPrefersDirectFailOpenForwardingSkipsUnrelatedReason() {
        XCTAssertFalse(QUICFlowRouter.prefersDirectFailOpenForwarding(for: "quic_mitm_ingest_failed"))
    }

    func testShouldFailOpenForNoProgressWhenSessionStalls() {
        let establishedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 104)

        let shouldFailOpen = QUICFlowRouter.shouldFailOpenForNoProgress(
            establishedAt: establishedAt,
            lastProgressAt: Date(timeIntervalSinceReferenceDate: 102),
            clientDatagramsSeen: 4,
            processedStreams: 0,
            now: now,
            gracePeriod: 2.5,
            idleTimeout: 1.0,
            minimumClientDatagrams: 3
        )

        XCTAssertTrue(shouldFailOpen)
    }

    func testShouldFailOpenForNoProgressSkipsAfterStreamProcessed() {
        let establishedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 106)

        let shouldFailOpen = QUICFlowRouter.shouldFailOpenForNoProgress(
            establishedAt: establishedAt,
            lastProgressAt: Date(timeIntervalSinceReferenceDate: 104),
            clientDatagramsSeen: 5,
            processedStreams: 1,
            now: now,
            gracePeriod: 2.5,
            idleTimeout: 1.0,
            minimumClientDatagrams: 3
        )

        XCTAssertFalse(shouldFailOpen)
    }

    func testShouldFailOpenForNoProgressRequiresMinimumClientDatagrams() {
        let establishedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 106)

        let shouldFailOpen = QUICFlowRouter.shouldFailOpenForNoProgress(
            establishedAt: establishedAt,
            lastProgressAt: Date(timeIntervalSinceReferenceDate: 101),
            clientDatagramsSeen: 2,
            processedStreams: 0,
            now: now,
            gracePeriod: 2.5,
            idleTimeout: 1.0,
            minimumClientDatagrams: 3
        )

        XCTAssertFalse(shouldFailOpen)
    }

    func testShouldFailOpenForNoProgressUsesAbsoluteTimeoutEvenWithRecentDatagramProgress() {
        let establishedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 105)

        let shouldFailOpen = QUICFlowRouter.shouldFailOpenForNoProgress(
            establishedAt: establishedAt,
            lastProgressAt: Date(timeIntervalSinceReferenceDate: 104.8),
            clientDatagramsSeen: 6,
            processedStreams: 0,
            now: now,
            gracePeriod: 2.5,
            idleTimeout: 1.0,
            minimumClientDatagrams: 3,
            absoluteTimeout: 4.0
        )

        XCTAssertTrue(shouldFailOpen)
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
