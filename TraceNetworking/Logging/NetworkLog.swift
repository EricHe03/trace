//
//  NetworkLog.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/11.
//

import OSLog
import TraceCore

// MARK: - Networking Module Logging

/// Defines the networking module logging namespace for Trace Logging Standard v1.0.
///
/// **Subsystem:** `com.trace.TraceNetworking`
///
/// ## Categories
/// | Logger | Category | Use Case |
/// |--------|----------|----------|
/// | `http` | Networking.HTTP | HTTP/1.x requests and responses |
/// | `http2` | Networking.HTTP2 | HTTP/2 streams and multiplexing |
/// | `sse` | Networking.SSE | Server-Sent Events streaming |
/// | `webSocket` | Networking.WebSocket | WebSocket connections |
/// | `dns` | Networking.DNS | DNS resolution |
///
/// ## Usage
/// ```swift
/// // Request lifecycle
/// NetworkLog.http.debug("event=http.request_start method=\(method, privacy: .public) path=\(path, privacy: .private)")
/// NetworkLog.http.info("event=http.request_complete outcome=success status=\(status) duration_ms=\(elapsed)")
///
/// // HTTP/2 streams
/// NetworkLog.http2.debug("event=http2.stream_open stream_id=\(streamId, privacy: .public)")
/// NetworkLog.http2.info("event=http2.stream_close outcome=success stream_id=\(streamId)")
///
/// // SSE streaming
/// NetworkLog.sse.info("event=sse.connection_open url=\(url, privacy: .private(mask: .hash))")
/// NetworkLog.sse.debug("event=sse.event_received type=\(eventType, privacy: .public)")
/// ```
///
/// ## Privacy Guidelines
/// - HTTP methods, status codes, content-types: `.public`
/// - Full URLs with query params: `.private` or `.private(mask: .hash)`
/// - Headers: Never log full headers; log specific safe ones as `.public`
/// - Request/response bodies: Never log; use size/hash instead
/// - Stream IDs, connection IDs: `.public`
///
/// ## Console Filtering
/// ```
/// subsystem:com.trace.TraceNetworking category:Networking.HTTP
/// ```
public enum NetworkLog {
    /// Provides the HTTP/1.x request/response logger.
    ///
    /// Log levels:
    /// - `.info`: Request complete (success or known failure status)
    /// - `.error`: Connection failed, timeout, parse error
    /// - `.debug`: Request start, header details, body transfer
    public static let http = TraceLog.make(
        module: .networking,
        category: .networkingHTTP
    )

    /// Provides the HTTP/2 multiplexed streams logger.
    ///
    /// Log levels:
    /// - `.info`: Stream opened/closed, connection established
    /// - `.error`: Stream reset, connection error, GOAWAY
    /// - `.debug`: Frame details, flow control, HPACK
    public static let http2 = TraceLog.make(
        module: .networking,
        category: .networkingHTTP2
    )

    /// Provides the Server-Sent Events streaming logger.
    ///
    /// Log levels:
    /// - `.info`: Connection opened/closed
    /// - `.warning`: Reconnection triggered
    /// - `.error`: Connection failed, parse error
    /// - `.debug`: Individual events received (rate-limit in hot paths)
    public static let sse = TraceLog.make(
        module: .networking,
        category: .networkingSSE
    )

    /// Provides the WebSocket connections logger.
    ///
    /// Log levels:
    /// - `.info`: Connection opened/closed
    /// - `.warning`: Unexpected close, reconnection
    /// - `.error`: Handshake failed, connection error
    /// - `.debug`: Frame details, ping/pong
    public static let webSocket = TraceLog.make(
        module: .networking,
        category: .networkingWebSocket
    )

    /// Provides the DNS resolution logger.
    ///
    /// Log levels:
    /// - `.info`: Resolution complete
    /// - `.error`: Resolution failed
    /// - `.debug`: Query details, cache hits
    public static let dns = TraceLog.make(
        module: .networking,
        category: .networkingDNS
    )
}

// MARK: - Networking Event Domains

/// Defines pre-built event builders for common networking operations.
public extension LogEvent {
    /// Creates an HTTP event.
    /// - Parameter action: The action (e.g., "request_start", "request_complete", "response_parse")
    static func http(_ action: String) -> LogEvent {
        LogEvent(domain: "http", action: action)
    }

    /// Creates an HTTP/2 event.
    /// - Parameter action: The action (e.g., "stream_open", "stream_close", "frame_send")
    static func http2(_ action: String) -> LogEvent {
        LogEvent(domain: "http2", action: action)
    }

    /// Creates an SSE event.
    /// - Parameter action: The action (e.g., "connection_open", "event_received", "reconnect")
    static func sse(_ action: String) -> LogEvent {
        LogEvent(domain: "sse", action: action)
    }

    /// Creates a WebSocket event.
    /// - Parameter action: The action (e.g., "connection_open", "message_received", "close")
    static func webSocket(_ action: String) -> LogEvent {
        LogEvent(domain: "websocket", action: action)
    }

    /// Creates a DNS event.
    /// - Parameter action: The action (e.g., "resolve", "cache_hit", "cache_miss")
    static func dns(_ action: String) -> LogEvent {
        LogEvent(domain: "dns", action: action)
    }
}
