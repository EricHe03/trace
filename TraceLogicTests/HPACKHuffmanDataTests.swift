//
//  HPACKHuffmanDataTests.swift
//  TraceTests
//
//  Updated to validate legacy-compatible HPACK snapshot decoding.
//

@testable import TraceCore
import XCTest

final class HPACKHuffmanDataTests: XCTestCase {
    func testHPACKSnapshotDecodesLegacyStaticEntryFormat() throws {
        let json = """
        {
          "staticEntries": [[":method", "GET"], [":path", "/"]],
          "dynamicEntries": [[62, "user-agent", "Trace/1.0", 43]],
          "currentSize": 43,
          "maxSize": 4096,
          "timestamp": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(HPACKTableSnapshot.self, from: json)

        XCTAssertEqual(snapshot.staticEntries.count, 2)
        XCTAssertEqual(snapshot.staticEntries[0].name, ":method")
        XCTAssertEqual(snapshot.dynamicEntries.count, 1)
        XCTAssertEqual(snapshot.dynamicEntries[0].name, "user-agent")
    }

    func testHPACKSnapshotEncodesTupleIndices() throws {
        let snapshot = HPACKTableSnapshot(
            staticEntries: [(index: 1, name: ":method", value: "GET")],
            dynamicEntries: [(index: 62, name: "x-test", value: "value", size: 42)],
            currentSize: 42,
            maxSize: 4096
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HPACKTableSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.staticEntries.first?.index, 1)
        XCTAssertEqual(decoded.dynamicEntries.first?.index, 62)
    }
}
