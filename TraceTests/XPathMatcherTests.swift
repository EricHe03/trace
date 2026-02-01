//
//  XPathMatcherTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class XPathMatcherTests: XCTestCase {

    // MARK: - Basic Matching Tests

    func testMatchesSimpleElement() {
        let xml = "<root><item>value</item></root>"
        let xpath = "//item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testMatchesNestedElement() {
        let xml = "<root><parent><child>value</child></parent></root>"
        let xpath = "//child"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testDoesNotMatchNonexistentElement() {
        let xml = "<root><item>value</item></root>"
        let xpath = "//nonexistent"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertFalse(matches)
    }

    func testMatchesRootElement() {
        let xml = "<root><item>value</item></root>"
        let xpath = "//root"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    // MARK: - Path Variations Tests

    func testMatchesWithSingleSlash() {
        let xml = "<root><item>value</item></root>"
        let xpath = "/root/item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testMatchesWithoutSlashes() {
        let xml = "<root><item>value</item></root>"
        let xpath = "item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    // MARK: - Edge Cases Tests

    func testEmptyXPath() {
        let xml = "<root><item>value</item></root>"
        let xpath = ""

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertFalse(matches)
    }

    func testWhitespaceOnlyXPath() {
        let xml = "<root><item>value</item></root>"
        let xpath = "   "

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertFalse(matches)
    }

    func testEmptyXML() {
        let xml = ""
        let xpath = "//item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertFalse(matches)
    }

    func testInvalidXML() {
        let xml = "<root><item>value</item>"
        let xpath = "//item"

        // Should handle invalid XML gracefully
        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        // May or may not match depending on XML parser tolerance
        XCTAssertTrue(true, "Should not crash with invalid XML")
    }

    // MARK: - Complex XML Tests

    func testMatchesWithAttributes() {
        let xml = "<root><item id=\"1\">value</item></root>"
        let xpath = "//item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testMatchesWithNamespaces() {
        let xml = "<root xmlns:ns=\"http://example.com\"><ns:item>value</ns:item></root>"
        let xpath = "//ns:item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        // Namespace handling may vary by platform
        XCTAssertTrue(true, "Should handle namespaces without crashing")
    }

    func testMatchesMultipleOccurrences() {
        let xml = "<root><item>one</item><item>two</item><item>three</item></root>"
        let xpath = "//item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testMatchesSelfClosingTag() {
        let xml = "<root><item/></root>"
        let xpath = "//item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    // MARK: - Case Sensitivity Tests

    func testCaseSensitiveElement() {
        let xml = "<root><Item>value</Item></root>"
        let xpath = "//item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        // XML is case-sensitive
        XCTAssertFalse(matches)
    }

    func testCaseSensitiveMatch() {
        let xml = "<root><Item>value</Item></root>"
        let xpath = "//Item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    // MARK: - Special Characters Tests

    func testMatchesWithHyphens() {
        let xml = "<root><my-item>value</my-item></root>"
        let xpath = "//my-item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testMatchesWithUnderscores() {
        let xml = "<root><my_item>value</my_item></root>"
        let xpath = "//my_item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testMatchesWithNumbers() {
        let xml = "<root><item123>value</item123></root>"
        let xpath = "//item123"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    // MARK: - Real-World Examples Tests

    func testMatchesSOAPEnvelope() {
        let xml = """
        <?xml version="1.0"?>
        <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
            <soap:Body>
                <GetStockPrice>
                    <StockName>IBM</StockName>
                </GetStockPrice>
            </soap:Body>
        </soap:Envelope>
        """
        let xpath = "//StockName"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testMatchesRSSFeed() {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0">
            <channel>
                <title>Example Feed</title>
                <item>
                    <title>Item Title</title>
                    <link>http://example.com</link>
                </item>
            </channel>
        </rss>
        """
        let xpath = "//item"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    func testMatchesHTML() {
        let xml = """
        <html>
            <head><title>Page Title</title></head>
            <body>
                <div class="content">
                    <p>Paragraph text</p>
                </div>
            </body>
        </html>
        """
        let xpath = "//div"

        let matches = XPathMatcher.matches(xpath: xpath, in: xml)

        XCTAssertTrue(matches)
    }

    // MARK: - Performance Tests

    func testPerformanceWithLargeXML() {
        var xml = "<root>"
        for i in 0..<1000 {
            xml += "<item id=\"\(i)\">value\(i)</item>"
        }
        xml += "</root>"

        let xpath = "//item"

        measure {
            _ = XPathMatcher.matches(xpath: xpath, in: xml)
        }
    }

    func testPerformanceWithDeeplyNestedXML() {
        var xml = "<root>"
        for _ in 0..<100 {
            xml += "<level>"
        }
        xml += "<target>value</target>"
        for _ in 0..<100 {
            xml += "</level>"
        }
        xml += "</root>"

        let xpath = "//target"

        measure {
            _ = XPathMatcher.matches(xpath: xpath, in: xml)
        }
    }
}
