//
//  CompressionHelper.swift
//  TraceCore
//
//  Created by Justin on 2026/01/21.
//

import Compression
import Foundation

#if canImport(TraceCompression)
import TraceCompression
#endif

public enum CompressionHelper {
    public static func compress(data: Data, algorithm: String?, maxOutputBytes: Int? = nil) -> Data? {
        let algo = algorithm?.lowercased() ?? "deflate"
        switch algo {
        case "deflate", "zlib":
            return compress(data: data, algorithm: COMPRESSION_ZLIB, maxOutputBytes: maxOutputBytes)
        case "gzip":
            let wrapperBytes = 18
            let deflatedMax = maxOutputBytes.map { max(0, $0 - wrapperBytes) }
            guard let deflated = compress(data: data, algorithm: COMPRESSION_ZLIB, maxOutputBytes: deflatedMax) else { return nil }
            let wrapped = wrapGzip(deflated, originalSize: data.count, crc32: crc32(data))
            if let maxOutputBytes, wrapped.count > maxOutputBytes { return nil }
            return wrapped
        case "br", "brotli":
            return nil
        default:
            return nil
        }
    }

    public static func decompress(data: Data, algorithm: String?, maxOutputBytes: Int? = nil) -> Data? {
        let algo = algorithm?.lowercased() ?? "deflate"
        let detectionLimit = maxOutputBytes.map { $0 == Int.max ? Int.max : ($0 + 1) }
        switch algo {
        case "deflate", "zlib":
            #if canImport(TraceCompression)
            if let decompressed = try? DeflateDecoder.decompress(data, maxOutputBytes: detectionLimit) {
                if let maxOutputBytes, decompressed.count > maxOutputBytes { return nil }
                return decompressed
            }
            return nil
            #else
            return decompress(data: data, algorithm: COMPRESSION_ZLIB, maxOutputBytes: maxOutputBytes)
            #endif
        case "gzip":
            guard let stripped = GzipWrapper.strip(from: data) else { return nil }
            #if canImport(TraceCompression)
            if let decompressed = try? DeflateDecoder.decompress(stripped, maxOutputBytes: detectionLimit) {
                if let maxOutputBytes, decompressed.count > maxOutputBytes { return nil }
                return decompressed
            }
            return nil
            #else
            return decompress(data: stripped, algorithm: COMPRESSION_ZLIB, maxOutputBytes: maxOutputBytes)
            #endif
        case "br", "brotli":
            #if canImport(TraceCompression)
            if let decompressed = try? BrotliDecoder.decompress(data, maxOutputBytes: detectionLimit) {
                if let maxOutputBytes, decompressed.count > maxOutputBytes { return nil }
                return decompressed
            }
            return nil
            #else
            return nil
            #endif
        default:
            return nil
        }
    }

    private static func compress(data: Data, algorithm: compression_algorithm, maxOutputBytes: Int?) -> Data? {
        guard !data.isEmpty else { return data }

        // Note: In this environment, `compression_stream_process` for encoding can return `COMPRESSION_STATUS_ERROR`
        // even for valid inputs; `compression_encode_buffer` is consistently reliable for one-shot compression.
        let bound = max(64, compressBound(for: data.count, algorithm: algorithm))
        let dstCapacity = maxOutputBytes.map { min(bound, $0) } ?? bound
        guard dstCapacity > 0 else { return nil }

        var dst = Data(count: dstCapacity)
        let encodedSize = dst.withUnsafeMutableBytes { (dstBuffer: UnsafeMutableRawBufferPointer) -> Int in
            guard let dstPtr = dstBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return data.withUnsafeBytes { (srcBuffer: UnsafeRawBufferPointer) -> Int in
                guard let srcPtr = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(dstPtr, dstCapacity, srcPtr, data.count, nil, algorithm)
            }
        }

        guard encodedSize > 0 else { return nil }
        let result = dst.prefix(encodedSize)
        if let maxOutputBytes, result.count > maxOutputBytes { return nil }
        return result
    }

    private static func decompress(data: Data, algorithm: compression_algorithm, maxOutputBytes: Int?) -> Data? {
        guard !data.isEmpty else { return data }
        let bufferSize = 64 * 1024

        return data.withUnsafeBytes { (srcBuffer: UnsafeRawBufferPointer) -> Data? in
            guard let srcPtr = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { dstBuffer.deallocate() }

            var output = Data()
            if let maxOutputBytes {
                output.reserveCapacity(min(maxOutputBytes, bufferSize))
            }

            var stream = compression_stream(
                dst_ptr: dstBuffer,
                dst_size: bufferSize,
                src_ptr: srcPtr,
                src_size: data.count,
                state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_ERROR else {
                return nil
            }
            defer { compression_stream_destroy(&stream) }

            // Re-set src fields after init (compression_stream_init clears all fields except state)
            stream.src_ptr = srcPtr
            stream.src_size = data.count

            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = bufferSize
                // Always finalize for decompression since all input is provided upfront
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    if let maxOutputBytes, output.count + produced > maxOutputBytes { return nil }
                    output.append(dstBuffer, count: produced)
                }

                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { return nil }
                // Safety: Avoid infinite loops if no progress is made
                if status == COMPRESSION_STATUS_OK && produced == 0 { return nil }
            }

            return output
        }
    }

    private static func compressBound(for inputSize: Int, algorithm: compression_algorithm) -> Int {
        if algorithm == COMPRESSION_ZLIB {
            return zlibCompressBound(inputSize)
        }
        return max(64, inputSize)
    }

    private static func zlibCompressBound(_ inputSize: Int) -> Int {
        // Matches zlib's `compressBound` formula.
        let n = Int64(inputSize)
        let bound = n + (n >> 12) + (n >> 14) + (n >> 25) + 13
        if bound >= Int64(Int.max) { return Int.max }
        return Int(bound)
    }

    private static func wrapGzip(_ deflated: Data, originalSize: Int, crc32: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append(0x00)
        data.append(0xFF)
        data.append(deflated)

        var crc = crc32.littleEndian
        withUnsafeBytes(of: &crc) { data.append(contentsOf: $0) }
        var size = UInt32(originalSize).littleEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xFFFF_FFFF : 0
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }
}
