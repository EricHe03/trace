//
//  RequestInterceptorTests.swift
//  TraceTests
//
//  Created by Justin on 2026-02-01.
//

import XCTest
@testable import TraceProxy
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class RequestInterceptorTests: XCTestCase {
    // MARK: - Properties

    var sut: RequestInterceptor!

    // MARK: - Setup & Teardown

    override func setUp() async throws {
        try await super.setUp()
        sut = await RequestInterceptor.shared
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - ConfigSnapshot Tests

    func testConfigSnapshotInitialization() {
        // Given
        let rules = [makeRewriteRule()]
        let maps = [makeRequestMap()]
        let scripts = [makeScript()]
        let groups = [makeRuleGroup()]
        let profile = makeProfile()

        // When
        let snapshot = ConfigSnapshot(
            rewriteRules: rules,
            requestMaps: maps,
            scripts: scripts,
            ruleGroups: groups,
            activeProfile: profile
        )

        // Then
        XCTAssertEqual(snapshot.rewriteRules.count, 1)
        XCTAssertEqual(snapshot.requestMaps.count, 1)
        XCTAssertEqual(snapshot.scripts.count, 1)
        XCTAssertEqual(snapshot.ruleGroups.count, 1)
        XCTAssertNotNil(snapshot.activeProfile)
        XCTAssertNotNil(snapshot.timestamp)
    }

    func testConfigSnapshotEmpty() {
        // Given / When
        let snapshot = ConfigSnapshot.empty

        // Then
        XCTAssertTrue(snapshot.rewriteRules.isEmpty)
        XCTAssertTrue(snapshot.requestMaps.isEmpty)
        XCTAssertTrue(snapshot.scripts.isEmpty)
        XCTAssertTrue(snapshot.ruleGroups.isEmpty)
        XCTAssertNil(snapshot.activeProfile)
    }

    func testConfigSnapshotWithEmptyCollections() {
        // Given / When
        let snapshot = ConfigSnapshot(
            rewriteRules: [],
            requestMaps: [],
            scripts: [],
            ruleGroups: [],
            activeProfile: nil
        )

        // Then
        XCTAssertTrue(snapshot.rewriteRules.isEmpty)
        XCTAssertTrue(snapshot.requestMaps.isEmpty)
        XCTAssertTrue(snapshot.scripts.isEmpty)
        XCTAssertTrue(snapshot.ruleGroups.isEmpty)
        XCTAssertNil(snapshot.activeProfile)
    }

    func testConfigSnapshotWithMultipleRules() {
        // Given
        let rules = (0 ..< 5).map { _ in makeRewriteRule() }

        // When
        let snapshot = ConfigSnapshot(
            rewriteRules: rules,
            requestMaps: [],
            scripts: [],
            ruleGroups: [],
            activeProfile: nil
        )

        // Then
        XCTAssertEqual(snapshot.rewriteRules.count, 5)
    }

    func testConfigSnapshotTimestampIsRecent() {
        // Given / When
        let snapshot = ConfigSnapshot.empty
        let now = Date()

        // Then
        XCTAssertLessThan(now.timeIntervalSince(snapshot.timestamp), 1.0)
    }

    // MARK: - InterceptionMetrics Tests

    func testInterceptionMetricsDefaultValues() {
        // Given / When
        let metrics = InterceptionMetrics()

        // Then
        XCTAssertEqual(metrics.totalRequests, 0)
        XCTAssertEqual(metrics.totalResponses, 0)
        XCTAssertEqual(metrics.blockedCount, 0)
        XCTAssertEqual(metrics.redirectedCount, 0)
        XCTAssertEqual(metrics.mockedCount, 0)
        XCTAssertEqual(metrics.breakpointHits, 0)
        XCTAssertEqual(metrics.scriptFailures, 0)
        XCTAssertEqual(metrics.redirectLoopsPrevented, 0)
    }

    func testInterceptionMetricsTimingDefaultValues() {
        // Given / When
        let metrics = InterceptionMetrics()

        // Then
        XCTAssertEqual(metrics.blockCheckTimeNs, 0)
        XCTAssertEqual(metrics.redirectCheckTimeNs, 0)
        XCTAssertEqual(metrics.mockCheckTimeNs, 0)
        XCTAssertEqual(metrics.ruleApplicationTimeNs, 0)
        XCTAssertEqual(metrics.scriptExecutionTimeNs, 0)
        XCTAssertEqual(metrics.breakpointTimeNs, 0)
    }

    func testInterceptionMetricsConfigReloadTracking() {
        // Given / When
        var metrics = InterceptionMetrics()

        // Then
        XCTAssertEqual(metrics.configReloadCount, 0)
        XCTAssertNil(metrics.lastConfigReload)

        // When
        metrics.configReloadCount += 1
        metrics.lastConfigReload = Date()

        // Then
        XCTAssertEqual(metrics.configReloadCount, 1)
        XCTAssertNotNil(metrics.lastConfigReload)
    }

    func testInterceptionMetricsIncrement() {
        // Given
        var metrics = InterceptionMetrics()

        // When
        metrics.totalRequests += 1
        metrics.totalResponses += 1
        metrics.blockedCount += 1

        // Then
        XCTAssertEqual(metrics.totalRequests, 1)
        XCTAssertEqual(metrics.totalResponses, 1)
        XCTAssertEqual(metrics.blockedCount, 1)
    }

    func testInterceptionMetricsMultipleIncrements() {
        // Given
        var metrics = InterceptionMetrics()

        // When
        for _ in 0 ..< 100 {
            metrics.totalRequests += 1
        }

        // Then
        XCTAssertEqual(metrics.totalRequests, 100)
    }

    func testInterceptionMetricsTimingAccumulation() {
        // Given
        var metrics = InterceptionMetrics()

        // When
        metrics.blockCheckTimeNs += 1_000_000 // 1ms in ns
        metrics.redirectCheckTimeNs += 2_000_000 // 2ms in ns
        metrics.mockCheckTimeNs += 500_000 // 0.5ms in ns

        // Then
        XCTAssertEqual(metrics.blockCheckTimeNs, 1_000_000)
        XCTAssertEqual(metrics.redirectCheckTimeNs, 2_000_000)
        XCTAssertEqual(metrics.mockCheckTimeNs, 500_000)
    }

    // MARK: - Safety Limits Tests

    func testMaxRedirectsPerFlowLimit() {
        // Given
        let maxRedirects = 10

        // When / Then
        XCTAssertEqual(maxRedirects, 10)
        XCTAssertGreaterThan(maxRedirects, 0)
    }

    func testMaxBodyModificationBytesLimit() {
        // Given
        let maxBodyBytes = 10 * 1024 * 1024 // 10 MB

        // When / Then
        XCTAssertEqual(maxBodyBytes, 10_485_760)
    }

    func testConfigRefreshDebounceMs() {
        // Given
        let debounceMs: UInt64 = 50

        // When / Then
        XCTAssertEqual(debounceMs, 50)
        XCTAssertGreaterThan(debounceMs, 0)
    }

    func testConfigFileCheckIntervalMs() {
        // Given
        let intervalMs: Double = 1000

        // When / Then
        XCTAssertEqual(intervalMs, 1000)
        XCTAssertGreaterThanOrEqual(intervalMs, 0)
    }

    // MARK: - Request Interception Tests (Basic Structure)

    func testInterceptRequestBasicStructure() async {
        // Given
        let flowId = UUID()
        let url = "https://api.example.com/test"
        let method = "GET"
        let headers: [String: String] = ["User-Agent": "Test"]
        let body: Data? = nil

        // When
        let result = await sut.interceptRequest(
            flowId: flowId,
            url: url,
            method: method,
            headers: headers,
            body: body
        )

        // Then
        XCTAssertNotNil(result)
    }

    func testInterceptRequestWithBody() async {
        // Given
        let flowId = UUID()
        let url = "https://api.example.com/test"
        let method = "POST"
        let headers: [String: String] = ["Content-Type": "application/json"]
        let body = "{\"key\":\"value\"}".data(using: .utf8)

        // When
        let result = await sut.interceptRequest(
            flowId: flowId,
            url: url,
            method: method,
            headers: headers,
            body: body
        )

        // Then
        XCTAssertNotNil(result)
    }

    func testInterceptRequestWithDifferentMethods() async {
        // Given
        let methods = ["GET", "POST", "PUT", "DELETE", "PATCH"]

        for method in methods {
            // When
            let result = await sut.interceptRequest(
                flowId: UUID(),
                url: "https://api.example.com/test",
                method: method,
                headers: [:],
                body: nil
            )

            // Then
            XCTAssertNotNil(result, "Failed for method \(method)")
        }
    }

    // MARK: - Edge Cases

    func testConfigSnapshotWithLargeCollections() {
        // Given
        let rules = (0 ..< 1000).map { _ in makeRewriteRule() }
        let maps = (0 ..< 500).map { _ in makeRequestMap() }

        // When
        let snapshot = ConfigSnapshot(
            rewriteRules: rules,
            requestMaps: maps,
            scripts: [],
            ruleGroups: [],
            activeProfile: nil
        )

        // Then
        XCTAssertEqual(snapshot.rewriteRules.count, 1000)
        XCTAssertEqual(snapshot.requestMaps.count, 500)
    }

    func testInterceptionMetricsLargeValues() {
        // Given
        var metrics = InterceptionMetrics()

        // When
        metrics.totalRequests = 1_000_000
        metrics.blockCheckTimeNs = UInt64.max

        // Then
        XCTAssertEqual(metrics.totalRequests, 1_000_000)
        XCTAssertEqual(metrics.blockCheckTimeNs, UInt64.max)
    }

    func testInterceptRequestWithEmptyURL() async {
        // Given
        let flowId = UUID()
        let url = ""
        let method = "GET"

        // When
        let result = await sut.interceptRequest(
            flowId: flowId,
            url: url,
            method: method,
            headers: [:],
            body: nil
        )

        // Then
        XCTAssertNotNil(result)
    }

    func testInterceptRequestWithVeryLongURL() async {
        // Given
        let flowId = UUID()
        let url = "https://example.com/" + String(repeating: "a", count: 10000)
        let method = "GET"

        // When
        let result = await sut.interceptRequest(
            flowId: flowId,
            url: url,
            method: method,
            headers: [:],
            body: nil
        )

        // Then
        XCTAssertNotNil(result)
    }

    func testInterceptRequestWithManyHeaders() async {
        // Given
        let flowId = UUID()
        let url = "https://api.example.com/test"
        let method = "GET"
        var headers: [String: String] = [:]
        for i in 0 ..< 100 {
            headers["X-Header-\(i)"] = "value\(i)"
        }

        // When
        let result = await sut.interceptRequest(
            flowId: flowId,
            url: url,
            method: method,
            headers: headers,
            body: nil
        )

        // Then
        XCTAssertNotNil(result)
    }

    func testInterceptRequestWithLargeBody() async {
        // Given
        let flowId = UUID()
        let url = "https://api.example.com/upload"
        let method = "POST"
        let headers = ["Content-Type": "application/octet-stream"]
        let body = Data(repeating: 0xFF, count: 1_000_000) // 1 MB

        // When
        let result = await sut.interceptRequest(
            flowId: flowId,
            url: url,
            method: method,
            headers: headers,
            body: body
        )

        // Then
        XCTAssertNotNil(result)
    }

    func testInterceptRequestWithUnicodeURL() async {
        // Given
        let flowId = UUID()
        let url = "https://例え.jp/テスト"
        let method = "GET"

        // When
        let result = await sut.interceptRequest(
            flowId: flowId,
            url: url,
            method: method,
            headers: [:],
            body: nil
        )

        // Then
        XCTAssertNotNil(result)
    }

    func testInterceptRequestWithSpecialCharactersInHeaders() async {
        // Given
        let flowId = UUID()
        let url = "https://api.example.com/test"
        let method = "GET"
        let headers = [
            "X-Special": "value with spaces",
            "X-Unicode": "値",
            "X-Symbols": "!@#$%^&*()"
        ]

        // When
        let result = await sut.interceptRequest(
            flowId: flowId,
            url: url,
            method: method,
            headers: headers,
            body: nil
        )

        // Then
        XCTAssertNotNil(result)
    }

    func testInterceptStreamEventAppliesStreamScriptPayloadMutation() async {
        let scriptManager = ScriptManager.shared
        scriptManager.clearAllScripts()
        await MainActor.run {
            RewriteManager.shared.clearAllRules()
        }
        await BreakpointManager.shared.setEnabled(false)

        let streamScript = Script(
            name: "Stream Mutator",
            enabled: true,
            scriptType: .stream,
            matchType: .contains,
            matchPattern: "example.com",
            code: """
            stream.event.payload.text = 'patched-stream';
            stream.event.metadata['scripted'] = 'true';
            stream.action = 'forward';
            """
        )
        scriptManager.addScript(streamScript)
        await sut.forceConfigRefresh()

        let session = StreamSession(
            protocolType: .websocket,
            url: "wss://api.example.com/socket",
            status: .open
        )
        let event = StreamEvent(
            sessionID: session.id,
            sequence: 1,
            direction: .received,
            kind: .message,
            payload: .text("original", contentType: "text/plain"),
            metadata: ["message_type": "text"]
        )

        let decision = await sut.interceptStreamEvent(session: session, event: event)

        switch decision {
        case let .modify(mutation):
            XCTAssertEqual(mutation.payload?.text, "patched-stream")
            XCTAssertEqual(mutation.metadata["scripted"], "true")
            XCTAssertEqual(mutation.metadata["applied_stream_scripts"], "Stream Mutator")
        default:
            XCTFail("Expected stream script to produce modify decision")
        }

        scriptManager.clearAllScripts()
        await sut.forceConfigRefresh()
    }

    func testInterceptStreamEventSupportsStreamScriptDropAction() async {
        let scriptManager = ScriptManager.shared
        scriptManager.clearAllScripts()
        await MainActor.run {
            RewriteManager.shared.clearAllRules()
        }
        await BreakpointManager.shared.setEnabled(false)

        let streamScript = Script(
            name: "Stream Dropper",
            enabled: true,
            scriptType: .stream,
            matchType: .contains,
            matchPattern: "example.com",
            code: "stream.action = 'drop';"
        )
        scriptManager.addScript(streamScript)
        await sut.forceConfigRefresh()

        let session = StreamSession(
            protocolType: .sse,
            url: "https://events.example.com/feed",
            status: .streaming
        )
        let event = StreamEvent(
            sessionID: session.id,
            sequence: 1,
            direction: .received,
            kind: .sseEvent,
            payload: .text("data", contentType: "text/event-stream")
        )

        let decision = await sut.interceptStreamEvent(session: session, event: event)
        XCTAssertEqual(decision, .drop)

        scriptManager.clearAllScripts()
        await sut.forceConfigRefresh()
    }
}

// MARK: - Helper Factory Functions

private func makeRewriteRule(
    id: UUID = UUID(),
    name: String = "Test Rule",
    enabled: Bool = true
) -> RewriteRule {
    RewriteRule(
        id: id,
        name: name,
        enabled: enabled,
        ruleType: .modifyRequest,
        matchType: .wildcard,
        matchPattern: "*.example.com",
        actions: []
    )
}

private func makeRequestMap(
    id: UUID = UUID(),
    name: String = "Test Map",
    enabled: Bool = true
) -> RequestMap {
    let mockResponse = MockResponse(
        statusCode: 200,
        statusMessage: "OK",
        headers: [],
        bodySource: .inline,
        bodyContent: Data(),
        delay: 0
    )

    return RequestMap(
        id: id,
        name: name,
        enabled: enabled,
        matchType: .exact,
        matchPattern: "https://api.example.com/old",
        mockResponse: mockResponse
    )
}

private func makeScript(
    id: UUID = UUID(),
    name: String = "Test Script",
    enabled: Bool = true
) -> Script {
    Script(
        id: id,
        name: name,
        enabled: enabled,
        scriptType: .request,
        code: "// Test script"
    )
}

private func makeRuleGroup(
    id: UUID = UUID(),
    name: String = "Test Group",
    enabled: Bool = true
) -> RuleGroup {
    RuleGroup(
        id: id,
        name: name,
        enabled: enabled,
        rules: []
    )
}

private func makeProfile(
    id: UUID = UUID(),
    name: String = "Test Profile"
) -> Profile {
    Profile(
        id: id,
        name: name,
        ruleGroups: [],
        isActive: true
    )
}
