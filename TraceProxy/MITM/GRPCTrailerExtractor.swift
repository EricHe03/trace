//
//  GRPCTrailerExtractor.swift
//  TraceProxy
//

import Foundation
import NIOHTTP1
import TraceCore

/// Extracts gRPC-specific metadata from HTTP headers (both response headers and HTTP/2 trailing HEADERS).
///
/// In gRPC over HTTP/2 (RFC 9113 + gRPC spec), the server sends a trailing HEADERS frame with
/// END_STREAM set that contains the gRPC status fields. AsyncHTTPClient merges these trailing
/// headers into the final response.headers collection, so the same extraction logic applies to
/// both the buffered and streaming capture paths.
enum GRPCTrailerExtractor {
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
        return meta
    }

    /// Count the number of gRPC length-prefixed messages in a body buffer.
    ///
    /// gRPC message framing (§2.2 of the gRPC HTTP/2 spec):
    ///   - Byte 0:   Compressed-Flag (0 or 1)
    ///   - Bytes 1–4: Message-Length (big-endian uint32)
    ///   - Bytes 5…: Message bytes
    ///
    /// Returns 0 for empty data; stops counting on malformed frames to avoid infinite loops.
    static func countMessages(in data: Data) -> Int {
        var count = 0
        var offset = data.startIndex
        while offset + 5 <= data.endIndex {
            let len = Int(data[offset + 1]) << 24
                | Int(data[offset + 2]) << 16
                | Int(data[offset + 3]) << 8
                | Int(data[offset + 4])
            guard len >= 0 else { break }
            guard let next = data.index(offset, offsetBy: 5 + len, limitedBy: data.endIndex) else { break }
            count += 1
            offset = next
        }
        return count
    }
}
