//
//  ProxyNetworkMetricsTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceProxy

final class ProxyNetworkMetricsTests: XCTestCase {

    // MARK: - Initial State Tests

    func testInitialMetrics() async {
        let metrics = await ProxyNetworkMetrics.shared.getAllMetrics()

        // Initial packet metrics
        XCTAssertGreaterThanOrEqual(metrics.packet.forwarded, 0)
        XCTAssertGreaterThanOrEqual(metrics.packet.quicDropped, 0)
        XCTAssertGreaterThanOrEqual(metrics.packet.mitmBypassed, 0)
        XCTAssertGreaterThanOrEqual(metrics.packet.mitmIntercepted, 0)

        // Initial HTTP metrics
        XCTAssertGreaterThanOrEqual(metrics.http.requestsParsed, 0)
        XCTAssertGreaterThanOrEqual(metrics.http.responsesParsed, 0)
        XCTAssertGreaterThanOrEqual(metrics.http.transactionsCompleted, 0)
        XCTAssertGreaterThanOrEqual(metrics.http.parseFailures, 0)
        XCTAssertGreaterThanOrEqual(metrics.http.activeTransactions, 0)

        // Initial HTTP/2 metrics
        XCTAssertGreaterThanOrEqual(metrics.http2.framesParsed, 0)
        XCTAssertGreaterThanOrEqual(metrics.http2.protocolErrors, 0)
        XCTAssertGreaterThanOrEqual(metrics.http2.streamsCreated, 0)
        XCTAssertGreaterThanOrEqual(metrics.http2.streamsActive, 0)

        // Uptime should be positive
        XCTAssertGreaterThanOrEqual(metrics.uptimeSeconds, 0)
    }

    // MARK: - Packet Metrics Tests

    func testRecordPacketForwarded() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordPacketForwarded()
        await ProxyNetworkMetrics.shared.recordPacketForwarded()

        let metrics = await ProxyNetworkMetrics.shared.getPacketMetrics()
        XCTAssertEqual(metrics.forwarded, 2)
    }

    func testRecordQUICPacketDropped() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordQUICPacketDropped()
        await ProxyNetworkMetrics.shared.recordQUICPacketDropped()
        await ProxyNetworkMetrics.shared.recordQUICPacketDropped()

        let metrics = await ProxyNetworkMetrics.shared.getPacketMetrics()
        XCTAssertEqual(metrics.quicDropped, 3)
    }

    func testRecordMITMBypassed() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordMITMBypassed()

        let metrics = await ProxyNetworkMetrics.shared.getPacketMetrics()
        XCTAssertEqual(metrics.mitmBypassed, 1)
    }

    func testRecordMITMIntercepted() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordMITMIntercepted()
        await ProxyNetworkMetrics.shared.recordMITMIntercepted()

        let metrics = await ProxyNetworkMetrics.shared.getPacketMetrics()
        XCTAssertEqual(metrics.mitmIntercepted, 2)
    }

    // MARK: - HTTP Metrics Tests

    func testRecordHTTPRequestParsed() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTPRequestParsed()
        await ProxyNetworkMetrics.shared.recordHTTPRequestParsed()

        let metrics = await ProxyNetworkMetrics.shared.getHTTPMetrics()
        XCTAssertEqual(metrics.requestsParsed, 2)
    }

    func testRecordHTTPResponseParsed() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
        await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
        await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()

        let metrics = await ProxyNetworkMetrics.shared.getHTTPMetrics()
        XCTAssertEqual(metrics.responsesParsed, 3)
    }

    func testRecordHTTPTransactionCompleted() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()

        let metrics = await ProxyNetworkMetrics.shared.getHTTPMetrics()
        XCTAssertEqual(metrics.transactionsCompleted, 1)
    }

    func testRecordHTTPParseFailure() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTPParseFailure()
        await ProxyNetworkMetrics.shared.recordHTTPParseFailure()

        let metrics = await ProxyNetworkMetrics.shared.getHTTPMetrics()
        XCTAssertEqual(metrics.parseFailures, 2)
    }

    func testUpdateActiveTransactions() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.updateActiveTransactions(5)

        let metrics = await ProxyNetworkMetrics.shared.getHTTPMetrics()
        XCTAssertEqual(metrics.activeTransactions, 5)
    }

    // MARK: - HTTP/2 Metrics Tests

    func testRecordHTTP2FrameParsed() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed()
        await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed()
        await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed()

        let metrics = await ProxyNetworkMetrics.shared.getHTTP2Metrics()
        XCTAssertEqual(metrics.framesParsed, 3)
    }

    func testRecordHTTP2ProtocolError() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTP2ProtocolError()

        let metrics = await ProxyNetworkMetrics.shared.getHTTP2Metrics()
        XCTAssertEqual(metrics.protocolErrors, 1)
    }

    func testRecordHTTP2StreamCreated() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTP2StreamCreated()
        await ProxyNetworkMetrics.shared.recordHTTP2StreamCreated()

        let metrics = await ProxyNetworkMetrics.shared.getHTTP2Metrics()
        XCTAssertEqual(metrics.streamsCreated, 2)
        XCTAssertEqual(metrics.streamsActive, 2)
    }

    func testRecordHTTP2StreamClosed() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTP2StreamCreated()
        await ProxyNetworkMetrics.shared.recordHTTP2StreamCreated()
        await ProxyNetworkMetrics.shared.recordHTTP2StreamClosed()

        let metrics = await ProxyNetworkMetrics.shared.getHTTP2Metrics()
        XCTAssertEqual(metrics.streamsCreated, 2)
        XCTAssertEqual(metrics.streamsActive, 1)
    }

    func testRecordHTTP2StreamClosedDoesNotGoNegative() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordHTTP2StreamClosed()
        await ProxyNetworkMetrics.shared.recordHTTP2StreamClosed()

        let metrics = await ProxyNetworkMetrics.shared.getHTTP2Metrics()
        XCTAssertEqual(metrics.streamsActive, 0)
    }

    func testUpdateHTTP2StreamsActive() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.updateHTTP2StreamsActive(10)

        let metrics = await ProxyNetworkMetrics.shared.getHTTP2Metrics()
        XCTAssertEqual(metrics.streamsActive, 10)
    }

    // MARK: - Reset Tests

    func testResetClearsAllMetrics() async {
        await ProxyNetworkMetrics.shared.reset()

        // Record some metrics
        await ProxyNetworkMetrics.shared.recordPacketForwarded()
        await ProxyNetworkMetrics.shared.recordHTTPRequestParsed()
        await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed()

        // Reset
        await ProxyNetworkMetrics.shared.reset()

        let metrics = await ProxyNetworkMetrics.shared.getAllMetrics()

        XCTAssertEqual(metrics.packet.forwarded, 0)
        XCTAssertEqual(metrics.http.requestsParsed, 0)
        XCTAssertEqual(metrics.http2.framesParsed, 0)
    }

    // MARK: - Format Summary Tests

    func testFormatSummary() async {
        await ProxyNetworkMetrics.shared.reset()

        await ProxyNetworkMetrics.shared.recordPacketForwarded()
        await ProxyNetworkMetrics.shared.recordHTTPRequestParsed()
        await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed()

        let metrics = await ProxyNetworkMetrics.shared.getAllMetrics()
        let summary = metrics.formatSummary()

        XCTAssertTrue(summary.contains("Proxy Metrics"))
        XCTAssertTrue(summary.contains("Uptime"))
        XCTAssertTrue(summary.contains("Packets"))
        XCTAssertTrue(summary.contains("HTTP"))
        XCTAssertTrue(summary.contains("HTTP/2"))
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentAccess() async {
        await ProxyNetworkMetrics.shared.reset()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await ProxyNetworkMetrics.shared.recordPacketForwarded()
                }
                group.addTask {
                    await ProxyNetworkMetrics.shared.recordHTTPRequestParsed()
                }
                group.addTask {
                    await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed()
                }
            }
        }

        let metrics = await ProxyNetworkMetrics.shared.getAllMetrics()

        XCTAssertEqual(metrics.packet.forwarded, 100)
        XCTAssertEqual(metrics.http.requestsParsed, 100)
        XCTAssertEqual(metrics.http2.framesParsed, 100)
    }
}
