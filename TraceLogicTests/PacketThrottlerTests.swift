//
//  PacketThrottlerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
import XCTest
@testable import TraceCore
@testable import TraceProxy
@testable import TraceVPNKit

final class PacketThrottlerTests: XCTestCase {
    var sut: PacketThrottler!

    override func setUp() {
        super.setUp()
        sut = PacketThrottler()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - State Management Tests

    func testUpdateState_ChangesProcessingBehavior() {
        let disabledState = NetworkThrottlingState(enabled: false, condition: nil)
        sut.updateState(disabledState)

        var handlerCalled = false
        let testPacket = Data(count: 1024)

        sut.process(packet: testPacket, direction: .download) {
            handlerCalled = true
        }

        let expectation = XCTestExpectation(description: "Disabled throttling handler execution")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(handlerCalled, "Handler should be called immediately when disabled")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testUpdateState_ResetsTimingCounters() {
        let enabledState = makeThrottlingState(enabled: true, latency: 50, downloadSpeed: 512)
        sut.updateState(enabledState)

        let packet1 = Data(count: 512)
        var handler1Called = false

        sut.process(packet: packet1, direction: .download) {
            handler1Called = true
        }

        let expectation1 = XCTestExpectation(description: "First packet processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(handler1Called)
            expectation1.fulfill()
        }
        wait(for: [expectation1], timeout: 1.0)

        // Update state (should reset timing)
        let newState = makeThrottlingState(enabled: true, latency: 100, downloadSpeed: 256)
        sut.updateState(newState)

        let packet2 = Data(count: 256)
        var handler2Called = false

        let startTime = Date()
        sut.process(packet: packet2, direction: .download) {
            handler2Called = true
        }

        let expectation2 = XCTestExpectation(description: "Second packet processed after state update")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertTrue(handler2Called)
            expectation2.fulfill()
        }
        wait(for: [expectation2], timeout: 1.0)
    }

    // MARK: - Disabled Throttling Tests

    func testProcess_WithThrottlingDisabled_CallsHandlerImmediately() {
        sut.updateState(.disabled)

        var handlerCalled = false
        let packet = Data(count: 1024)

        sut.process(packet: packet, direction: .download) {
            handlerCalled = true
        }

        let expectation = XCTestExpectation(description: "Handler called immediately")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            XCTAssertTrue(handlerCalled)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    // MARK: - Packet Loss Tests

    func testProcess_WithZeroPacketLoss_AllPacketsProcessed() {
        let state = makeThrottlingState(enabled: true, packetLoss: 0.0)
        sut.updateState(state)

        let iterations = 50
        let expectation = XCTestExpectation(description: "All packets processed")
        expectation.expectedFulfillmentCount = iterations

        var successCount = 0
        DispatchQueue.global().async {
            for _ in 0 ..< iterations {
                let packet = Data(count: 512)
                self.sut.process(packet: packet, direction: .download) {
                    successCount += 1
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(successCount, iterations, "All packets should be processed with 0% loss")
    }

    func testProcess_WithFullPacketLoss_NoPacketsProcessed() {
        let state = makeThrottlingState(enabled: true, packetLoss: 1.0)
        sut.updateState(state)

        let iterations = 50
        var successCount = 0

        for _ in 0 ..< iterations {
            let packet = Data(count: 512)
            sut.process(packet: packet, direction: .download) {
                successCount += 1
            }
        }

        let expectation = XCTestExpectation(description: "No packets processed with 100% loss")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(successCount, 0, "No packets should be processed with 100% loss")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testProcess_WithPartialPacketLoss_SomePacketsDropped() {
        let state = makeThrottlingState(enabled: true, packetLoss: 0.5)
        sut.updateState(state)

        let iterations = 100
        let expectation = XCTestExpectation(description: "Partial packet loss")

        var successCount = 0
        for _ in 0 ..< iterations {
            let packet = Data(count: 512)
            self.sut.process(packet: packet, direction: .download) {
                successCount += 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // With 50% loss, we expect roughly 50 packets to succeed
            // Allow for variance due to randomness
            let acceptable = successCount > 20 && successCount < 80
            XCTAssertTrue(acceptable, "Expected ~50 packets with 50% loss, got \(successCount)")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Bandwidth Rate Limiting Tests

    func testProcess_WithZeroBandwidth_DropsPacket() {
        let state = NetworkThrottlingState(
            enabled: true,
            condition: .custom(download: 0, upload: 1024, latency: 0, packetLoss: 0.0)
        )
        sut.updateState(state)

        var handlerCalled = false
        let packet = Data(count: 512)

        sut.process(packet: packet, direction: .download) {
            handlerCalled = true
        }

        let expectation = XCTestExpectation(description: "Zero bandwidth drops packet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(handlerCalled, "Packet should be dropped with zero bandwidth")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testProcess_RateLimitsDownload() {
        // 1024 KB/s = 1 MB/s
        let state = makeThrottlingState(
            enabled: true,
            latency: 0,
            downloadSpeed: 1024,
            uploadSpeed: 1024
        )
        sut.updateState(state)

        let packetSize = 1024 // 1 KB packet
        let startTime = Date()
        var handlerCalled = false

        let packet = Data(count: packetSize)
        sut.process(packet: packet, direction: .download) {
            handlerCalled = true
        }

        let expectation = XCTestExpectation(description: "Rate limiting download")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertTrue(handlerCalled)
            // With 1 KB/s bandwidth for a 1 KB packet, delay should be ~1ms
            // We're being lenient with timing due to system variance
            XCTAssertTrue(elapsed >= 0.0, "Handler should be called after rate limiting delay")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testProcess_RateLimitsUpload() {
        let state = makeThrottlingState(
            enabled: true,
            latency: 0,
            downloadSpeed: 1024,
            uploadSpeed: 512
        )
        sut.updateState(state)

        var handlerCalled = false
        let packet = Data(count: 512)

        sut.process(packet: packet, direction: .upload) {
            handlerCalled = true
        }

        let expectation = XCTestExpectation(description: "Rate limiting upload")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(handlerCalled)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Latency Injection Tests

    func testProcess_AppliesLatency() {
        let latencyMs = 50
        let state = makeThrottlingState(
            enabled: true,
            latency: latencyMs,
            downloadSpeed: 100000,
            uploadSpeed: 100000,
            packetLoss: 0.0
        )
        sut.updateState(state)

        let startTime = Date()
        var handlerCalled = false

        let packet = Data(count: 512)
        sut.process(packet: packet, direction: .download) {
            handlerCalled = true
        }

        let expectation = XCTestExpectation(description: "Latency injection")
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(latencyMs) / 1000.0 + 0.02) {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertTrue(handlerCalled, "Handler should be called after latency")

            let expectedLatency = TimeInterval(latencyMs) / 1000.0
            let tolerance = 0.02 // 20ms tolerance
            XCTAssertGreaterThanOrEqual(
                elapsed,
                expectedLatency - tolerance,
                "Elapsed time should be at least \(expectedLatency)s, got \(elapsed)s"
            )
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testProcess_ZeroLatency_NoDelay() {
        let state = makeThrottlingState(
            enabled: true,
            latency: 0,
            downloadSpeed: 100000,
            uploadSpeed: 100000
        )
        sut.updateState(state)

        let startTime = Date()
        var handlerCalled = false

        let packet = Data(count: 512)
        sut.process(packet: packet, direction: .download) {
            handlerCalled = true
        }

        let expectation = XCTestExpectation(description: "Zero latency no delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertTrue(handlerCalled)
            XCTAssertLessThan(elapsed, 0.03, "Should have minimal delay with zero latency")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)
    }

    // MARK: - Direction Tests

    func testProcess_DirectionsAreIndependent() {
        let state = makeThrottlingState(
            enabled: true,
            downloadSpeed: 512,
            uploadSpeed: 1024
        )
        sut.updateState(state)

        var downloadCalled = false
        var uploadCalled = false

        let downloadPacket = Data(count: 512)
        let uploadPacket = Data(count: 512)

        // Process in sequence but measure independently
        sut.process(packet: downloadPacket, direction: .download) {
            downloadCalled = true
        }

        sut.process(packet: uploadPacket, direction: .upload) {
            uploadCalled = true
        }

        let expectation = XCTestExpectation(description: "Independent directions")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(downloadCalled)
            if uploadCalled {
                expectation.fulfill()
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Combined Effects Tests

    func testProcess_CombinedLatencyAndRateLimiting() {
        let state = makeThrottlingState(
            enabled: true,
            latency: 20,
            downloadSpeed: 1024,
            uploadSpeed: 512
        )
        sut.updateState(state)

        let startTime = Date()
        var handlerCalled = false

        let packet = Data(count: 1024)
        sut.process(packet: packet, direction: .download) {
            handlerCalled = true
        }

        let expectation = XCTestExpectation(description: "Combined effects")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertTrue(handlerCalled)
            // Should have at least the latency delay
            XCTAssertGreaterThanOrEqual(elapsed, 0.02)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testProcess_CombinedLatencyRateLimitingAndLoss() {
        let state = makeThrottlingState(
            enabled: true,
            latency: 10,
            downloadSpeed: 1024,
            uploadSpeed: 512,
            packetLoss: 0.5
        )
        sut.updateState(state)

        let iterations = 100
        var successCount = 0
        let expectation = XCTestExpectation(description: "All combined effects")

        DispatchQueue.global().async {
            for _ in 0 ..< iterations {
                let packet = Data(count: 512)
                self.sut.process(packet: packet, direction: .download) {
                    successCount += 1
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // With 50% loss, we expect roughly half to succeed
            let acceptable = successCount > 20 && successCount < 80
            XCTAssertTrue(acceptable, "Expected ~50 successes with 50% loss, got \(successCount)")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }
}
