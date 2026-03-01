//
//  ZstdDecoder.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import libzstd

/// Provides Zstandard decompression.
public class ZstdDecoder {
    /// libzstd is vendored as an SPM dependency, so support is always present when this module loads.
    public static var isSupported: Bool {
        true
    }

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

        guard let stream = ZSTD_createDStream() else {
            throw CompressionError.initializationFailed("Failed to create zstd decompression stream")
        }
        defer { ZSTD_freeDStream(stream) }

        let initStatus = ZSTD_initDStream(stream)
        guard !isError(initStatus) else {
            throw CompressionError.initializationFailed("Failed to initialize zstd stream: \(errorMessage(for: initStatus))")
        }

        let outputChunkSize = max(Int(ZSTD_DStreamOutSize()), 4 * 1024)
        var outputChunk = [UInt8](repeating: 0, count: outputChunkSize)
        var output = Data()
        if let maxOutputBytes {
            output.reserveCapacity(min(maxOutputBytes, outputChunkSize))
        }

        return try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let sourceBase = source.baseAddress else {
                throw CompressionError.invalidInput("Invalid data buffer")
            }

            var inputBuffer = ZSTD_inBuffer(
                src: UnsafeMutableRawPointer(mutating: sourceBase),
                size: source.count,
                pos: 0
            )
            var previousInputPosition = inputBuffer.pos

            while true {
                var produced = 0
                var resultCode = 0

                produced = outputChunk.withUnsafeMutableBytes { destination in
                    var outputBuffer = ZSTD_outBuffer(
                        dst: destination.baseAddress,
                        size: destination.count,
                        pos: 0
                    )
                    resultCode = ZSTD_decompressStream(stream, &outputBuffer, &inputBuffer)
                    return outputBuffer.pos
                }

                guard !isError(resultCode) else {
                    throw CompressionError.decompressionFailed("Zstandard decompression failed: \(errorMessage(for: resultCode))")
                }

                if produced > 0 {
                    if let maxOutputBytes {
                        let remaining = max(0, maxOutputBytes - output.count)
                        if remaining > 0 {
                            output.append(outputChunk, count: min(remaining, produced))
                        }
                    } else {
                        output.append(outputChunk, count: produced)
                    }
                }

                if let maxOutputBytes, output.count >= maxOutputBytes {
                    return output
                }

                if inputBuffer.pos == inputBuffer.size, resultCode == 0 {
                    break
                }

                if produced == 0, inputBuffer.pos == previousInputPosition {
                    throw CompressionError.decompressionFailed("Zstandard decompression made no progress (likely truncated or invalid stream)")
                }

                previousInputPosition = inputBuffer.pos
            }

            if inputBuffer.pos != inputBuffer.size {
                throw CompressionError.decompressionFailed("Zstandard decompression left unconsumed input")
            }

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

    static func isError(_ code: Int) -> Bool {
        ZSTD_isError(code) != 0
    }

    static func errorMessage(for code: Int) -> String {
        String(cString: ZSTD_getErrorName(code))
    }
}
