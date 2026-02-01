//
//  TunnelLifecycleTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

#if !targetEnvironment(simulator)
import XCTest
@testable import TraceVPN

final class TunnelLifecycleTests: XCTestCase {
    var sut: TunnelLifecycle!

    override func setUp() async throws {
        try await super.setUp()
        sut = TunnelLifecycle()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - State Management Tests

    func testInitialState_IsStopped() async {
        // Given - Fresh instance
        // When - Check state
        let invocationID = await sut.currentInvocationID()

        // Then
        XCTAssertNil(invocationID, "Initial state should have no active invocation")
    }

    func testStart_FromStoppedState_Succeeds() async throws {
        // Given
        var startCalled = false
        let startImpl = {
            startCalled = true
        }

        // When
        try await sut.start(invocationID: "test-1", startImpl)

        // Then
        XCTAssertTrue(startCalled, "Start implementation should be called")
        let invocationID = await sut.currentInvocationID()
        XCTAssertEqual(invocationID, "test-1")
    }

    func testStart_WhenAlreadyRunning_ReturnsImmediately() async throws {
        // Given - Already started
        try await sut.start(invocationID: "test-1") {}

        var secondStartCalled = false

        // When - Start again
        try await sut.start(invocationID: "test-2") {
            secondStartCalled = true
        }

        // Then - Should return without calling implementation
        XCTAssertFalse(secondStartCalled, "Second start should not call implementation when already running")
        let invocationID = await sut.currentInvocationID()
        XCTAssertEqual(invocationID, "test-1", "Should preserve original invocation ID")
    }

    func testStart_WhenStarting_WaitsForCompletion() async throws {
        // Given - Start in progress
        let expectation = expectation(description: "First start completes")

        Task {
            try await sut.start(invocationID: "test-1") {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                expectation.fulfill()
            }
        }

        // Wait a bit to ensure first start is in progress
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        var secondStartCalled = false

        // When - Second start while first is still starting
        try await sut.start(invocationID: "test-2") {
            secondStartCalled = true
        }

        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertFalse(secondStartCalled, "Second start should wait and not call implementation")
    }

    func testStart_AfterFailure_CanRestartSuccessfully() async throws {
        // Given - Failed start
        do {
            try await sut.start(invocationID: "test-1") {
                throw NSError(domain: "test", code: 1, userInfo: nil)
            }
            XCTFail("Should have thrown error")
        } catch {
            // Expected
        }

        var invocationID = await sut.currentInvocationID()
        XCTAssertNil(invocationID, "Invocation ID should be cleared after failure")

        // When - Try to start again
        try await sut.start(invocationID: "test-2") {}

        // Then
        invocationID = await sut.currentInvocationID()
        XCTAssertEqual(invocationID, "test-2")
    }

    func testStop_FromRunningState_CallsImplementation() async throws {
        // Given - Running state
        try await sut.start(invocationID: "test-1") {}

        var stopCalled = false

        // When
        await sut.stop {
            stopCalled = true
        }

        // Then
        XCTAssertTrue(stopCalled, "Stop implementation should be called")
        let invocationID = await sut.currentInvocationID()
        XCTAssertNil(invocationID, "Invocation ID should be cleared after stop")
    }

    func testStop_FromStoppedState_ReturnsImmediately() async {
        // Given - Stopped state
        var stopCalled = false

        // When
        await sut.stop {
            stopCalled = true
        }

        // Then
        XCTAssertFalse(stopCalled, "Stop implementation should not be called when already stopped")
    }

    func testStop_WhileStarting_CancelsStartAndStops() async throws {
        // Given - Start in progress
        let startExpectation = expectation(description: "Start called")
        startExpectation.isInverted = true // We expect it to be cancelled

        Task {
            try await sut.start(invocationID: "test-1") {
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                startExpectation.fulfill()
            }
        }

        // Wait to ensure start is in progress
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        var stopCalled = false

        // When - Stop while starting
        await sut.stop {
            stopCalled = true
        }

        // Then
        await fulfillment(of: [startExpectation], timeout: 0.5)
        XCTAssertTrue(stopCalled, "Stop should be called after cancelling start")
        let invocationID = await sut.currentInvocationID()
        XCTAssertNil(invocationID)
    }

    func testStop_WhenAlreadyStopping_WaitsForCompletion() async throws {
        // Given - Running state
        try await sut.start(invocationID: "test-1") {}

        let stopExpectation = expectation(description: "First stop completes")
        var firstStopCalled = false
        var secondStopCalled = false

        // When - Two stops concurrently
        Task {
            await sut.stop {
                firstStopCalled = true
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                stopExpectation.fulfill()
            }
        }

        // Wait a bit to ensure first stop is in progress
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        await sut.stop {
            secondStopCalled = true
        }

        // Then
        await fulfillment(of: [stopExpectation], timeout: 1.0)
        XCTAssertTrue(firstStopCalled, "First stop should be called")
        XCTAssertFalse(secondStopCalled, "Second stop should wait and not call implementation")
    }

    // MARK: - Error Handling Tests

    func testStart_WhenImplementationThrows_PropagatesError() async {
        // Given
        let testError = NSError(domain: "test.error", code: 123, userInfo: nil)

        // When/Then
        do {
            try await sut.start(invocationID: "test-1") {
                throw testError
            }
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertEqual((error as NSError).domain, testError.domain)
            XCTAssertEqual((error as NSError).code, testError.code)
        }
    }

    func testStart_WhenImplementationThrows_ClearsInvocationID() async {
        // Given
        do {
            try await sut.start(invocationID: "test-1") {
                throw NSError(domain: "test", code: 1, userInfo: nil)
            }
        } catch {
            // Expected
        }

        // When
        let invocationID = await sut.currentInvocationID()

        // Then
        XCTAssertNil(invocationID, "Invocation ID should be cleared after error")
    }

    func testStart_WhenImplementationThrows_TransitionsToStopped() async throws {
        // Given - Failed start
        do {
            try await sut.start(invocationID: "test-1") {
                throw NSError(domain: "test", code: 1, userInfo: nil)
            }
        } catch {
            // Expected
        }

        // When - Try to stop
        var stopCalled = false
        await sut.stop {
            stopCalled = true
        }

        // Then
        XCTAssertFalse(stopCalled, "Stop should not be called when in stopped state")
    }

    // MARK: - Concurrent Operations Tests

    func testConcurrentStarts_DeduplicatesCorrectly() async throws {
        // Given
        var callCount = 0
        let lock = NSLock()

        let startImpl = {
            lock.lock()
            callCount += 1
            lock.unlock()
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        // When - Multiple concurrent starts
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    try? await self.sut.start(invocationID: "test-\(i)", startImpl)
                }
            }
        }

        // Then - Only one start should be executed
        XCTAssertEqual(callCount, 1, "Start implementation should only be called once")
    }

    func testStartAndStop_Concurrent_HandlesCorrectly() async throws {
        // Given
        let startExpectation = expectation(description: "Start called")
        let stopExpectation = expectation(description: "Stop called")

        var startCalled = false
        var stopCalled = false

        // When - Start and stop concurrently
        async let startTask: Void = {
            try? await self.sut.start(invocationID: "test-1") {
                startCalled = true
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                startExpectation.fulfill()
            }
        }()

        // Wait a bit to ensure start is in progress
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        async let stopTask: Void = {
            await self.sut.stop {
                stopCalled = true
                stopExpectation.fulfill()
            }
        }()

        _ = await (startTask, stopTask)

        // Then
        await fulfillment(of: [stopExpectation], timeout: 1.0)
        XCTAssertTrue(stopCalled, "Stop should be called")
    }

    // MARK: - Edge Cases

    func testInvocationID_UpdatesCorrectly() async throws {
        // Given
        XCTAssertNil(await sut.currentInvocationID())

        // When - Start
        try await sut.start(invocationID: "test-1") {}

        // Then
        XCTAssertEqual(await sut.currentInvocationID(), "test-1")

        // When - Stop
        await sut.stop {}

        // Then
        XCTAssertNil(await sut.currentInvocationID())
    }

    func testStart_WithEmptyInvocationID_Succeeds() async throws {
        // Given
        let emptyID = ""

        // When
        try await sut.start(invocationID: emptyID) {}

        // Then
        let invocationID = await sut.currentInvocationID()
        XCTAssertEqual(invocationID, emptyID)
    }

    func testStart_WithSpecialCharactersInID_Succeeds() async throws {
        // Given
        let specialID = "test-🚀-123-@#$"

        // When
        try await sut.start(invocationID: specialID) {}

        // Then
        let invocationID = await sut.currentInvocationID()
        XCTAssertEqual(invocationID, specialID)
    }

    func testStop_AfterMultipleStarts_ClearsCorrectInvocationID() async throws {
        // Given - Multiple start attempts
        try await sut.start(invocationID: "test-1") {}
        try await sut.start(invocationID: "test-2") {} // Should return immediately
        try await sut.start(invocationID: "test-3") {} // Should return immediately

        // When
        await sut.stop {}

        // Then
        let invocationID = await sut.currentInvocationID()
        XCTAssertNil(invocationID)
    }

    // MARK: - Lifecycle Tests

    func testFullLifecycle_StartStopStart() async throws {
        // Given - First lifecycle
        try await sut.start(invocationID: "test-1") {}
        await sut.stop {}

        // When - Second lifecycle
        try await sut.start(invocationID: "test-2") {}

        // Then
        let invocationID = await sut.currentInvocationID()
        XCTAssertEqual(invocationID, "test-2")
    }

    func testMultipleLifecycles_MaintainCorrectState() async throws {
        // Test multiple start-stop cycles
        for i in 0..<10 {
            // Start
            try await sut.start(invocationID: "test-\(i)") {}
            var invocationID = await sut.currentInvocationID()
            XCTAssertEqual(invocationID, "test-\(i)")

            // Stop
            await sut.stop {}
            invocationID = await sut.currentInvocationID()
            XCTAssertNil(invocationID)
        }
    }

    // MARK: - Performance Tests

    func testStart_Performance() async throws {
        measure {
            let expectation = self.expectation(description: "Start completes")

            Task {
                try await self.sut.start(invocationID: "perf-test") {}
                await self.sut.stop {}
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 1.0)
        }
    }

    func testStop_Performance() async throws {
        // Given - Running state
        try await sut.start(invocationID: "test-1") {}

        measure {
            let expectation = self.expectation(description: "Stop completes")

            Task {
                await self.sut.stop {}
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 1.0)

            // Reset for next iteration
            Task {
                try? await self.sut.start(invocationID: "test-reset") {}
            }
        }
    }
}
#else
import XCTest

final class TunnelLifecycleTests: XCTestCase {
    func testTunnelLifecycleUnavailableOnSimulator() throws {
        throw XCTSkip("TunnelLifecycle lives in the TraceVPN app extension, which is not linked into simulator unit tests.")
    }
}
#endif
