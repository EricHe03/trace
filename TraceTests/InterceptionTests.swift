//
//  InterceptionTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class InterceptionTests: XCTestCase {
    private struct TestInterceptor: InterceptionProviding {
        func interceptRequest(
            flowId _: UUID,
            url _: String,
            method _: String,
            headers _: [String: String],
            body _: Data?
        ) async -> InterceptionResult {
            .blocked
        }

        func interceptResponse(
            request: NetworkRequest,
            statusCode _: Int,
            statusMessage _: String,
            headers _: [TraceHTTPHeader],
            body _: Data?
        ) async -> NetworkRequest {
            request
        }
    }

    // MARK: - InterceptionResult Tests

    func testBlockedResult() {
        let result = InterceptionResult.blocked

        switch result {
        case .blocked:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected blocked result")
        }
    }

    func testFailedResult() {
        let result = InterceptionResult.failed(.timeout)

        switch result {
        case .failed(let failure):
            XCTAssertEqual(failure, .timeout)
        default:
            XCTFail("Expected failed result")
        }
    }

    func testMockedResult() {
        let request = NetworkRequest.sample
        let result = InterceptionResult.mocked(request)

        switch result {
        case .mocked(let mockedRequest):
            XCTAssertEqual(mockedRequest.id, request.id)
        default:
            XCTFail("Expected mocked result")
        }
    }

    func testModifiedResult() {
        let request = NetworkRequest.sample
        let result = InterceptionResult.modified(request)

        switch result {
        case .modified(let modifiedRequest):
            XCTAssertEqual(modifiedRequest.id, request.id)
        default:
            XCTFail("Expected modified result")
        }
    }

    // MARK: - RequestInterceptionFailure Tests

    func testInterceptionFailureRawValues() {
        XCTAssertEqual(RequestInterceptionFailure.timeout.rawValue, "timeout")
        XCTAssertEqual(RequestInterceptionFailure.connectionReset.rawValue, "connectionReset")
        XCTAssertEqual(RequestInterceptionFailure.dropConnection.rawValue, "dropConnection")
        XCTAssertEqual(RequestInterceptionFailure.packetLoss.rawValue, "packetLoss")
    }

    func testInterceptionFailureFromRawValue() {
        XCTAssertEqual(RequestInterceptionFailure(rawValue: "timeout"), .timeout)
        XCTAssertEqual(RequestInterceptionFailure(rawValue: "connectionReset"), .connectionReset)
        XCTAssertEqual(RequestInterceptionFailure(rawValue: "dropConnection"), .dropConnection)
        XCTAssertEqual(RequestInterceptionFailure(rawValue: "packetLoss"), .packetLoss)
    }

    func testInterceptionFailureAllCases() {
        let failures: [RequestInterceptionFailure] = [
            .timeout,
            .connectionReset,
            .dropConnection,
            .packetLoss
        ]

        XCTAssertEqual(failures.count, 4)
    }

    // MARK: - ResponsePipeline Tests

    func testBufferAndInterceptPipeline() {
        let pipeline = ResponsePipeline.bufferAndIntercept

        switch pipeline {
        case .bufferAndIntercept:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected bufferAndIntercept")
        }
    }

    func testStreamAndCapturePipeline() {
        let pipeline = ResponsePipeline.streamAndCapture

        switch pipeline {
        case .streamAndCapture:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected streamAndCapture")
        }
    }

    // MARK: - Pattern Matching Tests

    func testPatternMatchingOnBlockedResult() {
        let result = InterceptionResult.blocked

        if case .blocked = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("Pattern matching failed for blocked result")
        }
    }

    func testPatternMatchingOnFailedResult() {
        let result = InterceptionResult.failed(.connectionReset)

        if case .failed(let failure) = result {
            XCTAssertEqual(failure, .connectionReset)
        } else {
            XCTFail("Pattern matching failed for failed result")
        }
    }

    func testPatternMatchingOnMockedResult() {
        let request = NetworkRequest.sample
        let result = InterceptionResult.mocked(request)

        if case .mocked(let mockedRequest) = result {
            XCTAssertEqual(mockedRequest.id, request.id)
        } else {
            XCTFail("Pattern matching failed for mocked result")
        }
    }

    func testPatternMatchingOnModifiedResult() {
        let request = NetworkRequest.sample
        let result = InterceptionResult.modified(request)

        if case .modified(let modifiedRequest) = result {
            XCTAssertEqual(modifiedRequest.id, request.id)
        } else {
            XCTFail("Pattern matching failed for modified result")
        }
    }

    // MARK: - Sendable Conformance Tests

    func testInterceptionResultIsSendable() {
        // This is primarily a compile-time check
        // If the code compiles, the Sendable conformance is working
        let result: InterceptionResult = .blocked

        Task {
            let _ = result
        }

        XCTAssertTrue(true, "InterceptionResult is Sendable")
    }

    func testInterceptionFailureIsSendable() {
        // This is primarily a compile-time check
        let failure: RequestInterceptionFailure = .timeout

        Task {
            let _ = failure
        }

        XCTAssertTrue(true, "RequestInterceptionFailure is Sendable")
    }

    func testResponsePipelineIsSendable() {
        // This is primarily a compile-time check
        let pipeline: ResponsePipeline = .bufferAndIntercept

        Task {
            let _ = pipeline
        }

        XCTAssertTrue(true, "ResponsePipeline is Sendable")
    }

    // MARK: - Stream Interception Tests

    func testStreamInterceptionDecisionModify() {
        let mutation = StreamMutation(payload: .text("patched"))
        let decision = StreamInterceptionDecision.modify(mutation)

        switch decision {
        case .modify(let extracted):
            XCTAssertEqual(extracted.payload?.text, "patched")
        default:
            XCTFail("Expected modify decision")
        }
    }

    func testStreamInterceptionDecisionReplay() {
        let spec = StreamReplaySpec(sessionID: UUID(), eventIDs: [UUID()])
        let decision = StreamInterceptionDecision.replay(spec)

        switch decision {
        case .replay(let extracted):
            XCTAssertEqual(extracted.sessionID, spec.sessionID)
            XCTAssertEqual(extracted.eventIDs, spec.eventIDs)
        default:
            XCTFail("Expected replay decision")
        }
    }

    func testInterceptionProvidingDefaultStreamHooksForward() async {
        let interceptor = TestInterceptor()
        let session = StreamSession(
            protocolType: .sse,
            url: "https://example.com/events"
        )
        let event = StreamEvent(
            sessionID: session.id,
            sequence: 1,
            direction: .received,
            kind: .sseEvent,
            payload: .text("hello")
        )

        let openDecision = await interceptor.interceptStreamOpen(session: session)
        let eventDecision = await interceptor.interceptStreamEvent(session: session, event: event)
        let closeDecision = await interceptor.interceptStreamClose(session: session, reason: nil)

        XCTAssertEqual(openDecision, .forward)
        XCTAssertEqual(eventDecision, .forward)
        XCTAssertEqual(closeDecision, .forward)
    }

    // MARK: - Edge Cases Tests

    func testMultipleFailureTypes() {
        let failures: [RequestInterceptionFailure] = [
            .timeout,
            .connectionReset,
            .dropConnection,
            .packetLoss
        ]

        for failure in failures {
            let result = InterceptionResult.failed(failure)

            if case .failed(let extractedFailure) = result {
                XCTAssertEqual(extractedFailure, failure)
            } else {
                XCTFail("Failed to extract failure type: \(failure)")
            }
        }
    }

    func testResultWithDifferentRequests() {
        var request1 = NetworkRequest.sample
        request1.url = "https://example1.com"

        var request2 = NetworkRequest.sample
        request2.url = "https://example2.com"

        let result1 = InterceptionResult.mocked(request1)
        let result2 = InterceptionResult.modified(request2)

        if case .mocked(let mockedRequest) = result1 {
            XCTAssertEqual(mockedRequest.url, "https://example1.com")
        } else {
            XCTFail("Expected mocked result")
        }

        if case .modified(let modifiedRequest) = result2 {
            XCTAssertEqual(modifiedRequest.url, "https://example2.com")
        } else {
            XCTFail("Expected modified result")
        }
    }
}
