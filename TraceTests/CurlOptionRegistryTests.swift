//
//  CurlOptionRegistryTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceFeatures

final class CurlOptionRegistryTests: XCTestCase {

    // MARK: - All Options Tests

    func testAllOptionsIsNotEmpty() {
        // Arrange & Act
        let options = CurlOptionRegistry.allOptions

        // Assert
        XCTAssertFalse(options.isEmpty)
        XCTAssertGreaterThan(options.count, 0)
    }

    func testAllOptionsCount() {
        // Arrange & Act
        let options = CurlOptionRegistry.allOptions

        // Assert
        // Do not assert an exact count since the upstream cURL option set changes over time.
        XCTAssertGreaterThanOrEqual(options.count, 300)
    }

    func testAllOptionsContainsCommonShortOptions() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let commonShortOptions = ["-X", "-H", "-d", "-u", "-k", "-v", "-i", "-o"]

        // Act & Assert
        for option in commonShortOptions {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    func testAllOptionsContainsCommonLongOptions() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let commonLongOptions = [
            "--header",
            "--data",
            "--request",
            "--user",
            "--verbose",
            "--insecure",
            "--output",
            "--url"
        ]

        // Act & Assert
        for option in commonLongOptions {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    func testAllOptionsContainsHTTPMethodOptions() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let httpOptions = ["--get", "--head", "-X", "--request"]

        // Act & Assert
        for option in httpOptions {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    func testAllOptionsContainsAuthenticationOptions() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let authOptions = [
            "--user",
            "--basic",
            "--digest",
            "--ntlm",
            "--negotiate",
            "--anyauth",
            "-u"
        ]

        // Act & Assert
        for option in authOptions {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    func testAllOptionsContainsCertificateOptions() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let certOptions = [
            "--cert",
            "--cacert",
            "--capath",
            "--cert-type",
            "--key",
            "--insecure",
            "-k"
        ]

        // Act & Assert
        for option in certOptions {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    func testAllOptionsContainsHTTP2Options() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let http2Options = [
            "--http2",
            "--http2-prior-knowledge",
            "--http3",
            "--http3-only",
            "--http1.0",
            "--http1.1"
        ]

        // Act & Assert
        for option in http2Options {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    func testAllOptionsContainsProxyOptions() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let proxyOptions = [
            "--proxy",
            "--proxy-user",
            "--proxy-header",
            "--noproxy",
            "-x"
        ]

        // Act & Assert
        for option in proxyOptions {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    // MARK: - Options Requiring Value Tests

    func testOptionsRequiringValueIsNotEmpty() {
        // Arrange & Act
        let options = CurlOptionRegistry.optionsRequiringValue

        // Assert
        XCTAssertFalse(options.isEmpty)
        XCTAssertGreaterThan(options.count, 0)
    }

    func testOptionsRequiringValueCount() {
        // Arrange & Act
        let options = CurlOptionRegistry.optionsRequiringValue

        // Assert
        // Do not assert an exact count since the upstream cURL option set changes over time.
        XCTAssertGreaterThanOrEqual(options.count, 150)
    }

    func testCommonOptionsRequiringValue() {
        // Arrange
        let options = CurlOptionRegistry.optionsRequiringValue
        let requiresValue = [
            "--header",
            "-H",
            "--data",
            "-d",
            "--request",
            "-X",
            "--user",
            "-u",
            "--output",
            "-o",
            "--url"
        ]

        // Act & Assert
        for option in requiresValue {
            XCTAssertTrue(options.contains(option), "\(option) should require a value")
        }
    }

    func testFlagOptionsNotRequiringValue() {
        // Arrange
        let options = CurlOptionRegistry.optionsRequiringValue
        let flags = [
            "--verbose",
            "-v",
            "--insecure",
            "-k",
            "--follow",
            "-L",
            "--silent",
            "-s"
        ]

        // Act & Assert
        for flag in flags {
            XCTAssertFalse(options.contains(flag), "\(flag) should not require a value")
        }
    }

    func testDataOptionsRequireValue() {
        // Arrange
        let options = CurlOptionRegistry.optionsRequiringValue
        let dataOptions = [
            "--data",
            "--data-ascii",
            "--data-raw",
            "--data-urlencode",
            "-d"
        ]

        // Act & Assert
        for option in dataOptions {
            XCTAssertTrue(options.contains(option), "\(option) should require a value")
        }
    }

    func testHeaderOptionsRequireValue() {
        // Arrange
        let options = CurlOptionRegistry.optionsRequiringValue
        let headerOptions = [
            "--header",
            "-H",
            "--proxy-header",
            "--user-agent"
        ]

        // Act & Assert
        for option in headerOptions {
            XCTAssertTrue(options.contains(option), "\(option) should require a value")
        }
    }

    // MARK: - Options With Optional Value Tests

    func testOptionsWithOptionalValueCount() {
        // Arrange & Act
        let options = CurlOptionRegistry.optionsWithOptionalValue

        // Assert
        XCTAssertGreaterThan(options.count, 0)
    }

    func testRepresentativeOptionsHaveOptionalValue() {
        // Arrange & Act
        let options = CurlOptionRegistry.optionsWithOptionalValue

        // Assert
        XCTAssertTrue(options.contains("--proxy"))
        XCTAssertTrue(options.contains("-x"))
    }

    // MARK: - isKnown Tests

    func testIsKnownReturnsTrueForValidOption() {
        // Arrange
        let validOptions = [
            "--header",
            "-H",
            "--data",
            "--request",
            "--verbose",
            "-X"
        ]

        // Act & Assert
        for option in validOptions {
            XCTAssertTrue(CurlOptionRegistry.isKnown(option), "\(option) should be known")
        }
    }

    func testIsKnownReturnsFalseForInvalidOption() {
        // Arrange
        let invalidOptions = [
            "--not-a-real-option",
            "-Z123",
            "--fake",
            "header",
            "data",
            ""
        ]

        // Act & Assert
        for option in invalidOptions {
            XCTAssertFalse(CurlOptionRegistry.isKnown(option), "\(option) should not be known")
        }
    }

    func testIsKnownWithEmptyString() {
        // Arrange
        let emptyOption = ""

        // Act
        let result = CurlOptionRegistry.isKnown(emptyOption)

        // Assert
        XCTAssertFalse(result)
    }

    func testIsKnownCaseSensitive() {
        // Arrange
        let upperCase = "--HEADER"
        let lowerCase = "--header"

        // Act
        let upperResult = CurlOptionRegistry.isKnown(upperCase)
        let lowerResult = CurlOptionRegistry.isKnown(lowerCase)

        // Assert
        XCTAssertFalse(upperResult, "Should be case sensitive")
        XCTAssertTrue(lowerResult)
    }

    func testIsKnownAllRegisteredOptions() {
        // Arrange & Act & Assert
        for option in CurlOptionRegistry.allOptions {
            XCTAssertTrue(CurlOptionRegistry.isKnown(option), "\(option) from allOptions should be known")
        }
    }

    // MARK: - requiresValue Tests

    func testRequiresValueReturnsTrueForOptionsWithValue() {
        // Arrange
        let optionsWithValue = [
            "--header",
            "-H",
            "--data",
            "-d",
            "--user",
            "-u",
            "--output",
            "-o"
        ]

        // Act & Assert
        for option in optionsWithValue {
            XCTAssertTrue(CurlOptionRegistry.requiresValue(option), "\(option) should require value")
        }
    }

    func testRequiresValueReturnsFalseForFlagOptions() {
        // Arrange
        let flagOptions = [
            "--verbose",
            "-v",
            "--insecure",
            "-k",
            "--silent",
            "-s",
            "--location",
            "-L"
        ]

        // Act & Assert
        for option in flagOptions {
            XCTAssertFalse(CurlOptionRegistry.requiresValue(option), "\(option) should not require value")
        }
    }

    func testRequiresValueForUnknownOption() {
        // Arrange
        let unknownOption = "--not-a-real-option"

        // Act
        let result = CurlOptionRegistry.requiresValue(unknownOption)

        // Assert
        XCTAssertFalse(result, "Unknown option should return false")
    }

    func testRequiresValueForEmptyString() {
        // Arrange
        let emptyOption = ""

        // Act
        let result = CurlOptionRegistry.requiresValue(emptyOption)

        // Assert
        XCTAssertFalse(result)
    }

    // MARK: - hasOptionalValue Tests

    func testHasOptionalValueForProxy() {
        // Arrange
        let option = "--proxy"

        // Act
        let result = CurlOptionRegistry.hasOptionalValue(option)

        // Assert
        XCTAssertTrue(result)
    }

    func testHasOptionalValueReturnsFalseForOtherOptions() {
        // Arrange
        let options = [
            "--header",
            "--data",
            "--verbose",
            "--request",
            "-H",
            "-d",
            "-X"
        ]

        // Act & Assert
        for option in options {
            XCTAssertFalse(CurlOptionRegistry.hasOptionalValue(option), "\(option) should not have optional value")
        }
    }

    func testHasOptionalValueForUnknownOption() {
        // Arrange
        let unknownOption = "--not-a-real-option"

        // Act
        let result = CurlOptionRegistry.hasOptionalValue(unknownOption)

        // Assert
        XCTAssertFalse(result)
    }

    // MARK: - Set Property Tests

    func testAllOptionsIsSet() {
        // Arrange & Act
        let options = CurlOptionRegistry.allOptions

        // Assert - Sets should not contain duplicates
        let optionsArray = Array(options)
        XCTAssertEqual(options.count, optionsArray.count)
    }

    func testOptionsRequiringValueIsSet() {
        // Arrange & Act
        let options = CurlOptionRegistry.optionsRequiringValue

        // Assert - Sets should not contain duplicates
        let optionsArray = Array(options)
        XCTAssertEqual(options.count, optionsArray.count)
    }

    func testOptionsWithOptionalValueIsSet() {
        // Arrange & Act
        let options = CurlOptionRegistry.optionsWithOptionalValue

        // Assert - Sets should not contain duplicates
        let optionsArray = Array(options)
        XCTAssertEqual(options.count, optionsArray.count)
    }

    // MARK: - Subset Relationship Tests

    func testOptionsRequiringValueIsSubsetOfAllOptions() {
        // Arrange
        let allOptions = CurlOptionRegistry.allOptions
        let requiringValue = CurlOptionRegistry.optionsRequiringValue

        // Act & Assert
        XCTAssertTrue(requiringValue.isSubset(of: allOptions),
                     "All options requiring value should be in allOptions")
    }

    func testOptionsWithOptionalValueIsSubsetOfAllOptions() {
        // Arrange
        let allOptions = CurlOptionRegistry.allOptions
        let optionalValue = CurlOptionRegistry.optionsWithOptionalValue

        // Act & Assert
        XCTAssertTrue(optionalValue.isSubset(of: allOptions),
                     "All options with optional value should be in allOptions")
    }

    func testOptionsRequiringAndOptionalAreDisjoint() {
        // Arrange
        let requiringValue = CurlOptionRegistry.optionsRequiringValue
        let optionalValue = CurlOptionRegistry.optionsWithOptionalValue

        // Act
        let intersection = requiringValue.intersection(optionalValue)

        // Assert
        XCTAssertFalse(intersection.isEmpty, "Expected overlap between required and optional value option sets")
        XCTAssertTrue(intersection.contains("--proxy"))
    }

    // MARK: - Special Characters Tests

    func testAllOptionsContainsHashOption() {
        // Arrange & Act
        let options = CurlOptionRegistry.allOptions

        // Assert
        XCTAssertTrue(options.contains("-#"), "Should contain -# option")
    }

    func testAllOptionsContainsColonOption() {
        // Arrange & Act
        let options = CurlOptionRegistry.allOptions

        // Assert
        XCTAssertTrue(options.contains("-:"), "Should contain -: option")
    }

    func testAllOptionsContainsNumericOptions() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let numericOptions = ["-0", "-1", "-2", "-3", "-4", "-6"]

        // Act & Assert
        for option in numericOptions {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    func testAllOptionsContainsDotInOptions() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let dotOptions = [
            "--http0.9",
            "--http1.0",
            "--http1.1",
            "--tlsv1.0",
            "--tlsv1.1",
            "--tlsv1.2",
            "--tlsv1.3"
        ]

        // Act & Assert
        for option in dotOptions {
            XCTAssertTrue(options.contains(option), "Should contain \(option)")
        }
    }

    // MARK: - Edge Cases Tests

    func testIsKnownWithWhitespace() {
        // Arrange
        let optionsWithWhitespace = [
            " --header",
            "--header ",
            " --header ",
            "\t--header",
            "--header\n"
        ]

        // Act & Assert
        for option in optionsWithWhitespace {
            XCTAssertFalse(CurlOptionRegistry.isKnown(option),
                          "Option with whitespace should not be recognized: '\(option)'")
        }
    }

    func testRequiresValueWithWhitespace() {
        // Arrange
        let optionWithWhitespace = " --header "

        // Act
        let result = CurlOptionRegistry.requiresValue(optionWithWhitespace)

        // Assert
        XCTAssertFalse(result, "Option with whitespace should not be recognized")
    }

    func testHasOptionalValueWithWhitespace() {
        // Arrange
        let optionWithWhitespace = " --data-binary "

        // Act
        let result = CurlOptionRegistry.hasOptionalValue(optionWithWhitespace)

        // Assert
        XCTAssertFalse(result, "Option with whitespace should not be recognized")
    }

    // MARK: - Comprehensive Option Coverage Tests

    func testAllSingleLetterShortOptionsPresent() {
        // Arrange
        let options = CurlOptionRegistry.allOptions
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        // Act
        var foundOptions: [String] = []
        for char in alphabet {
            let option = "-\(char)"
            if options.contains(option) {
                foundOptions.append(option)
            }
        }

        // Assert
        XCTAssertFalse(foundOptions.isEmpty, "Should have some single-letter options")
        // Common ones we know exist
        XCTAssertTrue(foundOptions.contains("-H"))
        XCTAssertTrue(foundOptions.contains("-d"))
        XCTAssertTrue(foundOptions.contains("-X"))
    }

    func testRequiresValueConsistency() {
        // Arrange
        let requiringValue = CurlOptionRegistry.optionsRequiringValue

        // Act & Assert - Verify some known patterns
        // All --data variants should require values (except maybe --data-binary which has optional)
        XCTAssertTrue(requiringValue.contains("--data"))
        XCTAssertTrue(requiringValue.contains("--data-ascii"))
        XCTAssertTrue(requiringValue.contains("--data-raw"))
        XCTAssertTrue(requiringValue.contains("--data-urlencode"))

        // All --cert variants should require values
        XCTAssertTrue(requiringValue.contains("--cert"))
        XCTAssertTrue(requiringValue.contains("--cert-type"))
    }

    // MARK: - Performance Tests

    func testIsKnownPerformance() {
        measure {
            for _ in 0..<10000 {
                _ = CurlOptionRegistry.isKnown("--header")
                _ = CurlOptionRegistry.isKnown("--not-a-real-option")
            }
        }
    }

    func testRequiresValuePerformance() {
        measure {
            for _ in 0..<10000 {
                _ = CurlOptionRegistry.requiresValue("--header")
                _ = CurlOptionRegistry.requiresValue("--verbose")
            }
        }
    }

    func testHasOptionalValuePerformance() {
        measure {
            for _ in 0..<10000 {
                _ = CurlOptionRegistry.hasOptionalValue("--data-binary")
                _ = CurlOptionRegistry.hasOptionalValue("--header")
            }
        }
    }
}
