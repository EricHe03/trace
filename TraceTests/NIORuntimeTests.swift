//
//  NIORuntimeTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/13.
//

import XCTest
@testable import TraceCore

final class NIORuntimeTests: XCTestCase {
    override func tearDownWithError() throws {
        try NIORuntime.shared.shutdown(reason: .tests)
        try super.tearDownWithError()
    }

    func testAcquireCreatesSharedRuntime() {
        let resources = NIORuntime.shared.acquire(for: .tests)

        XCTAssertNotNil(resources.httpClient)
        XCTAssertNotNil(resources.eventLoopGroup)
        XCTAssertNotNil(NIORuntime.shared.currentResources())
    }

    func testNetworkExtensionReleaseShutsDownWhenIdle() throws {
        _ = NIORuntime.shared.acquire(for: .networkExtension)
        XCTAssertNotNil(NIORuntime.shared.currentResources())

        try NIORuntime.shared.release(for: .networkExtension)

        XCTAssertNil(NIORuntime.shared.currentResources())
    }

    func testAppReleaseDoesNotShutdownUntilExplicitShutdown() throws {
        _ = NIORuntime.shared.acquire(for: .app)
        XCTAssertNotNil(NIORuntime.shared.currentResources())

        try NIORuntime.shared.release(for: .app)
        XCTAssertNotNil(NIORuntime.shared.currentResources())

        try NIORuntime.shared.shutdown(reason: .appLifecycle)
        XCTAssertNil(NIORuntime.shared.currentResources())
    }
}

