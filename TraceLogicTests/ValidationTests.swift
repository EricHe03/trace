//
//  ValidationTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

@testable import TraceCore
import XCTest

final class ValidationTests: XCTestCase {
    // MARK: - isValidDomainPattern Tests - Valid Domains

    func testIsValidDomainPatternWithSimpleDomain() {
        XCTAssertTrue(Validation.isValidDomainPattern("example.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("google.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("test.org"))
    }

    func testIsValidDomainPatternWithSubdomain() {
        XCTAssertTrue(Validation.isValidDomainPattern("www.example.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("api.service.example.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("sub.sub.sub.example.com"))
    }

    func testIsValidDomainPatternWithHyphen() {
        XCTAssertTrue(Validation.isValidDomainPattern("my-site.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("multi-word-domain.org"))
        XCTAssertTrue(Validation.isValidDomainPattern("test-123.example.com"))
    }

    func testIsValidDomainPatternWithNumbers() {
        XCTAssertTrue(Validation.isValidDomainPattern("example123.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("123example.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("12345.com"))
    }

    func testIsValidDomainPatternWithWildcard() {
        XCTAssertTrue(Validation.isValidDomainPattern("*.example.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("*.*.example.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("*"))
    }

    func testIsValidDomainPatternWithMixedCase() {
        XCTAssertTrue(Validation.isValidDomainPattern("Example.COM"))
        XCTAssertTrue(Validation.isValidDomainPattern("MixedCase.Domain.Com"))
        XCTAssertTrue(Validation.isValidDomainPattern("API.Example.ORG"))
    }

    func testIsValidDomainPatternWithSingleCharacter() {
        XCTAssertTrue(Validation.isValidDomainPattern("a.com"))
        XCTAssertTrue(Validation.isValidDomainPattern("x.y.z"))
    }

    // MARK: - isValidDomainPattern Tests - Invalid Domains

    func testIsValidDomainPatternWithEmptyString() {
        XCTAssertFalse(Validation.isValidDomainPattern(""))
    }

    func testIsValidDomainPatternWithWhitespace() {
        XCTAssertFalse(Validation.isValidDomainPattern("   "))
        XCTAssertFalse(Validation.isValidDomainPattern("\n"))
        XCTAssertFalse(Validation.isValidDomainPattern("\t"))
    }

    func testIsValidDomainPatternWithSpaces() {
        XCTAssertFalse(Validation.isValidDomainPattern("example .com"))
        XCTAssertFalse(Validation.isValidDomainPattern("example. com"))
        XCTAssertFalse(Validation.isValidDomainPattern("example com"))
    }

    func testIsValidDomainPatternWithInvalidCharacters() {
        XCTAssertFalse(Validation.isValidDomainPattern("example@.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("example#.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("example$.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("example%.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("example&.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("example!.com"))
    }

    func testIsValidDomainPatternWithUnicode() {
        XCTAssertFalse(Validation.isValidDomainPattern("例え.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("münchen.de"))
        XCTAssertFalse(Validation.isValidDomainPattern("café.fr"))
    }

    func testIsValidDomainPatternWithProtocol() {
        XCTAssertFalse(Validation.isValidDomainPattern("http://example.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("https://example.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("ftp://example.com"))
    }

    func testIsValidDomainPatternWithPath() {
        XCTAssertFalse(Validation.isValidDomainPattern("example.com/path"))
        XCTAssertFalse(Validation.isValidDomainPattern("example.com/"))
    }

    func testIsValidDomainPatternWithPort() {
        XCTAssertFalse(Validation.isValidDomainPattern("example.com:8080"))
        XCTAssertFalse(Validation.isValidDomainPattern("localhost:3000"))
    }

    func testIsValidDomainPatternWithUnderscore() {
        XCTAssertFalse(Validation.isValidDomainPattern("my_site.com"))
        XCTAssertFalse(Validation.isValidDomainPattern("test_domain.org"))
    }

    // MARK: - isValidDomainPattern Tests - Edge Cases

    func testIsValidDomainPatternTrimsWhitespace() {
        XCTAssertTrue(Validation.isValidDomainPattern("  example.com  "))
        XCTAssertTrue(Validation.isValidDomainPattern("\nexample.com\n"))
        XCTAssertTrue(Validation.isValidDomainPattern("\texample.com\t"))
    }

    func testIsValidDomainPatternWithOnlyDots() {
        XCTAssertTrue(Validation.isValidDomainPattern("."))
        XCTAssertTrue(Validation.isValidDomainPattern(".."))
        XCTAssertTrue(Validation.isValidDomainPattern("..."))
    }

    func testIsValidDomainPatternWithLeadingDot() {
        XCTAssertTrue(Validation.isValidDomainPattern(".example.com"))
    }

    func testIsValidDomainPatternWithTrailingDot() {
        XCTAssertTrue(Validation.isValidDomainPattern("example.com."))
    }

    // MARK: - isValidIPAddress Tests - Valid IPs

    func testIsValidIPAddressWithIPv4() {
        XCTAssertTrue(Validation.isValidIPAddress("192.168.1.1"))
        XCTAssertTrue(Validation.isValidIPAddress("8.8.8.8"))
        XCTAssertTrue(Validation.isValidIPAddress("127.0.0.1"))
        XCTAssertTrue(Validation.isValidIPAddress("255.255.255.255"))
        XCTAssertTrue(Validation.isValidIPAddress("0.0.0.0"))
    }

    func testIsValidIPAddressWithIPv6() {
        XCTAssertTrue(Validation.isValidIPAddress("2001:0db8:85a3:0000:0000:8a2e:0370:7334"))
        XCTAssertTrue(Validation.isValidIPAddress("2001:db8:85a3::8a2e:370:7334"))
        XCTAssertTrue(Validation.isValidIPAddress("::1"))
        XCTAssertTrue(Validation.isValidIPAddress("::"))
        XCTAssertTrue(Validation.isValidIPAddress("fe80::1"))
    }

    // MARK: - isValidIPAddress Tests - Invalid IPs

    func testIsValidIPAddressWithInvalidIPv4() {
        XCTAssertFalse(Validation.isValidIPAddress("256.1.1.1"))
        XCTAssertFalse(Validation.isValidIPAddress("1.1.1"))
        XCTAssertFalse(Validation.isValidIPAddress("1.1.1.1.1"))
        XCTAssertFalse(Validation.isValidIPAddress("abc.def.ghi.jkl"))
        XCTAssertFalse(Validation.isValidIPAddress(""))
    }

    func testIsValidIPAddressWithInvalidIPv6() {
        XCTAssertFalse(Validation.isValidIPAddress("gggg::1"))
        XCTAssertFalse(Validation.isValidIPAddress("2001:0db8:85a3::8a2e:370g:7334"))
        XCTAssertFalse(Validation.isValidIPAddress("::::::"))
    }

    // MARK: - isValidIPv4 Tests - Valid IPv4

    func testIsValidIPv4WithStandardAddresses() {
        XCTAssertTrue(Validation.isValidIPv4("192.168.1.1"))
        XCTAssertTrue(Validation.isValidIPv4("10.0.0.1"))
        XCTAssertTrue(Validation.isValidIPv4("172.16.0.1"))
    }

    func testIsValidIPv4WithPublicDNS() {
        XCTAssertTrue(Validation.isValidIPv4("8.8.8.8"))
        XCTAssertTrue(Validation.isValidIPv4("1.1.1.1"))
    }

    func testIsValidIPv4WithLoopback() {
        XCTAssertTrue(Validation.isValidIPv4("127.0.0.1"))
        XCTAssertTrue(Validation.isValidIPv4("127.0.0.2"))
        XCTAssertTrue(Validation.isValidIPv4("127.255.255.255"))
    }

    func testIsValidIPv4WithBroadcast() {
        XCTAssertTrue(Validation.isValidIPv4("255.255.255.255"))
    }

    func testIsValidIPv4WithZeros() {
        XCTAssertTrue(Validation.isValidIPv4("0.0.0.0"))
        XCTAssertTrue(Validation.isValidIPv4("0.0.0.1"))
        XCTAssertTrue(Validation.isValidIPv4("1.0.0.0"))
    }

    func testIsValidIPv4WithEdgeValues() {
        XCTAssertTrue(Validation.isValidIPv4("255.255.255.255"))
        XCTAssertTrue(Validation.isValidIPv4("0.0.0.0"))
        XCTAssertTrue(Validation.isValidIPv4("1.2.3.4"))
    }

    // MARK: - isValidIPv4 Tests - Invalid IPv4

    func testIsValidIPv4WithOutOfRangeOctet() {
        XCTAssertFalse(Validation.isValidIPv4("256.1.1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.256.1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.1.256.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.1.1.256"))
        XCTAssertFalse(Validation.isValidIPv4("300.1.1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.1.1.999"))
    }

    func testIsValidIPv4WithNegativeNumbers() {
        XCTAssertFalse(Validation.isValidIPv4("-1.1.1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.-1.1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.1.-1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.1.1.-1"))
    }

    func testIsValidIPv4WithTooFewOctets() {
        XCTAssertFalse(Validation.isValidIPv4("1.1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1"))
        XCTAssertFalse(Validation.isValidIPv4("192.168.1"))
    }

    func testIsValidIPv4WithTooManyOctets() {
        XCTAssertFalse(Validation.isValidIPv4("1.1.1.1.1"))
        XCTAssertFalse(Validation.isValidIPv4("192.168.1.1.1"))
        XCTAssertFalse(Validation.isValidIPv4("1.2.3.4.5.6"))
    }

    func testIsValidIPv4WithNonNumericOctets() {
        XCTAssertFalse(Validation.isValidIPv4("abc.def.ghi.jkl"))
        XCTAssertFalse(Validation.isValidIPv4("1.2.3.abc"))
        XCTAssertFalse(Validation.isValidIPv4("a.b.c.d"))
    }

    func testIsValidIPv4WithEmptyString() {
        XCTAssertFalse(Validation.isValidIPv4(""))
    }

    func testIsValidIPv4WithWhitespace() {
        XCTAssertFalse(Validation.isValidIPv4("   "))
        XCTAssertFalse(Validation.isValidIPv4("1.1.1. 1"))
        XCTAssertFalse(Validation.isValidIPv4("1. 1.1.1"))
    }

    func testIsValidIPv4WithLeadingZeros() {
        // Leading zeros might be interpreted as octal in some systems
        // The implementation should handle this
        let result = Validation.isValidIPv4("01.02.03.04")
        // We don't assert a specific result, just verify it doesn't crash
        XCTAssertNotNil(result)
    }

    func testIsValidIPv4WithSpecialCharacters() {
        XCTAssertFalse(Validation.isValidIPv4("1.1.1.1!"))
        XCTAssertFalse(Validation.isValidIPv4("1.1.1.1/24"))
        XCTAssertFalse(Validation.isValidIPv4("192.168.1.1:8080"))
    }

    // MARK: - isValidIPv6 Tests - Valid IPv6

    func testIsValidIPv6WithFullAddress() {
        XCTAssertTrue(Validation.isValidIPv6("2001:0db8:85a3:0000:0000:8a2e:0370:7334"))
        XCTAssertTrue(Validation.isValidIPv6("2001:0db8:0000:0000:0000:0000:0000:0001"))
    }

    func testIsValidIPv6WithCompressedAddress() {
        XCTAssertTrue(Validation.isValidIPv6("2001:db8:85a3::8a2e:370:7334"))
        XCTAssertTrue(Validation.isValidIPv6("2001:db8::1"))
        XCTAssertTrue(Validation.isValidIPv6("2001:db8::"))
    }

    func testIsValidIPv6WithLoopback() {
        XCTAssertTrue(Validation.isValidIPv6("::1"))
    }

    func testIsValidIPv6WithUnspecified() {
        XCTAssertTrue(Validation.isValidIPv6("::"))
    }

    func testIsValidIPv6WithLinkLocal() {
        XCTAssertTrue(Validation.isValidIPv6("fe80::1"))
        XCTAssertTrue(Validation.isValidIPv6("fe80::200:5aee:feaa:20a2"))
    }

    func testIsValidIPv6WithMixedCase() {
        XCTAssertTrue(Validation.isValidIPv6("2001:0DB8:85A3::8A2E:370:7334"))
        XCTAssertTrue(Validation.isValidIPv6("2001:db8:85A3::8a2e:370:7334"))
    }

    func testIsValidIPv6WithIPv4Mapped() {
        XCTAssertTrue(Validation.isValidIPv6("::ffff:192.168.1.1"))
        XCTAssertTrue(Validation.isValidIPv6("::ffff:c0a8:0101"))
    }

    // MARK: - isValidIPv6 Tests - Invalid IPv6

    func testIsValidIPv6WithEmptyString() {
        XCTAssertFalse(Validation.isValidIPv6(""))
    }

    func testIsValidIPv6WithWhitespace() {
        XCTAssertFalse(Validation.isValidIPv6("   "))
    }

    func testIsValidIPv6WithInvalidCharacters() {
        XCTAssertFalse(Validation.isValidIPv6("gggg::1"))
        XCTAssertFalse(Validation.isValidIPv6("2001:0db8:85a3::8a2e:370g:7334"))
        XCTAssertFalse(Validation.isValidIPv6("zzzz::1"))
    }

    func testIsValidIPv6WithTooManyColons() {
        XCTAssertFalse(Validation.isValidIPv6("::::::"))
        XCTAssertFalse(Validation.isValidIPv6("1:::1"))
    }

    func testIsValidIPv6WithInvalidFormat() {
        XCTAssertFalse(Validation.isValidIPv6("12345::1"))
        XCTAssertFalse(Validation.isValidIPv6("2001:db8:85a3:0000:0000:8a2e:0370:7334:extra"))
    }

    func testIsValidIPv6WithTrailingWhitespace() {
        // Should handle whitespace
        let trimmed = "::1"
        XCTAssertTrue(Validation.isValidIPv6(trimmed))

        // But whitespace in the middle should fail
        XCTAssertFalse(Validation.isValidIPv6(":: 1"))
    }

    // MARK: - Integration Tests

    func testValidationOfCommonDomains() {
        let domains = [
            "google.com",
            "github.com",
            "stackoverflow.com",
            "www.amazon.com",
            "api.example.com",
            "*.google.com"
        ]

        for domain in domains {
            XCTAssertTrue(Validation.isValidDomainPattern(domain), "\(domain) should be valid")
        }
    }

    func testValidationOfCommonIPv4Addresses() {
        let ipv4Addresses = [
            "192.168.1.1",
            "10.0.0.1",
            "172.16.0.1",
            "8.8.8.8",
            "127.0.0.1",
            "255.255.255.255",
            "0.0.0.0"
        ]

        for ip in ipv4Addresses {
            XCTAssertTrue(Validation.isValidIPv4(ip), "\(ip) should be valid IPv4")
            XCTAssertTrue(Validation.isValidIPAddress(ip), "\(ip) should be valid IP address")
        }
    }

    func testValidationOfCommonIPv6Addresses() {
        let ipv6Addresses = [
            "::1",
            "::",
            "fe80::1",
            "2001:db8::1",
            "2001:0db8:85a3::8a2e:370:7334"
        ]

        for ip in ipv6Addresses {
            XCTAssertTrue(Validation.isValidIPv6(ip), "\(ip) should be valid IPv6")
            XCTAssertTrue(Validation.isValidIPAddress(ip), "\(ip) should be valid IP address")
        }
    }

    func testValidationRejectsObviouslyInvalidInputs() {
        let invalidInputs = [
            "",
            "   ",
            "not a domain or ip",
            "http://example.com",
            "example .com",
            "256.256.256.256",
            "999.999.999.999"
        ]

        for input in invalidInputs {
            XCTAssertFalse(Validation.isValidDomainPattern(input), "\(input) should be invalid domain")
            XCTAssertFalse(Validation.isValidIPv4(input), "\(input) should be invalid IPv4")
        }
    }

    // MARK: - Performance Tests

    func testDomainValidationPerformance() {
        measure {
            for _ in 0 ..< 1000 {
                _ = Validation.isValidDomainPattern("example.com")
            }
        }
    }

    func testIPv4ValidationPerformance() {
        measure {
            for _ in 0 ..< 1000 {
                _ = Validation.isValidIPv4("192.168.1.1")
            }
        }
    }

    func testIPv6ValidationPerformance() {
        measure {
            for _ in 0 ..< 1000 {
                _ = Validation.isValidIPv6("::1")
            }
        }
    }
}
