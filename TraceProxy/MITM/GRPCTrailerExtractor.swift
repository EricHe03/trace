//
//  GRPCTrailerExtractor.swift
//  TraceProxy
//

import Foundation
import NIOHTTP1
import TraceCore

/// Extracts gRPC-specific metadata from HTTP headers (both response headers and HTTP/2 trailing HEADERS frames).
///
/// In gRPC over HTTP/2 (RFC 9113 + gRPC spec), the server sends a trailing HEADERS frame with
/// END_STREAM set that contains the gRPC status fields. AsyncHTTPClient merges these trailing
/// headers into the final response.headers collection, so the same extraction logic applies to
/// both the buffered and streaming capture paths.
///
/// For gRPC-Web, trailers are embedded in the response body as the last data frame with the
/// high bit of the compression flag set (flag == 0x80). Use extractFromWebBody(_:contentType:)
/// for those responses.
enum GRPCTrailerExtractor {
    // MARK: - Content-Type Detection

    /// Returns true when the content-type indicates a gRPC-Web variant.
    /// Covers: application/grpc-web, application/grpc-web+proto,
    ///         application/grpc-web-text, application/grpc-web-text+proto.
    static func isGRPCWeb(contentType: String) -> Bool {
        contentType.lowercased().hasPrefix("application/grpc-web")
    }

    static func isGRPCWebText(contentType: String) -> Bool {
        let normalized = contentType.lowercased()
        return normalized.contains("grpc-web-text") || normalized.contains("grpc-web+text")
    }

    // MARK: - Native gRPC (HTTP/2 trailers)

    /// Extract gRPC metadata from the given HTTPHeaders.
    /// Returns nil if no grpc-status header is present (i.e., not a gRPC response).
    static func extract(from headers: HTTPHeaders) -> GRPCMetadata? {
        guard headers["grpc-status"].first != nil else { return nil }
        var meta = GRPCMetadata()
        meta.statusCode = headers["grpc-status"].first.flatMap { Int($0) }
        // grpc-message is percent-encoded per the gRPC spec (§2.4).
        meta.statusMessage = headers["grpc-message"].first.map {
            $0.removingPercentEncoding ?? $0
        }
        meta.encoding = headers["grpc-encoding"].first
        meta.statusDetailsBin = headers["grpc-status-details-bin"].first
        return meta
    }

    // MARK: - gRPC-Web (embedded trailers)

    /// Extract gRPC metadata from a gRPC-Web response body.
    ///
    /// gRPC-Web embeds trailers as the last frame in the response body with the high bit
    /// of the compression flag byte set (flag == 0x80). The trailer payload is a sequence
    /// of HTTP/1.1-style header lines ("key: value\r\n").
    ///
    /// For the `-text` content-type variant, the entire body is Base64-encoded and must be
    /// decoded before frame parsing.
    ///
    /// Returns nil if no trailer frame is found (stream still open or body truncated).
    static func extractFromWebBody(responseBody: Data, contentType: String) -> GRPCMetadata? {
        let isTextVariant = isGRPCWebText(contentType: contentType)
        let bodyData: Data
        if isTextVariant {
            guard let decoded = Data(base64Encoded: responseBody, options: .ignoreUnknownCharacters) else {
                return nil
            }
            bodyData = decoded
        } else {
            bodyData = responseBody
        }

        var offset = bodyData.startIndex
        while offset + 5 <= bodyData.endIndex {
            let flag = bodyData[offset]
            let len = Int(bodyData[offset + 1]) << 24
                | Int(bodyData[offset + 2]) << 16
                | Int(bodyData[offset + 3]) << 8
                | Int(bodyData[offset + 4])
            guard len >= 0,
                  let next = bodyData.index(offset, offsetBy: 5 + len, limitedBy: bodyData.endIndex) else {
                break
            }

            if flag & 0x80 != 0 {
                // Embedded trailer frame — parse payload as HTTP header lines.
                let trailerData = bodyData[(offset + 5) ..< next]
                var meta = parseWebTrailerPayload(trailerData)
                meta.isGRPCWeb = true
                return meta
            }
            offset = next
        }
        return nil
    }

    /// Parse the trailer payload of a gRPC-Web trailer frame.
    /// The payload is a sequence of ASCII "key: value\r\n" or "key: value\n" lines.
    private static func parseWebTrailerPayload(_ data: Data) -> GRPCMetadata {
        var meta = GRPCMetadata()
        guard let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
            return meta
        }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex ..< colonIdx])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        meta.statusCode = headers["grpc-status"].flatMap { Int($0) }
        meta.statusMessage = headers["grpc-message"].map { $0.removingPercentEncoding ?? $0 }
        meta.encoding = headers["grpc-encoding"]
        meta.statusDetailsBin = headers["grpc-status-details-bin"]
        return meta
    }

    // MARK: - Message Counting

    /// Count the number of gRPC data messages in a body buffer.
    ///
    /// gRPC message framing (§2.2 of the gRPC HTTP/2 spec):
    ///   - Byte 0:   Compressed-Flag (0 = uncompressed, 1 = compressed; 0x80 = gRPC-Web trailer)
    ///   - Bytes 1–4: Message-Length (big-endian uint32)
    ///   - Bytes 5…: Message bytes
    ///
    /// Returns 0 for empty data; stops counting on malformed frames.
    /// gRPC-Web trailer frames (flag & 0x80 != 0) are skipped and not counted as messages.
    static func countMessages(in data: Data) -> Int {
        var count = 0
        var offset = data.startIndex
        while offset + 5 <= data.endIndex {
            let flag = data[offset]
            // High bit: gRPC-Web embedded trailer frame — skip, not a data message.
            let isTrailerFrame = flag & 0x80 != 0
            // For data frames, flag must be 0 (uncompressed) or 1 (compressed).
            guard isTrailerFrame || flag == 0 || flag == 1 else {
                return count
            }
            let len = Int(data[offset + 1]) << 24
                | Int(data[offset + 2]) << 16
                | Int(data[offset + 3]) << 8
                | Int(data[offset + 4])
            guard len >= 0 else { break }
            guard let next = data.index(offset, offsetBy: 5 + len, limitedBy: data.endIndex) else { break }
            if !isTrailerFrame {
                count += 1
            }
            offset = next
        }
        return count
    }

    /// Count gRPC messages in a gRPC-Web text body.
    /// Base64-decodes the body before counting.
    static func countMessagesInGRPCWebText(in data: Data) -> Int {
        guard let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else { return 0 }
        return countMessages(in: decoded)
    }
}
