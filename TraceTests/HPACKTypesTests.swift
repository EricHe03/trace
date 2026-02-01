//
//  HPACKTypesTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class HPACKTypesTests: XCTestCase {

    // MARK: - HPACKTableSnapshot Tests

    func testHPACKTableSnapshotInit() {
        let staticEntries: [(index: Int, name: String, value: String)] = [
            (index: 1, name: ":authority", value: ""),
            (index: 2, name: ":method", value: "GET")
        ]
        let dynamicEntries: [(index: Int, name: String, value: String, size: Int)] = [
            (index: 62, name: "user-agent", value: "Trace/1.0", size: 43)
        ]

        let snapshot = HPACKTableSnapshot(
            staticEntries: staticEntries,
            dynamicEntries: dynamicEntries,
            currentSize: 43,
            maxSize: 4096
        )

        XCTAssertEqual(snapshot.staticEntries.count, 2)
        XCTAssertEqual(snapshot.dynamicEntries.count, 1)
        XCTAssertEqual(snapshot.currentSize, 43)
        XCTAssertEqual(snapshot.maxSize, 4096)
    }

    func testHPACKTableSnapshotWithDefaultTimestamp() {
        let snapshot = HPACKTableSnapshot(
            staticEntries: [],
            dynamicEntries: [],
            currentSize: 0,
            maxSize: 4096
        )

        let now = Date()
        XCTAssertLessThanOrEqual(snapshot.timestamp.timeIntervalSince(now), 1.0)
    }

    func testHPACKTableSnapshotWithCustomTimestamp() {
        let customTime = Date(timeIntervalSince1970: 1000000)
        let snapshot = HPACKTableSnapshot(
            staticEntries: [],
            dynamicEntries: [],
            currentSize: 0,
            maxSize: 4096,
            timestamp: customTime
        )

        XCTAssertEqual(snapshot.timestamp, customTime)
    }

    func testHPACKTableSnapshotEmptyEntries() {
        let snapshot = HPACKTableSnapshot(
            staticEntries: [],
            dynamicEntries: [],
            currentSize: 0,
            maxSize: 4096
        )

        XCTAssertTrue(snapshot.staticEntries.isEmpty)
        XCTAssertTrue(snapshot.dynamicEntries.isEmpty)
        XCTAssertEqual(snapshot.currentSize, 0)
    }

    func testHPACKTableSnapshotCodableRoundTrip() throws {
        let staticEntries: [(index: Int, name: String, value: String)] = [
            (index: 1, name: ":authority", value: ""),
            (index: 2, name: ":method", value: "GET"),
            (index: 3, name: ":path", value: "/")
        ]
        let dynamicEntries: [(index: Int, name: String, value: String, size: Int)] = [
            (index: 62, name: "authorization", value: "Bearer token", size: 78),
            (index: 63, name: "user-agent", value: "Trace/1.0", size: 43)
        ]

        let snapshot = HPACKTableSnapshot(
            staticEntries: staticEntries,
            dynamicEntries: dynamicEntries,
            currentSize: 121,
            maxSize: 4096
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HPACKTableSnapshot.self, from: data)

        XCTAssertEqual(decoded.staticEntries.count, snapshot.staticEntries.count)
        XCTAssertEqual(decoded.dynamicEntries.count, snapshot.dynamicEntries.count)
        XCTAssertEqual(decoded.currentSize, snapshot.currentSize)
        XCTAssertEqual(decoded.maxSize, snapshot.maxSize)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, snapshot.timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testHPACKTableSnapshotStaticEntryDetails() throws {
        let staticEntries: [(index: Int, name: String, value: String)] = [
            (index: 1, name: ":authority", value: "example.com"),
            (index: 2, name: ":method", value: "POST")
        ]

        let snapshot = HPACKTableSnapshot(
            staticEntries: staticEntries,
            dynamicEntries: [],
            currentSize: 0,
            maxSize: 4096
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HPACKTableSnapshot.self, from: data)

        XCTAssertEqual(decoded.staticEntries[0].index, 1)
        XCTAssertEqual(decoded.staticEntries[0].name, ":authority")
        XCTAssertEqual(decoded.staticEntries[0].value, "example.com")
        XCTAssertEqual(decoded.staticEntries[1].index, 2)
        XCTAssertEqual(decoded.staticEntries[1].name, ":method")
        XCTAssertEqual(decoded.staticEntries[1].value, "POST")
    }

    func testHPACKTableSnapshotDynamicEntryDetails() throws {
        let dynamicEntries: [(index: Int, name: String, value: String, size: Int)] = [
            (index: 62, name: "custom-header", value: "custom-value", size: 57)
        ]

        let snapshot = HPACKTableSnapshot(
            staticEntries: [],
            dynamicEntries: dynamicEntries,
            currentSize: 57,
            maxSize: 4096
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HPACKTableSnapshot.self, from: data)

        XCTAssertEqual(decoded.dynamicEntries[0].index, 62)
        XCTAssertEqual(decoded.dynamicEntries[0].name, "custom-header")
        XCTAssertEqual(decoded.dynamicEntries[0].value, "custom-value")
        XCTAssertEqual(decoded.dynamicEntries[0].size, 57)
    }

    func testHPACKTableSnapshotLargeTable() throws {
        var staticEntries: [(index: Int, name: String, value: String)] = []
        for i in 1...61 {
            staticEntries.append((index: i, name: "header\(i)", value: "value\(i)"))
        }

        var dynamicEntries: [(index: Int, name: String, value: String, size: Int)] = []
        for i in 62...100 {
            dynamicEntries.append((index: i, name: "dynamic\(i)", value: "value\(i)", size: 32))
        }

        let snapshot = HPACKTableSnapshot(
            staticEntries: staticEntries,
            dynamicEntries: dynamicEntries,
            currentSize: 1248, // 39 * 32
            maxSize: 4096
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HPACKTableSnapshot.self, from: data)

        XCTAssertEqual(decoded.staticEntries.count, 61)
        XCTAssertEqual(decoded.dynamicEntries.count, 39)
    }

    // MARK: - HPACKTableEvent Tests

    func testHPACKTableEventEntryAdded() {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryAdded(name: "authorization", value: "Bearer token", index: 62),
            timestamp: Date(),
            tableSnapshot: snapshot
        )

        if case let .entryAdded(name, value, index) = event.type {
            XCTAssertEqual(name, "authorization")
            XCTAssertEqual(value, "Bearer token")
            XCTAssertEqual(index, 62)
        } else {
            XCTFail("Expected entryAdded event type")
        }
    }

    func testHPACKTableEventEntryEvicted() {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryEvicted(name: "old-header", value: "old-value", index: 62),
            timestamp: Date(),
            tableSnapshot: snapshot
        )

        if case let .entryEvicted(name, value, index) = event.type {
            XCTAssertEqual(name, "old-header")
            XCTAssertEqual(value, "old-value")
            XCTAssertEqual(index, 62)
        } else {
            XCTFail("Expected entryEvicted event type")
        }
    }

    func testHPACKTableEventTableSizeUpdated() {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .tableSizeUpdated(newSize: 8192),
            timestamp: Date(),
            tableSnapshot: snapshot
        )

        if case let .tableSizeUpdated(newSize) = event.type {
            XCTAssertEqual(newSize, 8192)
        } else {
            XCTFail("Expected tableSizeUpdated event type")
        }
    }

    func testHPACKTableEventCodableEntryAdded() throws {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryAdded(name: "test-header", value: "test-value", index: 62),
            tableSnapshot: snapshot
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: data)

        if case let .entryAdded(name, value, index) = decoded.type {
            XCTAssertEqual(name, "test-header")
            XCTAssertEqual(value, "test-value")
            XCTAssertEqual(index, 62)
        } else {
            XCTFail("Expected entryAdded event type")
        }
    }

    func testHPACKTableEventCodableEntryEvicted() throws {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryEvicted(name: "evicted-header", value: "evicted-value", index: 63),
            tableSnapshot: snapshot
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: data)

        if case let .entryEvicted(name, value, index) = decoded.type {
            XCTAssertEqual(name, "evicted-header")
            XCTAssertEqual(value, "evicted-value")
            XCTAssertEqual(index, 63)
        } else {
            XCTFail("Expected entryEvicted event type")
        }
    }

    func testHPACKTableEventCodableTableSizeUpdated() throws {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .tableSizeUpdated(newSize: 16384),
            tableSnapshot: snapshot
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: data)

        if case let .tableSizeUpdated(newSize) = decoded.type {
            XCTAssertEqual(newSize, 16384)
        } else {
            XCTFail("Expected tableSizeUpdated event type")
        }
    }

    func testHPACKTableEventWithDefaultTimestamp() {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryAdded(name: "test", value: "value", index: 62),
            tableSnapshot: snapshot
        )

        let now = Date()
        XCTAssertLessThanOrEqual(event.timestamp.timeIntervalSince(now), 1.0)
    }

    func testHPACKTableEventWithCustomTimestamp() {
        let customTime = Date(timeIntervalSince1970: 2000000)
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryAdded(name: "test", value: "value", index: 62),
            timestamp: customTime,
            tableSnapshot: snapshot
        )

        XCTAssertEqual(event.timestamp, customTime)
    }

    func testHPACKTableEventArrayCodable() throws {
        let snapshot = createMockSnapshot()
        let events = [
            HPACKTableEvent(type: .entryAdded(name: "header1", value: "value1", index: 62), tableSnapshot: snapshot),
            HPACKTableEvent(type: .entryEvicted(name: "header2", value: "value2", index: 63), tableSnapshot: snapshot),
            HPACKTableEvent(type: .tableSizeUpdated(newSize: 8192), tableSnapshot: snapshot)
        ]

        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([HPACKTableEvent].self, from: data)

        XCTAssertEqual(decoded.count, 3)

        if case .entryAdded = decoded[0].type {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected entryAdded")
        }

        if case .entryEvicted = decoded[1].type {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected entryEvicted")
        }

        if case .tableSizeUpdated = decoded[2].type {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected tableSizeUpdated")
        }
    }

    // MARK: - Edge Cases

    func testHPACKTableSnapshotWithEmptyValues() throws {
        let staticEntries: [(index: Int, name: String, value: String)] = [
            (index: 1, name: ":authority", value: "")
        ]
        let dynamicEntries: [(index: Int, name: String, value: String, size: Int)] = [
            (index: 62, name: "empty-value", value: "", size: 32)
        ]

        let snapshot = HPACKTableSnapshot(
            staticEntries: staticEntries,
            dynamicEntries: dynamicEntries,
            currentSize: 32,
            maxSize: 4096
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HPACKTableSnapshot.self, from: data)

        XCTAssertEqual(decoded.staticEntries[0].value, "")
        XCTAssertEqual(decoded.dynamicEntries[0].value, "")
    }

    func testHPACKTableSnapshotWithSpecialCharacters() throws {
        let staticEntries: [(index: Int, name: String, value: String)] = [
            (index: 1, name: "header-name", value: "测试值 🔥")
        ]
        let dynamicEntries: [(index: Int, name: String, value: String, size: Int)] = [
            (index: 62, name: "动态头", value: "@#$%^&*()", size: 50)
        ]

        let snapshot = HPACKTableSnapshot(
            staticEntries: staticEntries,
            dynamicEntries: dynamicEntries,
            currentSize: 50,
            maxSize: 4096
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HPACKTableSnapshot.self, from: data)

        XCTAssertEqual(decoded.staticEntries[0].value, "测试值 🔥")
        XCTAssertEqual(decoded.dynamicEntries[0].name, "动态头")
        XCTAssertEqual(decoded.dynamicEntries[0].value, "@#$%^&*()")
    }

    func testHPACKTableSnapshotWithZeroSize() {
        let snapshot = HPACKTableSnapshot(
            staticEntries: [],
            dynamicEntries: [],
            currentSize: 0,
            maxSize: 0
        )

        XCTAssertEqual(snapshot.currentSize, 0)
        XCTAssertEqual(snapshot.maxSize, 0)
    }

    func testHPACKTableSnapshotWithLargeSize() {
        let snapshot = HPACKTableSnapshot(
            staticEntries: [],
            dynamicEntries: [],
            currentSize: 1_000_000,
            maxSize: 10_000_000
        )

        XCTAssertEqual(snapshot.currentSize, 1_000_000)
        XCTAssertEqual(snapshot.maxSize, 10_000_000)
    }

    func testHPACKTableEventWithVeryLongHeaderValue() throws {
        let longValue = String(repeating: "A", count: 10000)
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryAdded(name: "long-header", value: longValue, index: 62),
            tableSnapshot: snapshot
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: data)

        if case let .entryAdded(_, value, _) = decoded.type {
            XCTAssertEqual(value.count, 10000)
        } else {
            XCTFail("Expected entryAdded")
        }
    }

    func testHPACKTableEventWithZeroIndex() throws {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryAdded(name: "zero-index", value: "value", index: 0),
            tableSnapshot: snapshot
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: data)

        if case let .entryAdded(_, _, index) = decoded.type {
            XCTAssertEqual(index, 0)
        } else {
            XCTFail("Expected entryAdded")
        }
    }

    func testHPACKTableEventWithLargeIndex() throws {
        let snapshot = createMockSnapshot()
        let event = HPACKTableEvent(
            type: .entryAdded(name: "large-index", value: "value", index: 100000),
            tableSnapshot: snapshot
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HPACKTableEvent.self, from: data)

        if case let .entryAdded(_, _, index) = decoded.type {
            XCTAssertEqual(index, 100000)
        } else {
            XCTFail("Expected entryAdded")
        }
    }

    // MARK: - Sample Data Tests

    func testHPACKTableSnapshotSample() {
        let sample = HPACKTableSnapshot.sample()

        XCTAssertEqual(sample.staticEntries.count, 10)
        XCTAssertEqual(sample.dynamicEntries.count, 4)
        XCTAssertEqual(sample.currentSize, 227)
        XCTAssertEqual(sample.maxSize, 4096)
        XCTAssertEqual(sample.staticEntries[0].name, ":authority")
        XCTAssertEqual(sample.staticEntries[1].name, ":method")
    }

    func testHPACKTableEventSampleEvents() {
        let sampleEvents = HPACKTableEvent.sampleEvents()

        XCTAssertEqual(sampleEvents.count, 5)

        // Verify event types
        if case .entryAdded = sampleEvents[0].type {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected first event to be entryAdded")
        }

        if case .tableSizeUpdated = sampleEvents[2].type {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected third event to be tableSizeUpdated")
        }

        if case .entryEvicted = sampleEvents[3].type {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected fourth event to be entryEvicted")
        }
    }

    // MARK: - Integration Tests

    func testHPACKTableSnapshotInHTTP2ConnectionInfo() throws {
        let snapshot = createMockSnapshot()
        let connectionInfo = HTTP2ConnectionInfo(
            settingsReceived: ["HEADER_TABLE_SIZE": 4096],
            settingsSent: ["HEADER_TABLE_SIZE": 4096],
            goAwayReceived: false,
            lastStreamId: nil,
            connectionStartTime: Date(),
            connectionEndTime: nil,
            hpackTableSnapshot: snapshot,
            hpackTableEvents: nil
        )

        XCTAssertNotNil(connectionInfo.hpackTableSnapshot)
        XCTAssertEqual(connectionInfo.hpackTableSnapshot?.maxSize, snapshot.maxSize)
    }

    func testHPACKTableEventsInHTTP2ConnectionInfo() throws {
        let snapshot = createMockSnapshot()
        let events = [
            HPACKTableEvent(type: .entryAdded(name: "test", value: "value", index: 62), tableSnapshot: snapshot)
        ]

        let connectionInfo = HTTP2ConnectionInfo(
            settingsReceived: [:],
            settingsSent: [:],
            goAwayReceived: false,
            lastStreamId: nil,
            connectionStartTime: Date(),
            connectionEndTime: nil,
            hpackTableSnapshot: nil,
            hpackTableEvents: events
        )

        XCTAssertNotNil(connectionInfo.hpackTableEvents)
        XCTAssertEqual(connectionInfo.hpackTableEvents?.count, 1)
    }

    // MARK: - Performance Tests

    func testHPACKTableSnapshotEncodingPerformance() throws {
        let snapshot = HPACKTableSnapshot.sample()

        measure {
            do {
                _ = try JSONEncoder().encode(snapshot)
            } catch {
                XCTFail("Encoding failed: \(error)")
            }
        }
    }

    func testHPACKTableSnapshotDecodingPerformance() throws {
        let snapshot = HPACKTableSnapshot.sample()
        let data = try JSONEncoder().encode(snapshot)

        measure {
            do {
                _ = try JSONDecoder().decode(HPACKTableSnapshot.self, from: data)
            } catch {
                XCTFail("Decoding failed: \(error)")
            }
        }
    }

    func testHPACKTableEventEncodingPerformance() throws {
        let events = HPACKTableEvent.sampleEvents()

        measure {
            do {
                _ = try JSONEncoder().encode(events)
            } catch {
                XCTFail("Encoding failed: \(error)")
            }
        }
    }

    // MARK: - Helper Methods

    private func createMockSnapshot() -> HPACKTableSnapshot {
        HPACKTableSnapshot(
            staticEntries: [
                (index: 1, name: ":authority", value: ""),
                (index: 2, name: ":method", value: "GET")
            ],
            dynamicEntries: [
                (index: 62, name: "user-agent", value: "Trace/1.0", size: 43)
            ],
            currentSize: 43,
            maxSize: 4096
        )
    }
}
