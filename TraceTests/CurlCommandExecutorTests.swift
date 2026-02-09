//
//  CurlCommandExecutorTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/08.
//

import XCTest
@testable import TraceCore
@testable import TraceFeatures
#if canImport(TraceCurlRuntime)
import TraceCurlRuntime
#endif

@MainActor
final class CurlCommandExecutorTests: XCTestCase {

    func testExecuteBlocksWhenAnalyzerHasErrors() async {
        let mockExecutor = MockTransferExecutor()
        let executor = CurlCommandExecutor(
            analyzer: CurlCommandAnalyzer(capabilities: .urlSession),
            requestExecutorFactory: { mockExecutor }
        )

        let result = await executor.execute("curl --parallel https://example.com")

        XCTAssertTrue(result.plan.hasBlockingDiagnostics)
        XCTAssertEqual(result.transfers.count, 0)
        XCTAssertTrue(mockExecutor.executedURLs.isEmpty)
    }

    func testExecuteRunsAllTransfersSequentially() async {
        let mockExecutor = MockTransferExecutor()
        let analyzer = CurlCommandAnalyzer(
            capabilities: CurlRuntimeCapabilities(
                backendName: "Test",
                supportedProtocols: ["http", "https"],
                supportedOptions: CurlOptionRegistry.allOptions
            )
        )
        let executor = CurlCommandExecutor(
            analyzer: analyzer,
            requestExecutorFactory: { mockExecutor }
        )

        let result = await executor.execute("curl https://one.example --next https://two.example")

        XCTAssertEqual(result.succeededCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(mockExecutor.executedURLs, ["https://one.example", "https://two.example"])

        let requests = result.transfers.compactMap(\.request)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].curlExecutionMetadata?.transferIndex, 0)
        XCTAssertEqual(requests[1].curlExecutionMetadata?.transferIndex, 1)
        XCTAssertEqual(requests[0].curlExecutionMetadata?.transferCount, 2)
    }

    func testExecuteContinuesAfterTransferFailure() async {
        let mockExecutor = MockTransferExecutor()
        mockExecutor.errorsByURL["https://two.example"] = MockError.transport

        let analyzer = CurlCommandAnalyzer(
            capabilities: CurlRuntimeCapabilities(
                backendName: "Test",
                supportedProtocols: ["http", "https"],
                supportedOptions: CurlOptionRegistry.allOptions
            )
        )
        let executor = CurlCommandExecutor(
            analyzer: analyzer,
            requestExecutorFactory: { mockExecutor }
        )

        let command = "curl https://one.example --next https://two.example --next https://three.example"
        let result = await executor.execute(command)

        XCTAssertEqual(result.succeededCount, 2)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(mockExecutor.executedURLs, ["https://one.example", "https://two.example", "https://three.example"])
        XCTAssertTrue(result.transfers.contains { $0.errorMessage != nil })
    }

    func testExecuteRunsAllURLsWhenCommandContainsMultipleURLsWithoutNext() async {
        let mockExecutor = MockTransferExecutor()
        let analyzer = CurlCommandAnalyzer(
            capabilities: CurlRuntimeCapabilities(
                backendName: "Test",
                supportedProtocols: ["http", "https"],
                supportedOptions: CurlOptionRegistry.allOptions
            )
        )
        let executor = CurlCommandExecutor(
            analyzer: analyzer,
            requestExecutorFactory: { mockExecutor }
        )

        let result = await executor.execute("curl https://one.example https://two.example")

        XCTAssertEqual(result.succeededCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(mockExecutor.executedURLs, ["https://one.example", "https://two.example"])
        XCTAssertEqual(result.transfers.count, 2)
    }

    func testExecuteRuntimeRejectsExpiredCertificateTransfer() async throws {
        #if canImport(TraceCurlRuntime)
        let stderr = "curl: (60) SSL certificate problem: certificate has expired"
        let executor = makeRuntimeExecutor(exitCode: 60, statusCode: 0, stderr: stderr)

        let result = await executor.execute("curl https://expired.badssl.com/")

        XCTAssertEqual(result.transfers.count, 1)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.failedCount, 1)

        let transfer = try XCTUnwrap(result.transfers.first)
        XCTAssertFalse(transfer.succeeded)
        XCTAssertEqual(
            transfer.errorMessage,
            "curl exited with code 60: \(stderr)"
        )
        XCTAssertNil(transfer.request)
        XCTAssertTrue(
            transfer.diagnostics.contains {
                $0.message.contains("failed in runtime backend") &&
                    $0.message.contains("certificate has expired")
            }
        )
        #else
        throw XCTSkip("TraceCurlRuntime module unavailable")
        #endif
    }

    func testExecuteRuntimeRejectsSelfSignedCertificateTransfer() async throws {
        #if canImport(TraceCurlRuntime)
        let stderr = "curl: (60) SSL certificate problem: self signed certificate"
        let executor = makeRuntimeExecutor(exitCode: 60, statusCode: 0, stderr: stderr)

        let result = await executor.execute("curl https://self-signed.badssl.com/")

        XCTAssertEqual(result.transfers.count, 1)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertEqual(result.failedCount, 1)

        let transfer = try XCTUnwrap(result.transfers.first)
        XCTAssertFalse(transfer.succeeded)
        XCTAssertEqual(
            transfer.errorMessage,
            "curl exited with code 60: \(stderr)"
        )
        XCTAssertNil(transfer.request)
        XCTAssertTrue(
            transfer.diagnostics.contains {
                $0.message.contains("failed in runtime backend") &&
                    $0.message.contains("self signed certificate")
            }
        )
        #else
        throw XCTSkip("TraceCurlRuntime module unavailable")
        #endif
    }
}

@MainActor
private final class MockTransferExecutor: CurlTransferRequestExecuting {
    var executedURLs: [String] = []
    var errorsByURL: [String: Error] = [:]

    func execute(_ request: RequestBuilder) async throws -> NetworkRequest {
        executedURLs.append(request.url)
        if let error = errorsByURL[request.url] {
            throw error
        }

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

private enum MockError: LocalizedError {
    case transport

    var errorDescription: String? {
        switch self {
        case .transport:
            return "Mock transport error"
        }
    }
}

#if canImport(TraceCurlRuntime)
private extension CurlCommandExecutorTests {
    func makeRuntimeExecutor(
        exitCode: Int32,
        statusCode: Int?,
        stderr: String
    ) -> CurlCommandExecutor {
        CurlCommandExecutor(
            analyzer: CurlCommandAnalyzer(capabilities: .parityValidation),
            requestExecutorFactory: { MockTransferExecutor() },
            runtimeExecutionOverride: true,
            runtimeTransferExecutor: { argv in
                let url = argv.last
                return CurlRuntimeExecutionResult(
                    exitCode: exitCode,
                    transferCount: 1,
                    statusCode: statusCode,
                    statusLine: nil,
                    effectiveURL: url,
                    responseHeaderLines: [],
                    responseBody: Data(),
                    timeTotal: nil,
                    standardOutput: "",
                    standardError: stderr
                )
            }
        )
    }
}
#endif
