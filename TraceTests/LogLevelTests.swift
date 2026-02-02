//
//  LogLevelTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class LogLevelTests: XCTestCase {

    // MARK: - Enum Cases Tests

    func testLogLevelCases() {
        let allCases: [LogLevel] = [.debug, .info, .warning, .error]
        XCTAssertEqual(allCases.count, 4)
    }

    func testDebugLevel() {
        let level = LogLevel.debug
        XCTAssertEqual(level.rawValue, "debug")
    }

    func testInfoLevel() {
        let level = LogLevel.info
        XCTAssertEqual(level.rawValue, "info")
    }

    func testWarningLevel() {
        let level = LogLevel.warning
        XCTAssertEqual(level.rawValue, "warning")
    }

    func testErrorLevel() {
        let level = LogLevel.error
        XCTAssertEqual(level.rawValue, "error")
    }

    // MARK: - Codable Tests

    func testLogLevelEncoding() throws {
        let encoder = JSONEncoder()

        let debugData = try encoder.encode(LogLevel.debug)
        let debugString = String(data: debugData, encoding: .utf8)
        XCTAssertEqual(debugString, "\"debug\"")

        let infoData = try encoder.encode(LogLevel.info)
        let infoString = String(data: infoData, encoding: .utf8)
        XCTAssertEqual(infoString, "\"info\"")

        let warningData = try encoder.encode(LogLevel.warning)
        let warningString = String(data: warningData, encoding: .utf8)
        XCTAssertEqual(warningString, "\"warning\"")

        let errorData = try encoder.encode(LogLevel.error)
        let errorString = String(data: errorData, encoding: .utf8)
        XCTAssertEqual(errorString, "\"error\"")
    }

    func testLogLevelDecoding() throws {
        let decoder = JSONDecoder()

        let debugData = "\"debug\"".data(using: .utf8)!
        let debugLevel = try decoder.decode(LogLevel.self, from: debugData)
        XCTAssertEqual(debugLevel, .debug)

        let infoData = "\"info\"".data(using: .utf8)!
        let infoLevel = try decoder.decode(LogLevel.self, from: infoData)
        XCTAssertEqual(infoLevel, .info)

        let warningData = "\"warning\"".data(using: .utf8)!
        let warningLevel = try decoder.decode(LogLevel.self, from: warningData)
        XCTAssertEqual(warningLevel, .warning)

        let errorData = "\"error\"".data(using: .utf8)!
        let errorLevel = try decoder.decode(LogLevel.self, from: errorData)
        XCTAssertEqual(errorLevel, .error)
    }

    func testInvalidLogLevelDecoding() {
        let decoder = JSONDecoder()
        let invalidData = "\"invalid\"".data(using: .utf8)!

        XCTAssertThrowsError(try decoder.decode(LogLevel.self, from: invalidData))
    }

    // MARK: - Codable Round-trip Tests

    func testLogLevelCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let levels: [LogLevel] = [.debug, .info, .warning, .error]

        for level in levels {
            let encoded = try encoder.encode(level)
            let decoded = try decoder.decode(LogLevel.self, from: encoded)
            XCTAssertEqual(decoded, level)
        }
    }

    // MARK: - Equatable Tests

    func testLogLevelEquality() {
        XCTAssertEqual(LogLevel.debug, LogLevel.debug)
        XCTAssertEqual(LogLevel.info, LogLevel.info)
        XCTAssertEqual(LogLevel.warning, LogLevel.warning)
        XCTAssertEqual(LogLevel.error, LogLevel.error)
    }

    func testLogLevelInequality() {
        XCTAssertNotEqual(LogLevel.debug, LogLevel.info)
        XCTAssertNotEqual(LogLevel.info, LogLevel.warning)
        XCTAssertNotEqual(LogLevel.warning, LogLevel.error)
        XCTAssertNotEqual(LogLevel.debug, LogLevel.error)
    }

    // MARK: - Sendable Tests

    func testLogLevelIsSendable() async {
        let level = LogLevel.info

        await withTaskGroup(of: LogLevel.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    level
                }
            }

            var results: [LogLevel] = []
            for await result in group {
                results.append(result)
            }

            XCTAssertEqual(results.count, 10)
            XCTAssertTrue(results.allSatisfy { $0 == .info })
        }
    }

    // MARK: - Collection Tests

    func testLogLevelInArray() {
        let levels: [LogLevel] = [.debug, .info, .warning, .error]

        XCTAssertEqual(levels.count, 4)
        XCTAssertEqual(levels[0], .debug)
        XCTAssertEqual(levels[1], .info)
        XCTAssertEqual(levels[2], .warning)
        XCTAssertEqual(levels[3], .error)
    }

    func testLogLevelInSet() {
        let levels: Set<LogLevel> = [.debug, .info, .warning, .error, .debug]

        XCTAssertEqual(levels.count, 4)
        XCTAssertTrue(levels.contains(.debug))
        XCTAssertTrue(levels.contains(.info))
        XCTAssertTrue(levels.contains(.warning))
        XCTAssertTrue(levels.contains(.error))
    }

    func testLogLevelAsDictionaryKey() {
        let dict: [LogLevel: String] = [
            .debug: "Debug Level",
            .info: "Info Level",
            .warning: "Warning Level",
            .error: "Error Level"
        ]

        XCTAssertEqual(dict[.debug], "Debug Level")
        XCTAssertEqual(dict[.info], "Info Level")
        XCTAssertEqual(dict[.warning], "Warning Level")
        XCTAssertEqual(dict[.error], "Error Level")
    }

    // MARK: - Raw Value Tests

    func testRawValueInitialization() {
        XCTAssertEqual(LogLevel(rawValue: "debug"), .debug)
        XCTAssertEqual(LogLevel(rawValue: "info"), .info)
        XCTAssertEqual(LogLevel(rawValue: "warning"), .warning)
        XCTAssertEqual(LogLevel(rawValue: "error"), .error)
        XCTAssertNil(LogLevel(rawValue: "invalid"))
    }

    // MARK: - String Conversion Tests

    func testStringInterpolation() {
        let debug = LogLevel.debug
        let info = LogLevel.info
        let warning = LogLevel.warning
        let error = LogLevel.error

        XCTAssertEqual("\(debug.rawValue)", "debug")
        XCTAssertEqual("\(info.rawValue)", "info")
        XCTAssertEqual("\(warning.rawValue)", "warning")
        XCTAssertEqual("\(error.rawValue)", "error")
    }

    // MARK: - Edge Cases

    func testEmptyRawValue() {
        XCTAssertNil(LogLevel(rawValue: ""))
    }

    func testWhitespaceRawValue() {
        XCTAssertNil(LogLevel(rawValue: " "))
        XCTAssertNil(LogLevel(rawValue: "  "))
    }

    func testCaseSensitivity() {
        XCTAssertNil(LogLevel(rawValue: "Debug"))
        XCTAssertNil(LogLevel(rawValue: "INFO"))
        XCTAssertNil(LogLevel(rawValue: "Warning"))
        XCTAssertNil(LogLevel(rawValue: "ERROR"))
    }

    func testUnicodeRawValue() {
        XCTAssertNil(LogLevel(rawValue: "debug🚀"))
        XCTAssertNil(LogLevel(rawValue: "デバッグ"))
    }

    // MARK: - JSON Encoding Tests

    func testJSONArrayEncoding() throws {
        let encoder = JSONEncoder()
        let levels: [LogLevel] = [.debug, .info, .warning, .error]

        let data = try encoder.encode(levels)
        let json = String(data: data, encoding: .utf8)

        XCTAssertEqual(json, "[\"debug\",\"info\",\"warning\",\"error\"]")
    }

    func testJSONArrayDecoding() throws {
        let decoder = JSONDecoder()
        let json = "[\"debug\",\"info\",\"warning\",\"error\"]"
        let data = json.data(using: .utf8)!

        let levels = try decoder.decode([LogLevel].self, from: data)

        XCTAssertEqual(levels.count, 4)
        XCTAssertEqual(levels[0], .debug)
        XCTAssertEqual(levels[1], .info)
        XCTAssertEqual(levels[2], .warning)
        XCTAssertEqual(levels[3], .error)
    }

    func testJSONDictionaryEncoding() throws {
        struct Container: Codable {
            let level: LogLevel
            let message: String
        }

        let encoder = JSONEncoder()
        let container = Container(level: .error, message: "Test message")

        let data = try encoder.encode(container)
        let json = String(data: data, encoding: .utf8)

        XCTAssertTrue(json?.contains("\"level\":\"error\"") ?? false)
        XCTAssertTrue(json?.contains("\"message\":\"Test message\"") ?? false)
    }

    func testJSONDictionaryDecoding() throws {
        struct Container: Codable {
            let level: LogLevel
            let message: String
        }

        let decoder = JSONDecoder()
        let json = "{\"level\":\"warning\",\"message\":\"Test warning\"}"
        let data = json.data(using: .utf8)!

        let container = try decoder.decode(Container.self, from: data)

        XCTAssertEqual(container.level, .warning)
        XCTAssertEqual(container.message, "Test warning")
    }

    // MARK: - Performance Tests

    func testLogLevelCreationPerformance() {
        measure {
            for _ in 0..<10000 {
                _ = LogLevel.debug
                _ = LogLevel.info
                _ = LogLevel.warning
                _ = LogLevel.error
            }
        }
    }

    func testLogLevelComparisonPerformance() {
        let level1 = LogLevel.info
        let level2 = LogLevel.info

        measure {
            for _ in 0..<10000 {
                _ = level1 == level2
            }
        }
    }
}
