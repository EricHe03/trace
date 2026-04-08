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
        try clearSharedBreakpointState()
        await manager.setEnabled(false)
        await manager.resumeAllRequests(action: .continue)
    }

    override func tearDown() async throws {
        await manager.setEnabled(false)
        await manager.resumeAllRequests(action: .continue)
        try clearSharedBreakpointState()
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
            method: .get,
            headers: [],
            body: nil
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
            method: .get,
            headers: [],
            body: nil
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
            statusCode: 200,
            headers: [],
            body: nil
        )

        XCTAssertTrue(shouldBreak)
    }

    func testShouldBreakOnStream() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .stream
        await manager.updateConfiguration(config)

        let shouldBreak = await manager.shouldBreakOnStream(
            url: "wss://echo.example/ws",
            headers: [],
            body: Data("hello".utf8)
        )

        XCTAssertTrue(shouldBreak)
    }

    func testShouldNotBreakOnStreamWhenLogOnly() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .stream
        config.executionMode = .logOnly
        await manager.updateConfiguration(config)

        let shouldBreak = await manager.shouldBreakOnStream(
            url: "wss://echo.example/ws",
            headers: [],
            body: Data("hello".utf8)
        )

        XCTAssertFalse(shouldBreak)
    }

    func testShouldBreakOnStreamRespectsAlwaysApplyStoredModifications() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .stream
        config.executionMode = .alwaysApply
        await manager.updateConfiguration(config)

        let eventId = UUID().uuidString
        let pauseTask = Task {
            await self.manager.pauseStreamEvent(
                id: eventId,
                url: "wss://echo.example/ws",
                headers: [],
                body: Data("hello".utf8)
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await manager.updatePausedRequest(
            id: eventId,
            modifications: PausedRequestModifications(body: Data("patched".utf8))
        )
        await manager.resumeRequest(id: eventId, action: .continue)
        _ = await pauseTask.value

        let shouldBreakAgain = await manager.shouldBreakOnStream(
            url: "wss://echo.example/ws",
            headers: [],
            body: Data("hello".utf8)
        )
        XCTAssertFalse(shouldBreakAgain)
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

    func testPauseStreamEvent() async {
        let eventId = UUID().uuidString

        let pauseTask = Task {
            await manager.pauseStreamEvent(
                id: eventId,
                url: "wss://echo.example/ws",
                headers: [],
                body: Data("hello".utf8)
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        let count = await manager.pausedRequestsCount()
        XCTAssertEqual(count, 1)

        await manager.resumeRequest(id: eventId, action: .continue)

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

    func testResumeRequest_PreservesResumedRequestModifications() async {
        let requestId = UUID().uuidString

        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com/original",
                method: .get,
                methodToken: "GET",
                headers: [TraceHTTPHeader(key: "X-Test", value: "1")],
                body: Data("original".utf8)
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.updatePausedRequest(
            id: requestId,
            modifications: PausedRequestModifications(
                url: "https://example.com/modified",
                methodToken: "PURGE",
                headers: [TraceHTTPHeader(key: "X-Test", value: "2")],
                body: Data("modified".utf8)
            )
        )
        await manager.resumeRequest(id: requestId, action: .continue)
        _ = await pauseTask.value

        let resumedRequest = await manager.consumeResumedRequest(id: requestId)
        XCTAssertEqual(resumedRequest?.effectiveUrl, "https://example.com/modified")
        XCTAssertEqual(resumedRequest?.effectiveMethodToken, "PURGE")
        XCTAssertEqual(resumedRequest?.effectiveHeaders, [TraceHTTPHeader(key: "X-Test", value: "2")])
        XCTAssertEqual(resumedRequest?.effectiveBody, Data("modified".utf8))
    }

    func testResumeRequest_CancelDoesNotPreserveEdits() async {
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

        await manager.updatePausedRequest(
            id: requestId,
            modifications: PausedRequestModifications(url: "https://example.com/changed")
        )
        await manager.resumeRequest(id: requestId, action: .cancel)
        _ = await pauseTask.value

        let resumedRequest = await manager.consumeResumedRequest(id: requestId)
        XCTAssertNil(resumedRequest)
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

    func testPauseRequest_ConsumesSharedResumeCommand() async throws {
        let requestId = UUID().uuidString

        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com/original",
                method: .get,
                methodToken: "GET",
                headers: [TraceHTTPHeader(key: "X-Test", value: "1")],
                body: Data("original".utf8)
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.updatePausedRequest(
            id: requestId,
            modifications: PausedRequestModifications(
                url: "https://example.com/updated",
                methodToken: "PURGE",
                headers: [TraceHTTPHeader(key: "X-Test", value: "2")],
                body: Data("patched".utf8)
            )
        )

        try AppGroupStorage.shared.saveBreakpointResumeCommand(
            BreakpointResumeCommand(requestId: requestId, action: .continue)
        )

        let action = await pauseTask.value
        XCTAssertEqual(action, .continue)

        let resumedRequest = await manager.consumeResumedRequest(id: requestId)
        XCTAssertEqual(resumedRequest?.effectiveUrl, "https://example.com/updated")
        XCTAssertEqual(resumedRequest?.effectiveMethodToken, "PURGE")
        XCTAssertEqual(resumedRequest?.effectiveHeaders, [TraceHTTPHeader(key: "X-Test", value: "2")])
        XCTAssertEqual(resumedRequest?.effectiveBody, Data("patched".utf8))
        XCTAssertThrowsError(try AppGroupStorage.shared.loadPausedBreakpointRequest(id: requestId))
    }

    func testResumeAllRequests_QueuesSharedCommandsForSharedPausedRequests() async throws {
        let requestId = UUID().uuidString
        let pausedRequest = PausedRequest(
            id: requestId,
            url: "https://example.com",
            method: .get,
            headers: [],
            breakpointType: .request
        )

        try AppGroupStorage.shared.savePausedBreakpointRequest(pausedRequest)

        await manager.resumeAllRequests(action: .continue)

        let command = try AppGroupStorage.shared.consumeBreakpointResumeCommand(requestId: requestId)
        XCTAssertEqual(command?.action, .continue)
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

    func testApplyStoredRequestModifications_AppliesURLMethodHeadersAndBody() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .request
        config.executionMode = .alwaysApply
        await manager.updateConfiguration(config)

        let requestId = UUID().uuidString
        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com/original",
                method: .get,
                methodToken: "GET",
                headers: [TraceHTTPHeader(key: "X-Test", value: "1")],
                body: Data("original".utf8)
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.updatePausedRequest(
            id: requestId,
            modifications: PausedRequestModifications(
                url: "https://example.com/updated",
                methodToken: "PURGE",
                headers: [TraceHTTPHeader(key: "X-Test", value: "2")],
                body: Data("patched".utf8)
            )
        )
        await manager.resumeRequest(id: requestId, action: .continue)
        _ = await pauseTask.value

        var request = NetworkRequest(
            url: "https://example.com/original",
            method: .get,
            duration: 0,
            requestHeaders: [TraceHTTPHeader(key: "X-Test", value: "1")],
            requestBody: .from(data: Data("original".utf8))
        )

        let applied = await manager.applyStoredRequestModifications(to: &request)
        XCTAssertTrue(applied)
        XCTAssertEqual(request.url, "https://example.com/updated")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.requestMethodRaw, "PURGE")
        XCTAssertEqual(request.requestHeaders, [TraceHTTPHeader(key: "X-Test", value: "2")])
        XCTAssertEqual(request.requestBody.getData(), Data("patched".utf8))
    }

    func testApplyStoredRequestModifications_DoesNotApplyToNonMatchingTraffic() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .request
        config.matchType = .exact
        config.matchPattern = "https://example.com/target"
        config.executionMode = .alwaysApply
        await manager.updateConfiguration(config)

        let requestId = UUID().uuidString
        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com/target",
                method: .get,
                headers: [],
                body: nil
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.updatePausedRequest(
            id: requestId,
            modifications: PausedRequestModifications(url: "https://example.com/patched")
        )
        await manager.resumeRequest(id: requestId, action: .continue)
        _ = await pauseTask.value

        var otherRequest = NetworkRequest(
            url: "https://example.com/other",
            method: .get,
            duration: 0
        )

        let applied = await manager.applyStoredRequestModifications(to: &otherRequest)
        XCTAssertFalse(applied)
        XCTAssertEqual(otherRequest.url, "https://example.com/other")
    }

    func testApplyStoredRequestModifications_EditOnceClearsAfterSingleReplay() async {
        var config = BreakpointConfiguration()
        config.enabled = true
        config.breakpointType = .request
        config.matchType = .exact
        config.matchPattern = "https://example.com/original"
        config.executionMode = .editOnce
        await manager.updateConfiguration(config)

        let requestId = UUID().uuidString
        let pauseTask = Task {
            await manager.pauseRequest(
                id: requestId,
                url: "https://example.com/original",
                method: .get,
                headers: [],
                body: nil
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        await manager.updatePausedRequest(
            id: requestId,
            modifications: PausedRequestModifications(url: "https://example.com/patched")
        )
        await manager.resumeRequest(id: requestId, action: .continue)
        _ = await pauseTask.value

        var firstReplay = NetworkRequest(
            url: "https://example.com/original",
            method: .get,
            duration: 0
        )
        let firstApplied = await manager.applyStoredRequestModifications(to: &firstReplay)
        XCTAssertTrue(firstApplied)
        XCTAssertEqual(firstReplay.url, "https://example.com/patched")

        var secondReplay = NetworkRequest(
            url: "https://example.com/original",
            method: .get,
            duration: 0
        )
        let secondApplied = await manager.applyStoredRequestModifications(to: &secondReplay)
        XCTAssertFalse(secondApplied)
        XCTAssertEqual(secondReplay.url, "https://example.com/original")

        let shouldBreakAgain = await manager.shouldBreakOnRequest(
            url: "https://example.com/original",
            method: .get,
            headers: [],
            body: nil
        )
        XCTAssertTrue(shouldBreakAgain)
    }

    private func clearSharedBreakpointState() throws {
        let storage = AppGroupStorage.shared
        let pausedRequests = try storage.loadAllPausedBreakpointRequests()
        for pausedRequest in pausedRequests {
            try storage.deletePausedBreakpointRequest(id: pausedRequest.id)
            try storage.deleteBreakpointResumeCommand(requestId: pausedRequest.id)
        }
    }
}
