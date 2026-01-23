//
//  BreakpointManagerTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class BreakpointManagerTests: XCTestCase {

    var manager: BreakpointManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = BreakpointManager.shared
        await manager.setEnabled(false)
        await manager.resumeAllRequests(action: .continue)
    }

    override func tearDown() async throws {
        await manager.setEnabled(false)
        await manager.resumeAllRequests(action: .continue)
        try await super.tearDown()
    }

    // MARK: - Singleton Tests

    func testSingletonPattern() {
        let manager1 = BreakpointManager.shared
        let manager2 = BreakpointManager.shared

        XCTAssertTrue(manager1 === manager2, "BreakpointManager should be a singleton")
    }

    // MARK: - Configuration Tests

    func testGetConfiguration() async {
        let config = await manager.getConfiguration()

        XCTAssertNotNil(config)
    }

    func testUpdateConfiguration() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .request

        await manager.updateConfiguration(config)

        let retrieved = await manager.getConfiguration()
        XCTAssertEqual(retrieved.enabled, true)
        XCTAssertEqual(retrieved.breakpointType, .request)
    }

    func testSetEnabled() async {
        await manager.setEnabled(true)
        var isEnabled = await manager.isEnabled()
        XCTAssertTrue(isEnabled)

        await manager.setEnabled(false)
        isEnabled = await manager.isEnabled()
        XCTAssertFalse(isEnabled)
    }

    // MARK: - Breakpoint Checking Tests

    func testShouldBreakOnRequest() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .request
        await manager.updateConfiguration(config)

        let shouldBreak = await manager.shouldBreakOnRequest(
            url: "https://example.com",
            method: .get
        )

        XCTAssertTrue(shouldBreak)
    }

    func testShouldNotBreakOnRequestWhenDisabled() async {
        var config = BreakpointConfiguration()
        config.enabled = false
        config.breakpointType = .request
        await manager.updateConfiguration(config)

        let shouldBreak = await manager.shouldBreakOnRequest(
            url: "https://example.com",
            method: .get
        )

        XCTAssertFalse(shouldBreak)
    }

    func testShouldBreakOnResponse() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .response
        await manager.updateConfiguration(config)

        let shouldBreak = await manager.shouldBreakOnResponse(
            url: "https://example.com",
            statusCode: 200
        )

        XCTAssertTrue(shouldBreak)
    }

    // MARK: - Request Pausing Tests

    func testPauseAndResumeRequest() async {
        let requestId = UUID().uuidString

        // Start pausing in background
        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com",
                method: .get,
                headers: [],
                body: nil
            )
        }

        // Give it time to register
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Verify it's paused
        let count = await manager.pausedRequestsCount()
        XCTAssertEqual(count, 1)

        // Resume it
        await manager.resumeRequest(id: requestId, action: .continue)

        // Wait for pause task to complete
        let action = await pauseTask.value
        XCTAssertEqual(action, .continue)

        // Verify it's no longer paused
        let finalCount = await manager.pausedRequestsCount()
        XCTAssertEqual(finalCount, 0)
    }

    func testPauseResponse() async {
        let requestId = UUID().uuidString

        // Start pausing in background
        let pauseTask = Task {
            await manager.pauseResponse(
                id: requestId,
                url: "https://example.com",
                method: .get,
                statusCode: 200,
                statusMessage: "OK",
                headers: [],
                body: nil
            )
        }

        // Give it time to register
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Verify it's paused
        let count = await manager.pausedRequestsCount()
        XCTAssertEqual(count, 1)

        // Resume it
        await manager.resumeRequest(id: requestId, action: .continue)

        // Wait for completion
        let action = await pauseTask.value
        XCTAssertEqual(action, .continue)
    }

    // MARK: - Request Modification Tests

    func testUpdatePausedRequest() async {
        let requestId = UUID().uuidString

        // Start pausing
        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com",
                method: .get,
                headers: [],
                body: nil
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        // Update the request
        let modifications = PausedRequestModifications(
            url: "https://modified.com",
            method: .post,
            headers: [TraceHTTPHeader(key: "X-Modified", value: "true")],
            body: "modified".data(using: .utf8),
            statusCode: nil,
            statusMessage: nil
        )

        await manager.updatePausedRequest(id: requestId, modifications: modifications)

        // Get the paused request
        let pausedRequest = await manager.getPausedRequest(id: requestId)
        XCTAssertNotNil(pausedRequest)
        XCTAssertEqual(pausedRequest?.modifiedUrl, "https://modified.com")
        XCTAssertEqual(pausedRequest?.modifiedMethod, .post)

        // Clean up
        await manager.resumeRequest(id: requestId, action: .continue)
        _ = await pauseTask.value
    }

    func testGetPausedRequest() async {
        let requestId = UUID().uuidString

        // Start pausing
        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com",
                method: .get,
                headers: [],
                body: nil
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        // Get the request
        let pausedRequest = await manager.getPausedRequest(id: requestId)
        XCTAssertNotNil(pausedRequest)
        XCTAssertEqual(pausedRequest?.id, requestId)
        XCTAssertEqual(pausedRequest?.url, "https://example.com")

        // Clean up
        await manager.resumeRequest(id: requestId, action: .continue)
        _ = await pauseTask.value
    }

    func testGetAllPausedRequests() async {
        let requestId1 = UUID().uuidString
        let requestId2 = UUID().uuidString

        // Pause two requests
        let task1 = Task {
            await manager.pauseRequest(
                id: requestId1,
                url: "https://example1.com",
                method: .get,
                headers: [],
                body: nil
            )
        }

        let task2 = Task {
            await manager.pauseRequest(
                id: requestId2,
                url: "https://example2.com",
                method: .post,
                headers: [],
                body: nil
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        // Get all paused requests
        let allPaused = await manager.getAllPausedRequests()
        XCTAssertEqual(allPaused.count, 2)

        // Clean up
        await manager.resumeRequest(id: requestId1, action: .continue)
        await manager.resumeRequest(id: requestId2, action: .continue)
        _ = await task1.value
        _ = await task2.value
    }

    func testPausedRequestsCount() async {
        let initialCount = await manager.pausedRequestsCount()
        XCTAssertEqual(initialCount, 0)

        let requestId = UUID().uuidString
        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com",
                method: .get,
                headers: [],
                body: nil
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        let count = await manager.pausedRequestsCount()
        XCTAssertEqual(count, 1)

        await manager.resumeRequest(id: requestId, action: .continue)
        _ = await pauseTask.value

        let finalCount = await manager.pausedRequestsCount()
        XCTAssertEqual(finalCount, 0)
    }

    // MARK: - Resume All Tests

    func testResumeAllRequests() async {
        let requestIds = (0..<3).map { _ in UUID().uuidString }

        // Pause multiple requests
        let tasks = requestIds.map { id in
            Task {
                await manager.pauseRequest(
                    id: id,
                    url: "https://example.com",
                    method: .get,
                    headers: [],
                    body: nil
                )
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        let count = await manager.pausedRequestsCount()
        XCTAssertEqual(count, 3)

        // Resume all
        await manager.resumeAllRequests(action: .continue)

        // Wait for all tasks
        for task in tasks {
            _ = await task.value
        }

        let finalCount = await manager.pausedRequestsCount()
        XCTAssertEqual(finalCount, 0)
    }

    // MARK: - Breakpoint Action Tests

    func testDropAction() async {
        let requestId = UUID().uuidString

        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com",
                method: .get,
                headers: [],
                body: nil
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        // Resume with drop action
        await manager.resumeRequest(id: requestId, action: .drop)

        let action = await pauseTask.value
        XCTAssertEqual(action, .drop)
    }
}
