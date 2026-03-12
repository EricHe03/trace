//
//  Interception.swift
//  TraceCore
//
//  Created by Justin on 2026/01/13.
//

import Foundation

/// Result of request interception.
///
/// - Important: This lives in `TraceCore` so both `TraceProxy` and `TraceSecurity` can use it
///   without introducing a dependency cycle.
public enum InterceptionResult: Sendable {
    /// Request should be blocked.
    case blocked

    /// Request should fail with a simulated network error.
    case failed(RequestInterceptionFailure)

    /// Return a mock response (the returned `NetworkRequest` includes response fields).
    case mocked(NetworkRequest)

    /// Continue with potentially modified request.
    case modified(NetworkRequest)
}

public enum RequestInterceptionFailure: String, Sendable {
    case timeout
    case connectionReset
    case dropConnection
    case packetLoss
}

/// Response handling strategy for a given request URL.
public enum ResponsePipeline: Sendable {
    /// Buffer the full response (or up to internal limits) and run response interception before sending to client.
    case bufferAndIntercept
    /// Stream response to client immediately while capturing a bounded buffer for UI.
    case streamAndCapture
}

/// A provider that can intercept HTTP requests/responses and stream events
/// (rewrite, scripts, breakpoints, mocks, replay, etc).
///
/// Implementations are expected to be concurrency-safe (`Sendable`). The primary implementation is
/// `RequestInterceptor` (in `TraceProxy`).
public protocol InterceptionProviding: Sendable {
    /// Intercept an outgoing request before it is sent to the server.
    func interceptRequest(
        flowId: UUID,
        url: String,
        method: String,
        headers: [String: String],
        body: Data?
    ) async -> InterceptionResult

    /// Intercept an incoming response before it is returned to the client.
    func interceptResponse(
        request: NetworkRequest,
        statusCode: Int,
        statusMessage: String,
        headers: [TraceHTTPHeader],
        body: Data?
    ) async -> NetworkRequest

    /// Decide whether responses for a given URL should be buffered (for modification/breakpoints/delay)
    /// or streamed (for performance).
    func responsePipeline(for url: String) async -> ResponsePipeline

    /// Intercept a stream session open lifecycle event.
    func interceptStreamOpen(session: StreamSession) async -> StreamInterceptionDecision

    /// Intercept a stream event (SSE/WebSocket).
    func interceptStreamEvent(session: StreamSession, event: StreamEvent) async -> StreamInterceptionDecision

    /// Intercept a stream close lifecycle event.
    func interceptStreamClose(session: StreamSession, reason: String?) async -> StreamInterceptionDecision

    /// Returns `true` when interception features are active and the TLS MITM layer should prefer
    /// negotiating HTTP/1.1 (to ensure request/response modification feature parity).
    ///
    /// - Note: This is evaluated during TLS handshake, before any specific request URL is known.
    ///   Implementations should treat this as a coarse "global interception is on" signal.
    func requiresHTTP1Interception() async -> Bool
}

public extension InterceptionProviding {
    func responsePipeline(for _: String) async -> ResponsePipeline {
        .bufferAndIntercept
    }

    func interceptStreamOpen(session _: StreamSession) async -> StreamInterceptionDecision {
        .forward
    }

    func interceptStreamEvent(session _: StreamSession, event _: StreamEvent) async -> StreamInterceptionDecision {
        .forward
    }

    func interceptStreamClose(session _: StreamSession, reason _: String?) async -> StreamInterceptionDecision {
        .forward
    }

    func requiresHTTP1Interception() async -> Bool {
        // Backwards-compatible default: if an interceptor is present and doesn't provide a more
        // precise signal, assume interception is active and prefer HTTP/1.1 for correctness.
        true
    }
}
