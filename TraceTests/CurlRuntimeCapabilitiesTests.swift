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
}
