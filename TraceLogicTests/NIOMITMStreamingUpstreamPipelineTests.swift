//
//  NIOMITMStreamingUpstreamPipelineTests.swift
//  TraceTests
//
//  Created by Justin on 2026/03/04.
//

import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOTransportServices
import XCTest
@testable import TraceCore
@testable import TraceProxy

final class NIOMITMStreamingUpstreamPipelineTests: XCTestCase {
    func testStreamingUpstreamPipelineEncodesHTTPRequestParts() throws {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let connectHandler = NIOMITMHTTPConnectHandler(
            group: group,
            eventLog: nil,
            throttler: nil,
            interceptor: nil,
            captureConfigProvider: { CaptureConfiguration.default },
            onRequestCaptured: nil,
            shouldMitmConnect: { _, _ in false },
            shouldFailOpenAfterMITMFailure: { _, _, _, _ in true },
            onMITMFailure: nil,
            ingressMode: .proxy,
            upstreamHint: nil
        )

        let upstream = EmbeddedChannel()
        defer { XCTAssertNoThrow(try upstream.finish()) }

        try connectHandler.installStreamingUpstreamHTTPPipeline(
            on: upstream,
            onResponsePart: { _ in },
            onError: { _ in },
            onInactive: {}
        ).wait()

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "sse.dev")
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/test")
        head.headers = headers

        try upstream.writeOutbound(HTTPClientRequestPart.head(head))
        try upstream.writeOutbound(HTTPClientRequestPart.end(nil))

        var written = ByteBuffer()
        while var out = try upstream.readOutbound(as: ByteBuffer.self) {
            written.writeBuffer(&out)
        }

        let text = String(decoding: written.readableBytesView, as: UTF8.self)
        XCTAssertTrue(text.contains("GET /test HTTP/1.1"))
        XCTAssertTrue(text.lowercased().contains("host: sse.dev"))
    }
}

