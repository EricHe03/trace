//
//  NIOMITMHTTPClientResponseRelayHandlerBehaviorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/03/04.
//

import NIOCore
import NIOEmbedded
import XCTest
@testable import TraceProxy

final class NIOMITMHTTPClientResponseRelayHandlerBehaviorTests: XCTestCase {
    func testHandlerIsRemovableByName() throws {
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }

        let handler = NIOMITMHTTPClientResponseRelayHandler(
            onPart: { _ in },
            onError: { _ in },
            onInactive: {}
        )

        try channel.pipeline.addHandler(handler, name: NIOMITMHTTPConnectHandler.upstreamHTTPHandlerName).wait()
        try channel.pipeline.removeHandler(name: NIOMITMHTTPConnectHandler.upstreamHTTPHandlerName).wait()
    }
}
