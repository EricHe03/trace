//
//  DeflateDecoder.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import zlib

/// Provides DEFLATE decompression for raw and zlib-wrapped streams.
public class DeflateDecoder {
    /// Decompresses raw or zlib-wrapped DEFLATE data.
    /// - Parameter data: DEFLATE-compressed data, with or without a zlib wrapper.
    /// - Returns: Decompressed data.
    /// - Throws: DecompressionError if decompression fails.
    public static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        // Tradeoff: Try zlib-wrapped DEFLATE first because Content-Encoding: deflate commonly uses it.
        if hasZlibWrapper(data) {
            if let result = try? decompressZlib(data) { return result }
        }

        return try decompressRaw(data)
    }

    private static func hasZlibWrapper(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }

        let cmf = data[0]
        let flg = data[1]

        // Rule: RFC 1950 requires the CMF lower nibble to be 8 for DEFLATE.
        let cm = cmf & 0x0F
        guard cm == 8 else { return false }

        // Rule: RFC 1950 requires (CMF << 8 | FLG) to be a multiple of 31.
        let check = (UInt16(cmf) << 8) | UInt16(flg)
        return check % 31 == 0
    }

    private static func decompressZlib(_ data: Data) throws -> Data {
        try decompressWithZlib(data, windowBits: MAX_WBITS)
    }

    private static func decompressRaw(_ data: Data) throws -> Data {
        try decompressWithZlib(data, windowBits: -MAX_WBITS)
    }

    private static func decompressWithZlib(_ data: Data, windowBits: Int32) throws -> Data {
        try data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = sourcePtr.bindMemory(to: UInt8.self).baseAddress else {
                throw DecompressionError.invalidData
            }

            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: baseAddress)
            stream.avail_in = uInt(data.count)

            let initStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initStatus == Z_OK else {
                throw DecompressionError.initializationFailed
            }
            defer { inflateEnd(&stream) }

            var output = Data()
            let bufferSize = 64 * 1024
            var outBuffer = [UInt8](repeating: 0, count: bufferSize)

            var status: Int32 = Z_OK
            repeat {
                try outBuffer.withUnsafeMutableBytes { buffer in
                    guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else {
                        throw DecompressionError.invalidData
                    }
                    stream.next_out = baseAddress
                    stream.avail_out = uInt(bufferSize)

                    status = inflate(&stream, Z_NO_FLUSH)

                    switch status {
                    case Z_OK, Z_STREAM_END:
                        let produced = bufferSize - Int(stream.avail_out)
                        if produced > 0 {
                            output.append(baseAddress, count: produced)
                        }
                    case Z_BUF_ERROR:
                        // If we're out of input but not at stream end, treat as corrupted/truncated.
                        throw DecompressionError.processingFailed
                    default:
                        throw DecompressionError.processingFailed
                    }
                }
            } while status == Z_OK

            guard status == Z_STREAM_END, stream.avail_in == 0 else {
                throw DecompressionError.processingFailed
            }

            return output
        }
    }
}
