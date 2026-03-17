//
//  Samples.swift
//  TraceTests
//
//  Test-only sample fixtures for core models.
//

import Foundation
@testable import TraceCore

extension NetworkRequest {
    static func sample(
        id: UUID = UUID(),
        url: String = "https://example.com/api",
        method: HTTPMethod = .get,
        statusCode: Int? = 200,
        statusMessage: String? = "OK",
        timestamp: Date = Date(),
        duration: TimeInterval = 0.25,
        requestHeaders: [TraceHTTPHeader] = [],
        responseHeaders: [TraceHTTPHeader] = [],
        requestBody: BodyStorage = .empty,
        responseBody: BodyStorage = .empty,
        protocolVersion: HTTPProtocolVersion? = .http11
    ) -> NetworkRequest {
        NetworkRequest(
            id: id,
            url: url,
            method: method,
            statusCode: statusCode,
            statusMessage: statusMessage,
            timestamp: timestamp,
            duration: duration,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody,
            protocolVersion: protocolVersion
        )
    }

    static var sample: NetworkRequest {
        sample()
    }
}

extension WebSocketConnection {
    static var sample: WebSocketConnection {
        WebSocketConnection(
            url: "wss://example.com/socket",
            startTime: Date(),
            status: .open
        )
    }
}

extension SSEConnection {
    static var sample: SSEConnection {
        SSEConnection(
            url: "https://example.com/events",
            startTime: Date(),
            status: .streaming
        )
    }
}
