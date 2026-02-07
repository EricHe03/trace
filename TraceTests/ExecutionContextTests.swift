//
//  ExecutionContextTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class ExecutionContextTests: XCTestCase {

    // MARK: - ExecutionContext Initializer Tests

    func testExecutionContextInit() {
        let request = createMockNetworkRequest()
        let context = ExecutionContext(request: request)

        XCTAssertEqual(context.requestId, request.id)
        XCTAssertEqual(context.originalRequest.id, request.id)
        XCTAssertEqual(context.currentRequest.id, request.id)
        XCTAssertTrue(context.executionLog.isEmpty)
        XCTAssertTrue(context.appliedRules.isEmpty)
        XCTAssertTrue(context.timings.isEmpty)
        XCTAssertTrue(context.errors.isEmpty)
    }

    func testExecutionContextPreservesOriginalRequest() {
        let originalRequest = createMockNetworkRequest()
        var context = ExecutionContext(request: originalRequest)

        // Modify current request
        context.currentRequest.url = "https://modified.example.com"

        XCTAssertEqual(context.originalRequest.url, "https://example.com/api")
        XCTAssertEqual(context.currentRequest.url, "https://modified.example.com")
    }

    func testExecutionContextMutableProperties() {
        let request = createMockNetworkRequest()
        var context = ExecutionContext(request: request)

        context.executionLog.append(createMockLogEntry())
        context.appliedRules.append(UUID())
        context.timings["rule1"] = 0.5
        context.errors.append(ExecutionError(message: "Test error"))

        XCTAssertEqual(context.executionLog.count, 1)
        XCTAssertEqual(context.appliedRules.count, 1)
        XCTAssertEqual(context.timings.count, 1)
        XCTAssertEqual(context.errors.count, 1)
    }

    // MARK: - ExecutionLogEntry Tests

    func testExecutionLogEntryInitWithDefaults() {
        let entry = ExecutionLogEntry(
            phase: .block,
            outcome: .matched
        )

        XCTAssertNotNil(entry.timestamp)
        XCTAssertEqual(entry.phase, .block)
        XCTAssertNil(entry.ruleId)
        XCTAssertNil(entry.ruleName)
        XCTAssertEqual(entry.outcome, .matched)
        XCTAssertNil(entry.message)
        XCTAssertEqual(entry.duration, 0)
        XCTAssertNil(entry.diffSummary)
    }

    func testExecutionLogEntryInitWithAllParameters() {
        let timestamp = Date()
        let ruleId = UUID()
        let entry = ExecutionLogEntry(
            timestamp: timestamp,
            phase: .redirect,
            ruleId: ruleId,
            ruleName: "Test Rule",
            outcome: .applied,
            message: "Rule applied successfully",
            duration: 0.25,
            diffSummary: "URL changed"
        )

        XCTAssertEqual(entry.timestamp, timestamp)
        XCTAssertEqual(entry.phase, .redirect)
        XCTAssertEqual(entry.ruleId, ruleId)
        XCTAssertEqual(entry.ruleName, "Test Rule")
        XCTAssertEqual(entry.outcome, .applied)
        XCTAssertEqual(entry.message, "Rule applied successfully")
        XCTAssertEqual(entry.duration, 0.25)
        XCTAssertEqual(entry.diffSummary, "URL changed")
    }

    func testExecutionLogEntryCodableRoundTrip() throws {
        let entry = ExecutionLogEntry(
            timestamp: Date(),
            phase: .scriptRequest,
            ruleId: UUID(),
            ruleName: "Script Test",
            outcome: .applied,
            message: "Script executed",
            duration: 1.5,
            diffSummary: "Headers modified"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ExecutionLogEntry.self, from: data)

        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, decoded.timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(entry.phase, decoded.phase)
        XCTAssertEqual(entry.ruleId, decoded.ruleId)
        XCTAssertEqual(entry.ruleName, decoded.ruleName)
        XCTAssertEqual(entry.outcome, decoded.outcome)
        XCTAssertEqual(entry.message, decoded.message)
        XCTAssertEqual(entry.duration, decoded.duration)
        XCTAssertEqual(entry.diffSummary, decoded.diffSummary)
    }

    func testExecutionLogEntryWithNilOptionals() throws {
        let entry = ExecutionLogEntry(
            phase: .mock,
            outcome: .skipped
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ExecutionLogEntry.self, from: data)

        XCTAssertNil(decoded.ruleId)
        XCTAssertNil(decoded.ruleName)
        XCTAssertNil(decoded.message)
        XCTAssertNil(decoded.diffSummary)
        XCTAssertEqual(decoded.duration, 0)
    }

    func testExecutionLogEntryWithAllPhases() throws {
        let phases: [ExecutionPhase] = [
            .block, .redirect, .mock, .breakpointRequest, .scriptRequest,
            .rewriteRequest, .sendRequest, .scriptResponse, .rewriteResponse, .breakpointResponse
        ]

        for phase in phases {
            let entry = ExecutionLogEntry(phase: phase, outcome: .applied)
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(ExecutionLogEntry.self, from: data)
            XCTAssertEqual(decoded.phase, phase)
        }
    }

    func testExecutionLogEntryWithAllOutcomes() throws {
        let outcomes: [ExecutionOutcome] = [.matched, .notMatched, .applied, .skipped, .error]

        for outcome in outcomes {
            let entry = ExecutionLogEntry(phase: .block, outcome: outcome)
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(ExecutionLogEntry.self, from: data)
            XCTAssertEqual(decoded.outcome, outcome)
        }
    }

    // MARK: - ExecutionOutcome Tests

    func testExecutionOutcomeRawValues() {
        XCTAssertEqual(ExecutionOutcome.matched.rawValue, "matched")
        XCTAssertEqual(ExecutionOutcome.notMatched.rawValue, "notMatched")
        XCTAssertEqual(ExecutionOutcome.applied.rawValue, "applied")
        XCTAssertEqual(ExecutionOutcome.skipped.rawValue, "skipped")
        XCTAssertEqual(ExecutionOutcome.error.rawValue, "error")
    }

    func testExecutionOutcomeCodable() throws {
        let outcomes: [ExecutionOutcome] = [.matched, .notMatched, .applied, .skipped, .error]

        for outcome in outcomes {
            let data = try JSONEncoder().encode(outcome)
            let decoded = try JSONDecoder().decode(ExecutionOutcome.self, from: data)
            XCTAssertEqual(decoded, outcome)
        }
    }

    // MARK: - ExecutionError Tests

    func testExecutionErrorInit() {
        let error = ExecutionError(message: "Test error")

        XCTAssertNil(error.ruleId)
        XCTAssertEqual(error.message, "Test error")
    }

    func testExecutionErrorInitWithRuleId() {
        let ruleId = UUID()
        let error = ExecutionError(ruleId: ruleId, message: "Rule failed")

        XCTAssertEqual(error.ruleId, ruleId)
        XCTAssertEqual(error.message, "Rule failed")
    }

    func testExecutionErrorCodableRoundTrip() throws {
        let error = ExecutionError(ruleId: UUID(), message: "Execution failed")

        let encoder = JSONEncoder()
        let data = try encoder.encode(error)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ExecutionError.self, from: data)

        XCTAssertEqual(error.ruleId, decoded.ruleId)
        XCTAssertEqual(error.message, decoded.message)
    }

    func testExecutionErrorWithNilRuleId() throws {
        let error = ExecutionError(ruleId: nil, message: "General error")

        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(ExecutionError.self, from: data)

        XCTAssertNil(decoded.ruleId)
        XCTAssertEqual(decoded.message, "General error")
    }

    func testExecutionErrorWithEmptyMessage() {
        let error = ExecutionError(message: "")

        XCTAssertTrue(error.message.isEmpty)
    }

    func testExecutionErrorWithLongMessage() {
        let longMessage = String(repeating: "A", count: 1000)
        let error = ExecutionError(message: longMessage)

        XCTAssertEqual(error.message.count, 1000)
    }

    // MARK: - Edge Cases

    func testExecutionContextWithMultipleLogEntries() {
        let request = createMockNetworkRequest()
        var context = ExecutionContext(request: request)

        for i in 0..<10 {
            let entry = ExecutionLogEntry(
                phase: .block,
                outcome: .applied,
                message: "Entry \(i)"
            )
            context.executionLog.append(entry)
        }

        XCTAssertEqual(context.executionLog.count, 10)
    }

    func testExecutionContextWithMultipleRules() {
        let request = createMockNetworkRequest()
        var context = ExecutionContext(request: request)

        for _ in 0..<5 {
            context.appliedRules.append(UUID())
        }

        XCTAssertEqual(context.appliedRules.count, 5)
        // Ensure all UUIDs are unique
        let uniqueRules = Set(context.appliedRules)
        XCTAssertEqual(uniqueRules.count, 5)
    }

    func testExecutionContextWithMultipleTimings() {
        let request = createMockNetworkRequest()
        var context = ExecutionContext(request: request)

        context.timings["rule1"] = 0.5
        context.timings["rule2"] = 1.2
        context.timings["rule3"] = 0.3

        XCTAssertEqual(context.timings.count, 3)
        XCTAssertEqual(context.timings["rule1"], 0.5)
        XCTAssertEqual(context.timings["rule2"], 1.2)
        XCTAssertEqual(context.timings["rule3"], 0.3)
    }

    func testExecutionContextWithMultipleErrors() {
        let request = createMockNetworkRequest()
        var context = ExecutionContext(request: request)

        context.errors.append(ExecutionError(message: "Error 1"))
        context.errors.append(ExecutionError(ruleId: UUID(), message: "Error 2"))
        context.errors.append(ExecutionError(message: "Error 3"))

        XCTAssertEqual(context.errors.count, 3)
    }

    func testExecutionLogEntryWithVeryLongDuration() {
        let entry = ExecutionLogEntry(
            phase: .sendRequest,
            outcome: .applied,
            duration: 999999.999
        )

        XCTAssertEqual(entry.duration, 999999.999)
    }

    func testExecutionLogEntryWithZeroDuration() {
        let entry = ExecutionLogEntry(
            phase: .block,
            outcome: .applied,
            duration: 0
        )

        XCTAssertEqual(entry.duration, 0)
    }

    func testExecutionLogEntryWithNegativeDuration() {
        let entry = ExecutionLogEntry(
            phase: .block,
            outcome: .applied,
            duration: -1.0
        )

        XCTAssertEqual(entry.duration, -1.0)
    }

    func testExecutionErrorWithSpecialCharacters() throws {
        let error = ExecutionError(message: "Error: @#$%^&* 🔥")

        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(ExecutionError.self, from: data)

        XCTAssertEqual(decoded.message, "Error: @#$%^&* 🔥")
    }

    func testExecutionLogEntryWithSpecialCharacters() throws {
        let entry = ExecutionLogEntry(
            phase: .scriptRequest,
            ruleName: "测试规则 🎯",
            outcome: .applied,
            message: "Success! ✅",
            diffSummary: "Changed 变化"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ExecutionLogEntry.self, from: data)

        XCTAssertEqual(decoded.ruleName, "测试规则 🎯")
        XCTAssertEqual(decoded.message, "Success! ✅")
        XCTAssertEqual(decoded.diffSummary, "Changed 变化")
    }

    // MARK: - Sendable Tests

    func testExecutionContextSendable() {
        let request = createMockNetworkRequest()
        let context = ExecutionContext(request: request)

        let expectation = expectation(description: "Sendable context")

        Task {
            let captured = context
            XCTAssertEqual(captured.requestId, request.id)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testExecutionLogEntrySendable() {
        let entry = ExecutionLogEntry(phase: .block, outcome: .applied)

        let expectation = expectation(description: "Sendable log entry")

        Task {
            let captured = entry
            XCTAssertEqual(captured.phase, .block)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testExecutionErrorSendable() {
        let error = ExecutionError(message: "Test")

        let expectation = expectation(description: "Sendable error")

        Task {
            let captured = error
            XCTAssertEqual(captured.message, "Test")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Integration Tests

    func testExecutionContextCompleteWorkflow() {
        let request = createMockNetworkRequest()
        var context = ExecutionContext(request: request)

        // Add log entry
        let ruleId = UUID()
        let logEntry = ExecutionLogEntry(
            phase: .redirect,
            ruleId: ruleId,
            ruleName: "Redirect Rule",
            outcome: .applied,
            message: "Redirected to new URL",
            duration: 0.15,
            diffSummary: "URL: old -> new"
        )
        context.executionLog.append(logEntry)

        // Add applied rule
        context.appliedRules.append(ruleId)

        // Add timing
        context.timings[ruleId.uuidString] = 0.15

        // Modify current request
        context.currentRequest.url = "https://redirected.example.com"

        // Verify state
        XCTAssertEqual(context.executionLog.count, 1)
        XCTAssertEqual(context.appliedRules.count, 1)
        XCTAssertEqual(context.timings.count, 1)
        XCTAssertEqual(context.currentRequest.url, "https://redirected.example.com")
        XCTAssertEqual(context.originalRequest.url, "https://example.com/api")
    }

    // MARK: - Helper Methods

    private func createMockNetworkRequest() -> NetworkRequest {
        NetworkRequest(
            url: "https://example.com/api",
            method: .get,
            duration: 0.5
        )
    }

    private func createMockLogEntry() -> ExecutionLogEntry {
        ExecutionLogEntry(
            phase: .block,
            outcome: .matched
        )
    }
}
