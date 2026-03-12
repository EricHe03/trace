//
//  QUICFlowRouterTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/18.
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

    func testResolveInterceptRouteBlocksWhenPolicyEngineRejectsInitialFlow() {
        let policyEngine = DualMITMPolicyEngine(
            snapshot: DualMITMPolicySnapshot(
                tcpTransparentMITMEnabled: true,
                tcpInterceptPorts: [80, 443],
                mitmProxyHost: "127.0.0.1",
                mitmProxyPort: 8888,
                policyMode: .strictMITM,
                circuitBreakerEnabled: true,
                featureFlags: .init(
                    shadowEnabled: true,
                    enforceTCPRouting: false,
                    enforceProxyRouting: false,
                    enforceQUICRouting: true
                )
            )
        )
        let router = QUICFlowRouter(
            engineStatusProvider: {
                QUICEngineStatus(
                    availability: .available,
                    version: "test",
                    usingQuicheFFI: true
                )
            },
            dualMITMPolicy: .strictMITM,
            dualMITMPolicyEngine: policyEngine
        )

        let route = router.resolveInterceptRoute(
            ipPacket: makeIPPacket(),
            udpPacket: makeUDPPacket(destinationPort: 0),
            udpForwarderAvailable: true,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false
        )

        XCTAssertEqual(route.forwardingDecision, .dropQUIC)
        XCTAssertEqual(route.inspectionOutcome, .blocked)
        XCTAssertEqual(route.metadata.handshakeOutcome, .blocked)
        XCTAssertEqual(route.metadata.failureReason, "invalid_destination")
        XCTAssertFalse(route.consumeOriginalDatagram)
    }

    func testResolveInterceptRouteBlocksWhenEngineUnavailableAndPolicyEnforced() {
        let policyEngine = DualMITMPolicyEngine(
            snapshot: DualMITMPolicySnapshot(
                tcpTransparentMITMEnabled: true,
                tcpInterceptPorts: [80, 443],
                mitmProxyHost: "127.0.0.1",
                mitmProxyPort: 8888,
                policyMode: .strictMITM,
                circuitBreakerEnabled: true,
                featureFlags: .init(
                    shadowEnabled: true,
                    enforceTCPRouting: false,
                    enforceProxyRouting: false,
                    enforceQUICRouting: true
                )
            )
        )
        let router = QUICFlowRouter(
            engineStatusProvider: {
                QUICEngineStatus(
                    availability: .unavailable,
                    version: "ffi-not-linked",
                    usingQuicheFFI: false
                )
            },
            dualMITMPolicy: .strictMITM,
            dualMITMPolicyEngine: policyEngine
        )

        let route = router.resolveInterceptRoute(
            ipPacket: makeIPPacket(),
            udpPacket: makeUDPPacket(),
            udpForwarderAvailable: true,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false
        )

        XCTAssertEqual(route.forwardingDecision, .dropQUIC)
        XCTAssertEqual(route.inspectionOutcome, .blocked)
        XCTAssertEqual(route.metadata.handshakeOutcome, .blocked)
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

    func testResolveInterceptRouteSuppressesDuplicateInterceptLogsForSameFlowSignature() {
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
                    availability: .available,
                    version: "test",
                    usingQuicheFFI: true
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

        let interceptLogs = eventStore.snapshot().filter { $0.contains("outcome=intercepted") }
        XCTAssertEqual(interceptLogs.count, 1)
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
            quicWindowSeconds: 60,
            quicMinimumSamples: 5
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

    func testShouldEnableHostFailOpenSkipsNoProgressReason() {
        XCTAssertFalse(QUICFlowRouter.shouldEnableHostFailOpen(for: "quic_no_progress_fail_open"))
    }

    func testShouldEnableHostFailOpenForHandshakeFailedReason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "handshakeFailed"))
    }

    func testShouldEnableHostFailOpenForCertificatePinningReason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "certificatePinning"))
    }

    func testShouldEnableHostFailOpenForCanonicalCertificatePinningReason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "quic_certificate_pinning"))
    }

    func testShouldEnableHostFailOpenForClosedBeforeHTTP3Reason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "quic_closed_before_http3_handshakeFailed"))
    }

    func testShouldEnableHostFailOpenForCanonicalAuthorityRetryReason() {
        XCTAssertTrue(QUICFlowRouter.shouldEnableHostFailOpen(for: "quic_authority_retry_failed"))
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

    func testPrefersDirectFailOpenForwardingForTunnelUnavailableReason() {
        XCTAssertTrue(QUICFlowRouter.prefersDirectFailOpenForwarding(for: "quic_tunnel_required_unavailable"))
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

    func testShouldFailOpenForNoProgressUsesBudgetStartAcrossRetries() {
        let budgetStart = Date(timeIntervalSinceReferenceDate: 100)
        let establishedAtAfterRetry = Date(timeIntervalSinceReferenceDate: 103)
        let now = Date(timeIntervalSinceReferenceDate: 105)

        let shouldFailOpen = QUICFlowRouter.shouldFailOpenForNoProgress(
            budgetStartAt: budgetStart,
            establishedAt: establishedAtAfterRetry,
            lastProgressAt: establishedAtAfterRetry,
            clientDatagramsSeen: 6,
            processedStreams: 0,
            now: now,
            gracePeriod: 1.0,
            idleTimeout: 10.0,
            minimumClientDatagrams: 2,
            absoluteTimeout: 4.0
        )

        XCTAssertTrue(shouldFailOpen)
    }

    func testShouldFailOpenForNoProgressHonorsConfiguredMinimumDatagrams() {
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
            minimumClientDatagrams: 2
        )

        XCTAssertTrue(shouldFailOpen)
    }

    func testAuthorityRetryPolicySkipsHostnameToHostname() {
        let reason = QUICFlowRouter.authorityRetrySkipReason(
            currentAuthority: "example.com",
            nextAuthority: "api.example.com",
            attemptsUsed: 0,
            maxAttempts: 1,
            lastAuthorityRetry: nil
        )

        XCTAssertEqual(reason, "retry_policy_hostname_already_known")
    }

    func testAuthorityRetryPolicyAllowsIPToHostnameWithinLimit() {
        let reason = QUICFlowRouter.authorityRetrySkipReason(
            currentAuthority: "192.0.2.10",
            nextAuthority: "example.com",
            attemptsUsed: 0,
            maxAttempts: 1,
            lastAuthorityRetry: nil
        )

        XCTAssertNil(reason)
    }

    func testAuthorityRetryPolicyStopsWhenAttemptLimitReached() {
        let reason = QUICFlowRouter.authorityRetrySkipReason(
            currentAuthority: "192.0.2.10",
            nextAuthority: "example.com",
            attemptsUsed: 1,
            maxAttempts: 1,
            lastAuthorityRetry: nil
        )

        XCTAssertEqual(reason, "attempt_exhausted")
    }

    func testScheduleAuthorityRetryRequeuesBufferedClientDatagrams() {
        let router = QUICFlowRouter(maxAuthorityRetryAttempts: 1)
        let flowKey = QUICFlowRouter.FlowKey(
            sourceIP: .v4(0x0A000001),
            sourcePort: 50_000,
            destinationIP: .v4(0xC0A80101),
            destinationPort: 443
        )
        let datagram1 = Data([0xC0, 0x00, 0x01])
        let datagram2 = Data([0xC0, 0x00, 0x02])
        let datagram3 = Data([0xC0, 0x00, 0x03])
        let session = QUICMitmSession(flowID: UUID(), host: "192.0.2.10", port: 443)
        var state = QUICFlowRouter.FlowSessionState(
            flowID: UUID(),
            host: "192.0.2.10",
            port: 443,
            clientIP: .v4(0x0A000001),
            clientPort: 50_000,
            serverIP: .v4(0xC0A80101),
            serverPort: 443,
            upstreamForwardingDecision: .forwardDirect,
            now: Date(),
            tunnelPolicyRequired: false
        )
        state.session = session
        state.isEstablishing = false
        state.isEstablished = true
        state.recentClientDatagrams = [datagram1, datagram2]
        state.pendingDatagrams = [QUICFlowRouter.QueuedDatagram(payload: datagram3, fromClient: true)]

        router.stateQueue.sync {
            router.flowStates[flowKey] = state
        }

        let retryTask = router.scheduleAuthorityRetry(
            flowKey: flowKey,
            flowID: state.flowID,
            authorityHint: "example.com",
            replayDatagram: datagram3,
            fromClient: true
        )

        XCTAssertNotNil(retryTask)

        let updatedState = router.stateQueue.sync {
            router.flowStates[flowKey]
        }

        XCTAssertEqual(updatedState?.host, "example.com")
        XCTAssertEqual(updatedState?.authorityRetryCount, 1)
        XCTAssertEqual(
            updatedState?.pendingDatagrams.map(\.payload),
            [datagram1, datagram2, datagram3]
        )
    }

    func testScheduleAuthorityRetryKeepsAttemptCountAfterRetryBootstrap() {
        let router = QUICFlowRouter(maxAuthorityRetryAttempts: 1)
        let flowKey = QUICFlowRouter.FlowKey(
            sourceIP: .v4(0x0A000001),
            sourcePort: 50_000,
            destinationIP: .v4(0xC0A80101),
            destinationPort: 443
        )
        let session = QUICMitmSession(flowID: UUID(), host: "192.0.2.10", port: 443)
        var state = QUICFlowRouter.FlowSessionState(
            flowID: UUID(),
            host: "example.com",
            port: 443,
            clientIP: .v4(0x0A000001),
            clientPort: 50_000,
            serverIP: .v4(0xC0A80101),
            serverPort: 443,
            upstreamForwardingDecision: .forwardDirect,
            now: Date(),
            tunnelPolicyRequired: false
        )
        state.session = session
        state.isEstablishing = false
        state.isEstablished = true
        state.authorityRetryCount = 1
        state.lastAuthorityRetry = "example.com"

        let shouldSkip = QUICFlowRouter.authorityRetrySkipReason(
            currentAuthority: state.host,
            nextAuthority: "api.example.com",
            attemptsUsed: state.authorityRetryCount,
            maxAttempts: 1,
            lastAuthorityRetry: state.lastAuthorityRetry
        )

        XCTAssertEqual(shouldSkip, "retry_policy_hostname_already_known")

        router.stateQueue.sync {
            router.flowStates[flowKey] = state
        }

        let retryTask = router.scheduleAuthorityRetry(
            flowKey: flowKey,
            flowID: state.flowID,
            authorityHint: "other.example.com",
            replayDatagram: nil,
            fromClient: true
        )

        XCTAssertNil(retryTask)
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

    func makeUDPPacket(destinationPort: UInt16 = 443) -> UDPPacket {
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
            destinationPort: destinationPort,
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
