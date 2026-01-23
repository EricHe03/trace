//
//  RedirectChainResolverTests.swift
//  TraceTests
//
//  Created by Justin on 2026/01/23.
//

import XCTest
@testable import TraceCore

final class RedirectChainResolverTests: XCTestCase {
    func testEnrichAddsRedirectChainWhenFollowed() {
        let redirectResponse = makeNetworkRequest(
            url: "https://example.com/old",
            statusCode: 302,
            responseHeaders: [TraceHTTPHeader(key: "Location", value: "/new")],
            timestamp: Date()
        )

        let followUp = makeNetworkRequest(
            url: "https://example.com/new",
            statusCode: 200,
            timestamp: redirectResponse.timestamp.addingTimeInterval(1)
        )

        let resolver = RedirectChainResolver(maxMatchInterval: 30)
        let enriched = resolver.enrich([followUp, redirectResponse])

        let matched = enriched.first { $0.url == followUp.url }
        XCTAssertEqual(matched?.redirectChain.count, 1)
        XCTAssertEqual(matched?.redirectChain.first?.fromURL, redirectResponse.url)
        XCTAssertEqual(matched?.redirectChain.first?.toURL, followUp.url)
    }

    func testEnrichSkipsRedirectsOutsideInterval() {
        let redirectResponse = makeNetworkRequest(
            url: "https://example.com/old",
            statusCode: 301,
            responseHeaders: [TraceHTTPHeader(key: "Location", value: "https://example.com/new")],
            timestamp: Date()
        )

        let followUp = makeNetworkRequest(
            url: "https://example.com/new",
            statusCode: 200,
            timestamp: redirectResponse.timestamp.addingTimeInterval(120)
        )

        let resolver = RedirectChainResolver(maxMatchInterval: 30)
        let enriched = resolver.enrich([redirectResponse, followUp])

        let matched = enriched.first { $0.url == followUp.url }
        XCTAssertTrue(matched?.redirectChain.isEmpty ?? true)
    }
}
