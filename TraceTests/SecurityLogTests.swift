//
//  SecurityLogTests.swift
//  TraceTests
//
//  Created by Claude Code on 2026/01/27.
//

import XCTest
import os
@testable import Trace
@testable import TraceCore
@testable import TraceSecurity

final class SecurityLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TLSLog.setVerboseEnabled(false)
    }

    override func tearDown() {
        TLSLog.setVerboseEnabled(false)
        super.tearDown()
    }

    // MARK: - TLSLog Verbose Mode Tests

    func testTLSLogVerboseEnabledDefault() {
        XCTAssertFalse(TLSLog.verboseEnabled, "Verbose mode should be disabled by default")
    }

    func testTLSLogSetVerboseEnabled() {
        TLSLog.setVerboseEnabled(true)
        XCTAssertTrue(TLSLog.verboseEnabled)

        TLSLog.setVerboseEnabled(false)
        XCTAssertFalse(TLSLog.verboseEnabled)
    }

    func testTLSLogVerboseToggle() {
        let initialState = TLSLog.verboseEnabled

        TLSLog.setVerboseEnabled(!initialState)
        XCTAssertEqual(TLSLog.verboseEnabled, !initialState)

        TLSLog.setVerboseEnabled(initialState)
        XCTAssertEqual(TLSLog.verboseEnabled, initialState)
    }

    func testTLSLogVerboseThreadSafety() {
        let expectation = self.expectation(description: "Concurrent verbose mode updates")
        expectation.expectedFulfillmentCount = 100

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            TLSLog.setVerboseEnabled(index % 2 == 0)
            _ = TLSLog.verboseEnabled
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
        // Test passes if no crashes occur
    }

    func testTLSLogDebugWithVerboseDisabled() {
        TLSLog.setVerboseEnabled(false)

        // Should not crash when verbose is disabled
        TLSLog.debug("Test message")
        TLSLog.debug(LogEvent.tls("test_action"))
    }

    func testTLSLogDebugWithVerboseEnabled() {
        TLSLog.setVerboseEnabled(true)

        // Should not crash when verbose is enabled
        TLSLog.debug("Test message")
        TLSLog.debug(LogEvent.tls("test_action"))
    }

    // MARK: - LogEvent Extension Tests

    func testLogEventTLS() {
        let event = LogEvent.tls("handshake_start")
        XCTAssertTrue(event.description.hasPrefix("event=tls.handshake_start"))
    }

    func testLogEventKeychain() {
        let event = LogEvent.keychain("save")
        XCTAssertTrue(event.description.hasPrefix("event=keychain.save"))
    }

    func testLogEventCrypto() {
        let event = LogEvent.crypto("encrypt")
        XCTAssertTrue(event.description.hasPrefix("event=crypto.encrypt"))
    }

    func testLogEventCert() {
        let event = LogEvent.cert("generate")
        XCTAssertTrue(event.description.hasPrefix("event=cert.generate"))
    }

    func testLogEventWithAttributes() {
        let event = LogEvent.tls("handshake_complete")
            .success()
            .with("domain", value: "example.com", privacy: .hash)

        XCTAssertTrue(event.description.hasPrefix("event=tls.handshake_complete"))
    }

    // MARK: - SecurityLog Logger Tests

    func testSecurityLogTLSLogger() {
        XCTAssertNotNil(SecurityLog.tls)
        // Test that logger can be used without crashing
        SecurityLog.tls.info("Test TLS log")
    }

    func testSecurityLogKeychainLogger() {
        XCTAssertNotNil(SecurityLog.keychain)
        // Test that logger can be used without crashing
        SecurityLog.keychain.info("Test keychain log")
    }

    func testSecurityLogCryptoLogger() {
        XCTAssertNotNil(SecurityLog.crypto)
        // Test that logger can be used without crashing
        SecurityLog.crypto.info("Test crypto log")
    }

    func testSecurityLogCertificateLogger() {
        XCTAssertNotNil(SecurityLog.certificate)
        // Test that logger can be used without crashing
        SecurityLog.certificate.info("Test certificate log")
    }

    // MARK: - Integration Tests

    func testLogEventChaining() {
        let event = LogEvent.tls("handshake")
            .success()
            .with("duration_ms", value: 100)
            .with("cipher", value: "TLS_AES_128_GCM_SHA256")

        XCTAssertTrue(event.description.hasPrefix("event=tls.handshake"))
    }

    func testLogEventWithError() {
        let error = NSError(domain: "test", code: 42, userInfo: nil)
        let event = LogEvent.tls("handshake")
            .failure()
            .error(error)

        XCTAssertTrue(event.description.hasPrefix("event=tls.handshake"))
    }

    func testMultipleLoggersConcurrently() {
        let expectation = self.expectation(description: "Concurrent logging")
        expectation.expectedFulfillmentCount = 40

        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            SecurityLog.tls.info("TLS log")
            expectation.fulfill()

            SecurityLog.keychain.info("Keychain log")
            expectation.fulfill()

            SecurityLog.crypto.info("Crypto log")
            expectation.fulfill()

            SecurityLog.certificate.info("Certificate log")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }
}
