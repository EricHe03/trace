//
//  NetworkSimulatorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class NetworkSimulatorTests: XCTestCase {

    var simulator: NetworkSimulator!

    override func setUp() async throws {
        try await super.setUp()
        simulator = NetworkSimulator()
    }

    override func tearDown() async throws {
        simulator = nil
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func makeData(size: Int) -> Data {
        Data(repeating: 0xFF, count: size)
    }

    // MARK: - Bandwidth Throttling Tests

    func testApplyThrottleWithZeroBandwidth() async {
        let data = makeData(size: 1024)

        let result = await simulator.applyThrottle(bandwidth: 0, to: data)

        XCTAssertEqual(result, data)
        XCTAssertEqual(result.count, 1024)
    }

    func testApplyThrottleWithNegativeBandwidth() async {
        let data = makeData(size: 1024)

        let result = await simulator.applyThrottle(bandwidth: -100, to: data)

        // Should return original data without throttling
        XCTAssertEqual(result, data)
    }

    func testApplyThrottleWithSmallData() async {
        let data = makeData(size: 100)

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 10_000, to: data)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        XCTAssertEqual(result.count, 100)
        // Should complete quickly for small data
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testApplyThrottleWithLargeData() async {
        let data = makeData(size: 10_000)

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 100_000, to: data)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        XCTAssertEqual(result.count, 10_000)
        // Should take some time to throttle
        XCTAssertGreaterThan(elapsed, 0.01)
    }

    func testApplyThrottleReturnsCompleteData() async {
        let originalData = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let result = await simulator.applyThrottle(bandwidth: 1000, to: originalData)

        XCTAssertEqual(result, originalData)
    }

    func testApplyThrottleWithEmptyData() async {
        let data = Data()

        let result = await simulator.applyThrottle(bandwidth: 10_000, to: data)

        XCTAssertTrue(result.isEmpty)
    }

    func testApplyThrottleWithVeryHighBandwidth() async {
        let data = makeData(size: 10_000)

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 10_000_000, to: data)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        // Should complete very quickly with high bandwidth
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testApplyThrottleWithVeryLowBandwidth() async {
        let data = makeData(size: 2048)

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 1024, to: data)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        // Low bandwidth should take longer
        XCTAssertGreaterThan(elapsed, 0.1)
    }

    func testApplyThrottleChunking() async {
        // Test that data is properly chunked
        let data = makeData(size: 5000)

        let result = await simulator.applyThrottle(bandwidth: 10_000, to: data)

        XCTAssertEqual(result.count, data.count)
        XCTAssertEqual(result, data)
    }

    func testApplyThrottleMaintainsDataIntegrity() async {
        // Test with specific data pattern
        var data = Data()
        for i in 0..<1000 {
            data.append(UInt8(i % 256))
        }

        let result = await simulator.applyThrottle(bandwidth: 50_000, to: data)

        XCTAssertEqual(result.count, data.count)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], data[i])
        }
    }

    // MARK: - Jitter Tests

    func testApplyJitterWithZeroDelay() async {
        let startTime = Date()
        await simulator.applyJitter(baseDelay: 0, variance: 0)
        let elapsed = Date().timeIntervalSince(startTime)

        // Should complete immediately
        XCTAssertLessThan(elapsed, 0.01)
    }

    func testApplyJitterWithPositiveDelay() async {
        let baseDelay = 100 // 100ms
        let variance = 0

        let startTime = Date()
        await simulator.applyJitter(baseDelay: baseDelay, variance: variance)
        let elapsed = Date().timeIntervalSince(startTime)

        // Should delay approximately baseDelay milliseconds
        XCTAssertGreaterThan(elapsed, 0.08) // Allow some variance
        XCTAssertLessThan(elapsed, 0.15)
    }

    func testApplyJitterWithVariance() async {
        let baseDelay = 100 // 100ms
        let variance = 50 // ±50ms

        var delays: [TimeInterval] = []

        // Run multiple times to test variance
        for _ in 0..<5 {
            let startTime = Date()
            await simulator.applyJitter(baseDelay: baseDelay, variance: variance)
            let elapsed = Date().timeIntervalSince(startTime)
            delays.append(elapsed)
        }

        // Delays should vary
        let minDelay = delays.min() ?? 0
        let maxDelay = delays.max() ?? 0

        // Should be roughly in range [50ms, 150ms]
        XCTAssertGreaterThan(minDelay, 0.03)
        XCTAssertLessThan(maxDelay, 0.2)
    }

    func testApplyJitterWithNegativeVariance() async {
        let baseDelay = 100
        let variance = -50 // Negative variance should still work

        let startTime = Date()
        await simulator.applyJitter(baseDelay: baseDelay, variance: variance)
        let elapsed = Date().timeIntervalSince(startTime)

        // Should still apply some delay
        XCTAssertGreaterThan(elapsed, 0.0)
    }

    func testApplyJitterWithLargeVariance() {
        let baseDelay = 50
        let variance = 100 // Variance larger than base

        func random(expectedRange: ClosedRange<Int>, returning value: Int) -> (ClosedRange<Int>) -> Int {
            { range in
                XCTAssertEqual(range.lowerBound, expectedRange.lowerBound)
                XCTAssertEqual(range.upperBound, expectedRange.upperBound)
                return value
            }
        }

        let expectedRange = -variance ... variance

        XCTAssertEqual(
            NetworkSimulator.jitteredDelay(
                baseDelay: baseDelay,
                variance: variance,
                randomInRange: random(expectedRange: expectedRange, returning: -variance)
            ),
            0
        )

        XCTAssertEqual(
            NetworkSimulator.jitteredDelay(
                baseDelay: baseDelay,
                variance: variance,
                randomInRange: random(expectedRange: expectedRange, returning: 0)
            ),
            baseDelay
        )

        XCTAssertEqual(
            NetworkSimulator.jitteredDelay(
                baseDelay: baseDelay,
                variance: variance,
                randomInRange: random(expectedRange: expectedRange, returning: variance)
            ),
            baseDelay + variance
        )
    }

    func testApplyJitterNegativeResultClampsToZero() async {
        let baseDelay = 10
        let variance = 100 // Large variance could result in negative

        let startTime = Date()
        await simulator.applyJitter(baseDelay: baseDelay, variance: variance)
        let elapsed = Date().timeIntervalSince(startTime)

        // Should never be negative
        XCTAssertGreaterThanOrEqual(elapsed, 0)
    }

    // MARK: - Failure Simulation Tests

    func testSimulateFailureTimeout() {
        XCTAssertThrowsError(try simulator.simulateFailure(type: .timeout)) { error in
            XCTAssertTrue(error is NetworkSimulationError)
            if let simError = error as? NetworkSimulationError {
                XCTAssertEqual(simError, .timeout)
            }
        }
    }

    func testSimulateFailureConnectionReset() {
        XCTAssertThrowsError(try simulator.simulateFailure(type: .connectionReset)) { error in
            XCTAssertTrue(error is NetworkSimulationError)
            if let simError = error as? NetworkSimulationError {
                XCTAssertEqual(simError, .connectionReset)
            }
        }
    }

    func testSimulateFailurePacketLoss() {
        XCTAssertThrowsError(try simulator.simulateFailure(type: .packetLoss)) { error in
            XCTAssertTrue(error is NetworkSimulationError)
            if let simError = error as? NetworkSimulationError {
                XCTAssertEqual(simError, .packetLoss)
            }
        }
    }

    func testSimulateFailureCorruptData() {
        // Corrupt data doesn't throw
        XCTAssertNoThrow(try simulator.simulateFailure(type: .corruptData))
    }

    func testSimulateFailureDifferentTypes() {
        let types: [FailureType] = [.timeout, .connectionReset, .packetLoss]

        for failureType in types {
            XCTAssertThrowsError(try simulator.simulateFailure(type: failureType)) { error in
                XCTAssertTrue(error is NetworkSimulationError)
            }
        }
    }

    // MARK: - Combined Scenario Tests

    func testThrottleAndJitterCombined() async {
        let data = makeData(size: 5000)
        let baseDelay = 50
        let variance = 20

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 50_000, to: data)
        await simulator.applyJitter(baseDelay: baseDelay, variance: variance)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        // Should take time for both throttle and jitter
        XCTAssertGreaterThan(elapsed, 0.05)
    }

    func testMultipleThrottleOperationsSequentially() async {
        let data1 = makeData(size: 1000)
        let data2 = makeData(size: 2000)
        let data3 = makeData(size: 1500)

        let result1 = await simulator.applyThrottle(bandwidth: 10_000, to: data1)
        let result2 = await simulator.applyThrottle(bandwidth: 10_000, to: data2)
        let result3 = await simulator.applyThrottle(bandwidth: 10_000, to: data3)

        XCTAssertEqual(result1.count, 1000)
        XCTAssertEqual(result2.count, 2000)
        XCTAssertEqual(result3.count, 1500)
    }

    func testMultipleJitterOperationsSequentially() async {
        var totalTime: TimeInterval = 0

        for _ in 0..<3 {
            let startTime = Date()
            await simulator.applyJitter(baseDelay: 50, variance: 10)
            totalTime += Date().timeIntervalSince(startTime)
        }

        // Should accumulate delays
        XCTAssertGreaterThan(totalTime, 0.1)
    }

    // MARK: - Real-world Network Conditions

    func testSimulate3GNetwork() async {
        // 3G: ~384 Kbps, 100ms latency, ±50ms jitter
        let data = makeData(size: 10_000)

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 48_000, to: data) // 384 Kbps = 48 KB/s
        await simulator.applyJitter(baseDelay: 100, variance: 50)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        XCTAssertGreaterThan(elapsed, 0.1)
    }

    func testSimulate4GNetwork() async {
        // 4G: ~10 Mbps, 50ms latency, ±20ms jitter
        let data = makeData(size: 50_000)

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 1_250_000, to: data) // 10 Mbps = 1.25 MB/s
        await simulator.applyJitter(baseDelay: 50, variance: 20)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        XCTAssertGreaterThan(elapsed, 0.03)
    }

    func testSimulateSlowNetwork() async {
        // Simulate very slow connection
        let data = makeData(size: 1000)

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 1000, to: data)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        // Should take significant time
        XCTAssertGreaterThan(elapsed, 0.5)
    }

    func testSimulateFastNetwork() async {
        // Simulate fast connection (100 Mbps)
        let data = makeData(size: 100_000)

        let startTime = Date()
        let result = await simulator.applyThrottle(bandwidth: 12_500_000, to: data)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertEqual(result, data)
        // Should complete quickly
        XCTAssertLessThan(elapsed, 0.5)
    }

    // MARK: - Performance Tests

    func testThrottlePerformanceWithLargeData() async {
        let data = makeData(size: 1_000_000) // 1 MB

        measure {
            Task {
                let result = await self.simulator.applyThrottle(bandwidth: 10_000_000, to: data)
                XCTAssertEqual(result.count, 1_000_000)
            }
        }
    }

    func testJitterPerformance() async {
        measure {
            Task {
                await self.simulator.applyJitter(baseDelay: 10, variance: 5)
            }
        }
    }

    // MARK: - Concurrency Tests

    func testConcurrentThrottleOperations() async {
        let data1 = makeData(size: 5000)
        let data2 = makeData(size: 5000)
        let data3 = makeData(size: 5000)

        async let result1 = simulator.applyThrottle(bandwidth: 50_000, to: data1)
        async let result2 = simulator.applyThrottle(bandwidth: 50_000, to: data2)
        async let result3 = simulator.applyThrottle(bandwidth: 50_000, to: data3)

        let results = await [result1, result2, result3]

        XCTAssertEqual(results[0].count, 5000)
        XCTAssertEqual(results[1].count, 5000)
        XCTAssertEqual(results[2].count, 5000)
    }

    func testConcurrentJitterOperations() async {
        let expectation = XCTestExpectation(description: "Concurrent jitter")
        expectation.expectedFulfillmentCount = 5

        for _ in 0..<5 {
            Task {
                await self.simulator.applyJitter(baseDelay: 50, variance: 10)
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testConcurrentFailureSimulations() {
        let expectation = XCTestExpectation(description: "Concurrent failures")
        expectation.expectedFulfillmentCount = 3

        for failureType in [FailureType.timeout, .connectionReset, .packetLoss] {
            DispatchQueue.global().async {
                do {
                    _ = try self.simulator.simulateFailure(type: failureType)
                    XCTFail("Expected error to be thrown")
                } catch {
                    // Expected error
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Actor Isolation Tests

    func testSimulatorIsActorIsolated() async {
        let simulator1 = NetworkSimulator()
        let simulator2 = NetworkSimulator()

        let data = makeData(size: 1000)

        // Both should work independently
        async let result1 = simulator1.applyThrottle(bandwidth: 10_000, to: data)
        async let result2 = simulator2.applyThrottle(bandwidth: 10_000, to: data)

        let results = await [result1, result2]

        XCTAssertEqual(results[0].count, 1000)
        XCTAssertEqual(results[1].count, 1000)
    }

    // MARK: - Edge Cases

    func testThrottleWithSingleByte() async {
        let data = Data([0xFF])

        let result = await simulator.applyThrottle(bandwidth: 1000, to: data)

        XCTAssertEqual(result, data)
    }

    func testThrottleWithMaxBandwidth() async {
        let data = makeData(size: 10_000)

        let result = await simulator.applyThrottle(bandwidth: Int.max, to: data)

        XCTAssertEqual(result, data)
    }

    func testJitterWithZeroVariance() async {
        let baseDelay = 100

        let startTime = Date()
        await simulator.applyJitter(baseDelay: baseDelay, variance: 0)
        let elapsed = Date().timeIntervalSince(startTime)

        // Should be close to base delay
        XCTAssertGreaterThan(elapsed, 0.08)
        XCTAssertLessThan(elapsed, 0.15)
    }

    func testJitterWithMaxVariance() async {
        let baseDelay = 100

        await simulator.applyJitter(baseDelay: baseDelay, variance: Int.max)

        // Should not crash, delay will vary widely
    }

    // MARK: - Error Handling

    func testFailureTypesAreSendable() {
        // Ensure FailureType conforms to Sendable
        let types: [FailureType] = [.timeout, .connectionReset, .corruptData, .packetLoss]

        Task {
            for type in types {
                _ = type
            }
        }
    }

    func testNetworkSimulationErrorsAreSendable() {
        // Ensure NetworkSimulationError conforms to Sendable
        let errors: [NetworkSimulationError] = [.timeout, .connectionReset, .packetLoss]

        Task {
            for error in errors {
                _ = error
            }
        }
    }
}
