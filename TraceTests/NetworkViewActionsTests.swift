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
