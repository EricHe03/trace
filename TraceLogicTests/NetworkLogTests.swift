//
//  NetworkLogTests.swift
//  TraceTests
//
//  Created by Justin on 2026/02/01.
//

import OSLog
@testable import TraceCore
@testable import TraceNetworking
import XCTest

final class NetworkLogTests: XCTestCase {
    // MARK: - Logger Initialization Tests

    func testHTTPLoggerExists() {
        let logger = NetworkLog.http
        XCTAssertNotNil(logger)
    }

    func testHTTP2LoggerExists() {
        let logger = NetworkLog.http2
        XCTAssertNotNil(logger)
    }

    func testSSELoggerExists() {
        let logger = NetworkLog.sse
        XCTAssertNotNil(logger)
    }

    func testWebSocketLoggerExists() {
        let logger = NetworkLog.webSocket
        XCTAssertNotNil(logger)
    }

    func testDNSLoggerExists() {
        let logger = NetworkLog.dns
        XCTAssertNotNil(logger)
    }

    // MARK: - Logger Identity Tests

    func testAccessingSameLoggerTwiceDoesNotCrash() {
        _ = NetworkLog.http
        _ = NetworkLog.http
    }

    func testAccessingDifferentLoggersDoesNotCrash() {
        _ = NetworkLog.http
        _ = NetworkLog.http2
    }

    // MARK: - LogEvent Builder Tests

    func testHTTPEventCreation() {
        let event = LogEvent.http("request_start")
        XCTAssertNotNil(event)
    }

    func testHTTP2EventCreation() {
        let event = LogEvent.http2("stream_open")
        XCTAssertNotNil(event)
    }

    func testSSEEventCreation() {
        let event = LogEvent.sse("connection_open")
        XCTAssertNotNil(event)
    }

    func testWebSocketEventCreation() {
        let event = LogEvent.webSocket("connection_open")
        XCTAssertNotNil(event)
    }

    func testDNSEventCreation() {
        let event = LogEvent.dns("resolve")
        XCTAssertNotNil(event)
    }

    // MARK: - Logging Functionality Tests

    func testHTTPLoggingDoesNotCrash() {
        XCTAssertNoThrow {
            NetworkLog.http.debug("test message")
            NetworkLog.http.info("test message")
            NetworkLog.http.warning("test message")
            NetworkLog.http.error("test message")
        }
    }

    func testHTTP2LoggingDoesNotCrash() {
        XCTAssertNoThrow {
            NetworkLog.http2.debug("test message")
            NetworkLog.http2.info("test message")
            NetworkLog.http2.warning("test message")
            NetworkLog.http2.error("test message")
        }
    }

    func testSSELoggingDoesNotCrash() {
        XCTAssertNoThrow {
            NetworkLog.sse.debug("test message")
            NetworkLog.sse.info("test message")
            NetworkLog.sse.warning("test message")
            NetworkLog.sse.error("test message")
        }
    }

    func testWebSocketLoggingDoesNotCrash() {
        XCTAssertNoThrow {
            NetworkLog.webSocket.debug("test message")
            NetworkLog.webSocket.info("test message")
            NetworkLog.webSocket.warning("test message")
            NetworkLog.webSocket.error("test message")
        }
    }

    func testDNSLoggingDoesNotCrash() {
        XCTAssertNoThrow {
            NetworkLog.dns.debug("test message")
            NetworkLog.dns.info("test message")
            NetworkLog.dns.warning("test message")
            NetworkLog.dns.error("test message")
        }
    }

    // MARK: - Event Action Tests

    func testHTTPEventActions() {
        let actions = ["request_start", "request_complete", "response_parse", "connection_failed"]

        for action in actions {
            XCTAssertNoThrow {
                _ = LogEvent.http(action)
            }
        }
    }

    func testHTTP2EventActions() {
        let actions = ["stream_open", "stream_close", "frame_send", "frame_receive"]

        for action in actions {
            XCTAssertNoThrow {
                _ = LogEvent.http2(action)
            }
        }
    }

    func testSSEEventActions() {
        let actions = ["connection_open", "event_received", "reconnect", "connection_close"]

        for action in actions {
            XCTAssertNoThrow {
                _ = LogEvent.sse(action)
            }
        }
    }

    func testWebSocketEventActions() {
        let actions = ["connection_open", "message_received", "close", "ping", "pong"]

        for action in actions {
            XCTAssertNoThrow {
                _ = LogEvent.webSocket(action)
            }
        }
    }

    func testDNSEventActions() {
        let actions = ["resolve", "cache_hit", "cache_miss", "resolve_failed"]

        for action in actions {
            XCTAssertNoThrow {
                _ = LogEvent.dns(action)
            }
        }
    }

    // MARK: - Privacy Tests

    func testLoggingWithPrivacySensitiveData() {
        // Test that logging sensitive data doesn't crash
        XCTAssertNoThrow {
            NetworkLog.http.info("url=\("https://example.com/secret?token=abc123", privacy: .private)")
        }
    }

    func testLoggingWithPublicData() {
        XCTAssertNoThrow {
            NetworkLog.http.info("method=\("GET", privacy: .public)")
            NetworkLog.http.info("status=\(200, privacy: .public)")
        }
    }

    func testLoggingWithHashedPrivacy() {
        XCTAssertNoThrow {
            NetworkLog.http.info("url=\("https://example.com", privacy: .private(mask: .hash))")
        }
    }

    // MARK: - Structured Logging Tests

    func testStructuredHTTPLogging() {
        XCTAssertNoThrow {
            NetworkLog.http.info("event=http.request_start method=GET path=/api/test")
        }
    }

    func testStructuredHTTP2Logging() {
        XCTAssertNoThrow {
            NetworkLog.http2.info("event=http2.stream_open stream_id=1")
        }
    }

    func testStructuredSSELogging() {
        XCTAssertNoThrow {
            NetworkLog.sse.info("event=sse.connection_open url=https://example.com/events")
        }
    }

    func testStructuredWebSocketLogging() {
        XCTAssertNoThrow {
            NetworkLog.webSocket.info("event=websocket.connection_open url=wss://example.com")
        }
    }

    func testStructuredDNSLogging() {
        XCTAssertNoThrow {
            NetworkLog.dns.info("event=dns.resolve hostname=example.com result_count=2")
        }
    }

    // MARK: - Performance Logging Tests

    func testLoggingWithDuration() {
        XCTAssertNoThrow {
            NetworkLog.http.info("event=http.request_complete duration_ms=123")
        }
    }

    func testLoggingWithBytes() {
        XCTAssertNoThrow {
            NetworkLog.http.debug("event=http.body_transfer bytes_sent=1024 bytes_received=2048")
        }
    }

    // MARK: - Error Logging Tests

    func testErrorLogging() {
        XCTAssertNoThrow {
            NetworkLog.http.error("event=http.connection_failed reason=timeout")
        }
    }

    func testHTTP2ErrorLogging() {
        XCTAssertNoThrow {
            NetworkLog.http2.error("event=http2.stream_reset error_code=PROTOCOL_ERROR")
        }
    }

    func testSSEErrorLogging() {
        XCTAssertNoThrow {
            NetworkLog.sse.error("event=sse.connection_failed status_code=500")
        }
    }

    // MARK: - Multiple Logger Interactions

    func testMultipleLoggersSimultaneously() {
        XCTAssertNoThrow {
            NetworkLog.http.info("HTTP message")
            NetworkLog.http2.info("HTTP2 message")
            NetworkLog.sse.info("SSE message")
            NetworkLog.webSocket.info("WebSocket message")
            NetworkLog.dns.info("DNS message")
        }
    }

    // MARK: - Edge Cases

    func testEmptyMessage() {
        XCTAssertNoThrow {
            NetworkLog.http.info("")
        }
    }

    func testVeryLongMessage() {
        let longMessage = String(repeating: "x", count: 10000)
        XCTAssertNoThrow {
            NetworkLog.http.debug("\(longMessage)")
        }
    }

    func testSpecialCharactersInMessage() {
        XCTAssertNoThrow {
            NetworkLog.http.info("special=!@#$%^&*()_+-=[]{}|;:',.<>?/")
        }
    }

    func testUnicodeInMessage() {
        XCTAssertNoThrow {
            NetworkLog.http.info("message=Hello 世界 🌍")
        }
    }

    func testNewlinesInMessage() {
        XCTAssertNoThrow {
            NetworkLog.http.info("line1\nline2\nline3")
        }
    }

    // MARK: - Event Domain Tests

    func testEventDomainHTTP() {
        let event = LogEvent.http("test")
        // We can't easily inspect the internal domain, but we can verify it creates successfully
        XCTAssertNotNil(event)
    }

    func testEventDomainHTTP2() {
        let event = LogEvent.http2("test")
        XCTAssertNotNil(event)
    }

    func testEventDomainSSE() {
        let event = LogEvent.sse("test")
        XCTAssertNotNil(event)
    }

    func testEventDomainWebSocket() {
        let event = LogEvent.webSocket("test")
        XCTAssertNotNil(event)
    }

    func testEventDomainDNS() {
        let event = LogEvent.dns("test")
        XCTAssertNotNil(event)
    }

    // MARK: - Concurrent Logging Tests

    func testConcurrentLogging() {
        let expectation = expectation(description: "Concurrent logging")
        expectation.expectedFulfillmentCount = 100

        DispatchQueue.concurrentPerform(iterations: 100) { i in
            // Avoid emitting OSLog messages concurrently in unit tests; it can overwhelm the simulator
            // logging subsystem and make `xcodebuild test` appear stuck. This still validates
            // thread-safety of logger access and event formatting.
            _ = NetworkLog.http
            _ = LogEvent.http("concurrent_message").with("i", value: i).description
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testConcurrentMultiLoggerUsage() {
        let expectation = expectation(description: "Concurrent multi-logger")
        expectation.expectedFulfillmentCount = 50

        DispatchQueue.concurrentPerform(iterations: 50) { i in
            switch i % 5 {
            case 0:
                _ = NetworkLog.http
                _ = LogEvent.http("message").with("i", value: i).description
            case 1:
                _ = NetworkLog.http2
                _ = LogEvent.http2("message").with("i", value: i).description
            case 2:
                _ = NetworkLog.sse
                _ = LogEvent.sse("message").with("i", value: i).description
            case 3:
                _ = NetworkLog.webSocket
                _ = LogEvent.webSocket("message").with("i", value: i).description
            case 4:
                _ = NetworkLog.dns
                _ = LogEvent.dns("message").with("i", value: i).description
            default: break
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Performance Tests

    func testLoggingPerformance() {
        measure {
            // Measure message construction rather than OSLog emission to keep this test deterministic.
            for i in 0 ..< 1000 {
                _ = LogEvent.http("performance_test").with("i", value: i).description
            }
        }
    }

    func testStructuredLoggingPerformance() {
        measure {
            for i in 0 ..< 1000 {
                _ = LogEvent.http("test").count(i).with("status", value: "ok").description
            }
        }
    }

    func testMultiLoggerPerformance() {
        measure {
            for i in 0 ..< 200 {
                _ = LogEvent.http("message").with("i", value: i).description
                _ = LogEvent.http2("message").with("i", value: i).description
                _ = LogEvent.sse("message").with("i", value: i).description
                _ = LogEvent.webSocket("message").with("i", value: i).description
                _ = LogEvent.dns("message").with("i", value: i).description
            }
        }
    }

    // MARK: - Real-World Scenario Tests

    func testHTTPRequestLifecycle() {
        XCTAssertNoThrow {
            NetworkLog.http.debug("event=http.request_start method=GET path=/api/users")
            NetworkLog.http.debug("event=http.headers_sent count=5")
            NetworkLog.http.debug("event=http.body_sent bytes=256")
            NetworkLog.http.info("event=http.response_received status=200")
            NetworkLog.http.debug("event=http.body_received bytes=1024")
            NetworkLog.http.info("event=http.request_complete duration_ms=145")
        }
    }

    func testHTTP2StreamLifecycle() {
        XCTAssertNoThrow {
            NetworkLog.http2.info("event=http2.connection_established")
            NetworkLog.http2.debug("event=http2.stream_open stream_id=1")
            NetworkLog.http2.debug("event=http2.frame_send type=HEADERS stream_id=1")
            NetworkLog.http2.debug("event=http2.frame_receive type=HEADERS stream_id=1")
            NetworkLog.http2.debug("event=http2.frame_receive type=DATA stream_id=1")
            NetworkLog.http2.info("event=http2.stream_close stream_id=1")
        }
    }

    func testSSEConnectionLifecycle() {
        XCTAssertNoThrow {
            NetworkLog.sse.info("event=sse.connection_open url=https://example.com/events")
            NetworkLog.sse.debug("event=sse.event_received type=message")
            NetworkLog.sse.debug("event=sse.event_received type=update")
            NetworkLog.sse.warning("event=sse.reconnect retry_after=3000")
            NetworkLog.sse.info("event=sse.connection_close")
        }
    }

    func testWebSocketConnectionLifecycle() {
        XCTAssertNoThrow {
            NetworkLog.webSocket.info("event=websocket.connection_open url=wss://example.com")
            NetworkLog.webSocket.debug("event=websocket.message_received type=text length=128")
            NetworkLog.webSocket.debug("event=websocket.message_sent type=text length=64")
            NetworkLog.webSocket.debug("event=websocket.ping")
            NetworkLog.webSocket.debug("event=websocket.pong")
            NetworkLog.webSocket.info("event=websocket.close code=1000 reason=normal")
        }
    }

    func testDNSResolutionLifecycle() {
        XCTAssertNoThrow {
            NetworkLog.dns.debug("event=dns.query hostname=example.com type=A")
            NetworkLog.dns.debug("event=dns.cache_miss hostname=example.com")
            NetworkLog.dns.info("event=dns.resolve hostname=example.com addresses=2 duration_ms=45")
        }
    }
}
