//
//  HTTP3Bridge.swift
//  TraceQUIC
//
//  Created by Codex on 2026/02/18.
//

import Foundation
import TraceCore

public struct HTTP3HeaderField: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum HTTP3BridgeError: LocalizedError, Sendable, Equatable {
    case missingMethod
    case missingAuthority
    case invalidStatus(String)
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .missingMethod:
            "Missing :method pseudo-header"
        case .missingAuthority:
            "Missing :authority pseudo-header"
        case let .invalidStatus(raw):
            "Invalid :status pseudo-header: \(raw)"
        case let .invalidURL(raw):
            "Invalid URL generated from HTTP/3 pseudo-headers: \(raw)"
        }
    }
}

public struct HTTP3RequestHead: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [HTTP3HeaderField]

    public init(method: String, url: URL, headers: [HTTP3HeaderField]) {
        self.method = method
        self.url = url
        self.headers = headers
    }
}

public struct HTTP3ResponseHead: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [HTTP3HeaderField]

    public init(statusCode: Int, headers: [HTTP3HeaderField]) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

public struct HTTP3StreamEvent: Sendable {
    public let streamID: UInt64
    public let headers: [HTTP3HeaderField]
    public let body: Data

    public init(streamID: UInt64, headers: [HTTP3HeaderField], body: Data) {
        self.streamID = streamID
        self.headers = headers
        self.body = body
    }
}

/// Maps HTTP/3 header/body events to Trace request/response shapes.
public enum HTTP3Bridge {
    public static func toTraceHeaders(_ headers: [HTTP3HeaderField]) -> [TraceHTTPHeader] {
        toTraceHeaders(headers, includePseudoHeaders: true)
    }

    public static func toTraceHeaders(
        _ headers: [HTTP3HeaderField],
        includePseudoHeaders: Bool
    ) -> [TraceHTTPHeader] {
        headers
            .filter { includePseudoHeaders || !$0.name.hasPrefix(":") }
            .map { TraceHTTPHeader(key: $0.name, value: $0.value) }
    }

    public static func requestHead(
        from event: HTTP3StreamEvent,
        defaultScheme: String = "https",
        authorityFallback: String? = nil
    ) throws -> HTTP3RequestHead {
        let pseudo = pseudoHeaders(from: event.headers)
        guard let method = pseudo[":method"], !method.isEmpty else {
            throw HTTP3BridgeError.missingMethod
        }

        let scheme = pseudo[":scheme"]?.lowercased().nonEmpty ?? defaultScheme
        let authority = pseudo[":authority"]?.nonEmpty ??
            firstHeader(named: "host", in: event.headers)?.value.nonEmpty ??
            authorityFallback?.nonEmpty
        guard let authority else {
            throw HTTP3BridgeError.missingAuthority
        }

        let path = pseudo[":path"]?.nonEmpty ?? "/"
        let fullURLString = "\(scheme)://\(authority)\(path)"
        guard let url = URL(string: fullURLString) else {
            throw HTTP3BridgeError.invalidURL(fullURLString)
        }

        let headers = event.headers.filter { !$0.name.hasPrefix(":") }
        return HTTP3RequestHead(method: method, url: url, headers: headers)
    }

    public static func responseHead(from headers: [HTTP3HeaderField]) throws -> HTTP3ResponseHead {
        let pseudo = pseudoHeaders(from: headers)
        let rawStatus = pseudo[":status"] ?? "200"
        guard let status = Int(rawStatus) else {
            throw HTTP3BridgeError.invalidStatus(rawStatus)
        }
        let filtered = headers.filter { !$0.name.hasPrefix(":") }
        return HTTP3ResponseHead(statusCode: status, headers: filtered)
    }

    public static func toDictionary(_ headers: [HTTP3HeaderField]) -> [String: String] {
        var flattened: [String: String] = [:]
        for header in headers where !header.name.hasPrefix(":") {
            upsertHeader(name: header.name, value: header.value, into: &flattened)
        }
        return flattened
    }

    public static func toDictionary(_ headers: [TraceHTTPHeader]) -> [String: String] {
        var flattened: [String: String] = [:]
        for header in headers where !header.key.hasPrefix(":") {
            upsertHeader(name: header.key, value: header.value, into: &flattened)
        }
        return flattened
    }

    public static func toHTTP3ResponseHeaders(
        statusCode: Int,
        headers: [TraceHTTPHeader]
    ) -> [HTTP3HeaderField] {
        var mapped = [HTTP3HeaderField(name: ":status", value: String(statusCode))]
        mapped.append(contentsOf: headers.filter { !$0.key.hasPrefix(":") }.map {
            HTTP3HeaderField(name: $0.key, value: $0.value)
        })
        return mapped
    }

    private static func pseudoHeaders(from headers: [HTTP3HeaderField]) -> [String: String] {
        var pseudo: [String: String] = [:]
        for header in headers where header.name.hasPrefix(":") {
            pseudo[header.name] = header.value
        }
        return pseudo
    }

    private static func firstHeader(
        named name: String,
        in headers: [HTTP3HeaderField]
    ) -> HTTP3HeaderField? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func upsertHeader(name: String, value: String, into headers: inout [String: String]) {
        if let existingKey = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            let existingValue = headers[existingKey] ?? ""
            let mergedValue: String
            if name.caseInsensitiveCompare("Cookie") == .orderedSame {
                mergedValue = existingValue.isEmpty ? value : "\(existingValue); \(value)"
            } else if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                mergedValue = value
            } else {
                mergedValue = existingValue.isEmpty ? value : "\(existingValue), \(value)"
            }
            headers[existingKey] = mergedValue
            return
        }

        headers[name] = value
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
