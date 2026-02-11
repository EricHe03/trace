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
            XCTAssertEqual(capabilities.supportsHTTP2, report.supportsHTTP2)
            XCTAssertEqual(capabilities.supportsContentDecoding, report.supportsContentDecoding)
            XCTAssertEqual(capabilities.supportsNativeCA, report.supportsNativeCA)
            XCTAssertEqual(capabilities.supportsNTLM, report.supportsNTLM)
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

    func testRuntimeBackendReportsHTTPSSupport() throws {
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

    func testRuntimeBackendFeatureFlagsMatchConfiguredScope() throws {
        #if canImport(TraceCurlRuntime)
        let report = CurlRuntimeBridge.currentReport()
        guard report.available, report.supportsCLIExecution else {
            throw XCTSkip("Runtime backend unavailable in this environment")
        }

        XCTAssertTrue(report.supportsHTTP2, "HTTP/2 support is expected with nghttp2 enabled")
        XCTAssertTrue(report.supportsContentDecoding, "Compressed content decoding is expected with zlib enabled")
        XCTAssertFalse(report.supportsNativeCA, "Native CA is intentionally disabled for mbedTLS backend")
        XCTAssertFalse(report.supportsNTLM, "NTLM is intentionally disabled in current runtime policy")
        #else
        throw XCTSkip("TraceCurlRuntime module unavailable")
        #endif
    }
}
