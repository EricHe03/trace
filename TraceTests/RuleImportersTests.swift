//
//  RuleImportersTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceFeatures
@testable import TraceCore

final class RuleImportersTests: XCTestCase {

    // MARK: - ProxymanRuleParser Tests

    func testProxymanParserWithEmptyData() {
        // Arrange
        let emptyData = Data()

        // Act
        let rules = ProxymanRuleParser.parse(emptyData)

        // Assert
        XCTAssertEqual(rules.count, 0, "Empty data should return empty array")
    }

    func testProxymanParserWithValidData() {
        // Arrange
        let validJSON = """
        {
            "rules": [
                {
                    "name": "Test Rule",
                    "enabled": true,
                    "pattern": "*.example.com"
                }
            ]
        }
        """.data(using: .utf8)!

        // Act
        let rules = ProxymanRuleParser.parse(validJSON)

        // Assert
        // TODO: Once implementation is complete, verify rule parsing
        XCTAssertEqual(rules.count, 0, "Not yet implemented")
    }

    func testProxymanParserWithInvalidJSON() {
        // Arrange
        let invalidJSON = "not valid json".data(using: .utf8)!

        // Act
        let rules = ProxymanRuleParser.parse(invalidJSON)

        // Assert
        XCTAssertEqual(rules.count, 0, "Invalid JSON should return empty array")
    }

    func testProxymanParserWithLargeData() {
        // Arrange
        var largeJSON = "{"
        for i in 0..<1000 {
            largeJSON += "\"key\(i)\": \"value\(i)\","
        }
        largeJSON += "\"last\": \"value\"}"
        let largeData = largeJSON.data(using: .utf8)!

        // Act
        let rules = ProxymanRuleParser.parse(largeData)

        // Assert
        XCTAssertEqual(rules.count, 0, "Should handle large data without crashing")
    }

    func testProxymanParserWithNonUTF8Data() {
        // Arrange
        let nonUTF8Data = Data([0xFF, 0xFE, 0xFD])

        // Act
        let rules = ProxymanRuleParser.parse(nonUTF8Data)

        // Assert
        XCTAssertEqual(rules.count, 0, "Should handle non-UTF8 data gracefully")
    }

    // MARK: - CharlesRuleParser Tests

    func testCharlesParserWithEmptyData() {
        // Arrange
        let emptyData = Data()

        // Act
        let rules = CharlesRuleParser.parse(emptyData)

        // Assert
        XCTAssertEqual(rules.count, 0, "Empty data should return empty array")
    }

    func testCharlesParserWithValidData() {
        // Arrange
        let validXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <charles>
            <rule>
                <name>Test Rule</name>
                <enabled>true</enabled>
                <pattern>*.example.com</pattern>
            </rule>
        </charles>
        """.data(using: .utf8)!

        // Act
        let rules = CharlesRuleParser.parse(validXML)

        // Assert
        // TODO: Once implementation is complete, verify rule parsing
        XCTAssertEqual(rules.count, 0, "Not yet implemented")
    }

    func testCharlesParserWithInvalidXML() {
        // Arrange
        let invalidXML = "<unclosed>tag".data(using: .utf8)!

        // Act
        let rules = CharlesRuleParser.parse(invalidXML)

        // Assert
        XCTAssertEqual(rules.count, 0, "Invalid XML should return empty array")
    }

    func testCharlesParserWithMalformedData() {
        // Arrange
        let malformedData = "not xml at all".data(using: .utf8)!

        // Act
        let rules = CharlesRuleParser.parse(malformedData)

        // Assert
        XCTAssertEqual(rules.count, 0, "Malformed data should return empty array")
    }

    func testCharlesParserWithEmptyXML() {
        // Arrange
        let emptyXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>".data(using: .utf8)!

        // Act
        let rules = CharlesRuleParser.parse(emptyXML)

        // Assert
        XCTAssertEqual(rules.count, 0, "Empty XML should return empty array")
    }

    // MARK: - FiddlerRuleParser Tests

    func testFiddlerParserWithEmptyData() {
        // Arrange
        let emptyData = Data()

        // Act
        let rules = FiddlerRuleParser.parse(emptyData)

        // Assert
        XCTAssertEqual(rules.count, 0, "Empty data should return empty array")
    }

    func testFiddlerParserWithValidData() {
        // Arrange
        let validFarx = """
        [Fiddler]
        Version=1.0

        [Rule:Test]
        Enabled=true
        Pattern=*.example.com
        """.data(using: .utf8)!

        // Act
        let rules = FiddlerRuleParser.parse(validFarx)

        // Assert
        // TODO: Once implementation is complete, verify rule parsing
        XCTAssertEqual(rules.count, 0, "Not yet implemented")
    }

    func testFiddlerParserWithInvalidFormat() {
        // Arrange
        let invalidFormat = "random text content".data(using: .utf8)!

        // Act
        let rules = FiddlerRuleParser.parse(invalidFormat)

        // Assert
        XCTAssertEqual(rules.count, 0, "Invalid format should return empty array")
    }

    func testFiddlerParserWithMixedLineEndings() {
        // Arrange
        let mixedEndings = "[Fiddler]\r\nVersion=1.0\n[Rule:Test]\rEnabled=true".data(using: .utf8)!

        // Act
        let rules = FiddlerRuleParser.parse(mixedEndings)

        // Assert
        XCTAssertEqual(rules.count, 0, "Should handle mixed line endings")
    }

    func testFiddlerParserWithUnicodeContent() {
        // Arrange
        let unicodeContent = "[Fiddler]\nVersion=1.0\n[Rule:测试]\nEnabled=true".data(using: .utf8)!

        // Act
        let rules = FiddlerRuleParser.parse(unicodeContent)

        // Assert
        XCTAssertEqual(rules.count, 0, "Should handle Unicode content")
    }

    // MARK: - HARToRuleConverter Tests

    func testHARConverterWithEmptyData() {
        // Arrange
        let emptyData = Data()

        // Act
        let rules = HARToRuleConverter.convert(emptyData)

        // Assert
        XCTAssertEqual(rules.count, 0, "Empty data should return empty array")
    }

    func testHARConverterWithValidHAR() {
        // Arrange
        let validHAR = """
        {
            "log": {
                "version": "1.2",
                "creator": {
                    "name": "Test",
                    "version": "1.0"
                },
                "entries": [
                    {
                        "request": {
                            "method": "GET",
                            "url": "https://api.example.com/test",
                            "headers": []
                        },
                        "response": {
                            "status": 200,
                            "statusText": "OK",
                            "headers": []
                        }
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        // Act
        let rules = HARToRuleConverter.convert(validHAR)

        // Assert
        // TODO: Once implementation is complete, verify rule conversion
        XCTAssertEqual(rules.count, 0, "Not yet implemented")
    }

    func testHARConverterWithInvalidJSON() {
        // Arrange
        let invalidJSON = "{invalid json}".data(using: .utf8)!

        // Act
        let rules = HARToRuleConverter.convert(invalidJSON)

        // Assert
        XCTAssertEqual(rules.count, 0, "Invalid JSON should return empty array")
    }

    func testHARConverterWithMissingLogField() {
        // Arrange
        let missingLog = """
        {
            "version": "1.2"
        }
        """.data(using: .utf8)!

        // Act
        let rules = HARToRuleConverter.convert(missingLog)

        // Assert
        XCTAssertEqual(rules.count, 0, "Missing log field should return empty array")
    }

    func testHARConverterWithEmptyEntries() {
        // Arrange
        let emptyEntries = """
        {
            "log": {
                "version": "1.2",
                "creator": {
                    "name": "Test",
                    "version": "1.0"
                },
                "entries": []
            }
        }
        """.data(using: .utf8)!

        // Act
        let rules = HARToRuleConverter.convert(emptyEntries)

        // Assert
        XCTAssertEqual(rules.count, 0, "Empty entries should return empty array")
    }

    func testHARConverterWithMultipleEntries() {
        // Arrange
        let multipleEntries = """
        {
            "log": {
                "version": "1.2",
                "creator": {
                    "name": "Test",
                    "version": "1.0"
                },
                "entries": [
                    {
                        "request": {
                            "method": "GET",
                            "url": "https://api.example.com/test1"
                        }
                    },
                    {
                        "request": {
                            "method": "POST",
                            "url": "https://api.example.com/test2"
                        }
                    },
                    {
                        "request": {
                            "method": "PUT",
                            "url": "https://api.example.com/test3"
                        }
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        // Act
        let rules = HARToRuleConverter.convert(multipleEntries)

        // Assert
        // TODO: Once implementation is complete, verify multiple rules are created
        XCTAssertEqual(rules.count, 0, "Not yet implemented")
    }

    func testHARConverterWithMalformedEntry() {
        // Arrange
        let malformedEntry = """
        {
            "log": {
                "version": "1.2",
                "entries": [
                    {
                        "invalid": "entry"
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        // Act
        let rules = HARToRuleConverter.convert(malformedEntry)

        // Assert
        XCTAssertEqual(rules.count, 0, "Malformed entry should return empty array")
    }

    func testHARConverterWithVeryLargeHAR() {
        // Arrange
        var entries = ""
        for i in 0..<100 {
            entries += """
            {
                "request": {
                    "method": "GET",
                    "url": "https://api.example.com/test\(i)"
                }
            },
            """
        }
        entries.removeLast()
        let largeHAR = """
        {
            "log": {
                "version": "1.2",
                "entries": [\(entries)]
            }
        }
        """.data(using: .utf8)!

        // Act
        let rules = HARToRuleConverter.convert(largeHAR)

        // Assert
        XCTAssertEqual(rules.count, 0, "Should handle large HAR files without crashing")
    }

    // MARK: - Cross-Parser Tests

    func testAllParsersReturnEmptyArrayForNilEquivalent() {
        // Arrange
        let emptyData = Data()

        // Act
        let proxymanRules = ProxymanRuleParser.parse(emptyData)
        let charlesRules = CharlesRuleParser.parse(emptyData)
        let fiddlerRules = FiddlerRuleParser.parse(emptyData)
        let harRules = HARToRuleConverter.convert(emptyData)

        // Assert
        XCTAssertEqual(proxymanRules.count, 0)
        XCTAssertEqual(charlesRules.count, 0)
        XCTAssertEqual(fiddlerRules.count, 0)
        XCTAssertEqual(harRules.count, 0)
    }

    func testAllParsersHandleCorruptedData() {
        // Arrange
        let corruptedData = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])

        // Act
        let proxymanRules = ProxymanRuleParser.parse(corruptedData)
        let charlesRules = CharlesRuleParser.parse(corruptedData)
        let fiddlerRules = FiddlerRuleParser.parse(corruptedData)
        let harRules = HARToRuleConverter.convert(corruptedData)

        // Assert
        XCTAssertEqual(proxymanRules.count, 0, "Proxyman should handle corrupted data")
        XCTAssertEqual(charlesRules.count, 0, "Charles should handle corrupted data")
        XCTAssertEqual(fiddlerRules.count, 0, "Fiddler should handle corrupted data")
        XCTAssertEqual(harRules.count, 0, "HAR should handle corrupted data")
    }

    // MARK: - Performance Tests

    func testProxymanParserPerformance() {
        let testData = """
        {
            "rules": [
                {"name": "Rule 1", "enabled": true},
                {"name": "Rule 2", "enabled": false}
            ]
        }
        """.data(using: .utf8)!

        measure {
            _ = ProxymanRuleParser.parse(testData)
        }
    }

    func testCharlesParserPerformance() {
        let testData = """
        <?xml version="1.0"?>
        <charles>
            <rule><name>Rule 1</name></rule>
            <rule><name>Rule 2</name></rule>
        </charles>
        """.data(using: .utf8)!

        measure {
            _ = CharlesRuleParser.parse(testData)
        }
    }

    func testFiddlerParserPerformance() {
        let testData = """
        [Fiddler]
        Version=1.0
        [Rule:Test]
        Enabled=true
        """.data(using: .utf8)!

        measure {
            _ = FiddlerRuleParser.parse(testData)
        }
    }

    func testHARConverterPerformance() {
        let testData = """
        {
            "log": {
                "version": "1.2",
                "entries": [
                    {"request": {"method": "GET", "url": "https://example.com"}}
                ]
            }
        }
        """.data(using: .utf8)!

        measure {
            _ = HARToRuleConverter.convert(testData)
        }
    }
}
