//
//  CookieStoreTests.swift
//  TraceTests
//
//  Created by Claude on 2026/01/27.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class CookieStoreTests: XCTestCase {

    var cookieStore: DefaultCookieStore!
    var storage: Foundation.HTTPCookieStorage!

    override func setUp() {
        super.setUp()
        cookieStore = DefaultCookieStore()
        storage = Foundation.HTTPCookieStorage.shared

        // Clear all cookies before each test
        if let cookies = storage.cookies {
            for cookie in cookies {
                storage.deleteCookie(cookie)
            }
        }
    }

    override func tearDown() {
        // Clean up cookies after each test
        if let cookies = storage.cookies {
            for cookie in cookies {
                storage.deleteCookie(cookie)
            }
        }
        cookieStore = nil
        storage = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func createCookie(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expiresIn days: Int? = nil
    ) -> Foundation.HTTPCookie? {
        var properties: [Foundation.HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]

        if let days = days {
            let expiryDate = Date().addingTimeInterval(TimeInterval(days * 24 * 60 * 60))
            properties[.expires] = expiryDate
        }

        return Foundation.HTTPCookie(properties: properties)
    }

    // MARK: - Basic Cookie Retrieval Tests

    func testCookiesForURLWithNoCookies() {
        let url = URL(string: "https://example.com")!

        let cookies = cookieStore.cookies(for: url)

        XCTAssertTrue(cookies.isEmpty)
    }

    func testCookiesForURLWithMatchingCookie() {
        let url = URL(string: "https://example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].name, "session")
        XCTAssertEqual(cookies[0].value, "abc123")
    }

    func testCookiesForURLWithMultipleMatchingCookies() {
        let url = URL(string: "https://example.com")!
        let cookie1 = createCookie(name: "session", value: "abc123", domain: "example.com")!
        let cookie2 = createCookie(name: "user", value: "john", domain: "example.com")!
        let cookie3 = createCookie(name: "preferences", value: "dark", domain: "example.com")!

        storage.setCookie(cookie1)
        storage.setCookie(cookie2)
        storage.setCookie(cookie3)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 3)
        XCTAssertTrue(cookies.contains(where: { $0.name == "session" }))
        XCTAssertTrue(cookies.contains(where: { $0.name == "user" }))
        XCTAssertTrue(cookies.contains(where: { $0.name == "preferences" }))
    }

    func testCookiesForURLWithNonMatchingDomain() {
        let url = URL(string: "https://example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "other.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertTrue(cookies.isEmpty)
    }

    // MARK: - Domain Matching Tests

    func testCookiesForURLWithSubdomain() {
        let url = URL(string: "https://api.example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: ".example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].name, "session")
    }

    func testCookiesForURLWithExactDomain() {
        let url = URL(string: "https://example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
    }

    func testCookiesForURLWithWildcardDomain() {
        let url1 = URL(string: "https://www.example.com")!
        let url2 = URL(string: "https://api.example.com")!
        let url3 = URL(string: "https://cdn.example.com")!

        let cookie = createCookie(name: "session", value: "abc123", domain: ".example.com")!
        storage.setCookie(cookie)

        XCTAssertEqual(cookieStore.cookies(for: url1).count, 1)
        XCTAssertEqual(cookieStore.cookies(for: url2).count, 1)
        XCTAssertEqual(cookieStore.cookies(for: url3).count, 1)
    }

    func testCookiesForURLWithDifferentSubdomains() {
        let url = URL(string: "https://api.example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "www.example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        // Should not match different subdomain
        XCTAssertTrue(cookies.isEmpty)
    }

    // MARK: - Path Matching Tests

    func testCookiesForURLWithMatchingPath() {
        let url = URL(string: "https://example.com/api/users")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com", path: "/api")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
    }

    func testCookiesForURLWithNonMatchingPath() {
        let url = URL(string: "https://example.com/admin/settings")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com", path: "/api")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertTrue(cookies.isEmpty)
    }

    func testCookiesForURLWithRootPath() {
        let url = URL(string: "https://example.com/any/path/here")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com", path: "/")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
    }

    func testCookiesForURLWithMultiplePaths() {
        let url = URL(string: "https://example.com/api/v1/users")!

        let cookie1 = createCookie(name: "global", value: "val1", domain: "example.com", path: "/")!
        let cookie2 = createCookie(name: "api", value: "val2", domain: "example.com", path: "/api")!
        let cookie3 = createCookie(name: "v1", value: "val3", domain: "example.com", path: "/api/v1")!
        let cookie4 = createCookie(name: "admin", value: "val4", domain: "example.com", path: "/admin")!

        storage.setCookie(cookie1)
        storage.setCookie(cookie2)
        storage.setCookie(cookie3)
        storage.setCookie(cookie4)

        let cookies = cookieStore.cookies(for: url)

        // Should match global, api, and v1 paths, but not admin
        XCTAssertEqual(cookies.count, 3)
        XCTAssertTrue(cookies.contains(where: { $0.name == "global" }))
        XCTAssertTrue(cookies.contains(where: { $0.name == "api" }))
        XCTAssertTrue(cookies.contains(where: { $0.name == "v1" }))
        XCTAssertFalse(cookies.contains(where: { $0.name == "admin" }))
    }

    // MARK: - Scheme Tests

    func testCookiesForHTTPSURL() {
        let url = URL(string: "https://example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
    }

    func testCookiesForHTTPURL() {
        let url = URL(string: "http://example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
    }

    // MARK: - Cookie Properties Tests

    func testCookiesRetainProperties() {
        let url = URL(string: "https://example.com")!
        let cookie = createCookie(name: "session", value: "abc123xyz", domain: "example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].name, "session")
        XCTAssertEqual(cookies[0].value, "abc123xyz")
        XCTAssertEqual(cookies[0].domain, "example.com")
    }

    func testCookiesWithSpecialCharacters() {
        let url = URL(string: "https://example.com")!
        let cookie = createCookie(name: "data", value: "hello%20world", domain: "example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].value, "hello%20world")
    }

    func testCookiesWithLongValues() {
        let url = URL(string: "https://example.com")!
        let longValue = String(repeating: "a", count: 4000)
        let cookie = createCookie(name: "longCookie", value: longValue, domain: "example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].value, longValue)
    }

    // MARK: - Multiple Cookies with Same Name

    func testMultipleCookiesSameNameDifferentPaths() {
        let url = URL(string: "https://example.com/api/users")!

        let cookie1 = createCookie(name: "token", value: "root", domain: "example.com", path: "/")!
        let cookie2 = createCookie(name: "token", value: "api", domain: "example.com", path: "/api")!

        storage.setCookie(cookie1)
        storage.setCookie(cookie2)

        let cookies = cookieStore.cookies(for: url)

        // Should return both cookies with the same name
        XCTAssertEqual(cookies.count, 2)
        XCTAssertTrue(cookies.contains(where: { $0.value == "root" }))
        XCTAssertTrue(cookies.contains(where: { $0.value == "api" }))
    }

    func testMultipleCookiesSameNameDifferentDomains() {
        let url1 = URL(string: "https://example.com")!
        let url2 = URL(string: "https://api.example.com")!

        let cookie1 = createCookie(name: "session", value: "main", domain: "example.com")!
        let cookie2 = createCookie(name: "session", value: "api", domain: "api.example.com")!

        storage.setCookie(cookie1)
        storage.setCookie(cookie2)

        let cookies1 = cookieStore.cookies(for: url1)
        let cookies2 = cookieStore.cookies(for: url2)

        // Each URL should get appropriate cookies
        XCTAssertEqual(cookies1.count, 1)
        XCTAssertEqual(cookies1[0].value, "main")

        XCTAssertGreaterThanOrEqual(cookies2.count, 1)
        XCTAssertTrue(cookies2.contains(where: { $0.value == "api" }))
    }

    // MARK: - Empty and Invalid URLs

    func testCookiesForURLWithEmptyPath() {
        let url = URL(string: "https://example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com")!

        storage.setCookie(cookie)

        let cookies = cookieStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 1)
    }

    // MARK: - Real-world Scenarios

    func testAuthenticationScenario() {
        let loginURL = URL(string: "https://api.example.com/login")!

        // Simulate authentication cookies
        let sessionCookie = createCookie(name: "session_id", value: "abc123", domain: ".example.com")!
        let authCookie = createCookie(name: "auth_token", value: "xyz789", domain: ".example.com")!
        let userCookie = createCookie(name: "user_id", value: "12345", domain: ".example.com")!

        storage.setCookie(sessionCookie)
        storage.setCookie(authCookie)
        storage.setCookie(userCookie)

        let cookies = cookieStore.cookies(for: loginURL)

        XCTAssertEqual(cookies.count, 3)
        XCTAssertTrue(cookies.contains(where: { $0.name == "session_id" }))
        XCTAssertTrue(cookies.contains(where: { $0.name == "auth_token" }))
        XCTAssertTrue(cookies.contains(where: { $0.name == "user_id" }))
    }

    func testAPIRequestWithCookies() {
        let apiURL = URL(string: "https://api.example.com/v1/users")!

        let apiKeyCookie = createCookie(name: "api_key", value: "key123", domain: ".example.com", path: "/")!
        let versionCookie = createCookie(name: "api_version", value: "v1", domain: ".example.com", path: "/v1")!

        storage.setCookie(apiKeyCookie)
        storage.setCookie(versionCookie)

        let cookies = cookieStore.cookies(for: apiURL)

        XCTAssertGreaterThanOrEqual(cookies.count, 2)
        XCTAssertTrue(cookies.contains(where: { $0.name == "api_key" }))
        XCTAssertTrue(cookies.contains(where: { $0.name == "api_version" }))
    }

    func testTrackingCookiesAcrossSubdomains() {
        let mainURL = URL(string: "https://example.com")!
        let wwwURL = URL(string: "https://www.example.com")!
        let apiURL = URL(string: "https://api.example.com")!

        let trackingCookie = createCookie(name: "tracking_id", value: "track123", domain: ".example.com")!
        storage.setCookie(trackingCookie)

        XCTAssertEqual(cookieStore.cookies(for: mainURL).count, 1)
        XCTAssertEqual(cookieStore.cookies(for: wwwURL).count, 1)
        XCTAssertEqual(cookieStore.cookies(for: apiURL).count, 1)
    }

    // MARK: - Cookie Update Tests

    func testUpdatingCookieValue() {
        let url = URL(string: "https://example.com")!

        let cookie1 = createCookie(name: "session", value: "old_value", domain: "example.com")!
        storage.setCookie(cookie1)

        var cookies = cookieStore.cookies(for: url)
        XCTAssertEqual(cookies[0].value, "old_value")

        // Update cookie with new value
        let cookie2 = createCookie(name: "session", value: "new_value", domain: "example.com")!
        storage.setCookie(cookie2)

        cookies = cookieStore.cookies(for: url)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].value, "new_value")
    }

    // MARK: - Performance Tests

    func testPerformanceWithManyCookies() {
        let url = URL(string: "https://example.com")!

        // Add many cookies
        for i in 0..<100 {
            let cookie = createCookie(name: "cookie\(i)", value: "value\(i)", domain: "example.com")!
            storage.setCookie(cookie)
        }

        measure {
            let cookies = cookieStore.cookies(for: url)
            XCTAssertEqual(cookies.count, 100)
        }
    }

    func testPerformanceWithMultipleDomains() {
        let url = URL(string: "https://example.com")!

        // Add cookies for different domains
        for i in 0..<50 {
            let cookie1 = createCookie(name: "cookie\(i)", value: "value\(i)", domain: "example.com")!
            let cookie2 = createCookie(name: "cookie\(i)", value: "value\(i)", domain: "other\(i).com")!
            storage.setCookie(cookie1)
            storage.setCookie(cookie2)
        }

        measure {
            let cookies = cookieStore.cookies(for: url)
            XCTAssertEqual(cookies.count, 50)
        }
    }

    // MARK: - Thread Safety Tests

    func testConcurrentCookieRetrieval() {
        let url = URL(string: "https://example.com")!
        let cookie = createCookie(name: "session", value: "abc123", domain: "example.com")!
        storage.setCookie(cookie)

        let expectation = XCTestExpectation(description: "Concurrent cookie retrieval")
        expectation.expectedFulfillmentCount = 10

        for _ in 0..<10 {
            DispatchQueue.global().async {
                let cookies = self.cookieStore.cookies(for: url)
                XCTAssertEqual(cookies.count, 1)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Custom CookieStore Implementation Tests

    func testCustomCookieStoreImplementation() {
        // Test that custom implementations work with the protocol
        let customStore = MockCookieStore()
        let url = URL(string: "https://example.com")!

        let cookies = customStore.cookies(for: url)

        XCTAssertEqual(cookies.count, 2)
        XCTAssertEqual(cookies[0].name, "mock1")
        XCTAssertEqual(cookies[1].name, "mock2")
    }
}

// MARK: - Mock CookieStore

private class MockCookieStore: CookieStore {
    func cookies(for url: URL) -> [Foundation.HTTPCookie] {
        [
            Foundation.HTTPCookie(properties: [
                .name: "mock1",
                .value: "value1",
                .domain: url.host ?? "",
                .path: "/"
            ])!,
            Foundation.HTTPCookie(properties: [
                .name: "mock2",
                .value: "value2",
                .domain: url.host ?? "",
                .path: "/"
            ])!
        ]
    }
}
