//
//  NetworkRequestTagsTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import XCTest
@testable import TraceCore

final class NetworkRequestTagsTests: XCTestCase {

    // MARK: - Protocol Detection Tests

    func testIsHTTP3() {
        var request = NetworkRequest.sample
        request.protocolVersion = .http3

        XCTAssertTrue(request.isHTTP3)

        request.protocolVersion = .http2
        XCTAssertFalse(request.isHTTP3)

        request.protocolVersion = .http11
        XCTAssertFalse(request.isHTTP3)
    }

    func testIsWebSocket() {
        var request = NetworkRequest.sample
        request.statusCode = 101
        request.responseHeaders = [
            TraceHTTPHeader(key: "Upgrade", value: "websocket"),
            TraceHTTPHeader(key: "Connection", value: "Upgrade")
        ]

        XCTAssertTrue(request.isWebSocket)

        // Test with wrong status code
        request.statusCode = 200
        XCTAssertFalse(request.isWebSocket)

        // Test with wrong upgrade header
        request.statusCode = 101
        request.responseHeaders = [TraceHTTPHeader(key: "Upgrade", value: "http2")]
        XCTAssertFalse(request.isWebSocket)
    }

    func testIsGRPC() {
        var request = NetworkRequest.sample
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/grpc")
        ]

        XCTAssertTrue(request.isGRPC)

        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/grpc+proto")
        ]
        XCTAssertTrue(request.isGRPC)

        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ]
        XCTAssertFalse(request.isGRPC)
    }

    func testIsGraphQL() {
        var request = NetworkRequest.sample

        // Test path heuristic
        request.url = "https://api.example.com/graphql"
        XCTAssertTrue(request.isGraphQL)

        request.url = "https://api.example.com/v1/graphql/query"
        XCTAssertTrue(request.isGraphQL)

        // Test content-type heuristic
        request.url = "https://api.example.com/api"
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/graphql")
        ]
        XCTAssertTrue(request.isGraphQL)

        // Test negative case
        request.url = "https://api.example.com/rest"
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ]
        XCTAssertFalse(request.isGraphQL)
    }

    // MARK: - TLS/Security Detection Tests

    func testIsTLSPassthrough() {
        var request = NetworkRequest.sample(method: .connect, statusMessage: "TLS Passthrough")

        XCTAssertTrue(request.isTLSPassthrough)

        request.statusMessage = "Connection established - passthrough"
        XCTAssertTrue(request.isTLSPassthrough)

        request.statusMessage = "OK"
        XCTAssertFalse(request.isTLSPassthrough)
    }

    func testTLSPassthroughReason() {
        var request = NetworkRequest.sample(method: .connect, statusMessage: "TLS Passthrough")

        // Test with X-Trace-Note header
        request.requestHeaders = [
            TraceHTTPHeader(key: "X-Trace-Note", value: "Certificate pinning detected")
        ]
        XCTAssertEqual(request.tlsPassthroughReason, "Certificate pinning detected")

        // Test fallback to status message
        request.requestHeaders = []
        XCTAssertEqual(request.tlsPassthroughReason, "TLS Passthrough")

        // Test non-passthrough request
        let nonPassthrough = NetworkRequest.sample(method: .get)
        XCTAssertNil(nonPassthrough.tlsPassthroughReason)
    }

    func testIsPinningLikely() {
        var request = NetworkRequest.sample(method: .connect, statusMessage: "TLS Passthrough")

        // Test explicit pinning detection
        request.requestHeaders = [
            TraceHTTPHeader(key: "X-Trace-Note", value: "Certificate pinning detected")
        ]
        XCTAssertTrue(request.isPinningLikely)

        request.requestHeaders = [
            TraceHTTPHeader(key: "X-Trace-Note", value: "Possible_pinning_or_strict_trust")
        ]
        XCTAssertTrue(request.isPinningLikely)

        // Test non-pinning passthrough
        request.requestHeaders = [
            TraceHTTPHeader(key: "X-Trace-Note", value: "Root CA not trusted")
        ]
        XCTAssertFalse(request.isPinningLikely)

        // Test non-passthrough request
        let nonPassthrough = NetworkRequest.sample(method: .get)
        XCTAssertFalse(nonPassthrough.isPinningLikely)
    }

    // MARK: - Reliability Detection Tests

    func testIsFailed() {
        var request = NetworkRequest.sample

        // Test server error
        request.statusCode = 500
        XCTAssertTrue(request.isFailed)

        request.statusCode = 502
        XCTAssertTrue(request.isFailed)

        // Test missing status with negligible duration
        let missingStatusFast = NetworkRequest.sample(statusCode: nil, duration: 0.05)
        XCTAssertTrue(missingStatusFast.isFailed)

        // Test successful response
        request.statusCode = 200
        XCTAssertFalse(request.isFailed)

        // Test TLS passthrough is not a failure
        let tlsPassthrough = NetworkRequest.sample(method: .connect, statusCode: nil, statusMessage: "TLS Passthrough")
        XCTAssertFalse(tlsPassthrough.isFailed)
    }

    func testDidTimeout() {
        // Test timeout condition
        let timedOut = NetworkRequest.sample(statusCode: nil, duration: 35.0)
        XCTAssertTrue(timedOut.didTimeout)

        // Test non-timeout conditions
        let completed = NetworkRequest.sample(statusCode: 200, duration: 35.0)
        XCTAssertFalse(completed.didTimeout)

        let shortPending = NetworkRequest.sample(statusCode: nil, duration: 5.0)
        XCTAssertFalse(shortPending.didTimeout)
    }

    // MARK: - Performance Detection Tests

    func testStallDuration() {
        var request = NetworkRequest.sample

        // Test with timing phases showing high TTFB
        request.timingPhases = NetworkTimingPhases(
            dnsLookup: 0.1,
            tcpConnection: 0.2,
            tlsHandshake: 0.3,
            ttfb: 3.5,
            contentDownload: 0.5
        )
        XCTAssertEqual(request.stallDuration, 3.5)

        // Test with normal TTFB
        request.timingPhases = NetworkTimingPhases(
            dnsLookup: 0.1,
            tcpConnection: 0.2,
            tlsHandshake: 0.3,
            ttfb: 1.0,
            contentDownload: 0.5
        )
        XCTAssertNil(request.stallDuration)

        // Test without timing phases
        request.timingPhases = nil
        XCTAssertNil(request.stallDuration)
    }

    // MARK: - Caching Detection Tests

    func testIsCached() {
        var request = NetworkRequest.sample

        // Test with max-age and Age header
        request.responseHeaders = [
            TraceHTTPHeader(key: "Cache-Control", value: "max-age=3600"),
            TraceHTTPHeader(key: "Age", value: "300")
        ]
        XCTAssertTrue(request.isCached)

        // Test with X-Cache hit
        request.responseHeaders = [
            TraceHTTPHeader(key: "X-Cache", value: "HIT from cloudflare")
        ]
        XCTAssertTrue(request.isCached)

        // Test non-cached response
        request.responseHeaders = [
            TraceHTTPHeader(key: "Cache-Control", value: "no-cache")
        ]
        XCTAssertFalse(request.isCached)
    }

    func testCacheSource() {
        var request = NetworkRequest.sample

        // Test Cloudflare cache
        request.responseHeaders = [
            TraceHTTPHeader(key: "X-Cache", value: "HIT from cloudflare"),
            TraceHTTPHeader(key: "Cache-Control", value: "max-age=3600"),
            TraceHTTPHeader(key: "Age", value: "300")
        ]
        XCTAssertEqual(request.cacheSource, "Cloudflare ")

        // Test CDN cache
        request.responseHeaders = [
            TraceHTTPHeader(key: "X-Cache", value: "HIT"),
            TraceHTTPHeader(key: "Age", value: "300")
        ]
        XCTAssertEqual(request.cacheSource, "CDN ")

        // Test HTTP cache
        request.responseHeaders = [
            TraceHTTPHeader(key: "Cache-Control", value: "max-age=3600"),
            TraceHTTPHeader(key: "Age", value: "300")
        ]
        XCTAssertEqual(request.cacheSource, "HTTP ")

        // Test non-cached response
        request.responseHeaders = []
        XCTAssertNil(request.cacheSource)
    }

    func testIsStale() {
        var request = NetworkRequest.sample

        // Test stale-while-revalidate
        request.responseHeaders = [
            TraceHTTPHeader(key: "Cache-Control", value: "max-age=3600, stale-while-revalidate=60"),
            TraceHTTPHeader(key: "Age", value: "300")
        ]
        XCTAssertTrue(request.isStale)

        // Non-cached responses should not be marked stale just because directives exist.
        request.responseHeaders = [
            TraceHTTPHeader(key: "Cache-Control", value: "max-age=3600, stale-while-revalidate=60")
        ]
        XCTAssertFalse(request.isStale)

        // Test Warning 110
        request.responseHeaders = [
            TraceHTTPHeader(key: "Warning", value: "110 - Response is Stale")
        ]
        XCTAssertTrue(request.isStale)

        // Test non-stale cached response
        request.responseHeaders = [
            TraceHTTPHeader(key: "Cache-Control", value: "max-age=3600"),
            TraceHTTPHeader(key: "Age", value: "300")
        ]
        XCTAssertFalse(request.isStale)
    }

    func testRedirectCount() {
        var request = NetworkRequest.sample

        // Test with redirect chain
        request.redirectChain = [
            RedirectInfo(fromURL: "https://example.com", toURL: "https://www.example.com", statusCode: 301, location: nil),
            RedirectInfo(fromURL: "https://www.example.com", toURL: "https://www.example.com/page", statusCode: 302, location: nil)
        ]
        XCTAssertEqual(request.redirectCount, 2)

        // Test with redirect status code
        request.redirectChain = []
        request.statusCode = 302
        XCTAssertEqual(request.redirectCount, 1)

        // Test with no redirects
        request.statusCode = 200
        XCTAssertEqual(request.redirectCount, 0)
    }

    // MARK: - Analysis Detection Tests

    func testIsBinary() {
        var request = NetworkRequest.sample

        // Test image types
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "image/png")
        ]
        XCTAssertTrue(request.isBinary)

        // Test SVG is not binary
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "image/svg+xml")
        ]
        XCTAssertFalse(request.isBinary)

        // Test video
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "video/mp4")
        ]
        XCTAssertTrue(request.isBinary)

        // Test octet-stream
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/octet-stream")
        ]
        XCTAssertTrue(request.isBinary)

        // Test text types
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "text/html")
        ]
        XCTAssertFalse(request.isBinary)

        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "application/json")
        ]
        XCTAssertFalse(request.isBinary)
    }

    // MARK: - Tag Generation Tests

    func testGetAllTags() {
        var request = NetworkRequest.sample(duration: 6.0)

        // Setup a request with multiple tag conditions
        request.protocolVersion = .http3
        request.wasBlocked = true
        request.statusCode = 500
        request.responseHeaders = [
            TraceHTTPHeader(key: "Content-Type", value: "image/png")
        ]

        let tags = request.getAllTags()

        XCTAssertTrue(tags.contains(where: {
            if case .h3 = $0 { return true }
            return false
        }))
        XCTAssertTrue(tags.contains(where: {
            if case .blocked = $0 { return true }
            return false
        }))
        XCTAssertTrue(tags.contains(where: {
            if case .failed = $0 { return true }
            return false
        }))
        XCTAssertTrue(tags.contains(where: {
            if case .slow = $0 { return true }
            return false
        }))
        XCTAssertTrue(tags.contains(where: {
            if case .binary = $0 { return true }
            return false
        }))
    }

    func testGetVisibleTags() {
        var request = NetworkRequest.sample(duration: 6.0)

        // Setup a request with many tags
        request.protocolVersion = .http3
        request.wasBlocked = true
        request.statusCode = 500
        request.isMocked = true

        let (visible, overflow) = request.getVisibleTags(maxVisible: 3)

        XCTAssertEqual(visible.count, 3)
        XCTAssertGreaterThan(overflow, 0)
    }

    // MARK: - Edge Cases

    func testEmptyURL() {
        var request = NetworkRequest.sample
        request.url = ""

        XCTAssertFalse(request.isGraphQL)
    }

    func testMissingHeaders() {
        var request = NetworkRequest.sample
        request.responseHeaders = []

        XCTAssertFalse(request.isWebSocket)
        XCTAssertFalse(request.isGRPC)
        XCTAssertFalse(request.isCached)
        XCTAssertNil(request.cacheSource)
    }

    func testCaseInsensitiveHeaders() {
        var request = NetworkRequest.sample

        // Test WebSocket with mixed case
        request.statusCode = 101
        request.responseHeaders = [
            TraceHTTPHeader(key: "UPGRADE", value: "WebSocket")
        ]
        XCTAssertTrue(request.isWebSocket)

        // Test cache detection with mixed case
        request.responseHeaders = [
            TraceHTTPHeader(key: "x-cache", value: "hit from cloudflare")
        ]
        XCTAssertTrue(request.isCached)
    }
}
