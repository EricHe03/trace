//
//  NIOMITMHTTP2StreamHandlerFactoryTests.swift
//  TraceTests
//

import NIOCore
import NIOTransportServices
@testable import TraceCore
@testable import TraceProxy
import XCTest

final class NIOMITMHTTP2StreamHandlerFactoryTests: XCTestCase {
    func testFactoryCreatesHTTP2StreamHandlerAfterSetupHandlerIsReleased() throws {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var setupHandler: NIOMITMHTTPConnectHandler? = NIOMITMHTTPConnectHandler(
            group: group,
            eventLog: nil,
            interceptor: nil,
            captureConfigProvider: { CaptureConfiguration.default },
            onRequestCaptured: nil,
            shouldMitmConnect: { _, _ in true },
            shouldFailOpenAfterMITMFailure: { _, _, _, _ in true },
            onMITMFailure: nil,
            ingressMode: .tunneledHTTPS(host: "bootstrap.example", port: 443),
            upstreamHint: nil
        )
        weak var weakSetupHandler = setupHandler

        let factory = try XCTUnwrap(
            setupHandler?.makeTunneledHTTP2StreamHandlerFactory(
                host: "example.com",
                port: 443
            )
        )

        setupHandler = nil
        XCTAssertNil(weakSetupHandler)

        let streamHandler = factory.makeHandler()

        XCTAssertTrue(streamHandler.usesHTTP2StreamSemantics)
        if case let .tunneledHTTPS(host, port) = streamHandler.ingressMode {
            XCTAssertEqual(host, "example.com")
            XCTAssertEqual(port, 443)
        } else {
            XCTFail("Expected tunneled HTTPS ingress mode")
        }
    }
}
