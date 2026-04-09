//
//  MITMAutoBypassCacheTests.swift
//  TraceTests
//
//  Created by Justin on 2026-02-01.
//

@testable import TraceCore
@testable import TraceProxy
import XCTest

final class MITMAutoBypassCacheTests: XCTestCase {
    // MARK: - Properties

    var sut: MITMAutoBypassCache!

    // MARK: - Setup & Teardown

    override func setUp() {
        super.setUp()
        sut = MITMAutoBypassCache.shared
        sut.clear()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Basic Bypass Tests

    func testShouldNotBypassHostByDefault() {
        // Given
        let host = "example.com"

        // When
        let shouldBypass = sut.shouldBypass(host: host)

        // Then
        XCTAssertFalse(shouldBypass)
    }

    func testShouldBypassAfterRecording() {
        // Given
        let host = "example.com"
        let reason = "certificate pinning"

        // When
        sut.record(host: host, reason: reason)
        let shouldBypass = sut.shouldBypass(host: host)

        // Then
        XCTAssertTrue(shouldBypass)
    }

    func testReasonReturnsNilByDefault() {
        // Given
        let host = "example.com"

        // When
        let reason = sut.reason(host: host)

        // Then
        XCTAssertNil(reason)
    }

    func testReasonReturnsRecordedValue() {
        // Given
        let host = "example.com"
        let expectedReason = "certificate pinning"

        // When
        sut.record(host: host, reason: expectedReason)
        let actualReason = sut.reason(host: host)

        // Then
        XCTAssertEqual(actualReason, expectedReason)
    }

    func testReasonForTCPMITMIgnoresQUICReasons() {
        // Given
        let host = "example.com"
        sut.record(host: host, reason: "quic no progress fail open")

        // When
        let reason = MITMAutoBypassLookup.reasonForTCPMITM(host: host)

        // Then
        XCTAssertNil(reason)
    }

    func testReasonForTCPMITMPreservesNonQUICReasons() {
        // Given
        let host = "example.com"
        sut.record(host: host, reason: "pinning requirements")

        // When
        let reason = MITMAutoBypassLookup.reasonForTCPMITM(host: host)

        // Then
        XCTAssertEqual(reason, "pinning requirements")
    }

    // MARK: - Case Insensitivity Tests

    func testShouldBypassIsCaseInsensitive() {
        // Given
        let host = "Example.COM"
        let reason = "test"

        // When
        sut.record(host: host, reason: reason)
        let shouldBypassLower = sut.shouldBypass(host: "example.com")
        let shouldBypassUpper = sut.shouldBypass(host: "EXAMPLE.COM")
        let shouldBypassMixed = sut.shouldBypass(host: "ExAmPlE.cOm")

        // Then
        XCTAssertTrue(shouldBypassLower)
        XCTAssertTrue(shouldBypassUpper)
        XCTAssertTrue(shouldBypassMixed)
    }

    func testReasonIsCaseInsensitive() {
        // Given
        let host = "Example.COM"
        let expectedReason = "test reason"

        // When
        sut.record(host: host, reason: expectedReason)
        let reasonLower = sut.reason(host: "example.com")
        let reasonUpper = sut.reason(host: "EXAMPLE.COM")

        // Then
        XCTAssertEqual(reasonLower, expectedReason)
        XCTAssertEqual(reasonUpper, expectedReason)
    }

    // MARK: - Multiple Hosts Tests

    func testCanRecordMultipleHosts() {
        // Given
        let hosts = [
            ("api.example.com", "pinning"),
            ("cdn.example.com", "certificate error"),
            ("static.example.com", "handshake failure")
        ]

        // When
        for (host, reason) in hosts {
            sut.record(host: host, reason: reason)
        }

        // Then
        for (host, expectedReason) in hosts {
            XCTAssertTrue(sut.shouldBypass(host: host))
            XCTAssertEqual(sut.reason(host: host), expectedReason)
        }
    }

    func testRecordingOneHostDoesNotAffectOthers() {
        // Given
        let host1 = "example.com"
        let host2 = "other.com"

        // When
        sut.record(host: host1, reason: "test")

        // Then
        XCTAssertTrue(sut.shouldBypass(host: host1))
        XCTAssertFalse(sut.shouldBypass(host: host2))
    }

    // MARK: - TTL Expiration Tests

    func testEntryDoesNotExpireImmediately() {
        // Given
        let host = "example.com"
        let reason = "test"

        // When
        sut.record(host: host, reason: reason)

        // Then
        XCTAssertTrue(sut.shouldBypass(host: host))
        XCTAssertNotNil(sut.reason(host: host))
    }

    func testMultipleRecordsForSameHostUpdatesEntry() {
        // Given
        let host = "example.com"
        let firstReason = "first reason"
        let secondReason = "second reason"

        // When
        sut.record(host: host, reason: firstReason)
        sut.record(host: host, reason: secondReason)

        // Then
        XCTAssertTrue(sut.shouldBypass(host: host))
        XCTAssertEqual(sut.reason(host: host), secondReason)
    }

    func testPersistedEntriesAreLoadedByNewInstance() {
        let writer = MITMAutoBypassCache(
            ttl: 3600,
            nowProvider: { Date(timeIntervalSince1970: 1000) }
        )
        writer.clear()
        writer.record(host: "persisted.example.com", reason: "pinning")

        // When
        let reader = MITMAutoBypassCache(
            ttl: 3600,
            nowProvider: { Date(timeIntervalSince1970: 1100) }
        )

        // Then
        XCTAssertTrue(reader.shouldBypass(host: "persisted.example.com"))
        XCTAssertEqual(reader.reason(host: "persisted.example.com"), "pinning")

        reader.clear()
    }

    func testLegacyQUICReasonsArePrunedOnLoad() {
        let storage = AppGroupStorage()
        storage.resetStoredSettings()
        try? storage.replaceMITMAutoBypassEntries([
            MITMAutoBypassStoredEntry(
                host: "quic.example.com",
                reason: "quic handshake failure",
                createdAt: Date(timeIntervalSince1970: 1000),
                expiresAt: Date(timeIntervalSince1970: 4600),
                isAlias: false
            ),
            MITMAutoBypassStoredEntry(
                host: "tcp.example.com",
                reason: "pinning requirements",
                createdAt: Date(timeIntervalSince1970: 1000),
                expiresAt: Date(timeIntervalSince1970: 4600),
                isAlias: false
            )
        ])

        // When
        let reader = MITMAutoBypassCache(
            storage: storage,
            ttl: 3600,
            nowProvider: { Date(timeIntervalSince1970: 1100) }
        )

        // Then
        XCTAssertFalse(reader.shouldBypass(host: "quic.example.com"))
        XCTAssertNil(reader.reason(host: "quic.example.com"))
        XCTAssertTrue(reader.shouldBypass(host: "tcp.example.com"))
        XCTAssertEqual(reader.reason(host: "tcp.example.com"), "pinning requirements")

        storage.resetStoredSettings()
    }

    func testResolvedIPAliasesAreBypassed() {
        let cache = MITMAutoBypassCache(
            ttl: 3600,
            nowProvider: { Date(timeIntervalSince1970: 1000) },
            aliasResolver: { host in
                if host == "example.com" {
                    return ["203.0.113.10", "2001:db8::10"]
                }
                return []
            },
            resolveAliasesAsynchronously: false
        )
        cache.clear()

        // When
        cache.record(host: "example.com", reason: "pinning")

        // Then
        XCTAssertTrue(cache.shouldBypass(host: "203.0.113.10"))
        XCTAssertEqual(cache.reason(host: "203.0.113.10"), "pinning")
        XCTAssertTrue(cache.shouldBypass(host: "[2001:db8::10]"))
        XCTAssertEqual(cache.reason(host: "[2001:db8::10]"), "pinning")

        cache.clear()
    }

    func testPersistedAliasesAreLoadedByNewInstance() {
        let writer = MITMAutoBypassCache(
            ttl: 3600,
            nowProvider: { Date(timeIntervalSince1970: 1000) },
            aliasResolver: { host in
                host == "persisted.example.com" ? ["203.0.113.20"] : []
            },
            resolveAliasesAsynchronously: false
        )
        writer.clear()
        writer.record(host: "persisted.example.com", reason: "pinning")

        // When
        let reader = MITMAutoBypassCache(
            ttl: 3600,
            nowProvider: { Date(timeIntervalSince1970: 1100) },
            aliasResolver: { _ in [] },
            resolveAliasesAsynchronously: false
        )

        // Then
        XCTAssertTrue(reader.shouldBypass(host: "persisted.example.com"))
        XCTAssertTrue(reader.shouldBypass(host: "203.0.113.20"))
        XCTAssertEqual(reader.reason(host: "203.0.113.20"), "pinning")

        reader.clear()
    }

    func testExpiredPersistedEntriesArePrunedOnLoad() {
        let writer = MITMAutoBypassCache(
            ttl: 10,
            nowProvider: { Date(timeIntervalSince1970: 1000) }
        )
        writer.clear()
        writer.record(host: "expired.example.com", reason: "test")

        // When
        let reader = MITMAutoBypassCache(
            ttl: 10,
            nowProvider: { Date(timeIntervalSince1970: 2000) }
        )

        // Then
        XCTAssertFalse(reader.shouldBypass(host: "expired.example.com"))
        XCTAssertNil(reader.reason(host: "expired.example.com"))

        reader.clear()
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentReads() async {
        // Given
        let host = "example.com"
        sut.record(host: host, reason: "test")

        // When
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 100 {
                group.addTask {
                    self.sut.shouldBypass(host: host)
                }
            }

            // Then
            for await result in group {
                XCTAssertTrue(result)
            }
        }
    }

    func testConcurrentWrites() async {
        // Given
        let hosts = (0 ..< 100).map { "example\($0).com" }

        // When
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask {
                    self.sut.record(host: host, reason: "test")
                }
            }
        }

        // Then
        for host in hosts {
            XCTAssertTrue(sut.shouldBypass(host: host))
        }
    }

    func testConcurrentReadsDuringWrites() async {
        // Given
        let host = "example.com"
        sut.record(host: host, reason: "initial")

        // When
        await withTaskGroup(of: Void.self) { group in
            // Write tasks
            for i in 0 ..< 50 {
                group.addTask {
                    self.sut.record(host: host, reason: "update \(i)")
                }
            }

            // Read tasks
            for _ in 0 ..< 50 {
                group.addTask {
                    _ = self.sut.shouldBypass(host: host)
                    _ = self.sut.reason(host: host)
                }
            }
        }

        // Then
        XCTAssertTrue(sut.shouldBypass(host: host))
        XCTAssertNotNil(sut.reason(host: host))
    }

    func testReasonSpecificTTLPinningPersistsBeyondDefaultHour() {
        var now = Date(timeIntervalSince1970: 1000)
        let cache = MITMAutoBypassCache(
            ttl: 3600,
            nowProvider: { now },
            aliasResolver: { _ in [] },
            resolveAliasesAsynchronously: false
        )

        cache.record(host: "pin.example.com", reason: "client_rejected_mitm_or_pinning")
        now = now.addingTimeInterval(4000)
        XCTAssertTrue(cache.shouldBypass(host: "pin.example.com"))

        now = now.addingTimeInterval(83000)
        XCTAssertFalse(cache.shouldBypass(host: "pin.example.com"))
    }

    func testReasonSpecificTTLConnectionClosedEarlyExpiresQuickly() {
        var now = Date(timeIntervalSince1970: 2000)
        let cache = MITMAutoBypassCache(
            ttl: 3600,
            nowProvider: { now },
            aliasResolver: { _ in [] },
            resolveAliasesAsynchronously: false
        )

        cache.record(host: "transient.example.com", reason: "connection_closed_early")
        now = now.addingTimeInterval(181)
        XCTAssertFalse(cache.shouldBypass(host: "transient.example.com"))
    }

    func testReasonSpecificTTLUpstreamTimeoutExpiresQuickly() {
        var now = Date(timeIntervalSince1970: 3000)
        let cache = MITMAutoBypassCache(
            ttl: 3600,
            nowProvider: { now },
            aliasResolver: { _ in [] },
            resolveAliasesAsynchronously: false
        )

        cache.record(host: "timeout.example.com", reason: "upstream_timeout")
        now = now.addingTimeInterval(181)
        XCTAssertFalse(cache.shouldBypass(host: "timeout.example.com"))
    }

    func testRecordingRelatedHostsUsesSharedLookupKeyspace() {
        let cache = MITMAutoBypassCache(
            ttl: 3600,
            aliasResolver: { _ in [] },
            resolveAliasesAsynchronously: false
        )

        cache.record(
            host: "primary.example.com",
            reason: "mitm_setup_failed",
            relatedHosts: ["203.0.113.5", "alias.example.com"]
        )

        XCTAssertTrue(cache.shouldBypass(host: "primary.example.com"))
        XCTAssertTrue(cache.shouldBypass(host: "203.0.113.5"))
        XCTAssertTrue(cache.shouldBypass(host: "alias.example.com"))
    }

    // MARK: - Edge Cases

    func testEmptyHostName() {
        // Given
        let host = ""
        let reason = "test"

        // When
        sut.record(host: host, reason: reason)
        let shouldBypass = sut.shouldBypass(host: host)

        // Then
        XCTAssertFalse(shouldBypass)
    }

    func testEmptyReason() {
        // Given
        let host = "example.com"
        let reason = ""

        // When
        sut.record(host: host, reason: reason)
        let actualReason = sut.reason(host: host)

        // Then
        XCTAssertEqual(actualReason, reason)
    }

    func testVeryLongHostName() {
        // Given
        let host = String(repeating: "a", count: 1000) + ".com"
        let reason = "test"

        // When
        sut.record(host: host, reason: reason)
        let shouldBypass = sut.shouldBypass(host: host)

        // Then
        XCTAssertTrue(shouldBypass)
    }

    func testVeryLongReason() {
        // Given
        let host = "example.com"
        let reason = String(repeating: "x", count: 10000)

        // When
        sut.record(host: host, reason: reason)
        let actualReason = sut.reason(host: host)

        // Then
        XCTAssertEqual(actualReason, reason)
    }

    func testHostWithSpecialCharacters() {
        // Given
        let host = "example-test.com"
        let reason = "test"

        // When
        sut.record(host: host, reason: reason)
        let shouldBypass = sut.shouldBypass(host: host)

        // Then
        XCTAssertTrue(shouldBypass)
    }

    func testHostWithUnicode() {
        // Given
        let host = "例え.jp"
        let reason = "test"

        // When
        sut.record(host: host, reason: reason)
        let shouldBypass = sut.shouldBypass(host: host)

        // Then
        XCTAssertTrue(shouldBypass)
    }

    func testReasonWithSpecialCharacters() {
        // Given
        let host = "example.com"
        let reason = "Certificate pinning: TLS handshake failed @ 2026-02-01T10:30:00Z"

        // When
        sut.record(host: host, reason: reason)
        let actualReason = sut.reason(host: host)

        // Then
        XCTAssertEqual(actualReason, reason)
    }
}
