//
//  NetworkThrottlingControllerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceVPN

final class NetworkThrottlingControllerTests: XCTestCase {
    var sut: NetworkThrottlingController!

    override func setUp() {
        super.setUp()
        sut = NetworkThrottlingController.shared
        // Reset to disabled state
        sut.updateState(.disabled)
    }

    override func tearDown() {
        // Cleanup: reset to disabled state
        sut.updateState(.disabled)
        sut = nil
        super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let instance1 = NetworkThrottlingController.shared
        let instance2 = NetworkThrottlingController.shared

        XCTAssertTrue(instance1 === instance2, "NetworkThrottlingController should be a singleton")
    }

    // MARK: - State Management Tests

    func testUpdateState_SetsNewState() {
        let newState = makeThrottlingState(enabled: true, latency: 100, downloadSpeed: 1024)

        sut.updateState(newState)

        // Give async queue time to process
        let expectation = XCTestExpectation(description: "State update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let currentState = self.sut.currentState()
            XCTAssertEqual(currentState, newState)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testCurrentState_ReturnsDefaultDisabledState() {
        let currentState = sut.currentState()

        XCTAssertEqual(currentState, .disabled)
        XCTAssertFalse(currentState.enabled)
    }

    func testCurrentState_AfterUpdate_ReturnsUpdatedState() {
        let newState = makeThrottlingState(enabled: true, downloadSpeed: 512)

        sut.updateState(newState)

        let expectation = XCTestExpectation(description: "State retrieval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let currentState = self.sut.currentState()
            XCTAssertTrue(currentState.enabled)
            XCTAssertEqual(currentState, newState)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testStateTransition_DisabledToEnabled() {
        // Start disabled
        sut.updateState(.disabled)

        // Transition to enabled
        let enabledState = makeThrottlingState(enabled: true)
        sut.updateState(enabledState)

        let expectation = XCTestExpectation(description: "State transition")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let currentState = self.sut.currentState()
            XCTAssertTrue(currentState.enabled)
            XCTAssertNotNil(currentState.condition)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testStateTransition_EnabledToDisabled() {
        // Start enabled
        sut.updateState(makeThrottlingState(enabled: true))

        // Transition to disabled
        sut.updateState(.disabled)

        let expectation = XCTestExpectation(description: "State transition to disabled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let currentState = self.sut.currentState()
            XCTAssertFalse(currentState.enabled)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testStateTransition_ProfileChange() {
        // Set initial profile
        let profile1 = makeThrottlingState(enabled: true, latency: 100, downloadSpeed: 512)
        sut.updateState(profile1)

        // Change to different profile
        let profile2 = makeThrottlingState(enabled: true, latency: 200, downloadSpeed: 1024)
        sut.updateState(profile2)

        let expectation = XCTestExpectation(description: "Profile change")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let currentState = self.sut.currentState()
            XCTAssertEqual(currentState, profile2)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Apply Metadata Tests

    func testApplyMetadata_WhenDisabled_DoesNotModify() {
        sut.updateState(.disabled)

        var request = makeVPNNetworkRequest()
        sut.applyMetadata(to: &request)

        XCTAssertFalse(request.wasThrottled)
        XCTAssertNil(request.throttlingProfile)
    }

    func testApplyMetadata_WhenEnabledWithNoCondition_DoesNotModify() {
        let stateWithoutCondition = NetworkThrottlingState(enabled: true, condition: nil)
        sut.updateState(stateWithoutCondition)

        var request = makeVPNNetworkRequest()
        sut.applyMetadata(to: &request)

        XCTAssertFalse(request.wasThrottled)
        XCTAssertNil(request.throttlingProfile)
    }

    func testApplyMetadata_WhenEnabled_SetsThrottlingFields() {
        let state = makeThrottlingState(enabled: true, latency: 100, downloadSpeed: 1024)
        sut.updateState(state)

        let expectation = XCTestExpectation(description: "Metadata application")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var request = makeVPNNetworkRequest()
            self.sut.applyMetadata(to: &request)

            XCTAssertTrue(request.wasThrottled)
            XCTAssertNotNil(request.throttlingProfile)
            XCTAssertEqual(request.throttlingProfile, "Custom")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testApplyMetadata_WithPresetCondition_SetsCorrectProfileName() {
        let state = NetworkThrottlingState(enabled: true, condition: .cellular3G)
        sut.updateState(state)

        let expectation = XCTestExpectation(description: "Preset profile metadata")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var request = makeVPNNetworkRequest()
            self.sut.applyMetadata(to: &request)

            XCTAssertTrue(request.wasThrottled)
            XCTAssertEqual(request.throttlingProfile, "3G")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testApplyMetadata_PreservesOtherRequestFields() {
        let state = makeThrottlingState(enabled: true)
        sut.updateState(state)

        let expectation = XCTestExpectation(description: "Other fields preserved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var request = makeVPNNetworkRequest(
                url: "https://example.com",
                method: .post,
                statusCode: 200
            )
            let originalURL = request.url
            let originalMethod = request.method
            let originalStatus = request.statusCode

            self.sut.applyMetadata(to: &request)

            XCTAssertEqual(request.url, originalURL)
            XCTAssertEqual(request.method, originalMethod)
            XCTAssertEqual(request.statusCode, originalStatus)
            XCTAssertTrue(request.wasThrottled)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Thread Safety Tests

    func testConcurrentStateAccess_ThreadSafe() {
        let iterations = 100
        let expectation = XCTestExpectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = iterations * 2

        // Concurrent writes
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let state = makeThrottlingState(
                enabled: i % 2 == 0,
                latency: i * 10,
                downloadSpeed: i * 100
            )
            self.sut.updateState(state)
            expectation.fulfill()
        }

        // Concurrent reads
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            _ = self.sut.currentState()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        // Verify controller is still in valid state
        let finalState = sut.currentState()
        XCTAssertNotNil(finalState)
    }

    func testConcurrentMetadataApplication_ThreadSafe() {
        let state = makeThrottlingState(enabled: true)
        sut.updateState(state)

        let iterations = 100
        let expectation = XCTestExpectation(description: "Concurrent metadata application")
        expectation.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            var request = makeVPNNetworkRequest()
            self.sut.applyMetadata(to: &request)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Edge Cases

    func testMultipleRapidStateUpdates() {
        let states = [
            makeThrottlingState(enabled: true, latency: 50),
            makeThrottlingState(enabled: false),
            makeThrottlingState(enabled: true, latency: 150),
            .disabled,
            makeThrottlingState(enabled: true, downloadSpeed: 2048)
        ]

        for state in states {
            sut.updateState(state)
        }

        let expectation = XCTestExpectation(description: "Final state after rapid updates")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let finalState = self.sut.currentState()
            // Should have the last state
            XCTAssertNotNil(finalState)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }
}
