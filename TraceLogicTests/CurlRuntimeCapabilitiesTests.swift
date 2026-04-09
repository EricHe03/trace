//
//  CurlRuntimeCapabilitiesTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/08.
//

@testable import TraceFeatures
import XCTest

final class CurlRuntimeCapabilitiesTests: XCTestCase {
    func testResolvedDefaultUsesSwiftNIOBackendIdentity() {
        let capabilities = CurlRuntimeCapabilities.resolvedDefault

        XCTAssertEqual(capabilities.backendName, "SwiftNIO + AsyncHTTPClient + TraceQUIC")
        XCTAssertEqual(capabilities.supportedProtocols, CurlRuntimeCapabilities.nioAsyncHTTPClient.supportedProtocols)
        XCTAssertEqual(capabilities.supportedOptions, CurlRuntimeCapabilities.nioAsyncHTTPClient.supportedOptions)
        XCTAssertTrue(capabilities.supportsHTTP2)
        XCTAssertTrue(capabilities.supportsHTTP3)
        XCTAssertTrue(capabilities.supportsContentDecoding)
        XCTAssertTrue(capabilities.supportsNativeCA)
        XCTAssertFalse(capabilities.supportsNTLM)
    }

    func testDefaultBackendReportsHTTPAndHTTPSSupport() {
        let capabilities = CurlRuntimeCapabilities.resolvedDefault

        XCTAssertTrue(capabilities.supportedProtocols.contains("http"))
        XCTAssertTrue(capabilities.supportedProtocols.contains("https"))
        XCTAssertTrue(capabilities.supportedOptions.contains("--http3"))
        XCTAssertTrue(capabilities.supportedOptions.contains("--http3-only"))
    }

    func testParityValidationStillExposesFullRegistryForAnalyzerCoverage() {
        let capabilities = CurlRuntimeCapabilities.parityValidation

        XCTAssertTrue(capabilities.supportedOptions.isSuperset(of: CurlOptionRegistry.allOptions))
        XCTAssertTrue(capabilities.supportsHTTP2)
        XCTAssertTrue(capabilities.supportsHTTP3)
        XCTAssertTrue(capabilities.supportsContentDecoding)
        XCTAssertTrue(capabilities.supportsNativeCA)
        XCTAssertTrue(capabilities.supportsNTLM)
    }
}
