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
    public static func compress(data: Data, algorithm: String?) -> Data? {
        let algo = algorithm?.lowercased() ?? "deflate"
        switch algo {
        case "deflate", "zlib":
            return compress(data: data, algorithm: COMPRESSION_ZLIB)
        case "gzip":
            guard let deflated = compress(data: data, algorithm: COMPRESSION_ZLIB) else { return nil }
            return wrapGzip(deflated, originalSize: data.count, crc32: crc32(data))
        case "br", "brotli":
            return nil
        default:
            return nil
        }
    }

    public static func decompress(data: Data, algorithm: String?) -> Data? {
        let algo = algorithm?.lowercased() ?? "deflate"
        switch algo {
        case "deflate", "zlib":
            return decompress(data: data, algorithm: COMPRESSION_ZLIB)
        case "gzip":
            guard let stripped = stripGzipWrapper(from: data) else { return nil }
            return decompress(data: stripped, algorithm: COMPRESSION_ZLIB)
        case "br", "brotli":
            #if canImport(TraceCompression)
            return try? BrotliDecoder.decompress(data)
            #else
            return nil
            #endif
        default:
            return nil
        }
    }

    private static func compress(data: Data, algorithm: compression_algorithm) -> Data? {
        guard !data.isEmpty else { return data }
        let bufferSize = 64 * 1024
        var output = Data()

        data.withUnsafeBytes { (srcBuffer: UnsafeRawBufferPointer) in
            guard let srcPtr = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { dstBuffer.deallocate() }
            var stream = compression_stream(
                dst_ptr: dstBuffer,
                dst_size: bufferSize,
                src_ptr: srcPtr,
                src_size: data.count,
                state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, algorithm) != COMPRESSION_STATUS_ERROR else {
                return
            }
            defer { compression_stream_destroy(&stream) }

            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, 0)
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { return }
            }
        }

        return output
    }

    private static func decompress(data: Data, algorithm: compression_algorithm) -> Data? {
        guard !data.isEmpty else { return data }
        let bufferSize = 64 * 1024
        var output = Data()

        data.withUnsafeBytes { (srcBuffer: UnsafeRawBufferPointer) in
            guard let srcPtr = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { dstBuffer.deallocate() }
            var stream = compression_stream(
                dst_ptr: dstBuffer,
                dst_size: bufferSize,
                src_ptr: srcPtr,
                src_size: data.count,
                state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_ERROR else {
                return
            }
            defer { compression_stream_destroy(&stream) }

            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, 0)
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { return }
            }
        }
        return output
    }

    private static func stripGzipWrapper(from data: Data) -> Data? {
        guard data.count > 18 else { return nil }
        guard data[0] == 0x1F, data[1] == 0x8B else { return nil }
        let headerLength = 10
        let footerLength = 8
        guard data.count > headerLength + footerLength else { return nil }
        let deflatedRange = headerLength ..< (data.count - footerLength)
        return data.subdata(in: deflatedRange)
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
