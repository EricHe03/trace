//
//  ExecutionPhaseTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class ExecutionPhaseTests: XCTestCase {

    // MARK: - Raw Value Tests

    func testExecutionPhaseRawValues() {
        XCTAssertEqual(ExecutionPhase.block.rawValue, 1)
        XCTAssertEqual(ExecutionPhase.redirect.rawValue, 2)
        XCTAssertEqual(ExecutionPhase.mock.rawValue, 3)
        XCTAssertEqual(ExecutionPhase.breakpointRequest.rawValue, 4)
        XCTAssertEqual(ExecutionPhase.scriptRequest.rawValue, 5)
        XCTAssertEqual(ExecutionPhase.rewriteRequest.rawValue, 6)
        XCTAssertEqual(ExecutionPhase.sendRequest.rawValue, 7)
        XCTAssertEqual(ExecutionPhase.scriptResponse.rawValue, 8)
        XCTAssertEqual(ExecutionPhase.rewriteResponse.rawValue, 9)
        XCTAssertEqual(ExecutionPhase.breakpointResponse.rawValue, 10)
    }

    func testExecutionPhaseFromRawValue() {
        XCTAssertEqual(ExecutionPhase(rawValue: 1), .block)
        XCTAssertEqual(ExecutionPhase(rawValue: 2), .redirect)
        XCTAssertEqual(ExecutionPhase(rawValue: 3), .mock)
        XCTAssertEqual(ExecutionPhase(rawValue: 4), .breakpointRequest)
        XCTAssertEqual(ExecutionPhase(rawValue: 5), .scriptRequest)
        XCTAssertEqual(ExecutionPhase(rawValue: 6), .rewriteRequest)
        XCTAssertEqual(ExecutionPhase(rawValue: 7), .sendRequest)
        XCTAssertEqual(ExecutionPhase(rawValue: 8), .scriptResponse)
        XCTAssertEqual(ExecutionPhase(rawValue: 9), .rewriteResponse)
        XCTAssertEqual(ExecutionPhase(rawValue: 10), .breakpointResponse)
    }

    func testExecutionPhaseInvalidRawValue() {
        XCTAssertNil(ExecutionPhase(rawValue: 0))
        XCTAssertNil(ExecutionPhase(rawValue: 11))
        XCTAssertNil(ExecutionPhase(rawValue: 100))
        XCTAssertNil(ExecutionPhase(rawValue: -1))
    }

    // MARK: - Case Iterable Tests

    func testExecutionPhaseCaseIterable() {
        let allCases = ExecutionPhase.allCases
        XCTAssertEqual(allCases.count, 10)
    }

    func testExecutionPhaseCaseIterableContainsAllPhases() {
        let allCases = ExecutionPhase.allCases
        XCTAssertTrue(allCases.contains(.block))
        XCTAssertTrue(allCases.contains(.redirect))
        XCTAssertTrue(allCases.contains(.mock))
        XCTAssertTrue(allCases.contains(.breakpointRequest))
        XCTAssertTrue(allCases.contains(.scriptRequest))
        XCTAssertTrue(allCases.contains(.rewriteRequest))
        XCTAssertTrue(allCases.contains(.sendRequest))
        XCTAssertTrue(allCases.contains(.scriptResponse))
        XCTAssertTrue(allCases.contains(.rewriteResponse))
        XCTAssertTrue(allCases.contains(.breakpointResponse))
    }

    func testExecutionPhaseCaseIterableOrder() {
        let allCases = ExecutionPhase.allCases
        // Verify phases are in execution order
        XCTAssertEqual(allCases[0], .block)
        XCTAssertEqual(allCases[1], .redirect)
        XCTAssertEqual(allCases[2], .mock)
        XCTAssertEqual(allCases[3], .breakpointRequest)
        XCTAssertEqual(allCases[4], .scriptRequest)
        XCTAssertEqual(allCases[5], .rewriteRequest)
        XCTAssertEqual(allCases[6], .sendRequest)
        XCTAssertEqual(allCases[7], .scriptResponse)
        XCTAssertEqual(allCases[8], .rewriteResponse)
        XCTAssertEqual(allCases[9], .breakpointResponse)
    }

    // MARK: - Codable Tests

    func testExecutionPhaseCodable() throws {
        let phase = ExecutionPhase.scriptRequest

        let encoder = JSONEncoder()
        let data = try encoder.encode(phase)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ExecutionPhase.self, from: data)

        XCTAssertEqual(decoded, phase)
        XCTAssertEqual(decoded.rawValue, 5)
    }

    func testExecutionPhaseCodableRoundTrip() throws {
        let phases = ExecutionPhase.allCases

        for phase in phases {
            let data = try JSONEncoder().encode(phase)
            let decoded = try JSONDecoder().decode(ExecutionPhase.self, from: data)
            XCTAssertEqual(decoded, phase)
        }
    }

    func testExecutionPhaseCodableJSON() throws {
        let phase = ExecutionPhase.block

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(phase)

        let jsonString = String(data: data, encoding: .utf8)
        XCTAssertNotNil(jsonString)
        XCTAssertTrue(jsonString?.contains("1") ?? false)
    }

    func testExecutionPhaseCodableInArray() throws {
        let phases: [ExecutionPhase] = [.block, .redirect, .mock]

        let data = try JSONEncoder().encode(phases)
        let decoded = try JSONDecoder().decode([ExecutionPhase].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0], .block)
        XCTAssertEqual(decoded[1], .redirect)
        XCTAssertEqual(decoded[2], .mock)
    }

    func testExecutionPhaseCodableInDictionary() throws {
        let phaseDict: [String: ExecutionPhase] = [
            "first": .block,
            "second": .redirect,
            "third": .sendRequest
        ]

        let data = try JSONEncoder().encode(phaseDict)
        let decoded = try JSONDecoder().decode([String: ExecutionPhase].self, from: data)

        XCTAssertEqual(decoded["first"], .block)
        XCTAssertEqual(decoded["second"], .redirect)
        XCTAssertEqual(decoded["third"], .sendRequest)
    }

    // MARK: - Equatable Tests

    func testExecutionPhaseEquality() {
        XCTAssertEqual(ExecutionPhase.block, ExecutionPhase.block)
        XCTAssertEqual(ExecutionPhase.redirect, ExecutionPhase.redirect)
        XCTAssertEqual(ExecutionPhase.mock, ExecutionPhase.mock)
    }

    func testExecutionPhaseInequality() {
        XCTAssertNotEqual(ExecutionPhase.block, ExecutionPhase.redirect)
        XCTAssertNotEqual(ExecutionPhase.scriptRequest, ExecutionPhase.scriptResponse)
        XCTAssertNotEqual(ExecutionPhase.breakpointRequest, ExecutionPhase.breakpointResponse)
    }

    // MARK: - Comparable Tests (via raw value)

    func testExecutionPhaseComparison() {
        // Verify phases are ordered by their raw values
        XCTAssertLessThan(ExecutionPhase.block.rawValue, ExecutionPhase.redirect.rawValue)
        XCTAssertLessThan(ExecutionPhase.redirect.rawValue, ExecutionPhase.mock.rawValue)
        XCTAssertLessThan(ExecutionPhase.mock.rawValue, ExecutionPhase.breakpointRequest.rawValue)
        XCTAssertLessThan(ExecutionPhase.rewriteRequest.rawValue, ExecutionPhase.sendRequest.rawValue)
        XCTAssertLessThan(ExecutionPhase.sendRequest.rawValue, ExecutionPhase.scriptResponse.rawValue)
    }

    func testExecutionPhaseRequestBeforeResponse() {
        // Verify request phases come before response phases
        XCTAssertLessThan(ExecutionPhase.breakpointRequest.rawValue, ExecutionPhase.breakpointResponse.rawValue)
        XCTAssertLessThan(ExecutionPhase.scriptRequest.rawValue, ExecutionPhase.scriptResponse.rawValue)
        XCTAssertLessThan(ExecutionPhase.rewriteRequest.rawValue, ExecutionPhase.rewriteResponse.rawValue)
    }

    // MARK: - Hashable Tests

    func testExecutionPhaseHashable() {
        let set: Set<ExecutionPhase> = [.block, .redirect, .mock, .block]
        XCTAssertEqual(set.count, 3) // .block appears twice but should only be counted once
    }

    func testExecutionPhaseInSet() {
        var phaseSet = Set<ExecutionPhase>()
        phaseSet.insert(.block)
        phaseSet.insert(.redirect)
        phaseSet.insert(.block) // Duplicate

        XCTAssertEqual(phaseSet.count, 2)
        XCTAssertTrue(phaseSet.contains(.block))
        XCTAssertTrue(phaseSet.contains(.redirect))
        XCTAssertFalse(phaseSet.contains(.mock))
    }

    func testExecutionPhaseAsDictionaryKey() {
        var phaseDict: [ExecutionPhase: String] = [:]
        phaseDict[.block] = "Block phase"
        phaseDict[.redirect] = "Redirect phase"
        phaseDict[.mock] = "Mock phase"

        XCTAssertEqual(phaseDict.count, 3)
        XCTAssertEqual(phaseDict[.block], "Block phase")
        XCTAssertEqual(phaseDict[.redirect], "Redirect phase")
        XCTAssertEqual(phaseDict[.mock], "Mock phase")
    }

    // MARK: - Sendable Tests

    func testExecutionPhaseSendable() {
        let phase = ExecutionPhase.block

        let expectation = expectation(description: "Sendable phase")

        Task {
            let captured = phase
            XCTAssertEqual(captured.rawValue, 1)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    func testExecutionPhaseArraySendable() {
        let phases: [ExecutionPhase] = [.block, .redirect, .mock]

        let expectation = expectation(description: "Sendable phase array")

        Task {
            let captured = phases
            XCTAssertEqual(captured.count, 3)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Edge Cases

    func testExecutionPhaseExhaustiveSwitch() {
        // Verify all cases can be handled in a switch
        for phase in ExecutionPhase.allCases {
            let description: String
            switch phase {
            case .block:
                description = "Block"
            case .redirect:
                description = "Redirect"
            case .mock:
                description = "Mock"
            case .breakpointRequest:
                description = "Breakpoint Request"
            case .scriptRequest:
                description = "Script Request"
            case .rewriteRequest:
                description = "Rewrite Request"
            case .sendRequest:
                description = "Send Request"
            case .scriptResponse:
                description = "Script Response"
            case .rewriteResponse:
                description = "Rewrite Response"
            case .breakpointResponse:
                description = "Breakpoint Response"
            }
            XCTAssertFalse(description.isEmpty)
        }
    }

    func testExecutionPhaseUniqueRawValues() {
        let allCases = ExecutionPhase.allCases
        let rawValues = allCases.map { $0.rawValue }
        let uniqueRawValues = Set(rawValues)

        XCTAssertEqual(rawValues.count, uniqueRawValues.count, "All raw values should be unique")
    }

    func testExecutionPhaseSequentialRawValues() {
        // Verify raw values are sequential from 1 to 10
        let allCases = ExecutionPhase.allCases
        let sortedRawValues = allCases.map { $0.rawValue }.sorted()

        XCTAssertEqual(sortedRawValues, Array(1...10))
    }

    // MARK: - Pattern Matching Tests

    func testExecutionPhasePatternMatching() {
        let phase = ExecutionPhase.scriptRequest

        switch phase {
        case .scriptRequest:
            XCTAssertTrue(true) // Expected path
        default:
            XCTFail("Pattern matching failed")
        }
    }

    func testExecutionPhaseGroupMatching() {
        let requestPhases: Set<ExecutionPhase> = [
            .breakpointRequest, .scriptRequest, .rewriteRequest
        ]

        XCTAssertTrue(requestPhases.contains(.scriptRequest))
        XCTAssertFalse(requestPhases.contains(.scriptResponse))
    }

    // MARK: - Integration Tests

    func testExecutionPhaseInExecutionLogEntry() throws {
        let entry = ExecutionLogEntry(
            phase: .redirect,
            outcome: .applied
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ExecutionLogEntry.self, from: data)

        XCTAssertEqual(decoded.phase, .redirect)
    }

    func testExecutionPhaseWithAllOutcomes() throws {
        let outcomes: [ExecutionOutcome] = [.matched, .notMatched, .applied, .skipped, .error]

        for phase in ExecutionPhase.allCases {
            for outcome in outcomes {
                let entry = ExecutionLogEntry(phase: phase, outcome: outcome)
                XCTAssertEqual(entry.phase, phase)
                XCTAssertEqual(entry.outcome, outcome)
            }
        }
    }

    // MARK: - Performance Tests

    func testExecutionPhaseEncodingPerformance() throws {
        let phases = Array(repeating: ExecutionPhase.scriptRequest, count: 1000)

        measure {
            do {
                _ = try JSONEncoder().encode(phases)
            } catch {
                XCTFail("Encoding failed: \(error)")
            }
        }
    }

    func testExecutionPhaseDecodingPerformance() throws {
        let phases = Array(repeating: ExecutionPhase.scriptRequest, count: 1000)
        let data = try JSONEncoder().encode(phases)

        measure {
            do {
                _ = try JSONDecoder().decode([ExecutionPhase].self, from: data)
            } catch {
                XCTFail("Decoding failed: \(error)")
            }
        }
    }
}
