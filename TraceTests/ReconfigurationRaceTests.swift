//
//  ReconfigurationRaceTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

import XCTest
@testable import TraceCore
@testable import TraceVPN

final class ReconfigurationRaceTests: XCTestCase {
    func testConcurrentReconfigurationsRemainSerialized() async throws {
        let controller = CaptureRuntimeController()
        let recorder = ReconfigEventRecorder()
        let iterations = 100
        let disruptiveCount = iterations / 2

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< iterations {
                group.addTask {
                    let isDisruptive = index % 2 == 0
                    let toMode: CaptureMode = isDisruptive ? .fullTunnelDualMITM : .proxyOnly
                    try await controller.performReconfiguration(
                        currentMode: .proxyOnly,
                        newMode: toMode,
                        reason: "race_test",
                        eventSink: { type, message in
                            recorder.record(type: type, message: message)
                        }
                    ) { _ in }
                }
            }

            for try await _ in group {
                // Drain group
            }
        }

        let generation = await controller.currentTunnelGeneration()
        XCTAssertEqual(generation, disruptiveCount)

        let events = recorder.events
        XCTAssertEqual(events.count, iterations * 2)
        XCTAssertEqual(events.filter { $0.type == "reconfig_begin" }.count, iterations)
        XCTAssertEqual(events.filter { $0.type == "reconfig_commit" }.count, iterations)
        XCTAssertEqual(events.filter { $0.type == "reconfig_rollback" }.count, 0)
    }
}

private final class ReconfigEventRecorder: @unchecked Sendable {
    struct Entry: Sendable {
        let type: String
        let message: String
    }

    private let lock = NSLock()
    private var stored: [Entry] = []

    func record(type: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(Entry(type: type, message: message))
    }

    var events: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        stored
    }
}
