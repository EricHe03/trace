//
//  StreamingDecoderProtocol.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Defines a streaming decompression interface.
public protocol StreamingDecoderProtocol {
    /// Initializes the decoder.
    /// - Throws: CompressionError if initialization fails.
    func initialize() throws

    /// Decompresses a chunk of data.
    /// - Parameter chunk: Compressed data chunk.
    /// - Returns: Decompressed data, which may be empty if more input is needed.
    /// - Throws: CompressionError if decompression fails.
    func decompress(chunk: Data) throws -> Data

    /// Finalizes decompression and flushes any remaining data.
    /// - Returns: Final decompressed data.
    /// - Throws: CompressionError if finalization fails.
    func finalize() throws -> Data

    /// Resets the decoder to its initial state.
    func reset()

    /// Indicates whether the decoder is initialized.
    var isInitialized: Bool { get }

    /// Reports the total number of compressed bytes processed.
    var totalBytesIn: Int { get }

    /// Reports the total number of decompressed bytes produced.
    var totalBytesOut: Int { get }
}

/// Stores configuration for streaming decompression.
public struct StreamingDecoderConfig: Sendable {
    /// Chunk size in bytes used for processing.
    public let chunkSize: Int

    /// Maximum output size in bytes before the decoder fails.
    public let maxOutputSize: Int

    /// Indicates whether checksums are validated when supported.
    public let validateChecksums: Bool

    /// Provides the default streaming configuration.
    public static let `default` = StreamingDecoderConfig(
        chunkSize: 64 * 1024,
        maxOutputSize: 10 * 1024 * 1024,
        validateChecksums: true
    )
}
