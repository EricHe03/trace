//
//  BreakpointRawMessage.swift
//  TraceFeatures
//
//  Created by Codex on 2026/03/21.
//

import Foundation
import TraceCore

public enum BreakpointRawMessageError: LocalizedError, Equatable, Sendable {
    case invalidStartLine
    case invalidHeaderLine(String)
    case invalidURL
    case invalidStatusCode

    public var errorDescription: String? {
        switch self {
        case .invalidStartLine:
            "The raw HTTP message has an invalid start line."
        case let .invalidHeaderLine(line):
            "The header line is invalid: \(line)"
        case .invalidURL:
            "The request target could not be resolved into a valid URL."
        case .invalidStatusCode:
            "The response status code is invalid."
        }
    }
}

public enum BreakpointRawMessage {
    public static func serialize(_ pausedRequest: PausedRequest) -> String {
        switch pausedRequest.breakpointType {
        case .response:
            serializeResponse(pausedRequest)
        case .request, .both:
            serializeRequest(pausedRequest)
        case .stream:
            String(decoding: pausedRequest.effectiveBody ?? Data(), as: UTF8.self)
        }
    }

    public static func parse(
        _ rawMessage: String,
        for pausedRequest: PausedRequest
    ) throws -> PausedRequestModifications {
        switch pausedRequest.breakpointType {
        case .response:
            try parseResponse(rawMessage)
        case .request, .both:
            try parseRequest(rawMessage, originalURL: pausedRequest.url)
        case .stream:
            PausedRequestModifications(body: Data(rawMessage.utf8))
        }
    }
}

private extension BreakpointRawMessage {
    static func serializeRequest(_ pausedRequest: PausedRequest) -> String {
        let methodToken = pausedRequest.effectiveMethodToken
        let target = requestTarget(from: pausedRequest.effectiveUrl)
        let headers = pausedRequest.effectiveHeaders
        let body = String(decoding: pausedRequest.effectiveBody ?? Data(), as: UTF8.self)

        var lines = ["\(methodToken) \(target) HTTP/1.1"]
        lines.append(contentsOf: headers.map { "\($0.key): \($0.value)" })
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    static func serializeResponse(_ pausedRequest: PausedRequest) -> String {
        let statusCode = pausedRequest.effectiveStatusCode ?? pausedRequest.statusCode ?? 200
        let reasonPhrase = pausedRequest.effectiveStatusMessage
            ?? pausedRequest.statusMessage
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        let headers = pausedRequest.effectiveHeaders
        let body = String(decoding: pausedRequest.effectiveBody ?? Data(), as: UTF8.self)

        var lines = ["HTTP/1.1 \(statusCode) \(reasonPhrase)"]
        lines.append(contentsOf: headers.map { "\($0.key): \($0.value)" })
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    static func parseRequest(
        _ rawMessage: String,
        originalURL: String
    ) throws -> PausedRequestModifications {
        let components = splitRawMessage(rawMessage)
        let requestLineParts = components.startLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLineParts.count >= 3 else {
            throw BreakpointRawMessageError.invalidStartLine
        }

        let methodToken = String(requestLineParts[0]).uppercased()
        let target = String(requestLineParts[1])
        let headers = try parseHeaders(components.headerLines)
        guard let url = resolvedURL(from: target, originalURL: originalURL, headers: headers) else {
            throw BreakpointRawMessageError.invalidURL
        }

        return PausedRequestModifications(
            url: url,
            method: HTTPMethod(rawValue: methodToken),
            methodToken: methodToken,
            headers: headers,
            body: Data(components.body.utf8)
        )
    }

    static func parseResponse(_ rawMessage: String) throws -> PausedRequestModifications {
        let components = splitRawMessage(rawMessage)
        let statusLineParts = components.startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusLineParts.count >= 2 else {
            throw BreakpointRawMessageError.invalidStartLine
        }
        guard let statusCode = Int(statusLineParts[1]) else {
            throw BreakpointRawMessageError.invalidStatusCode
        }

        let statusMessage = statusLineParts.count == 3 ? String(statusLineParts[2]) : ""
        let headers = try parseHeaders(components.headerLines)
        return PausedRequestModifications(
            headers: headers,
            body: Data(components.body.utf8),
            statusCode: statusCode,
            statusMessage: statusMessage
        )
    }

    static func splitRawMessage(_ rawMessage: String) -> (startLine: String, headerLines: [String], body: String) {
        let normalized = rawMessage.replacingOccurrences(of: "\r\n", with: "\n")
        let separatorRange = normalized.range(of: "\n\n")
        let headerSection = separatorRange.map { String(normalized[..<$0.lowerBound]) } ?? normalized
        let bodySection = separatorRange.map { String(normalized[$0.upperBound...]) } ?? ""
        let headerLines = headerSection.components(separatedBy: "\n")
        let startLine = headerLines.first ?? ""
        return (startLine, Array(headerLines.dropFirst()), bodySection)
    }

    static func parseHeaders(_ headerLines: [String]) throws -> [TraceHTTPHeader] {
        try headerLines
            .filter { !$0.isEmpty }
            .map { line in
                guard let separatorIndex = line.firstIndex(of: ":") else {
                    throw BreakpointRawMessageError.invalidHeaderLine(line)
                }
                let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let valueStart = line.index(after: separatorIndex)
                let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return TraceHTTPHeader(key: key, value: value)
            }
    }

    static func resolvedURL(
        from target: String,
        originalURL: String,
        headers: [TraceHTTPHeader]
    ) -> String? {
        if let absoluteURL = URL(string: target), absoluteURL.scheme != nil {
            return absoluteURL.absoluteString
        }

        guard var components = URLComponents(string: originalURL) else {
            return nil
        }

        if let hostHeader = headers.first(where: { $0.key.caseInsensitiveCompare("Host") == .orderedSame })?.value,
           let hostComponents = parseHostHeader(hostHeader, scheme: components.scheme) {
            components.host = hostComponents.host
            components.port = hostComponents.port
        }

        if target.hasPrefix("/") || target.hasPrefix("?") {
            applyPathAndQuery(target, to: &components)
            return components.url?.absoluteString
        }

        if target.caseInsensitiveCompare("*") == .orderedSame {
            components.path = "/"
            components.query = nil
            return components.url?.absoluteString
        }

        if let parsedTarget = parseHostHeader(target, scheme: components.scheme) {
            components.host = parsedTarget.host
            components.port = parsedTarget.port
            components.path = "/"
            components.query = nil
            return components.url?.absoluteString
        }

        return nil
    }

    static func applyPathAndQuery(_ target: String, to components: inout URLComponents) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? "")
        components.path = path.isEmpty ? "/" : path
        components.percentEncodedQuery = parts.count == 2 ? String(parts[1]) : nil
    }

    static func parseHostHeader(_ value: String, scheme: String?) -> (host: String, port: Int?)? {
        let lowercasedScheme = (scheme ?? "https").lowercased()
        if let components = URLComponents(string: "\(lowercasedScheme)://\(value)"),
           let host = components.host {
            return (host, components.port)
        }
        return nil
    }

    static func requestTarget(from absoluteURL: String) -> String {
        guard let components = URLComponents(string: absoluteURL) else {
            return absoluteURL
        }

        var target = components.percentEncodedPath
        if target.isEmpty {
            target = "/"
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            target += "?\(query)"
        }
        return target
    }
}
