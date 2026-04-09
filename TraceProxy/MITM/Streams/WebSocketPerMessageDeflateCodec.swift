//
//  WebSocketPerMessageDeflateCodec.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/03.
//

import Foundation

#if canImport(zlib)
import zlib
#endif

/// Stateless helpers for permessage-deflate encode/decode (no context takeover).
///
/// RFC 7692 §7.2.1 / §7.2.2: Each call uses a fresh zlib context, which satisfies
/// both `client_no_context_takeover` and `server_no_context_takeover`. When context
/// takeover is allowed, use `WebSocketDeflateContext` instead.
enum WebSocketPerMessageDeflateCodec {
    static func decode(_ compressed: Data) -> Data? {
        #if canImport(zlib)
        var input = compressed
        input.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])
        return inflateRaw(input)
        #else
        return nil
        #endif
    }

    static func encode(_ plain: Data) -> Data? {
        #if canImport(zlib)
        guard let encoded = deflateRaw(plain) else { return nil }
        if encoded.count >= 4, encoded.suffix(4) == Data([0x00, 0x00, 0xFF, 0xFF]) {
            return encoded.dropLast(4)
        }
        return encoded
        #else
        return nil
        #endif
    }

    #if canImport(zlib)
    private static func inflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let chunkSize = 16 * 1024
        var output = Data()
        var status: Int32 = Z_OK

        data.withUnsafeBytes { srcBytes in
            guard let base = srcBytes.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            var buffer = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                let produced: Int = buffer.withUnsafeMutableBufferPointer { pointer in
                    stream.next_out = pointer.baseAddress
                    stream.avail_out = uInt(pointer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(buffer, count: produced)
                }

                if status == Z_STREAM_END {
                    break
                }

                if status != Z_OK {
                    return
                }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }

        guard status == Z_STREAM_END else { return nil }
        return output
    }

    private static func deflateRaw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        let chunkSize = 16 * 1024
        var output = Data()
        var status: Int32 = Z_OK

        data.withUnsafeBytes { srcBytes in
            guard let base = srcBytes.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            var buffer = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                let produced: Int = buffer.withUnsafeMutableBufferPointer { pointer in
                    stream.next_out = pointer.baseAddress
                    stream.avail_out = uInt(pointer.count)
                    let flushMode: Int32 = stream.avail_in == 0 ? Z_FINISH : Z_NO_FLUSH
                    status = deflate(&stream, flushMode)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(buffer, count: produced)
                }

                if status == Z_STREAM_END {
                    break
                }

                if status != Z_OK {
                    return
                }
            } while status != Z_STREAM_END
        }

        guard status == Z_STREAM_END else { return nil }
        return output
    }
    #endif
}

/// Negotiated permessage-deflate parameters (RFC 7692 §7.1).
///
/// These are parsed from the Sec-WebSocket-Extensions header and control whether
/// each side resets its LZ77 sliding window between messages.
struct WebSocketDeflateParameters: Sendable {
    /// Server must reset its DEFLATE context after each message (proxy→client direction).
    var serverNoContextTakeover: Bool = false
    /// Client must reset its DEFLATE context after each message (client→proxy direction).
    var clientNoContextTakeover: Bool = false

    /// Parse from a single Sec-WebSocket-Extensions header value.
    static func parse(from extensionValue: String) -> WebSocketDeflateParameters {
        var params = WebSocketDeflateParameters()
        let tokens = extensionValue
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for token in tokens {
            if token == "server_no_context_takeover" { params.serverNoContextTakeover = true }
            if token == "client_no_context_takeover" { params.clientNoContextTakeover = true }
        }
        return params
    }
}
