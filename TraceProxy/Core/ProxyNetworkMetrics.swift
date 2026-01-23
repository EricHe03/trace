//
//  ProxyNetworkMetrics.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Tracks network-related metrics for debugging and diagnostics.
/// Focuses on HTTP/HTTPS proxy metrics updated from multiple connection contexts.
public actor ProxyNetworkMetrics {
    public static let shared = ProxyNetworkMetrics()

    // MARK: - Packet Metrics

    private var packetsForwarded: Int = 0
    private var quicPacketsDropped: Int = 0
    private var mitmBypassed: Int = 0
    private var mitmIntercepted: Int = 0

    // MARK: - HTTP Metrics

    private var httpRequestsParsed: Int = 0
    private var httpResponsesParsed: Int = 0
    private var httpTransactionsCompleted: Int = 0
    private var httpParseFailures: Int = 0
    private var activeTransactions: Int = 0

    // MARK: - HTTP/2 Metrics

    private var http2FramesParsed: Int = 0
    private var http2ProtocolErrors: Int = 0
    private var http2StreamsCreated: Int = 0
    private var http2StreamsActive: Int = 0

    private var lastResetTime: Date = .init()

    // MARK: - Packet Metrics Recording

    func recordPacketForwarded() {
        packetsForwarded += 1
    }

    func recordQUICPacketDropped() {
        quicPacketsDropped += 1
    }

    func recordMITMBypassed() {
        mitmBypassed += 1
    }

    func recordMITMIntercepted() {
        mitmIntercepted += 1
    }

    // MARK: - HTTP Metrics Recording

    func recordHTTPRequestParsed() {
        httpRequestsParsed += 1
    }

    func recordHTTPResponseParsed() {
        httpResponsesParsed += 1
    }

    func recordHTTPTransactionCompleted() {
        httpTransactionsCompleted += 1
    }

    func recordHTTPParseFailure() {
        httpParseFailures += 1
    }

    func updateActiveTransactions(_ count: Int) {
        activeTransactions = count
    }

    // MARK: - HTTP/2 Metrics Recording

    func recordHTTP2FrameParsed() {
        http2FramesParsed += 1
    }

    func recordHTTP2ProtocolError() {
        http2ProtocolErrors += 1
    }

    func recordHTTP2StreamCreated() {
        http2StreamsCreated += 1
        http2StreamsActive += 1
    }

    func recordHTTP2StreamClosed() {
        http2StreamsActive = max(0, http2StreamsActive - 1)
    }

    func updateHTTP2StreamsActive(_ count: Int) {
        http2StreamsActive = count
    }

    // MARK: - Query Methods

    func getPacketMetrics() -> PacketMetrics {
        PacketMetrics(
            forwarded: packetsForwarded,
            quicDropped: quicPacketsDropped,
            mitmBypassed: mitmBypassed,
            mitmIntercepted: mitmIntercepted
        )
    }

    func getHTTPMetrics() -> HTTPMetrics {
        HTTPMetrics(
            requestsParsed: httpRequestsParsed,
            responsesParsed: httpResponsesParsed,
            transactionsCompleted: httpTransactionsCompleted,
            parseFailures: httpParseFailures,
            activeTransactions: activeTransactions
        )
    }

    func getHTTP2Metrics() -> HTTP2Metrics {
        HTTP2Metrics(
            framesParsed: http2FramesParsed,
            protocolErrors: http2ProtocolErrors,
            streamsCreated: http2StreamsCreated,
            streamsActive: http2StreamsActive
        )
    }

    /// Returns a snapshot of all current metrics in a single value for logging or UI.
    public func getAllMetrics() -> AllMetrics {
        AllMetrics(
            packet: getPacketMetrics(),
            http: getHTTPMetrics(),
            http2: getHTTP2Metrics(),
            uptimeSeconds: Date().timeIntervalSince(lastResetTime)
        )
    }

    /// Resets counters and restarts uptime tracking.
    func reset() {
        packetsForwarded = 0
        quicPacketsDropped = 0
        mitmBypassed = 0
        mitmIntercepted = 0

        httpRequestsParsed = 0
        httpResponsesParsed = 0
        httpTransactionsCompleted = 0
        httpParseFailures = 0
        activeTransactions = 0

        http2FramesParsed = 0
        http2ProtocolErrors = 0
        http2StreamsCreated = 0
        http2StreamsActive = 0

        lastResetTime = Date()
    }

    // MARK: - Data Structures

    public struct PacketMetrics: Sendable {
        public let forwarded: Int
        public let quicDropped: Int
        public let mitmBypassed: Int
        public let mitmIntercepted: Int
    }

    public struct HTTPMetrics: Sendable {
        public let requestsParsed: Int
        public let responsesParsed: Int
        public let transactionsCompleted: Int
        public let parseFailures: Int
        public let activeTransactions: Int
    }

    public struct HTTP2Metrics: Sendable {
        public let framesParsed: Int
        public let protocolErrors: Int
        public let streamsCreated: Int
        public let streamsActive: Int
    }

    public struct AllMetrics: Sendable {
        public let packet: PacketMetrics
        public let http: HTTPMetrics
        public let http2: HTTP2Metrics
        public let uptimeSeconds: TimeInterval

        /// Produces a human-readable summary for log output.
        public func formatSummary() -> String {
            """
            === Proxy Metrics ===
            Uptime: \(String(format: "%.1f", uptimeSeconds))s

            Packets:
              Forwarded: \(packet.forwarded)
              QUIC dropped: \(packet.quicDropped)
              MITM intercepted: \(packet.mitmIntercepted)
              MITM bypassed: \(packet.mitmBypassed)

            HTTP:
              Requests parsed: \(http.requestsParsed)
              Responses parsed: \(http.responsesParsed)
              Transactions complete: \(http.transactionsCompleted)
              Parse failures: \(http.parseFailures)
              Active transactions: \(http.activeTransactions)

            HTTP/2:
              Frames parsed: \(http2.framesParsed)
              Protocol errors: \(http2.protocolErrors)
              Streams created: \(http2.streamsCreated)
              Streams active: \(http2.streamsActive)
            """
        }
    }
}
