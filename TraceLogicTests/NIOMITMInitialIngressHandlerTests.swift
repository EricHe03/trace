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

    func testPlaintextProbeStateRecognizesHTTPRequestPrefix() {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let handler = makeHandler(group: group)
        var buffer = ByteBufferAllocator().buffer(capacity: 32)
        buffer.writeString("POST /cgi-bin/micromsg-bin HTTP/1.1\r\n")

        XCTAssertEqual(handler.plaintextProbeState(for: buffer), .httpLike)
    }

    func testPlaintextProbeStateRecognizesOpaqueBinaryTraffic() {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let handler = makeHandler(group: group)
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeBytes([0x16, 0xF1, 0x03, 0x7F, 0x88, 0x00])

        XCTAssertEqual(handler.plaintextProbeState(for: buffer), .opaque)
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
