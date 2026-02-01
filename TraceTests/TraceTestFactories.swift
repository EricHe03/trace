//
//  TraceTestFactories.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

import Foundation
@testable import Trace
@testable import TraceCore
@testable import TraceNetworking
@testable import TraceVPN

// MARK: - Network Request Factories

/// Creates a test NetworkRequest with customizable parameters
func makeNetworkRequest(
    id: UUID = UUID(),
    url: String = "https://api.example.com/test",
    method: HTTPMethod = .get,
    statusCode: Int? = 200,
    statusMessage: String? = "OK",
    timestamp: Date = Date(),
    duration: TimeInterval = 0.5,
    requestHeaders: [TraceHTTPHeader] = [],
    responseHeaders: [TraceHTTPHeader] = [],
    requestBody: BodyStorage = .empty,
    responseBody: BodyStorage = .empty,
    wasThrottled: Bool = false,
    throttlingProfile: String? = nil
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
        wasThrottled: wasThrottled,
        throttlingProfile: throttlingProfile
    )
}

/// Creates a test NetworkRequest for TraceVPN with customizable parameters
func makeVPNNetworkRequest(
    id: UUID = UUID(),
    url: String = "https://api.example.com/test",
    method: HTTPMethod = .get,
    statusCode: Int? = 200,
    statusMessage: String? = "OK",
    timestamp: Date = Date(),
    duration: TimeInterval = 0.5,
    requestHeaders: [TraceHTTPHeader] = [],
    responseHeaders: [TraceHTTPHeader] = [],
    requestBody: BodyStorage = .empty,
    responseBody: BodyStorage = .empty,
    wasThrottled: Bool = false,
    throttlingProfile: String? = nil
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
        wasThrottled: wasThrottled,
        throttlingProfile: throttlingProfile
    )
}

/// Creates a test HTTP header
func makeHTTPHeader(key: String, value: String) -> TraceHTTPHeader {
    TraceHTTPHeader(key: key, value: value)
}

/// Creates a test HTTP header array with common headers
func makeHTTPHeaders(
    count: Int = 3,
    includeContentType: Bool = true,
    includeUserAgent: Bool = true
) -> [TraceHTTPHeader] {
    var headers: [TraceHTTPHeader] = []

    if includeContentType {
        headers.append(TraceHTTPHeader(key: "Content-Type", value: "application/json"))
    }
    if includeUserAgent {
        headers.append(TraceHTTPHeader(key: "User-Agent", value: "Trace/1.0"))
    }

    for i in 0 ..< (count - headers.count) {
        headers.append(TraceHTTPHeader(key: "X-Header-\(i)", value: "value-\(i)"))
    }

    return Array(headers.prefix(count))
}

/// Creates test BodyStorage with string data
func makeBodyStorage(string: String) -> BodyStorage {
    BodyStorage.from(string: string)
}

/// Creates test BodyStorage with data
func makeBodyStorage(data: Data) -> BodyStorage {
    BodyStorage.from(data: data)
}

// MARK: - VPN Component Factories

/// Creates a NetworkThrottlingState for testing
func makeThrottlingState(
    enabled: Bool = true,
    latency: Int = 100,
    downloadSpeed: Int = 1024,
    uploadSpeed: Int = 512,
    packetLoss: Double = 0.0
) -> NetworkThrottlingState {
    let condition = NetworkCondition.custom(
        download: downloadSpeed,
        upload: uploadSpeed,
        latency: latency,
        packetLoss: packetLoss
    )
    return NetworkThrottlingState(enabled: enabled, condition: condition)
}

// MARK: - HTTP Parser Factories

/// Creates HTTP request data for testing
func makeHTTPRequest(
    method: String = "GET",
    path: String = "/api/test",
    httpVersion: String = "HTTP/1.1",
    headers: [String: String] = [:],
    body: Data = Data()
) -> Data {
    var requestData = "\(method) \(path) \(httpVersion)\r\n".data(using: .utf8) ?? Data()

    // Default headers
    var allHeaders = headers
    if allHeaders["Host"] == nil {
        allHeaders["Host"] = "example.com"
    }

    // Add headers
    for (key, value) in allHeaders {
        if let headerLine = "\(key): \(value)\r\n".data(using: .utf8) {
            requestData.append(headerLine)
        }
    }

    // Add body if present
    if !body.isEmpty {
        if let contentLength = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8) {
            requestData.append(contentLength)
        }
        requestData.append(body)
    } else {
        if let endHeaders = "\r\n".data(using: .utf8) {
            requestData.append(endHeaders)
        }
    }

    return requestData
}

/// Creates HTTP response data for testing
func makeHTTPResponse(
    statusCode: Int = 200,
    statusMessage: String = "OK",
    httpVersion: String = "HTTP/1.1",
    headers: [String: String] = [:],
    body: Data = Data()
) -> Data {
    var responseData = "\(httpVersion) \(statusCode) \(statusMessage)\r\n".data(using: .utf8) ?? Data()

    // Default headers
    var allHeaders = headers
    if allHeaders["Content-Type"] == nil {
        allHeaders["Content-Type"] = "text/plain"
    }

    // Add headers
    for (key, value) in allHeaders {
        if let headerLine = "\(key): \(value)\r\n".data(using: .utf8) {
            responseData.append(headerLine)
        }
    }

    // Add content-length if body is present
    if !body.isEmpty {
        if let contentLength = "Content-Length: \(body.count)\r\n\r\n".data(using: .utf8) {
            responseData.append(contentLength)
        }
        responseData.append(body)
    } else {
        if let endHeaders = "\r\n".data(using: .utf8) {
            responseData.append(endHeaders)
        }
    }

    return responseData
}

/// Creates chunked transfer encoding body
func makeChunkedBody(chunks: [String]) -> Data {
    var chunkedData = Data()

    for chunk in chunks {
        if let chunkSize = "\(String(format: "%X", chunk.count))\r\n".data(using: .utf8) {
            chunkedData.append(chunkSize)
        }
        if let chunkData = "\(chunk)\r\n".data(using: .utf8) {
            chunkedData.append(chunkData)
        }
    }

    // Terminal chunk
    if let terminal = "0\r\n\r\n".data(using: .utf8) {
        chunkedData.append(terminal)
    }

    return chunkedData
}

// MARK: - HTTP/2 Factories

/// Creates HTTP/2 frame data for testing
func makeHTTP2Frame(
    type: HTTP2FrameType = .data,
    flags: HTTP2FrameFlags = [],
    streamId: UInt32 = 1,
    payload: Data = Data()
) -> Data {
    var frame = Data(count: 9 + payload.count)

    // Frame header (9 bytes)
    // Length (24 bits / 3 bytes)
    let length = UInt32(payload.count)
    frame[0] = UInt8((length >> 16) & 0xFF)
    frame[1] = UInt8((length >> 8) & 0xFF)
    frame[2] = UInt8(length & 0xFF)

    // Type (8 bits / 1 byte)
    frame[3] = type.rawValue

    // Flags (8 bits / 1 byte)
    frame[4] = flags.rawValue

    // Stream ID (31 bits / 4 bytes, first bit reserved)
    frame[5] = UInt8((streamId >> 24) & 0x7F)
    frame[6] = UInt8((streamId >> 16) & 0xFF)
    frame[7] = UInt8((streamId >> 8) & 0xFF)
    frame[8] = UInt8(streamId & 0xFF)

    // Payload
    frame.replaceSubrange(9 ..< frame.count, with: payload)

    return frame
}

// MARK: - Test Data Generators

/// Generates a large binary payload for testing
func generateLargePayload(sizeInBytes: Int) -> Data {
    var data = Data(capacity: sizeInBytes)
    for i in 0 ..< sizeInBytes {
        data.append(UInt8(i % 256))
    }
    return data
}

/// Generates JSON string for testing
func makeJSON(
    _ dictionary: [String: Any] = ["key": "value", "number": 42, "boolean": true]
) -> String {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: dictionary),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        return "{\"error\": \"failed to create json\"}"
    }
    return jsonString
}

/// Generates a request with N headers for testing
func makeRequestWithNHeaders(count: Int) -> NetworkRequest {
    let headers = (0 ..< count).map { i in
        TraceHTTPHeader(key: "X-Test-Header-\(i)", value: "value-\(i)")
    }
    return makeNetworkRequest(requestHeaders: headers)
}

// MARK: - Interception Component Factories

/// Creates a test RewriteRule
func makeRewriteRule(
    id: UUID = UUID(),
    name: String = "Test Rule",
    enabled: Bool = true,
    matchURL: String = "*.example.com",
    action: RewriteRule.Action = .modifyHeaders,
    modifyHeadersAdd: [String: String] = [:],
    modifyHeadersSet: [String: String] = [:],
    modifyHeadersRemove: [String] = []
) -> RewriteRule {
    RewriteRule(
        id: id,
        name: name,
        enabled: enabled,
        matchURL: matchURL,
        action: action,
        modifyHeadersAdd: modifyHeadersAdd,
        modifyHeadersSet: modifyHeadersSet,
        modifyHeadersRemove: modifyHeadersRemove
    )
}

/// Creates a test RequestMap
func makeRequestMap(
    id: UUID = UUID(),
    name: String = "Test Map",
    enabled: Bool = true,
    source: String = "https://api.example.com/old",
    target: String = "https://api.example.com/new",
    method: String? = nil
) -> RequestMap {
    RequestMap(
        id: id,
        name: name,
        enabled: enabled,
        source: source,
        target: target,
        method: method
    )
}

/// Creates a test Script
func makeScript(
    id: UUID = UUID(),
    name: String = "Test Script",
    enabled: Bool = true,
    code: String = "// Test script",
    phase: Script.Phase = .request
) -> Script {
    Script(
        id: id,
        name: name,
        enabled: enabled,
        code: code,
        phase: phase
    )
}

/// Creates a test RuleGroup
func makeRuleGroup(
    id: UUID = UUID(),
    name: String = "Test Group",
    enabled: Bool = true,
    ruleIds: [UUID] = []
) -> RuleGroup {
    RuleGroup(
        id: id,
        name: name,
        enabled: enabled,
        ruleIds: ruleIds
    )
}

/// Creates a test Profile
func makeProfile(
    id: UUID = UUID(),
    name: String = "Test Profile",
    isActive: Bool = true,
    ruleGroupIds: [UUID] = []
) -> Profile {
    Profile(
        id: id,
        name: name,
        isActive: isActive,
        ruleGroupIds: ruleGroupIds
    )
}

/// Creates a test ConfigSnapshot
func makeConfigSnapshot(
    rewriteRules: [RewriteRule] = [],
    requestMaps: [RequestMap] = [],
    scripts: [Script] = [],
    ruleGroups: [RuleGroup] = [],
    activeProfile: Profile? = nil
) -> ConfigSnapshot {
    ConfigSnapshot(
        rewriteRules: rewriteRules,
        requestMaps: requestMaps,
        scripts: scripts,
        ruleGroups: ruleGroups,
        activeProfile: activeProfile
    )
}
