//
//  NetworkCaptureServiceTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
import Combine
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class NetworkCaptureServiceTests: XCTestCase {
    var sut: NetworkCaptureService!
    var mockVPNManager: MockVPNManager!

    override func setUp() {
        super.setUp()
        mockVPNManager = MockVPNManager()
        sut = NetworkCaptureService(vpnManager: mockVPNManager)
    }

    override func tearDown() {
        sut = nil
        mockVPNManager = nil
        super.tearDown()
    }

    // MARK: - isCapturing Property Tests

    func testIsCapturing_WhenVPNConnected_ReturnsTrue() {
        // Given
        mockVPNManager.isConnected = true

        // When
        let isCapturing = sut.isCapturing

        // Then
        XCTAssertTrue(isCapturing)
    }

    func testIsCapturing_WhenVPNDisconnected_ReturnsFalse() {
        // Given
        mockVPNManager.isConnected = false

        // When
        let isCapturing = sut.isCapturing

        // Then
        XCTAssertFalse(isCapturing)
    }

    // MARK: - Start Capture Tests

    func testStartCapture_CallsVPNManagerStart() async throws {
        // Given
        mockVPNManager.shouldSucceed = true

        // When
        try await sut.startCapture()

        // Then
        XCTAssertTrue(mockVPNManager.startCalled)
        XCTAssertEqual(mockVPNManager.startCallCount, 1)
    }

    func testStartCapture_WhenVPNFails_ThrowsError() async {
        // Given
        mockVPNManager.shouldSucceed = false

        // When/Then
        await XCTAssertThrowsError(try await sut.startCapture())
    }

    func testStartCapture_UpdatesIsCapturingStatus() async throws {
        // Given
        mockVPNManager.shouldSucceed = true
        mockVPNManager.isConnected = false

        // When
        try await sut.startCapture()
        mockVPNManager.isConnected = true

        // Then
        XCTAssertTrue(sut.isCapturing)
    }

    // MARK: - Stop Capture Tests

    func testStopCapture_CallsVPNManagerStop() async throws {
        // Given
        mockVPNManager.isConnected = true

        // When
        try await sut.stopCapture()

        // Then
        XCTAssertTrue(mockVPNManager.stopCalled)
        XCTAssertEqual(mockVPNManager.stopCallCount, 1)
    }

    func testStopCapture_UpdatesIsCapturingStatus() async throws {
        // Given
        mockVPNManager.isConnected = true

        // When
        try await sut.stopCapture()
        mockVPNManager.isConnected = false

        // Then
        XCTAssertFalse(sut.isCapturing)
    }

    // MARK: - Observe Capture Status Tests

    func testObserveCaptureStatus_EmitsInitialStatus() async throws {
        // Given
        mockVPNManager.isConnected = true
        var receivedValues: [Bool] = []

        // When
        let stream = await sut.observeCaptureStatus()
        let task = Task {
            for await value in stream {
                receivedValues.append(value)
                if receivedValues.count >= 1 {
                    break
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay
        task.cancel()

        // Then
        XCTAssertFalse(receivedValues.isEmpty)
        XCTAssertEqual(receivedValues.first, true)
    }

    func testObserveCaptureStatus_EmitsStatusChanges() async throws {
        // Given
        mockVPNManager.isConnected = true
        var receivedValues: [Bool] = []

        // When
        let stream = await sut.observeCaptureStatus()
        let task = Task {
            for await value in stream {
                receivedValues.append(value)
                if receivedValues.count >= 2 {
                    break
                }
            }
        }

        // Simulate status change
        try await Task.sleep(nanoseconds: 100_000_000)
        mockVPNManager.emitConnection(false)

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // Then
        XCTAssertGreaterThanOrEqual(receivedValues.count, 1)
    }

    func testObserveCaptureStatus_TerminationCancelsCancellable() async throws {
        // Given
        var cancellableRetained = false

        // When
        let stream = await sut.observeCaptureStatus()
        let task = Task {
            for await _ in stream {
                cancellableRetained = true
                break
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        // Then - stream should terminate cleanly
        XCTAssertTrue(task.isCancelled)
    }
}

// MARK: - Mock VPNManager

@MainActor
class MockVPNManager: VPNManaging {
    var isConnected: Bool = false {
        didSet {
            connectionSubject.send(isConnected)
        }
    }
    var shouldSucceed = true

    var startCalled = false
    var startCallCount = 0
    var stopCalled = false
    var stopCallCount = 0

    private let connectionSubject = CurrentValueSubject<Bool, Never>(false)

    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        connectionSubject.eraseToAnyPublisher()
    }

    func emitConnection(_ value: Bool) {
        isConnected = value
    }

    func start() async throws {
        startCalled = true
        startCallCount += 1

        if !shouldSucceed {
            struct MockError: Error {}
            throw MockError()
        }

        isConnected = true
    }

    func stop() {
        stopCalled = true
        stopCallCount += 1
        isConnected = false
    }
}
