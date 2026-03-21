import NIOHTTP1
import NIOTransportServices
import XCTest
@testable import TraceCore
@testable import TracePacket
@testable import TraceProxy
@testable import TraceQUIC
@testable import TraceVPNKit

final class FullTunnelRegressionTests: XCTestCase {
    func testMergedCapturedProtocolVersionPrefersUpstreamHTTP2() {
        let group = NIOTSEventLoopGroup()
        defer { try? group.syncShutdownGracefully() }

        let handler = NIOMITMHTTPConnectHandler(
            group: group,
            eventLog: nil,
            throttler: nil,
            interceptor: nil,
            captureConfigProvider: { .default },
            onRequestCaptured: nil,
            shouldMitmConnect: { _, _ in true },
            shouldFailOpenAfterMITMFailure: { _, _, _, _ in true },
            onMITMFailure: nil,
            ingressMode: .proxy,
            upstreamHint: nil
        )

        XCTAssertEqual(
            handler.mergedCapturedProtocolVersion(
                current: .http11,
                fallback: .init(major: 2, minor: 0)
            ),
            .http2
        )
        XCTAssertEqual(
            handler.mergedCapturedProtocolVersion(
                current: .http2,
                fallback: .http1_1
            ),
            .http2
        )
    }

    func testLegacyReasonCodecRecognizesEngineUnavailable() {
        let decoded = LegacyReasonCodec.decode("engineUnavailable")

        XCTAssertEqual(
            decoded.failure,
            .internalError(code: .quicInternal, context: "engineUnavailable")
        )
        XCTAssertEqual(decoded.bypassReason, .internalError)
        XCTAssertEqual(decoded.domain, .quicMITM)
    }

    func testQUICRetryBackoffReusesCachedFailureDecisionWithoutDuplicateEvent() {
        let sinkEvents = LockedInterceptionEvents()
        let policyEngine = DualMITMPolicyEngine(
            snapshot: DualMITMPolicySnapshot(
                tcpTransparentMITMEnabled: true,
                tcpInterceptPorts: [443],
                mitmProxyHost: "127.0.0.1",
                mitmProxyPort: 8888,
                policyMode: .adaptiveFailOpen,
                circuitBreakerEnabled: false,
                allowlist: ["*"],
                mitmEnabled: true,
                quicHandlingMode: .intercept,
                featureFlags: DualMITMPolicyFeatureFlags(
                    shadowEnabled: false,
                    enforceTCPRouting: false,
                    enforceProxyRouting: false,
                    enforceQUICRouting: false,
                    http2MITMEnabled: false,
                    strictEnforcementHardFail: false
                )
            ),
            eventSink: ClosureInterceptionEventSink { event in
                sinkEvents.append(event)
            }
        )
        let router = QUICFlowRouter(
            engineStatusProvider: {
                QUICEngineStatus(
                    availability: .unavailable,
                    version: "test",
                    usingQuicheFFI: false
                )
            },
            dualMITMPolicy: .adaptiveFailOpen,
            dualMITMCircuitBreakerEnabled: false,
            dualMITMPolicyEngine: policyEngine
        )

        let ipPacket = IPPacket(
            version: 4,
            headerLength: 20,
            totalLength: 48,
            protocolNumber: TransportProtocol.udp.rawValue,
            hopLimit: 64,
            fragmentOffset: 0,
            moreFragments: false,
            source: .v4(0x0A000001),
            destination: .v4(0x0A000002),
            payload: Data([0x01, 0x02, 0x03, 0x04])
        )
        let udpPacket = UDPPacket(
            sourcePort: 50_000,
            destinationPort: 443,
            length: 12,
            payload: Data([0xC0, 0x00, 0x00, 0x01])
        )

        let first = router.resolveInterceptRoute(
            ipPacket: ipPacket,
            udpPacket: udpPacket,
            udpForwarderAvailable: false,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false,
            authorityHint: "example.com"
        )
        let second = router.resolveInterceptRoute(
            ipPacket: ipPacket,
            udpPacket: udpPacket,
            udpForwarderAvailable: false,
            tunnelUDPSupported: true,
            tunnelPolicyRequired: false,
            authorityHint: "example.com"
        )

        XCTAssertEqual(first.inspectionOutcome, .passThroughMarked)
        XCTAssertEqual(first.metadata.failureReason, "engineUnavailable")
        XCTAssertEqual(second.inspectionOutcome, .passThroughMarked)
        XCTAssertEqual(second.metadata.failureReason, "engineUnavailable")

        let failoverEvents = sinkEvents.snapshot().filter { $0.type == .failoverDecision }
        XCTAssertEqual(failoverEvents.count, 1)
        XCTAssertEqual(
            failoverEvents.first?.failure?.failure,
            .internalError(code: .quicInternal, context: "engineUnavailable")
        )
    }
}

private final class LockedInterceptionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [InterceptionEvent] = []

    func append(_ event: InterceptionEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [InterceptionEvent] {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return snapshot
    }
}
