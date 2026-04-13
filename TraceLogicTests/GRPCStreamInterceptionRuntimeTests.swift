//
//  GRPCStreamInterceptionRuntimeTests.swift
//  TraceTests
//
//  Created by Codex on 2026/04/11.
//

import NIOCore
import NIOFoundationCompat
@testable import TraceCore
@testable import TraceProxy
import XCTest

final class GRPCStreamInterceptionRuntimeTests: XCTestCase {
    func testInterceptChunkForwardsStandaloneTrailerFrame() throws {
        let resources = NIORuntime.shared.acquire(for: .tests)
        defer { try? NIORuntime.shared.release(for: .tests) }

        let runtime = StreamSessionRuntime(
            protocolType: .grpc,
            url: "https://example.com/grpc",
            requestHeaders: []
        )
        let trailerPayload = Data("grpc-status: 0\r\ngrpc-message: ok\r\n".utf8)
        let trailerFrame = makeGRPCFrame(flag: 0x80, payload: trailerPayload)
        var recordedEvents: [StreamEvent] = []

        let output = try GRPCStreamInterceptionRuntime()
            .interceptChunk(
                trailerFrame,
                runtime: runtime,
                decisionProvider: { _, _, eventLoop in
                    eventLoop.makeSucceededFuture(.forward)
                },
                eventRecorder: { event in
                    recordedEvents.append(event)
                },
                replayEngine: .shared,
                eventLoop: resources.eventLoopGroup.next()
            )
            .wait()

        XCTAssertEqual(output, trailerFrame)
        XCTAssertTrue(recordedEvents.isEmpty)
        XCTAssertEqual(runtime.snapshot().metadata["grpc_grpc_status"], "0")
        XCTAssertEqual(runtime.snapshot().metadata["grpc_grpc_message"], "ok")
    }

    private func makeGRPCFrame(flag: UInt8, payload: Data) -> Data {
        let length = UInt32(payload.count)
        var frame = Data([
            flag,
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ])
        frame.append(payload)
        return frame
    }
}
