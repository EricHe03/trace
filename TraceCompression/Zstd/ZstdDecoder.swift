//
//  ZstdDecoder.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Compression
import Foundation

/// Provides Zstandard decompression.
///
/// Some SDKs do not expose a Zstandard symbol, so the decoder performs runtime
/// detection to select a supported algorithm.
public class ZstdDecoder {
    /// Decompresses Zstandard-compressed data.
    /// - Parameter data: Compressed data.
    /// - Returns: Decompressed data.
    /// - Throws: CompressionError if decompression fails.
    public static func decompress(_ data: Data) throws -> Data {
        try decompress(data, maxOutputBytes: nil)
    }

    /// Decompresses Zstandard-compressed data, enforcing an optional output limit.
    ///
    /// If `maxOutputBytes` is set and the decompressed output reaches the limit, this returns a truncated
    /// buffer of exactly `maxOutputBytes` bytes (useful for callers that want a bounded preview).
    public static func decompress(_ data: Data, maxOutputBytes: Int?) throws -> Data {
        guard !data.isEmpty else { return Data() }
        if let maxOutputBytes, maxOutputBytes <= 0 { return Data() }

        guard canDecode(data) else {
            throw CompressionError.invalidFormat("Not a valid zstd stream")
        }

        guard let algorithm = ZstdCompressionAlgorithm.supportedAlgorithm else {
            throw CompressionError.decompressionFailed("Zstandard decompression is not supported by this SDK")
        }

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

            var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw CompressionError.initializationFailed("Failed to initialize zstd decompression stream")
            }
            defer { compression_stream_destroy(&stream) }

            // Re-set src fields after init (compression_stream_init may clear all fields except state)
            let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
            stream.src_ptr = srcPtr
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
                        throw CompressionError.decompressionFailed("Zstandard decompression made no progress (likely truncated or invalid stream)")
                    }
                case COMPRESSION_STATUS_ERROR:
                    throw CompressionError.decompressionFailed("Zstandard decompression failed")
                default:
                    throw CompressionError.unknownError("Unexpected zstd decompression status \(status)")
                }
            } while status == COMPRESSION_STATUS_OK

            return output
        }
    }

    /// Reports whether data appears to be Zstandard-compressed.
    /// - Parameter data: Data to check.
    /// - Returns: True if the data starts with the Zstandard magic number.
    public static func canDecode(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }

        // Rule: Zstandard streams start with 0x28B52FFD in little-endian order.
        let magicNumber: UInt32 = 0xFD2F_B528
        let bytes = data.prefix(4)
        let value =
            UInt32(bytes[0]) |
            (UInt32(bytes[1]) << 8) |
            (UInt32(bytes[2]) << 16) |
            (UInt32(bytes[3]) << 24)
        return value == magicNumber
    }

    /// Calculates the compression ratio for a decompressed payload.
    /// - Parameters:
    ///   - compressed: Compressed data.
    ///   - decompressed: Decompressed data.
    /// - Returns: Compression ratio where lower values indicate better compression.
    public static func compressionRatio(compressed: Data, decompressed: Data) -> Double {
        guard !decompressed.isEmpty else { return 1.0 }
        return Double(compressed.count) / Double(decompressed.count)
    }
}
