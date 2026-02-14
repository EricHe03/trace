//
//  CurlRuntimeCapabilitiesTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/08.
//

import XCTest
@testable import TraceFeatures

final class CurlRuntimeCapabilitiesTests: XCTestCase {

    func testResolvedDefaultUsesSwiftNIOBackendIdentity() {
        let capabilities = CurlRuntimeCapabilities.resolvedDefault

        XCTAssertEqual(capabilities.backendName, "SwiftNIO + AsyncHTTPClient")
        XCTAssertEqual(capabilities.supportedProtocols, CurlRuntimeCapabilities.nioAsyncHTTPClient.supportedProtocols)
        XCTAssertEqual(capabilities.supportedOptions, CurlRuntimeCapabilities.nioAsyncHTTPClient.supportedOptions)
        XCTAssertTrue(capabilities.supportsHTTP2)
        XCTAssertTrue(capabilities.supportsContentDecoding)
        XCTAssertTrue(capabilities.supportsNativeCA)
        XCTAssertFalse(capabilities.supportsNTLM)
    }

    func testDefaultBackendReportsHTTPAndHTTPSSupport() {
        let capabilities = CurlRuntimeCapabilities.resolvedDefault

        XCTAssertTrue(capabilities.supportedProtocols.contains("http"))
        XCTAssertTrue(capabilities.supportedProtocols.contains("https"))
    }

    func testParityValidationStillExposesFullRegistryForAnalyzerCoverage() {
        let capabilities = CurlRuntimeCapabilities.parityValidation

        XCTAssertTrue(capabilities.supportedOptions.isSuperset(of: CurlOptionRegistry.allOptions))
        XCTAssertTrue(capabilities.supportsHTTP2)
        XCTAssertTrue(capabilities.supportsContentDecoding)
        XCTAssertTrue(capabilities.supportsNativeCA)
        XCTAssertTrue(capabilities.supportsNTLM)
    }
}
