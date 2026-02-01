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
    /// - Throws: DecompressionError if decompression fails.
    public static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        do {
            return try data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data in
                guard let baseAddress = sourcePtr.baseAddress else {
                    throw DecompressionError.invalidData
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
                    throw DecompressionError.initializationFailed
                }
                defer { compression_stream_destroy(&stream) }

                // Re-set src fields after init (compression_stream_init clears all fields except state)
                stream.src_ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
                stream.src_size = data.count

                var output = Data()

                repeat {
                    stream.dst_ptr = destinationBuffer
                    stream.dst_size = bufferSize

                    // Always finalize since all input is provided upfront
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                    switch status {
                    case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                        let produced = bufferSize - stream.dst_size
                        if produced > 0 {
                            output.append(destinationBuffer, count: produced)
                        } else if status == COMPRESSION_STATUS_OK {
                            // No progress while processing - likely invalid data
                            throw DecompressionError.processingFailed
                        }
                    case COMPRESSION_STATUS_ERROR:
                        throw DecompressionError.processingFailed
                    default:
                        throw DecompressionError.unknownError
                    }
                } while status == COMPRESSION_STATUS_OK

                return output
            }
        } catch let error as DecompressionError {
            throw error
        } catch {
            throw DecompressionError.unknownError
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

            let bufferSize = 256
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { destinationBuffer.deallocate() }

            // Tradeoff: Probe only the first 64 bytes to keep validation cheap.
            var stream = compression_stream(
                dst_ptr: destinationBuffer,
                dst_size: bufferSize,
                src_ptr: baseAddress.assumingMemoryBound(to: UInt8.self),
                src_size: min(data.count, 64),
                state: nil
            )

            let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
            defer { compression_stream_destroy(&stream) }

            return status != COMPRESSION_STATUS_ERROR
        }
    }
}
