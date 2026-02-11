//
//  CurlRuntimeCLIExecutorTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/08.
//

import Foundation
import XCTest
@testable import TraceCore
@testable import TraceFeatures
#if canImport(TraceCurlRuntime)
import TraceCurlRuntime
#endif

@MainActor
final class CurlRuntimeCLIExecutorTests: XCTestCase {

    func testRuntimeCLIExecutesTransferWhenAvailable() async throws {
        #if canImport(TraceCurlRuntime)
        let report = CurlRuntimeBridge.currentReport()
        guard report.available, report.supportsFullOptionParity, report.supportsCLIExecution else {
            throw XCTSkip("Runtime CLI backend unavailable in this environment")
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-runtime-\(UUID().uuidString).txt")
        let payload = "runtime-backend-smoke-test"
        try payload.write(to: fileURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let result = await CurlCommandExecutor().execute("curl \(fileURL.absoluteString)")

        XCTAssertEqual(result.transfers.count, 1)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failedCount, 0)

        let request = try XCTUnwrap(result.transfers.first?.request)
        let body = request.responseBody.getString()
        XCTAssertTrue(body?.contains(payload) == true)
        #else
        throw XCTSkip("TraceCurlRuntime module unavailable")
        #endif
    }
}
