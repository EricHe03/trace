//
//  NetworkViewActionsTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/08.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class NetworkViewActionsTests: XCTestCase {

    func testSuccessfulRequestsFiltersFailedTransfersEvenWhenRequestExists() {
        let successRequest = makeRequest(url: "https://one.example", statusCode: 200)
        let failedRequest = makeRequest(url: "https://two.example", statusCode: 0)

        let successfulTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "https://one.example"),
            request: successRequest
        )
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 1, url: "https://two.example"),
            request: failedRequest,
            errorMessage: "curl exited with code 35"
        )

        let result = makeExecutionResult(transfers: [successfulTransfer, failedTransfer])
        let successful = NetworkViewActions.successfulRequests(from: result)

        XCTAssertEqual(successful.count, 1)
        XCTAssertEqual(successful.first?.id, successRequest.id)
    }

    func testIsLikelyPermissionIssueWhenErrorMentionsPermissionDeniedOnLocalNetwork() {
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "http://192.168.1.88:8080"),
            request: nil,
            errorMessage: "Operation not permitted"
        )

        let result = makeExecutionResult(transfers: [failedTransfer])

        XCTAssertTrue(NetworkViewActions.isLikelyPermissionIssue(in: result))
    }

    func testIsLikelyPermissionIssueWhenErrorMentionsPermissionDeniedOnPublicHost() {
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "https://api.example.com"),
            request: nil,
            errorMessage: "Operation not permitted"
        )

        let result = makeExecutionResult(transfers: [failedTransfer])

        XCTAssertFalse(NetworkViewActions.isLikelyPermissionIssue(in: result))
    }

    func testIsLikelyPermissionIssueWhenOfflineErrorTargetsLocalNetwork() {
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "http://192.168.1.88:8080"),
            request: nil,
            errorMessage: "The Internet connection appears to be offline."
        )

        let result = makeExecutionResult(transfers: [failedTransfer])

        XCTAssertTrue(NetworkViewActions.isLikelyPermissionIssue(in: result))
        XCTAssertEqual(
            NetworkViewActions.permissionRequiredMessage,
            "Network access is required to import this cURL command. Allow access in the system prompt, or enable it later in Settings."
        )
    }

    func testIsLikelyPermissionIssueWhenOfflineErrorTargetsPublicHost() {
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "https://api.example.com"),
            request: nil,
            errorMessage: "The Internet connection appears to be offline."
        )

        let result = makeExecutionResult(transfers: [failedTransfer])

        XCTAssertFalse(NetworkViewActions.isLikelyPermissionIssue(in: result))
    }

    func testShouldRetryAfterPermissionPromptWhenNoTransfersSucceeded() {
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "http://192.168.1.88:8080"),
            request: nil,
            errorMessage: "The Internet connection appears to be offline."
        )

        let result = makeExecutionResult(transfers: [failedTransfer])

        XCTAssertTrue(NetworkViewActions.shouldRetryAfterPermissionPrompt(in: result))
    }

    func testShouldRetryAfterPermissionPromptWhenSomeTransfersSucceeded() {
        let successfulTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "http://192.168.1.88:8080"),
            request: makeRequest(url: "http://192.168.1.88:8080", statusCode: 200)
        )
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 1, url: "http://192.168.1.88:8081"),
            request: nil,
            errorMessage: "The Internet connection appears to be offline."
        )

        let result = makeExecutionResult(transfers: [successfulTransfer, failedTransfer])

        XCTAssertFalse(NetworkViewActions.shouldRetryAfterPermissionPrompt(in: result))
    }

    func testShouldRetryAfterPermissionPromptWhenLocalErrorIsNotPermissionRelated() {
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "http://192.168.1.88:8080"),
            request: nil,
            errorMessage: "SSL handshake failed"
        )

        let result = makeExecutionResult(transfers: [failedTransfer])

        XCTAssertFalse(NetworkViewActions.shouldRetryAfterPermissionPrompt(in: result))
    }

    func testImportFailureMessageUsesNeutralCopy() {
        let failedTransfer = CurlTransferExecution(
            transfer: makeTransferPlan(index: 0, url: "https://api.example.com"),
            request: nil,
            errorMessage: "curl exited with code 35"
        )

        let result = makeExecutionResult(transfers: [failedTransfer])
        let message = NetworkViewActions.importFailureMessage(from: result)

        XCTAssertEqual(message, "Couldn't import cURL command. curl exited with code 35")
    }
}

private extension NetworkViewActionsTests {
    func makeRequest(url: String, statusCode: Int?) -> NetworkRequest {
        NetworkRequest(
            url: url,
            method: .post,
            statusCode: statusCode,
            timestamp: Date(),
            duration: 0.1,
            requestHeaders: [],
            responseHeaders: [],
            requestBody: .empty,
            responseBody: .empty
        )
    }

    func makeTransferPlan(index: Int, url: String) -> CurlCommandTransferPlan {
        CurlCommandTransferPlan(
            index: index,
            command: "curl \(url)",
            argv: [url],
            urls: [url],
            effectiveOptions: [:]
        )
    }

    func makeExecutionResult(transfers: [CurlTransferExecution]) -> CurlExecutionResult {
        let plan = CurlCommandPlan(
            originalCommand: "curl",
            normalizedCommand: "curl",
            argv: [],
            transfers: transfers.map(\.transfer),
            diagnostics: []
        )

        return CurlExecutionResult(
            plan: plan,
            transfers: transfers,
            startedAt: Date(),
            finishedAt: Date()
        )
    }
}
