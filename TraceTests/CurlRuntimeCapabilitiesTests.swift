//
//  CurlRuntimeCapabilitiesTests.swift
//  TraceTests
//
//  Created by Codex on 2026/02/08.
//

import XCTest
@testable import TraceFeatures
#if canImport(TraceCurlRuntime)
import TraceCurlRuntime
#endif

final class CurlRuntimeCapabilitiesTests: XCTestCase {

    func testResolvedDefaultMatchesRuntimeAvailability() {
        let capabilities = CurlRuntimeCapabilities.resolvedDefault

        #if canImport(TraceCurlRuntime)
        let report = CurlRuntimeBridge.currentReport()
        if report.available && report.supportsCLIExecution {
            XCTAssertFalse(capabilities.supportedProtocols.isEmpty)
            XCTAssertFalse(capabilities.supportedOptions.isEmpty)
            XCTAssertTrue(CurlOptionRegistry.allOptions.isSuperset(of: capabilities.supportedOptions))
            XCTAssertTrue(capabilities.backendName.contains(report.backendName))
        } else {
            XCTAssertEqual(capabilities.supportedProtocols, CurlRuntimeCapabilities.urlSession.supportedProtocols)
            XCTAssertEqual(capabilities.supportedOptions, CurlRuntimeCapabilities.urlSession.supportedOptions)
            XCTAssertTrue(capabilities.backendName.contains("URLSession"))
        }
        #else
        XCTAssertEqual(capabilities.supportedProtocols, CurlRuntimeCapabilities.urlSession.supportedProtocols)
        XCTAssertEqual(capabilities.supportedOptions, CurlRuntimeCapabilities.urlSession.supportedOptions)
        XCTAssertTrue(capabilities.backendName.contains("URLSession"))
        #endif
    }

    func testRuntimeBackendReportsHTTPSSupport() {
        #if canImport(TraceCurlRuntime)
        let report = CurlRuntimeBridge.currentReport()
        guard report.available, report.supportsCLIExecution else {
            throw XCTSkip("Runtime backend unavailable in this environment")
        }
        XCTAssertTrue(report.supportedProtocols.contains("https"), "TLS backend is expected to expose https protocol support")
        #else
        throw XCTSkip("TraceCurlRuntime module unavailable")
        #endif
    }
}
