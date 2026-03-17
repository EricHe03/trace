//
//  CurlCommandTransferPlanCodableTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/08.
//

@testable import TraceFeatures
import XCTest

final class CurlCommandTransferPlanCodableTests: XCTestCase {
    func testDecodeTransferPlanWithoutArgvDefaultsToEmpty() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "index": 1,
          "command": "curl https://example.com",
          "urls": ["https://example.com"],
          "effectiveOptions": {"--verbose": ["true"]}
        }
        """

        let decoded = try JSONDecoder().decode(CurlCommandTransferPlan.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.index, 1)
        XCTAssertEqual(decoded.command, "curl https://example.com")
        XCTAssertEqual(decoded.urls, ["https://example.com"])
        XCTAssertEqual(decoded.effectiveOptions["--verbose"], ["true"])
        XCTAssertTrue(decoded.argv.isEmpty)
    }

    func testRoundTripTransferPlanPreservesArgvWhenPresent() throws {
        let original = CurlCommandTransferPlan(
            index: 0,
            command: "curl --header X-Test:1 https://example.com",
            argv: ["--header", "X-Test:1", "https://example.com"],
            urls: ["https://example.com"],
            effectiveOptions: ["--header": ["X-Test:1"]]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CurlCommandTransferPlan.self, from: data)

        XCTAssertEqual(decoded.argv, original.argv)
        XCTAssertEqual(decoded.command, original.command)
        XCTAssertEqual(decoded.effectiveOptions, original.effectiveOptions)
    }
}
