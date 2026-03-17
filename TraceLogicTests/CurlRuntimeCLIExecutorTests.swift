//
//  CurlRuntimeCLIExecutorTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/08.
//

@testable import TraceCore
@testable import TraceFeatures
import XCTest

@MainActor
final class CurlRuntimeCLIExecutorTests: XCTestCase {
    func testExecuteUsesParsedTransferPathWithoutRuntimeCLI() async {
        let mockExecutor = MockRequestExecutor()
        let executor = CurlCommandExecutor(
            analyzer: CurlCommandAnalyzer(capabilities: .nioAsyncHTTPClient),
            requestExecutorFactory: { mockExecutor }
        )

        let result = await executor.execute("curl https://example.com")

        XCTAssertEqual(result.transfers.count, 1)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(mockExecutor.executedURLs, ["https://example.com"])
    }
}

@MainActor
private final class MockRequestExecutor: CurlTransferRequestExecuting {
    var executedURLs: [String] = []

    func execute(_ request: RequestBuilder) async throws -> NetworkRequest {
        executedURLs.append(request.url)
        return NetworkRequest(
            url: request.url,
            method: request.method,
            requestMethodRaw: request.methodRaw,
            statusCode: 200,
            timestamp: Date(),
            duration: 0.01,
            requestHeaders: request.headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) },
            responseHeaders: [TraceHTTPHeader(key: "Content-Type", value: "text/plain")],
            requestBody: .empty,
            responseBody: .empty
        )
    }
}
