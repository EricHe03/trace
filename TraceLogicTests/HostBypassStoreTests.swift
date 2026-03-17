//
//  HostBypassStoreTests.swift
//  TraceTests
//

@testable import TraceCore
import XCTest

final class HostBypassStoreTests: XCTestCase {
    // MARK: - InMemoryHostBypassStore

    func testRecordAndLookupRoundTrip() {
        let store = InMemoryHostBypassStore()
        let now = Date()

        store.record(host: "example.com", domain: .tcpMITM, reason: .certificatePinning, ttl: 300, now: now)

        let result = store.lookup(host: "example.com", domain: .tcpMITM, now: now)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.host, "example.com")
        XCTAssertEqual(result?.domain, .tcpMITM)
        XCTAssertEqual(result?.reason, .certificatePinning)
        XCTAssertEqual(result?.createdAt, now)
        XCTAssertEqual(result?.expiresAt, now.addingTimeInterval(300))
    }

    func testExpiredRecordReturnsNil() {
        let store = InMemoryHostBypassStore()
        let now = Date()

        store.record(host: "example.com", domain: .tcpMITM, reason: .certificatePinning, ttl: 60, now: now)

        let futureDate = now.addingTimeInterval(61)
        let result = store.lookup(host: "example.com", domain: .tcpMITM, now: futureDate)
        XCTAssertNil(result)
    }

    func testCapacityTrimming() {
        let store = InMemoryHostBypassStore(maxEntries: 64)
        let now = Date()

        // Record 70 entries (exceeds the minimum capacity of 64)
        for i in 0 ..< 70 {
            store.record(
                host: "host\(i).example.com",
                domain: .tcpMITM,
                reason: .certificatePinning,
                ttl: 3600,
                now: now.addingTimeInterval(Double(i))
            )
        }

        // The newest entries should still be present
        let newest = store.lookup(host: "host69.example.com", domain: .tcpMITM, now: now.addingTimeInterval(100))
        XCTAssertNotNil(newest)

        // The oldest entries should have been trimmed
        let oldest = store.lookup(host: "host0.example.com", domain: .tcpMITM, now: now.addingTimeInterval(100))
        XCTAssertNil(oldest)
    }

    func testClearRemovesAllRecords() {
        let store = InMemoryHostBypassStore()
        let now = Date()

        store.record(host: "a.com", domain: .tcpMITM, reason: .certificatePinning, ttl: 300, now: now)
        store.record(host: "b.com", domain: .quicMITM, reason: .sniInvalid, ttl: 300, now: now)

        store.clear(host: nil, domain: nil)

        XCTAssertNil(store.lookup(host: "a.com", domain: .tcpMITM, now: now))
        XCTAssertNil(store.lookup(host: "b.com", domain: .quicMITM, now: now))
    }

    // MARK: - CompositeHostBypassStore

    func testCompositeLookupSearchesAllStores() {
        let store1 = InMemoryHostBypassStore()
        let store2 = InMemoryHostBypassStore()
        let composite = CompositeHostBypassStore(stores: [store1, store2])
        let now = Date()

        store2.record(host: "example.com", domain: .tcpMITM, reason: .certificatePinning, ttl: 300, now: now)

        let result = composite.lookup(host: "example.com", domain: .tcpMITM, now: now)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.reason, .certificatePinning)
    }

    func testCompositeRecordWritesToAllStores() {
        let store1 = InMemoryHostBypassStore()
        let store2 = InMemoryHostBypassStore()
        let composite = CompositeHostBypassStore(stores: [store1, store2])
        let now = Date()

        composite.record(host: "example.com", domain: .quicMITM, reason: .mitmSetupInstability, ttl: 600, now: now)

        XCTAssertNotNil(store1.lookup(host: "example.com", domain: .quicMITM, now: now))
        XCTAssertNotNil(store2.lookup(host: "example.com", domain: .quicMITM, now: now))
    }
}
