//
//  CaptureRuntimeControllerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

@testable import TraceCore
@testable import TraceVPNKit
import XCTest

final class CaptureRuntimeControllerTests: XCTestCase {
    func testClassifyReturnsNonDisruptiveWhenModeUnchanged() async {
        let controller = CaptureRuntimeController()

        let kind = await controller.classify(
            currentMode: .fullTunnelDualMITM,
            newMode: .fullTunnelDualMITM
        )

        XCTAssertEqual(kind, .nonDisruptive)
    }

    func testClassifyReturnsDisruptiveWhenModeChanges() async {
        let controller = CaptureRuntimeController()

        let kind = await controller.classify(
            currentMode: .proxyOnly,
            newMode: .fullTunnelDualMITM
        )

        XCTAssertEqual(kind, .disruptive)
    }

    func testDisruptiveReconfigurationIncrementsTunnelGeneration() async throws {
        let controller = CaptureRuntimeController()
        let recorder = EventRecorder()

        try await controller.performReconfiguration(
            currentMode: .proxyOnly,
            newMode: .fullTunnelDualMITM,
            reason: "unit_test",
            eventSink: { type, message in
                recorder.record(type: type, message: message)
            }
        ) { _ in }

        let generation = await controller.currentTunnelGeneration()
        XCTAssertEqual(generation, 1)

        let events = recorder.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.type), ["reconfig_begin", "reconfig_commit"])
    }

    func testNonDisruptiveReconfigurationKeepsTunnelGeneration() async throws {
        let controller = CaptureRuntimeController()
        let recorder = EventRecorder()

        try await controller.performReconfiguration(
            currentMode: .fullTunnelDualMITM,
            newMode: .fullTunnelDualMITM,
            reason: "unit_test",
            eventSink: { type, message in
                recorder.record(type: type, message: message)
            }
        ) { _ in }

        let generation = await controller.currentTunnelGeneration()
        XCTAssertEqual(generation, 0)

        let events = recorder.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.type), ["reconfig_begin", "reconfig_commit"])
    }

    func testFailedReconfigurationEmitsRollbackWithoutGenerationChange() async {
        enum TestError: Error { case failed }

        let controller = CaptureRuntimeController()
        let recorder = EventRecorder()

        await XCTAssertThrowsErrorAsync {
            try await controller.performReconfiguration(
                currentMode: .proxyOnly,
                newMode: .fullTunnelDualMITM,
                reason: "unit_test",
                eventSink: { type, message in
                    recorder.record(type: type, message: message)
                }
            ) { _ in
                throw TestError.failed
            }
        }

        let generation = await controller.currentTunnelGeneration()
        XCTAssertEqual(generation, 0)

        let events = recorder.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.type), ["reconfig_begin", "reconfig_rollback"])
    }
}

private final class EventRecorder: @unchecked Sendable {
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
        return stored
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
