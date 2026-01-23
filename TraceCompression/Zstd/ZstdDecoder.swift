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
        guard !data.isEmpty else {
            throw CompressionError.invalidInput("Empty data")
        }

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

            var output = Data()

            repeat {
                stream.dst_ptr = destinationBuffer
                stream.dst_size = bufferSize

                status = compression_stream_process(&stream, 0)

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 {
                        output.append(destinationBuffer, count: produced)
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
        let dataPrefix = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }

        return dataPrefix == magicNumber
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
