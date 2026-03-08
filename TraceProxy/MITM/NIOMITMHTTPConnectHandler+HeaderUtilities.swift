//
//  NIOMITMHTTPConnectHandler+HeaderUtilities.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import NIOCore
import NIOHTTP1
import TraceCore

extension NIOMITMHTTPConnectHandler {
    func resolveRequestURL(from head: HTTPRequestHead) -> String? {
        if case let .tunneledHTTPS(host, port) = ingressMode {
            let uri = head.uri
            if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
                return uri
            }

            let hostHeader = head.headers.first(name: "Host")
            let authority: String = if let hostHeader, !hostHeader.isEmpty {
                hostHeader
            } else if port == 443 {
                host
            } else {
                "\(host):\(port)"
            }
            let path = uri.hasPrefix("/") ? uri : "/\(uri)"
            return "https://\(authority)\(path)"
        }

        let uri = head.uri
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return uri
        }

        guard let host = head.headers.first(name: "Host"), !host.isEmpty else {
            return nil
        }
        let path = uri.hasPrefix("/") ? uri : "/\(uri)"
        return "http://\(host)\(path)"
    }

    func sanitizedRequestHeaders(from headers: HTTPHeaders) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Connection")
        sanitized.remove(name: "Keep-Alive")
        sanitized.remove(name: "TE")
        sanitized.remove(name: "Trailer")
        sanitized.remove(name: "Transfer-Encoding")
        sanitized.remove(name: "Content-Length")
        return sanitized
    }

    func sanitizedStreamingRequestHeaders(from headers: HTTPHeaders) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Proxy-Authorization")
        sanitized.remove(name: "Host")
        sanitized.remove(name: "Content-Length")
        sanitized.remove(name: "Transfer-Encoding")
        return sanitized
    }

    func isWebSocketUpgrade(headers: HTTPHeaders) -> Bool {
        headerContainsToken("Connection", token: "upgrade", in: headers) &&
            headers[canonicalForm: "Upgrade"].contains { $0.lowercased().contains("websocket") }
    }

    func webSocketPerMessageDeflateEnabled(headers: HTTPHeaders) -> Bool {
        headers[canonicalForm: "Sec-WebSocket-Extensions"].contains { value in
            value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains { $0.contains("permessage-deflate") }
        }
    }

    func isSSERequest(headers: HTTPHeaders) -> Bool {
        Self.isSSERequest(headers: headers)
    }

    static func isSSERequest(headers: HTTPHeaders) -> Bool {
        for acceptHeaderValue in headers[canonicalForm: "Accept"] {
            for rawToken in acceptHeaderValue.split(separator: ",", omittingEmptySubsequences: true) {
                let token = String(rawToken)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !token.isEmpty else { continue }
                let mimeType = token
                    .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? token
                if mimeType == "text/event-stream" {
                    return true
                }
            }
        }
        return false
    }

    func normalizedWebSocketURL(from url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        guard let scheme = components.scheme?.lowercased() else { return url }
        switch scheme {
        case "http":
            components.scheme = "ws"
            return components.string ?? url
        case "https":
            components.scheme = "wss"
            return components.string ?? url
        default:
            return url
        }
    }

    func normalizeWireBody(
        _ body: Data,
        headers: inout HTTPHeaders,
        compressionInfo: CompressionInfo?,
        direction: String
    ) -> Data {
        guard !body.isEmpty else { return body }
        guard let compressionInfo, compressionInfo.decompressionSuccess else { return body }
        guard let contentEncoding = headers.first(name: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !contentEncoding.isEmpty,
            contentEncoding.lowercased() != "identity"
        else {
            return body
        }

        let encodings = contentEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }

        guard !encodings.isEmpty else {
            headers.remove(name: "Content-Encoding")
            return body
        }

        var encodedBody = body
        for encoding in encodings {
            guard let compressed = CompressionHelper.compress(data: encodedBody, algorithm: encoding) else {
                headers.remove(name: "Content-Encoding")
                logConnectStage(
                    stage: "body_encoding_normalize",
                    outcome: "fallback_identity",
                    detail: "\(direction),encoding=\(contentEncoding),failed=\(encoding)"
                )
                eventLog?.append(
                    type: "proxy_nio_body_encoding_normalize",
                    msg: "mode=\(ingressModeLabel) id=\(connectionID) direction=\(direction) action=strip content_encoding=\(contentEncoding) failed=\(encoding)"
                )
                return body
            }
            encodedBody = compressed
        }

        logConnectStage(
            stage: "body_encoding_normalize",
            outcome: "recompressed",
            detail: "\(direction),encoding=\(contentEncoding),bytes=\(body.count)->\(encodedBody.count)"
        )
        eventLog?.append(
            type: "proxy_nio_body_encoding_normalize",
            msg: "mode=\(ingressModeLabel) id=\(connectionID) direction=\(direction) action=recompress content_encoding=\(contentEncoding) bytes_in=\(body.count) bytes_out=\(encodedBody.count)"
        )
        return encodedBody
    }

    func streamingResponseHeaders(
        from headers: HTTPHeaders,
        closeAfterSend: Bool
    ) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")

        if usesHTTP2StreamSemantics {
            sanitized.remove(name: "Connection")
            sanitized.remove(name: "Keep-Alive")
            sanitized.remove(name: "Transfer-Encoding")
            sanitized.remove(name: "Upgrade")
        } else if sanitized[canonicalForm: "Connection"].isEmpty {
            sanitized.add(name: "Connection", value: closeAfterSend ? "close" : "keep-alive")
        } else if closeAfterSend {
            sanitized.replaceOrAdd(name: "Connection", value: "close")
        }

        return sanitized
    }

    func sanitizedResponseHeaders(
        from headers: HTTPHeaders,
        bodyBytes: Int,
        closeAfterSend: Bool
    ) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Connection")
        sanitized.remove(name: "Keep-Alive")
        sanitized.remove(name: "Trailer")
        sanitized.remove(name: "Transfer-Encoding")
        sanitized.replaceOrAdd(name: "Content-Length", value: "\(bodyBytes)")
        if !usesHTTP2StreamSemantics {
            sanitized.replaceOrAdd(name: "Connection", value: closeAfterSend ? "close" : "keep-alive")
        }
        return sanitized
    }

    func shouldCloseConnection(requestHead: HTTPRequestHead, responseHeaders: HTTPHeaders) -> Bool {
        if headerContainsToken("Connection", token: "close", in: requestHead.headers) {
            return true
        }
        if headerContainsToken("Connection", token: "close", in: responseHeaders) {
            return true
        }

        if requestHead.version.major == 1, requestHead.version.minor == 0 {
            return !headerContainsToken("Connection", token: "keep-alive", in: requestHead.headers)
        }

        return false
    }

    func httpProtocolVersion(from version: HTTPVersion) -> HTTPProtocolVersion {
        switch version.major {
        case 1:
            version.minor == 0 ? .http10 : .http11
        case 2:
            .http2
        case 3:
            .http3
        default:
            .http11
        }
    }

    func headerContainsToken(_ headerName: String, token: String, in headers: HTTPHeaders) -> Bool {
        headers[canonicalForm: headerName].contains { value in
            value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(token.lowercased())
        }
    }

    func dictionary(from headers: HTTPHeaders) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            result[header.name] = header.value
        }
        return result
    }

    func dictionary(from headers: [TraceHTTPHeader]) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            result[header.key] = header.value
        }
        return result
    }

    func traceHeaders(from headers: HTTPHeaders) -> [TraceHTTPHeader] {
        headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) }
    }

    func traceHeaders(from headers: [String: String]) -> [TraceHTTPHeader] {
        headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
    }

    func makeHTTPHeaders(from headers: [String: String]) -> HTTPHeaders {
        var result = HTTPHeaders()
        for (key, value) in headers {
            result.add(name: key, value: value)
        }
        return result
    }

    func makeHTTPHeaders(from headers: [TraceHTTPHeader]) -> HTTPHeaders {
        var result = HTTPHeaders()
        for header in headers {
            result.add(name: header.key, value: header.value)
        }
        return result
    }

    func byteBuffer(from data: Data, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func byteBufferToData(_ buffer: ByteBuffer) -> Data {
        var mutableBuffer = buffer
        return mutableBuffer.readData(length: mutableBuffer.readableBytes) ?? Data()
    }
}
