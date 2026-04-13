import NIOCore
import NIOHTTP1
import NIOSSL
import NIOTransportServices
import XCTest
@testable import TraceCore
@testable import TracePacket
@testable import TraceProxy
@testable import TraceQUIC
@testable import TraceSecurity
@testable import TraceVPNKit

final class FullTunnelRegressionTests: XCTestCase {
    func testCaptureBodyPolicyCapsBinaryBodiesForPacketTunnelExtension() {
        XCTAssertEqual(
            CaptureBodyPolicy.effectiveCaptureLimit(
                configuredLimit: 10 * 1024 * 1024,
                contentType: "application/octet-stream",
                contentEncoding: nil,
                memoryConstrained: true
            ),
            64 * 1024
        )
    }

    func testCaptureBodyPolicyCapsCompressedBodiesForPacketTunnelExtension() {
        XCTAssertEqual(
            CaptureBodyPolicy.effectiveCaptureLimit(
                configuredLimit: 10 * 1024 * 1024,
                contentType: "application/json",
                contentEncoding: "br",
                memoryConstrained: true
            ),
            128 * 1024
        )
    }

    func testCaptureBodyPolicyKeepsConfiguredLimitOutsidePacketTunnelExtension() {
        XCTAssertEqual(
            CaptureBodyPolicy.effectiveCaptureLimit(
                configuredLimit: 512 * 1024,
                contentType: "application/json",
                contentEncoding: nil,
                memoryConstrained: false
            ),
            512 * 1024
        )
        XCTAssertEqual(
            CaptureBodyPolicy.effectiveInlineThreshold(
                configuredThreshold: 512 * 1024,
                memoryConstrained: true
            ),
            128 * 1024
        )
    }

    func testMergedCapturedProtocolVersionPrefersUpstreamHTTP2() {
        let group = NIOTSEventLoopGroup()
        defer { try? group.syncShutdownGracefully() }

        let handler = NIOMITMHTTPConnectHandler(
            group: group,
            eventLog: nil,
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

    func testServerTLSContextCacheEvictsLeastRecentlyUsedEntries() throws {
        NIOMITMHTTPConnectHandler.clearCachedTLSContexts()
        defer { NIOMITMHTTPConnectHandler.clearCachedTLSContexts() }

        let baseDate = Date(timeIntervalSince1970: 1_000)
        for index in 0 ... NIOMITMHTTPConnectHandler.tlsContextCacheMaxEntries {
            let context = try NIOSSLContext(configuration: .makeClientConfiguration())
            NIOMITMHTTPConnectHandler.cacheServerTLSContextForTesting(
                context,
                host: "host-\(index).example.com",
                now: baseDate.addingTimeInterval(TimeInterval(index))
            )
        }

        XCTAssertEqual(
            NIOMITMHTTPConnectHandler.cachedTLSContextCountForTesting(),
            NIOMITMHTTPConnectHandler.tlsContextCacheMaxEntries
        )
        XCTAssertNil(
            NIOMITMHTTPConnectHandler.cachedServerTLSContextForTesting(
                host: "host-0.example.com",
                now: baseDate.addingTimeInterval(1_000)
            )
        )
    }

    func testServerTLSContextCacheDropsExpiredEntries() throws {
        NIOMITMHTTPConnectHandler.clearCachedTLSContexts()
        defer { NIOMITMHTTPConnectHandler.clearCachedTLSContexts() }

        let baseDate = Date(timeIntervalSince1970: 2_000)
        let context = try NIOSSLContext(configuration: .makeClientConfiguration())
        NIOMITMHTTPConnectHandler.cacheServerTLSContextForTesting(
            context,
            host: "expired.example.com",
            now: baseDate
        )

        XCTAssertNotNil(
            NIOMITMHTTPConnectHandler.cachedServerTLSContextForTesting(
                host: "expired.example.com",
                now: baseDate.addingTimeInterval(1)
            )
        )
        XCTAssertNil(
            NIOMITMHTTPConnectHandler.cachedServerTLSContextForTesting(
                host: "expired.example.com",
                now: baseDate.addingTimeInterval(TLSHandler.certificateLifetime + 1)
            )
        )
    }

    func testCertificateRuntimeCacheClearAlsoClearsServerTLSContexts() throws {
        NIOMITMHTTPConnectHandler.clearCachedTLSContexts()
        defer { NIOMITMHTTPConnectHandler.clearCachedTLSContexts() }

        let context = try NIOSSLContext(configuration: .makeClientConfiguration())
        NIOMITMHTTPConnectHandler.cacheServerTLSContextForTesting(
            context,
            host: "cached.example.com"
        )

        XCTAssertEqual(NIOMITMHTTPConnectHandler.cachedTLSContextCountForTesting(), 1)

        CertificateManager.shared.clearRuntimeCaches()

        XCTAssertEqual(NIOMITMHTTPConnectHandler.cachedTLSContextCountForTesting(), 0)
    }

    func testPlaintextProbeTreatsWebDAVMethodAsHTTP() {
        let group = NIOTSEventLoopGroup()
        defer { try? group.syncShutdownGracefully() }

        let handler = NIOMITMInitialIngressHandler(
            group: group,
            eventLog: nil,
            interceptor: nil,
            captureConfigProvider: { .default },
            onRequestCaptured: nil,
            shouldMitmConnect: { _, _ in true },
            shouldEnableTransparentTLS: { true },
            http2MITMEnabledProvider: { true },
            shouldFailOpenAfterMITMFailure: { _, _, _, _ in true },
            onMITMFailure: nil
        )

        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeString("PROPFIND /remote.php/dav HTTP/1.1\r\n")

        switch handler.plaintextProbeState(for: buffer) {
        case .httpLike:
            return
        case .needMore, .opaque:
            XCTFail("Expected PROPFIND to be treated as HTTP-like")
        }
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
