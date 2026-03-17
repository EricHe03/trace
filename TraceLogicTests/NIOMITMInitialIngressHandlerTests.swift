//
//  NIOMITMInitialIngressHandlerTests.swift
//  TraceTests
//

import Foundation
import NIOCore
import NIOTransportServices
@testable import TraceCore
@testable import TraceProxy
import XCTest

final class NIOMITMInitialIngressHandlerTests: XCTestCase {
    func testShouldRecordTCPHandshakeFailureSkipsClientRejectedMITM() {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let handler = makeHandler(group: group)

        XCTAssertFalse(
            handler.shouldRecordTCPHandshakeFailure(
                for: .clientRejectedMITMOrPinning(detail: "peer_tls_alert_certificate_unknown")
            )
        )
        XCTAssertTrue(handler.shouldRecordTCPHandshakeFailure(for: .upstreamTimeout(detail: nil)))
    }

    func testClassifyTransparentMITMFailureExtractsClientTLSAlert() {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let handler = makeHandler(group: group)
        let underlying = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "peer alert certificate_unknown"]
        )
        let error = NSError(
            domain: "NIOSSL.NIOSSLError",
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey: "NIOSSL.NIOSSLError error 0",
                NSUnderlyingErrorKey: underlying
            ]
        )

        let result = handler.classifyTransparentMITMFailure(
            error,
            stage: .clientTLSHandshake
        )

        XCTAssertEqual(
            result,
            .clientRejectedMITMOrPinning(detail: "peer_tls_alert_certificate_unknown")
        )
    }

    private func makeHandler(group: NIOTSEventLoopGroup) -> NIOMITMInitialIngressHandler {
        NIOMITMInitialIngressHandler(
            group: group,
            eventLog: nil,
            throttler: nil,
            interceptor: nil,
            captureConfigProvider: { .default },
            onRequestCaptured: nil,
            shouldMitmConnect: { _, _ in true },
            shouldEnableTransparentTLS: { true },
            http2MITMEnabledProvider: { true },
            shouldFailOpenAfterMITMFailure: { _, _, _, _ in true },
            onMITMFailure: nil
        )
    }
}
