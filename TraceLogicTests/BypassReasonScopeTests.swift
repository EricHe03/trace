//
//  BypassReasonScopeTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/24.
//

@testable import TraceCore
import XCTest

final class BypassReasonScopeTests: XCTestCase {
    func testInMemoryStoreSeparatesTCPAndQUICDomains() {
        let store = InMemoryHostBypassStore()
        let now = Date(timeIntervalSinceReferenceDate: 1000)

        store.record(
            host: "example.com",
            domain: .quicMITM,
            reason: .mitmSetupInstability,
            ttl: 60,
            now: now
        )

        let quic = store.lookup(host: "example.com", domain: .quicMITM, now: now)
        let tcp = store.lookup(host: "example.com", domain: .tcpMITM, now: now)

        XCTAssertNotNil(quic)
        XCTAssertNil(tcp)
    }

    func testLegacyCodecMarksQUICNoProgressAsQUICDomain() {
        let decoded = LegacyReasonCodec.decode("quic_no_progress_fail_open")
        XCTAssertEqual(decoded.domain, .quicMITM)
        XCTAssertEqual(decoded.failure, .quicNoProgress(detail: .absoluteTimeout))
    }
}
