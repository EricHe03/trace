//
//  StreamingBrotliDecoder.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Compression
import Foundation

/// Provides streaming Brotli decompression using Apple's Compression framework.
/// Processes data incrementally as chunks arrive instead of accumulating.
public class StreamingBrotliDecoder: StreamingDecoderProtocol {
    private var config: StreamingDecoderConfig
    public private(set) var isInitialized: Bool = false
    public private(set) var totalBytesIn: Int = 0
    public private(set) var totalBytesOut: Int = 0

    private var stream: compression_stream
    private var streamInitialized: Bool = false

    private var outputBuffer: UnsafeMutablePointer<UInt8>?
    private var placeholderByte: UInt8 = 0

    public init(config: StreamingDecoderConfig = .default) {
        self.config = config
        self.stream = compression_stream()
        resetStreamToPlaceholder()
    }

    deinit {
        cleanup()
    }

    public func initialize() throws {
        guard !isInitialized else { return }

        outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: config.chunkSize)

        let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
        guard status != COMPRESSION_STATUS_ERROR else {
            outputBuffer?.deallocate()
            outputBuffer = nil
            resetStreamToPlaceholder()
            throw CompressionError.initializationFailed("Failed to initialize Brotli decompression stream")
        }

        streamInitialized = true
        isInitialized = true
    }

    public func decompress(chunk: Data) throws -> Data {
        guard isInitialized else {
            throw CompressionError.notInitialized("Decoder not initialized")
        }

        guard !chunk.isEmpty else {
            return Data()
        }

        guard let outputBuffer else {
            throw CompressionError.notInitialized("Output buffer not allocated")
        }

        var output = Data()

        try chunk.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
            guard let baseAddress = inputPointer.baseAddress else {
                throw CompressionError.invalidInput("Invalid chunk buffer")
            }

            stream.src_ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            stream.src_size = chunk.count

            repeat {
                stream.dst_ptr = outputBuffer
                stream.dst_size = config.chunkSize

                let status = compression_stream_process(&stream, 0)

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let bytesProduced = config.chunkSize - stream.dst_size
                    if bytesProduced > 0 {
                        output.append(outputBuffer, count: bytesProduced)
                        totalBytesOut += bytesProduced
                    }

                    // Rule: Enforce maxOutputSize to avoid unbounded output growth.
                    if totalBytesOut > config.maxOutputSize {
                        throw CompressionError.bufferTooSmall("Output exceeded \(config.maxOutputSize) bytes")
                    }

                case COMPRESSION_STATUS_ERROR:
                    throw CompressionError.decompressionFailed("Brotli decompression failed")

                default:
                    throw CompressionError.unknownError("Unexpected Brotli decompression status \(status)")
                }
            } while stream.src_size > 0 || stream.dst_size == 0
        }

        totalBytesIn += chunk.count
        return output
    }

    public func finalize() throws -> Data {
        guard isInitialized else {
            throw CompressionError.notInitialized("Decoder not initialized")
        }

        guard let outputBuffer else {
            throw CompressionError.notInitialized("Output buffer not allocated")
        }

        var output = Data()

        // Rule: Use an empty source to signal end of input to the stream.
        stream.src_ptr = UnsafePointer(Self.placeholderBuffer)
        stream.src_size = 0

        var status: compression_status
        repeat {
            stream.dst_ptr = outputBuffer
            stream.dst_size = config.chunkSize

            status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let bytesProduced = config.chunkSize - stream.dst_size
                if bytesProduced > 0 {
                    output.append(outputBuffer, count: bytesProduced)
                    totalBytesOut += bytesProduced
                }

            case COMPRESSION_STATUS_ERROR:
                throw CompressionError.decompressionFailed("Brotli finalization failed")

            default:
                throw CompressionError.unknownError("Unexpected Brotli finalization status \(status)")
            }
        } while status == COMPRESSION_STATUS_OK && stream.dst_size == 0

        cleanup()
        return output
    }

    public func reset() {
        cleanup()
        totalBytesIn = 0
        totalBytesOut = 0
    }

    private func cleanup() {
        if streamInitialized {
            compression_stream_destroy(&stream)
            streamInitialized = false
        }
        outputBuffer?.deallocate()
        outputBuffer = nil
        isInitialized = false

        // Rule: Recreate the stream to avoid "invalid reuse" after a failed init attempt.
        resetStreamToPlaceholder()
    }

    private func resetStreamToPlaceholder() {
        withUnsafeMutablePointer(to: &placeholderByte) { placeholderPtr in
            stream = compression_stream(
                dst_ptr: placeholderPtr,
                dst_size: 0,
                src_ptr: UnsafePointer(placeholderPtr),
                src_size: 0,
                state: nil
            )
        }
    }
}
