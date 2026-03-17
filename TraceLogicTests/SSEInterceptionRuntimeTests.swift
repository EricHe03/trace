//
//  SSEInterceptionRuntimeTests.swift
//  TraceTests
//
//  Validates that SSE stream interception preserves buffered tail bytes when rewriting.
//

import NIOCore
import NIOEmbedded
@testable import TraceCore
@testable import TraceProxy
import XCTest

final class SSEInterceptionRuntimeTests: XCTestCase {
    func testInterceptChunkPreservesBufferedTailForPartialLineWhenModified() throws {
        let eventLoop = EmbeddedEventLoop()
        let runtime = StreamSessionRuntime(
            protocolType: .sse,
            url: "https://example.com/events",
            requestHeaders: []
        )
        let interceptor = SSEInterceptionRuntime()

        let chunk1 = Data("data: first\n\ndata: sec".utf8)
        let forwarded1 = try interceptor.interceptChunk(
            chunk1,
            runtime: runtime,
            decisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(
                    .modify(
                        StreamMutation(
                            payload: .text("patched", contentType: "text/event-stream; charset=utf-8")
                        )
                    )
                )
            },
            replayEngine: .shared,
            eventLoop: eventLoop
        ).wait()

        let forwarded1Text = String(data: forwarded1, encoding: .utf8)
        XCTAssertTrue(forwarded1Text?.contains("data: patched") == true)
        XCTAssertTrue(forwarded1Text?.hasSuffix("data: sec") == true)

        let chunk2 = Data("ond\n\n".utf8)
        let forwarded2 = try interceptor.interceptChunk(
            chunk2,
            runtime: runtime,
            decisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            },
            replayEngine: .shared,
            eventLoop: eventLoop
        ).wait()

        var combined = Data()
        combined.append(forwarded1)
        combined.append(forwarded2)
        let combinedText = String(data: combined, encoding: .utf8)
        XCTAssertNotNil(combinedText)

        let parser = SSEParser()
        let events = parser.parse(combinedText ?? "")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data, "patched")
        XCTAssertEqual(events[1].data, "second")
    }

    func testInterceptChunkPreservesBufferedTailForIncompleteEventWhenModified() throws {
        let eventLoop = EmbeddedEventLoop()
        let runtime = StreamSessionRuntime(
            protocolType: .sse,
            url: "https://example.com/events",
            requestHeaders: []
        )
        let interceptor = SSEInterceptionRuntime()

        let chunk1 = Data("data: first\n\ndata: sec\n".utf8)
        let forwarded1 = try interceptor.interceptChunk(
            chunk1,
            runtime: runtime,
            decisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(
                    .modify(
                        StreamMutation(
                            payload: .text("patched", contentType: "text/event-stream; charset=utf-8")
                        )
                    )
                )
            },
            replayEngine: .shared,
            eventLoop: eventLoop
        ).wait()

        let forwarded1Text = String(data: forwarded1, encoding: .utf8)
        XCTAssertTrue(forwarded1Text?.contains("data: patched") == true)
        XCTAssertTrue(forwarded1Text?.hasSuffix("data: sec\n") == true)

        let chunk2 = Data("\n".utf8)
        let forwarded2 = try interceptor.interceptChunk(
            chunk2,
            runtime: runtime,
            decisionProvider: { _, _, eventLoop in
                eventLoop.makeSucceededFuture(.forward)
            },
            replayEngine: .shared,
            eventLoop: eventLoop
        ).wait()

        var combined = Data()
        combined.append(forwarded1)
        combined.append(forwarded2)
        let combinedText = String(data: combined, encoding: .utf8)
        XCTAssertNotNil(combinedText)

        let parser = SSEParser()
        let events = parser.parse(combinedText ?? "")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data, "patched")
        XCTAssertEqual(events[1].data, "sec")
    }
}
