//
//  NetworkSimulatorTests.swift
//  TraceTests
//
//  Created by Claude on 2026-02-01.
//

import XCTest
@testable import TraceFeatures
@testable import TraceCore

final class NetworkSimulatorTests: XCTestCase {
    var sut: NetworkSimulator!

    override func setUp() {
        super.setUp()
        sut = NetworkSimulator()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInit() {
        // Arrange & Act
        let simulator = NetworkSimulator()

        // Assert
        XCTAssertNotNil(simulator)
    }

    // MARK: - Apply Throttle Tests

    func testApplyThrottle_WithPositiveBandwidth_ReturnsFullData() async {
        // Arrange
        let testData = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let bandwidth = 10000 // High bandwidth

        // Act
        let result = await sut.applyThrottle(bandwidth: bandwidth, to: testData)

        // Assert
        XCTAssertEqual(result, testData)
        XCTAssertEqual(result.count, testData.count)
    }

    func testApplyThrottle_WithZeroBandwidth_ReturnsOriginalData() async {
        // Arrange
        let testData = Data([1, 2, 3, 4, 5])
        let bandwidth = 0

        // Act
        let result = await sut.applyThrottle(bandwidth: bandwidth, to: testData)

        // Assert
        XCTAssertEqual(result, testData)
    }

    func testApplyThrottle_WithNegativeBandwidth_ReturnsOriginalData() async {
        // Arrange
        let testData = Data([1, 2, 3, 4, 5])
        let bandwidth = -100

        // Act
        let result = await sut.applyThrottle(bandwidth: bandwidth, to: testData)

        // Assert
        XCTAssertEqual(result, testData)
    }

    func testApplyThrottle_WithEmptyData_ReturnsEmptyData() async {
        // Arrange
        let testData = Data()
        let bandwidth = 1024

        // Act
        let result = await sut.applyThrottle(bandwidth: bandwidth, to: testData)

        // Assert
        XCTAssertEqual(result, testData)
        XCTAssertTrue(result.isEmpty)
    }

    func testApplyThrottle_WithLargeBandwidth_ProcessesDataQuickly() async {
        // Arrange
        let testData = Data(count: 10000)
        let bandwidth = 1000000 // 1 MB/s
        let startTime = Date()

        // Act
        let result = await sut.applyThrottle(bandwidth: bandwidth, to: testData)
        let duration = Date().timeIntervalSince(startTime)

        // Assert
        XCTAssertEqual(result.count, testData.count)
        XCTAssertLessThan(duration, 1.0) // Should complete in less than 1 second
    }

    func testApplyThrottle_WithSmallBandwidth_TakesTime() async {
        // Arrange
        let testData = Data(count: 2048)
        let bandwidth = 1024 // 1 KB/s
        let startTime = Date()

        // Act
        let result = await sut.applyThrottle(bandwidth: bandwidth, to: testData)
        let duration = Date().timeIntervalSince(startTime)

        // Assert
        XCTAssertEqual(result.count, testData.count)
        XCTAssertGreaterThan(duration, 0.5) // Should take some time
    }

    func testApplyThrottle_ChunksDataCorrectly() async {
        // Arrange
        let testData = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let bandwidth = 2048

        // Act
        let result = await sut.applyThrottle(bandwidth: bandwidth, to: testData)

        // Assert
        XCTAssertEqual(result, testData)
        XCTAssertEqual(result[0], 1)
        XCTAssertEqual(result[result.count - 1], 8)
    }

    // MARK: - Apply Jitter Tests

    func testApplyJitter_WithZeroBaseDelay_CompletesQuickly() async {
        // Arrange
        let baseDelay = 0
        let variance = 10
        let startTime = Date()

        // Act
        await sut.applyJitter(baseDelay: baseDelay, variance: variance)
        let duration = Date().timeIntervalSince(startTime)

        // Assert
        XCTAssertLessThan(duration, 0.5)
    }

    func testApplyJitter_WithPositiveBaseDelay_AppliesDelay() async {
        // Arrange
        let baseDelay = 100 // 100ms
        let variance = 0
        let startTime = Date()

        // Act
        await sut.applyJitter(baseDelay: baseDelay, variance: variance)
        let duration = Date().timeIntervalSince(startTime)

        // Assert
        XCTAssertGreaterThanOrEqual(duration, 0.09) // Allow some margin
    }

    func testApplyJitter_WithVariance_AppliesDelayWithinRange() async {
        // Arrange
        let baseDelay = 100
        let variance = 50
        let startTime = Date()

        // Act
        await sut.applyJitter(baseDelay: baseDelay, variance: variance)
        let duration = Date().timeIntervalSince(startTime)

        // Assert - delay should be between (100-50)ms and (100+50)ms
        XCTAssertGreaterThanOrEqual(duration, 0.04) // Allow margin
        XCTAssertLessThan(duration, 0.2)
    }

    func testApplyJitter_WithNegativeBaseDelay_DoesNotApplyDelay() async {
        // Arrange
        let baseDelay = -100
        let variance = 10
        let startTime = Date()

        // Act
        await sut.applyJitter(baseDelay: baseDelay, variance: variance)
        let duration = Date().timeIntervalSince(startTime)

        // Assert
        XCTAssertLessThan(duration, 0.1)
    }

    // MARK: - Simulate Failure Tests

    func testSimulateFailure_Timeout_ThrowsTimeoutError() {
        // Arrange
        let failureType = FailureType.timeout

        // Act & Assert
        XCTAssertThrowsError(try sut.simulateFailure(type: failureType)) { error in
            XCTAssertTrue(error is NetworkSimulationError)
            XCTAssertEqual(error as? NetworkSimulationError, .timeout)
        }
    }

    func testSimulateFailure_ConnectionReset_ThrowsConnectionResetError() {
        // Arrange
        let failureType = FailureType.connectionReset

        // Act & Assert
        XCTAssertThrowsError(try sut.simulateFailure(type: failureType)) { error in
            XCTAssertTrue(error is NetworkSimulationError)
            XCTAssertEqual(error as? NetworkSimulationError, .connectionReset)
        }
    }

    func testSimulateFailure_PacketLoss_ThrowsPacketLossError() {
        // Arrange
        let failureType = FailureType.packetLoss

        // Act & Assert
        XCTAssertThrowsError(try sut.simulateFailure(type: failureType)) { error in
            XCTAssertTrue(error is NetworkSimulationError)
            XCTAssertEqual(error as? NetworkSimulationError, .packetLoss)
        }
    }

    func testSimulateFailure_CorruptData_DoesNotThrow() {
        // Arrange
        let failureType = FailureType.corruptData

        // Act & Assert
        XCTAssertNoThrow(try sut.simulateFailure(type: failureType))
    }

    // MARK: - Jittered Delay Static Method Tests

    func testJitteredDelay_WithZeroVariance_ReturnsBaseDelay() {
        // Arrange
        let baseDelay = 100
        let variance = 0

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in 0 }
        )

        // Assert
        XCTAssertEqual(result, baseDelay)
    }

    func testJitteredDelay_WithPositiveJitter_AddsToBaseDelay() {
        // Arrange
        let baseDelay = 100
        let variance = 50
        let fixedJitter = 25

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in fixedJitter }
        )

        // Assert
        XCTAssertEqual(result, baseDelay + fixedJitter)
    }

    func testJitteredDelay_WithNegativeJitter_SubtractsFromBaseDelay() {
        // Arrange
        let baseDelay = 100
        let variance = 50
        let fixedJitter = -25

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in fixedJitter }
        )

        // Assert
        XCTAssertEqual(result, baseDelay + fixedJitter)
    }

    func testJitteredDelay_WithNegativeResult_ReturnsZero() {
        // Arrange
        let baseDelay = 50
        let variance = 100
        let fixedJitter = -100

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in fixedJitter }
        )

        // Assert
        XCTAssertEqual(result, 0)
    }

    func testJitteredDelay_WithIntMinVariance_HandlesEdgeCase() {
        // Arrange
        let baseDelay = 100
        let variance = Int.min

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in 0 }
        )

        // Assert
        XCTAssertGreaterThanOrEqual(result, 0)
    }

    func testJitteredDelay_WithOverflow_ReturnsIntMax() {
        // Arrange
        let baseDelay = Int.max
        let variance = 100
        let fixedJitter = 50

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in fixedJitter }
        )

        // Assert
        XCTAssertEqual(result, Int.max)
    }

    func testJitteredDelay_WithUnderflow_ReturnsZero() {
        // Arrange
        let baseDelay = Int.min
        let variance = 100
        let fixedJitter = -50

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in fixedJitter }
        )

        // Assert
        XCTAssertEqual(result, 0)
    }

    func testJitteredDelay_WithZeroBaseDelay_ReturnsNonNegative() {
        // Arrange
        let baseDelay = 0
        let variance = 50
        let fixedJitter = 25

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in fixedJitter }
        )

        // Assert
        XCTAssertEqual(result, 25)
    }

    func testJitteredDelay_WithNegativeVariance_NormalizesToPositive() {
        // Arrange
        let baseDelay = 100
        let variance = -50
        let fixedJitter = 25

        // Act
        let result = NetworkSimulator.jitteredDelay(
            baseDelay: baseDelay,
            variance: variance,
            randomInRange: { _ in fixedJitter }
        )

        // Assert
        XCTAssertEqual(result, baseDelay + fixedJitter)
    }

    // MARK: - FailureType Codable Tests

    func testFailureType_Codable_Timeout() throws {
        // Arrange
        let failureType = FailureType.timeout

        // Act
        let encoded = try JSONEncoder().encode(failureType)
        let decoded = try JSONDecoder().decode(FailureType.self, from: encoded)

        // Assert
        XCTAssertEqual(decoded, failureType)
    }

    func testFailureType_Codable_AllCases() throws {
        // Arrange
        let allCases: [FailureType] = [.timeout, .connectionReset, .corruptData, .packetLoss]

        // Act & Assert
        for failureType in allCases {
            let encoded = try JSONEncoder().encode(failureType)
            let decoded = try JSONDecoder().decode(FailureType.self, from: encoded)
            XCTAssertEqual(decoded, failureType)
        }
    }

    // MARK: - NetworkSimulationError Tests

    func testNetworkSimulationError_IsError() {
        // Arrange
        let error: Error = NetworkSimulationError.timeout

        // Assert
        XCTAssertTrue(error is NetworkSimulationError)
    }

    func testNetworkSimulationError_Equality() {
        // Arrange
        let error1 = NetworkSimulationError.timeout
        let error2 = NetworkSimulationError.timeout
        let error3 = NetworkSimulationError.connectionReset

        // Assert
        XCTAssertEqual(error1, error2)
        XCTAssertNotEqual(error1, error3)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentThrottling() async {
        // Arrange
        let testData = Data(count: 1000)
        let bandwidth = 10000

        // Act
        await withTaskGroup(of: Data.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.sut.applyThrottle(bandwidth: bandwidth, to: testData)
                }
            }

            // Assert
            for await result in group {
                XCTAssertEqual(result.count, testData.count)
            }
        }
    }

    func testConcurrentJitter() async {
        // Arrange
        let baseDelay = 10
        let variance = 5

        // Act & Assert - should not crash
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.sut.applyJitter(baseDelay: baseDelay, variance: variance)
                }
            }
        }
    }

    // MARK: - Integration Tests

    func testThrottleThenJitter() async {
        // Arrange
        let testData = Data([1, 2, 3, 4, 5])
        let bandwidth = 10000
        let baseDelay = 50
        let variance = 10
        let startTime = Date()

        // Act
        let throttledData = await sut.applyThrottle(bandwidth: bandwidth, to: testData)
        await sut.applyJitter(baseDelay: baseDelay, variance: variance)
        let duration = Date().timeIntervalSince(startTime)

        // Assert
        XCTAssertEqual(throttledData, testData)
        XCTAssertGreaterThan(duration, 0.03) // Should have some delay from jitter
    }
}
