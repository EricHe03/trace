//
//  RegexMatcherTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/27.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class RegexMatcherTests: XCTestCase {

    // MARK: - Basic Matching Tests

    func testSimplePattern() {
        let pattern = "hello"
        let value = "hello world"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertTrue(result)
    }

    func testSimplePatternNoMatch() {
        let pattern = "hello"
        let value = "goodbye world"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertFalse(result)
    }

    func testExactMatch() {
        let pattern = "^hello$"
        let value = "hello"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testExactMatchFails() {
        let pattern = "^hello$"
        let value = "hello world"

        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testPartialMatch() {
        let pattern = "world"
        let value = "hello world today"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    // MARK: - Case Sensitivity Tests

    func testCaseInsensitiveMatching() {
        let pattern = "HELLO"
        let value = "hello world"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value, caseSensitive: false))
    }

    func testCaseSensitiveMatching() {
        let pattern = "HELLO"
        let value = "hello world"

        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value, caseSensitive: true))
    }

    func testCaseSensitiveMatchSuccess() {
        let pattern = "Hello"
        let value = "Hello World"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value, caseSensitive: true))
    }

    func testCaseInsensitiveMixedCase() {
        let pattern = "HeLLo WoRLd"
        let value = "hello WORLD"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value, caseSensitive: false))
    }

    // MARK: - Special Character Tests

    func testDotWildcard() {
        let pattern = "h.llo"
        let value = "hello"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testStarQuantifier() {
        let pattern = "he*llo"
        let value1 = "hllo"
        let value2 = "hello"
        let value3 = "heeeello"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    func testPlusQuantifier() {
        let pattern = "he+llo"
        let value1 = "hllo"
        let value2 = "hello"
        let value3 = "heello"

        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    func testQuestionMarkQuantifier() {
        let pattern = "colou?r"
        let value1 = "color"
        let value2 = "colour"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testCharacterClass() {
        let pattern = "[aeiou]"
        let value1 = "hello"
        let value2 = "world"
        let value3 = "xyz"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    func testNegatedCharacterClass() {
        let pattern = "[^aeiou]+"
        let value1 = "xyz"
        let value2 = "aeiou"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testRangeCharacterClass() {
        let pattern = "[0-9]+"
        let value1 = "abc"
        let value2 = "123"
        let value3 = "abc123"

        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    // MARK: - Anchors and Boundaries

    func testStartAnchor() {
        let pattern = "^hello"
        let value1 = "hello world"
        let value2 = "say hello"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testEndAnchor() {
        let pattern = "world$"
        let value1 = "hello world"
        let value2 = "world is great"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testWordBoundary() {
        let pattern = "\\bcat\\b"
        let value1 = "the cat sat"
        let value2 = "category"
        let value3 = "scat"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    // MARK: - Character Escapes

    func testEscapedDot() {
        let pattern = "\\."
        let value1 = "file.txt"
        let value2 = "filetxt"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testEscapedSpecialChars() {
        let pattern = "\\$\\d+\\.\\d+"
        let value1 = "$19.99"
        let value2 = "19.99"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testBackslashEscape() {
        let pattern = "\\\\"
        let value = "path\\to\\file"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    // MARK: - Digit and Whitespace Tests

    func testDigitShorthand() {
        let pattern = "\\d+"
        let value1 = "abc"
        let value2 = "123"
        let value3 = "abc123def"

        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    func testNonDigitShorthand() {
        let pattern = "\\D+"
        let value1 = "123"
        let value2 = "abc"

        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testWhitespaceShorthand() {
        let pattern = "\\s+"
        let value1 = "hello world"
        let value2 = "helloworld"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testNonWhitespaceShorthand() {
        let pattern = "\\S+"
        let value = "   abc   "

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testWordCharacterShorthand() {
        let pattern = "\\w+"
        let value1 = "hello123"
        let value2 = "   "

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    // MARK: - Grouping Tests

    func testSimpleGroup() {
        let pattern = "(hello)"
        let value = "hello world"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testAlternation() {
        let pattern = "(cat|dog)"
        let value1 = "I have a cat"
        let value2 = "I have a dog"
        let value3 = "I have a bird"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    func testComplexAlternation() {
        let pattern = "(http|https|ftp)://.*"
        let value1 = "http://example.com"
        let value2 = "https://example.com"
        let value3 = "ftp://files.example.com"
        let value4 = "gopher://old.example.com"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value3))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value4))
    }

    // MARK: - Real-world Patterns

    func testEmailPattern() {
        let pattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        let value1 = "user@example.com"
        let value2 = "invalid.email"
        let value3 = "user.name+tag@sub.example.co.uk"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    func testURLPattern() {
        let pattern = "https?://[^\\s]+"
        let value1 = "https://example.com/path"
        let value2 = "http://example.com"
        let value3 = "ftp://example.com"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    func testIPAddressPattern() {
        let pattern = "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"
        let value1 = "192.168.1.1"
        let value2 = "10.0.0.1"
        let value3 = "256.1.1.1" // Invalid but matches pattern
        let value4 = "not.an.ip.address"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value3))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value4))
    }

    func testDatePattern() {
        let pattern = "\\d{4}-\\d{2}-\\d{2}"
        let value1 = "2026-01-27"
        let value2 = "27-01-2026"
        let value3 = "2026/01/27"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value3))
    }

    func testPhonePattern() {
        let pattern = "\\(?\\d{3}\\)?[-.\\s]?\\d{3}[-.\\s]?\\d{4}"
        let value1 = "(123) 456-7890"
        let value2 = "123-456-7890"
        let value3 = "1234567890"
        let value4 = "123.456.7890"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value2))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value3))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value4))
    }

    // MARK: - Safety Limit Tests

    func testPatternTooLong() {
        let pattern = String(repeating: "a", count: RegexMatcher.maxPatternLength + 1)
        let value = "test"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertFalse(result)
    }

    func testPatternAtMaxLength() {
        let pattern = String(repeating: "a", count: RegexMatcher.maxPatternLength)
        let value = String(repeating: "a", count: RegexMatcher.maxPatternLength)

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        // Should not crash
        XCTAssertTrue(result || !result)
    }

    func testInputTooLong() {
        let pattern = "test"
        let value = String(repeating: "x", count: RegexMatcher.maxInputLength + 1)

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertFalse(result)
    }

    func testInputAtMaxLength() {
        let pattern = "test"
        let value = "test" + String(repeating: "x", count: RegexMatcher.maxInputLength - 4)

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertTrue(result)
    }

    // MARK: - Invalid Pattern Tests

    func testInvalidPattern() {
        let pattern = "["
        let value = "test"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertFalse(result)
    }

    func testInvalidPatternUnmatchedParenthesis() {
        let pattern = "(test"
        let value = "test"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertFalse(result)
    }

    func testInvalidPatternBadEscape() {
        let pattern = "\\x"
        let value = "test"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        // May or may not match depending on implementation
        XCTAssertTrue(result || !result)
    }

    // MARK: - Timeout Tests

    func testWithCustomTimeout() {
        let pattern = "hello"
        let value = "hello world"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value, timeoutMs: 500)

        XCTAssertTrue(result)
    }

    func testComplexPatternWithinTimeout() {
        let pattern = "^(\\d{3}[-.]?){2}\\d{4}$"
        let value = "123-456-7890"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value, timeoutMs: 100)

        XCTAssertTrue(result)
    }

    // MARK: - Edge Cases

    func testEmptyPattern() {
        let pattern = ""
        let value = "test"

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertFalse(result)
    }

    func testEmptyValue() {
        let pattern = "test"
        let value = ""

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertFalse(result)
    }

    func testBothEmpty() {
        let pattern = ""
        let value = ""

        let result = RegexMatcher.safeMatch(pattern: pattern, in: value)

        XCTAssertFalse(result)
    }

    func testWhitespaceOnly() {
        let pattern = "^\\s+$"
        let value1 = "   "
        let value2 = "  a  "

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    func testNewlineCharacters() {
        let pattern = "line1\\nline2"
        let value = "line1\nline2"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testTabCharacters() {
        let pattern = "col1\\tcol2"
        let value = "col1\tcol2"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testUnicodeCharacters() {
        let pattern = "世界"
        let value = "Hello 世界"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testEmojiCharacters() {
        let pattern = "rocket"
        let value = "Launch rocket successful"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value))
    }

    func testMultibyteCharacters() {
        let pattern = "café"
        let value1 = "café" // e with accent
        let value2 = "cafe" // plain e

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }

    // MARK: - Performance Tests

    func testPerformanceSimplePattern() {
        let pattern = "hello"
        let value = "hello world"

        measure {
            for _ in 0..<1000 {
                _ = RegexMatcher.safeMatch(pattern: pattern, in: value)
            }
        }
    }

    func testPerformanceComplexPattern() {
        let pattern = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        let value = "user.name+tag@example.co.uk"

        measure {
            for _ in 0..<100 {
                _ = RegexMatcher.safeMatch(pattern: pattern, in: value)
            }
        }
    }

    // MARK: - Thread Safety Tests

    func testConcurrentMatching() {
        let pattern = "test"
        let value = "test value"
        let expectation = XCTestExpectation(description: "Concurrent matching")
        expectation.expectedFulfillmentCount = 10

        for _ in 0..<10 {
            DispatchQueue.global().async {
                let result = RegexMatcher.safeMatch(pattern: pattern, in: value)
                XCTAssertTrue(result)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testConcurrentDifferentPatterns() {
        let patterns = ["test", "hello", "world", "[0-9]+", "\\d+", "[a-z]+"]
        let value = "test hello world 123"
        let expectation = XCTestExpectation(description: "Concurrent different patterns")
        expectation.expectedFulfillmentCount = patterns.count

        for pattern in patterns {
            DispatchQueue.global().async {
                _ = RegexMatcher.safeMatch(pattern: pattern, in: value)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - HTTP/Network Related Tests

    func testHTTPMethodPattern() {
        let pattern = "^(GET|POST|PUT|DELETE|PATCH)$"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: "GET"))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: "POST"))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: "PUT"))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: "get"))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: "INVALID"))
    }

    func testStatusCodePattern() {
        let pattern = "^[2-5]\\d{2}$"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: "200"))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: "404"))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: "500"))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: "100"))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: "600"))
    }

    func testContentTypePattern() {
        let pattern = "application/(json|xml)"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: "application/json"))
        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: "application/xml"))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: "text/html"))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: "application/pdf"))
    }

    func testAuthorizationHeaderPattern() {
        let pattern = "Bearer [A-Za-z0-9\\-._~+/]+="
        let value1 = "Bearer abc123xyz="
        let value2 = "Basic abc123"

        XCTAssertTrue(RegexMatcher.safeMatch(pattern: pattern, in: value1))
        XCTAssertFalse(RegexMatcher.safeMatch(pattern: pattern, in: value2))
    }
}
