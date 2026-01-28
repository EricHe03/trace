//
//  TunnelLifecycleTests.swift
//  TraceTests
//
//  Created by Codex on 2026/01/28.
//

import XCTest
@testable import TraceVPN

final class TunnelLifecycleTests: XCTestCase {
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    func testConcurrentStartsRunOnce() async throws {
        let lifecycle = TunnelLifecycle()
        let counter = Counter()

        async let first: Void = lifecycle.start(invocationID: "a") {
            await counter.increment()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        async let second: Void = lifecycle.start(invocationID: "b") {
            await counter.increment()
        }

        try await first
        try await second

        XCTAssertEqual(await counter.value, 1)
    }
}

