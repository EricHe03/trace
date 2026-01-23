//
//  PunycodeTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import XCTest
@testable import Trace
@testable import TraceCore

final class PunycodeTests: XCTestCase {
    
    // MARK: - Basic Encoding Tests
    
    func testEncodeASCIIOnly() {
        // ASCII-only strings should remain unchanged
        let input = "example"
        let result = Punycode.encode(input)
        XCTAssertEqual(result, "example")
    }
    
    func testEncodeSimpleUnicode() {
        // Test basic Unicode encoding
        let input = "bücher"
        let result = Punycode.encode(input)
        XCTAssertEqual(result, "bcher-kva")
    }
    
    func testEncodeArabic() {
        // Test Arabic script
        let input = "مثال"
        let result = Punycode.encode(input)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("") ?? false)
    }
    
    func testEncodeChinese() {
        // Test Chinese characters
        let input = "例え"
        let result = Punycode.encode(input)
        XCTAssertNotNil(result)
    }
    
    func testEncodeMixedASCIIAndUnicode() {
        // Test mixed ASCII and Unicode
        let input = "café"
        let result = Punycode.encode(input)
        XCTAssertEqual(result, "caf-dma")
    }
    
    // MARK: - RFC 3492 Test Cases
    
    func testRFC3492Examples() {
        // Test cases from RFC 3492 Section 7.1
        let testCases: [(String, String)] = [
            // (A) Arabic (Egyptian)
            ("ليهمابتكلموشعربي؟", "egbpdaj6bu4bxfgehfvwxn"),
            // (B) Chinese (simplified)
            ("他们为什么不说中文", "ihqwcrb4cv8a8dqg056pqjye"),
            // (C) Chinese (traditional)
            ("他們爲什麽不說中文", "ihqwctvzc91f659drss3x8bo0yb"),
            // (D) Czech
            ("Pročprostěnemluvíčesky", "Proprostnemluvesky-uyb24dma41a"),
            // (E) Hebrew
            ("למההםפשוטלאמדבריםעברית", "4dbcagdahymbxekheh6e0a7fei0b"),
            // (F) Hindi (Devanagari)
            ("यहलोगहिन्दीक्योंनहींबोलसकतेहैं", "i1baa7eci9glrd9b2ae1bj0hfcgg6iyaf8o0a1dig0cd"),
            // (G) Japanese (kanji and hiragana)
            ("なぜみんな日本語を話してくれないのか", "n8jok5ay5dzabd5bym9f0cm5685rrjetr6pdxa"),
            // (H) Korean (Hangul syllables)
            ("세계의모든사람들이한국어를이해한다면얼마나좋을까", "989aomsvi5e83db1d2a355cv1e0vak1dwrv93d5xbh15a0dt30a5jpsd879ccm6fea98c"),
            // (I) Russian (Cyrillic)
            ("почемужеонинеговорятпорусски", "b1abfaaepdrnnbgefbadotcwatmq2g4l"),
            // (J) Spanish
            ("PorquénopuedensimplementehablarenEspañol", "PorqunopuedensimplementehablarenEspaol-fmd56a"),
            // (K) Vietnamese
            ("TạisaohọkhôngthểchỉnóitiếngViệt", "TisaohkhngthchnitingVit-kjcr8268qyxafd2f1b9g"),
        ]
        
        for (input, expected) in testCases {
            let result = Punycode.encode(input)
            XCTAssertEqual(result, expected, "Failed to encode: \(input)")
        }
    }
    
    // MARK: - Decoding Tests
    
    func testDecodeSimple() {
        let input = "bcher-kva"
        let result = Punycode.decode(input)
        XCTAssertEqual(result, "bücher")
    }
    
    func testDecodeASCII() {
        let input = "example"
        let result = Punycode.decode(input)
        XCTAssertEqual(result, "example")
    }
    
    func testRoundTrip() {
        let testStrings = [
            "bücher",
            "café",
            "münchen",
            "日本",
            "한국",
            "Москва",
        ]
        
        for original in testStrings {
            if let encoded = Punycode.encode(original),
               let decoded = Punycode.decode(encoded) {
                XCTAssertEqual(decoded, original, "Round-trip failed for: \(original)")
            } else {
                XCTFail("Encoding or decoding failed for: \(original)")
            }
        }
    }
    
    // MARK: - Domain Encoding Tests
    
    func testEncodeDomainASCII() {
        let domain = "example.com"
        let result = Punycode.encodeDomain(domain)
        XCTAssertEqual(result, "example.com")
    }
    
    func testEncodeDomainWithUnicode() {
        let domain = "bücher.example.com"
        let result = Punycode.encodeDomain(domain)
        XCTAssertEqual(result, "xn--bcher-kva.example.com")
    }
    
    func testEncodeDomainMultipleUnicodeLabels() {
        let domain = "münchen.café.com"
        let result = Punycode.encodeDomain(domain)
        XCTAssertTrue(result.contains("xn--"))
    }
    
    func testEncodeDomainIDN() {
        // Test common IDN examples
        let testCases: [(String, String)] = [
            ("münchen.de", "xn--mnchen-3ya.de"),
            ("café.fr", "xn--caf-dma.fr"),
            ("日本.jp", "xn--wgv71a.jp"),
        ]
        
        for (input, expected) in testCases {
            let result = Punycode.encodeDomain(input)
            XCTAssertEqual(result, expected, "Failed to encode domain: \(input)")
        }
    }
    
    // MARK: - Domain Decoding Tests
    
    func testDecodeDomainASCII() {
        let domain = "example.com"
        let result = Punycode.decodeDomain(domain)
        XCTAssertEqual(result, "example.com")
    }
    
    func testDecodeDomainWithPunycode() {
        let domain = "xn--bcher-kva.example.com"
        let result = Punycode.decodeDomain(domain)
        XCTAssertEqual(result, "bücher.example.com")
    }
    
    func testDomainRoundTrip() {
        let testDomains = [
            "münchen.de",
            "café.fr",
            "example.com",
            "日本.jp",
        ]
        
        for original in testDomains {
            let encoded = Punycode.encodeDomain(original)
            let decoded = Punycode.decodeDomain(encoded)
            XCTAssertEqual(decoded, original, "Domain round-trip failed for: \(original)")
        }
    }
    
    // MARK: - Edge Cases
    
    func testEmptyString() {
        let result = Punycode.encode("")
        XCTAssertEqual(result, "")
    }
    
    func testSingleCharacter() {
        let result = Punycode.encode("a")
        XCTAssertEqual(result, "a")
    }
    
    func testSingleUnicodeCharacter() {
        let input = "ü"
        let result = Punycode.encode(input)
        XCTAssertNotNil(result)
        
        if let encoded = result, let decoded = Punycode.decode(encoded) {
            XCTAssertEqual(decoded, input)
        }
    }
    
    func testLongString() {
        let input = String(repeating: "ü", count: 100)
        let result = Punycode.encode(input)
        XCTAssertNotNil(result)
        
        if let encoded = result, let decoded = Punycode.decode(encoded) {
            XCTAssertEqual(decoded, input)
        }
    }
}
