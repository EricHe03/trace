//
//  BrotliDecoder.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Compression
import Foundation

/// Provides Brotli decompression using Apple's Compression framework.
public class BrotliDecoder {
    /// Decompresses Brotli-compressed data.
    /// - Parameter data: Brotli-compressed data.
    /// - Returns: Decompressed data.
    /// - Throws: CompressionError if decompression fails.
    public static func decompress(_ data: Data) throws -> Data {
        try decompress(data, maxOutputBytes: nil)
    }

    /// Decompresses Brotli-compressed data, enforcing an optional output limit.
    ///
    /// If `maxOutputBytes` is set and the decompressed output reaches the limit, this returns a truncated
    /// buffer of exactly `maxOutputBytes` bytes (useful for callers that want a bounded preview).
    public static func decompress(_ data: Data, maxOutputBytes: Int?) throws -> Data {
        guard !data.isEmpty else { return Data() }
        if let maxOutputBytes, maxOutputBytes <= 0 { return Data() }

        return try data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = sourcePtr.baseAddress else {
                throw CompressionError.invalidInput("Invalid data buffer")
            }

            let bufferSize = 64 * 1024
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { destinationBuffer.deallocate() }

            var stream = compression_stream(
                dst_ptr: destinationBuffer,
                dst_size: bufferSize,
                src_ptr: baseAddress.assumingMemoryBound(to: UInt8.self),
                src_size: data.count,
                state: nil
            )

            var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw CompressionError.initializationFailed("Failed to initialize Brotli decompression stream")
            }
            defer { compression_stream_destroy(&stream) }

            // Re-set src fields after init (compression_stream_init clears all fields except state)
            stream.src_ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            stream.src_size = data.count

            var output = Data()
            if let maxOutputBytes {
                output.reserveCapacity(min(maxOutputBytes, bufferSize))
            }

            repeat {
                let previousSrcSize = stream.src_size
                stream.dst_ptr = destinationBuffer
                stream.dst_size = bufferSize

                // Always finalize since all input is provided upfront
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 {
                        if let maxOutputBytes {
                            let remaining = max(0, maxOutputBytes - output.count)
                            if remaining > 0 {
                                output.append(destinationBuffer, count: min(produced, remaining))
                            }
                        } else {
                            output.append(destinationBuffer, count: produced)
                        }
                    }
                    if let maxOutputBytes, output.count >= maxOutputBytes {
                        return output
                    } else if status == COMPRESSION_STATUS_OK, stream.src_size == previousSrcSize {
                        // Safety: Avoid infinite loops on malformed/truncated streams.
                        throw CompressionError.decompressionFailed("Brotli decompression made no progress (likely truncated or invalid stream)")
                    }
                case COMPRESSION_STATUS_ERROR:
                    throw CompressionError.decompressionFailed("Brotli decompression failed")
                default:
                    throw CompressionError.unknownError("Unexpected Brotli decompression status \(status)")
                }
            } while status == COMPRESSION_STATUS_OK

            // Validate that the stream ended cleanly and consumed all input.
            guard status == COMPRESSION_STATUS_END, stream.src_size == 0 else {
                throw CompressionError.decompressionFailed("Brotli decompression did not reach end-of-stream")
            }

            return output
        }
    }

    /// Reports whether data appears to be Brotli-compressed.
    ///
    /// Brotli does not include a magic number, so this check uses heuristics and a
    /// lightweight stream initialization to reduce false positives.
    /// - Parameter data: Data to check.
    /// - Returns: True when the data looks like Brotli-compressed content.
    public static func canDecode(_ data: Data) -> Bool {
        guard data.count >= 1 else { return false }

        let firstByte = data[0]

        let windowBits = (firstByte & 0x0F)

        // Rule: RFC 7932 encodes window sizes 10-24 as values 0-14.
        if windowBits > 14 {
            return false
        }

        // Tradeoff: Stream initialization reduces false positives without full decoding.
        return tryValidateBrotliStream(data)
    }

    private static func tryValidateBrotliStream(_ data: Data) -> Bool {
        guard data.count >= 1 else { return false }

        return data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Bool in
            guard let baseAddress = sourcePtr.baseAddress else { return false }

            let srcPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            let srcSize = min(data.count, 64)

            let bufferSize = 256
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { destinationBuffer.deallocate() }

            // Tradeoff: Probe only the first 64 bytes to keep validation cheap.
            var stream = compression_stream(
                dst_ptr: destinationBuffer,
                dst_size: bufferSize,
                src_ptr: srcPointer,
                src_size: srcSize,
                state: nil
            )

            let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
            guard initStatus != COMPRESSION_STATUS_ERROR else { return false }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = srcPointer
            stream.src_size = srcSize
            stream.dst_ptr = destinationBuffer
            stream.dst_size = bufferSize

            let processStatus = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            guard processStatus != COMPRESSION_STATUS_ERROR else { return false }

            let produced = bufferSize - stream.dst_size

            // Be conservative: require either output, or a clean end-of-stream within the probe window.
            if processStatus == COMPRESSION_STATUS_END {
                return true
            }
            return produced > 0
        }
    }
}
