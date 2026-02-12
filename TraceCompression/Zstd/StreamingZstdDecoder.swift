//
//  StreamingZstdDecoder.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import libzstd

/// Provides streaming Zstd decompression using libzstd.
/// Processes data incrementally as chunks arrive instead of accumulating.
public class StreamingZstdDecoder: StreamingDecoderProtocol {
    private var config: StreamingDecoderConfig
    public private(set) var isInitialized: Bool = false
    public private(set) var totalBytesIn: Int = 0
    public private(set) var totalBytesOut: Int = 0

    private var stream: OpaquePointer?

    public init(config: StreamingDecoderConfig = .default) {
        self.config = config
    }

    deinit {
        cleanup()
    }

    public func initialize() throws {
        guard !isInitialized else { return }

        guard let stream = ZSTD_createDStream() else {
            throw CompressionError.initializationFailed("Failed to create zstd decompression stream")
        }

        let status = ZSTD_initDStream(stream)
        guard !ZstdDecoder.isError(status) else {
            ZSTD_freeDStream(stream)
            throw CompressionError.initializationFailed("Failed to initialize zstd stream: \(ZstdDecoder.errorMessage(for: status))")
        }

        self.stream = stream
        self.isInitialized = true
    }

    public func decompress(chunk: Data) throws -> Data {
        guard isInitialized, let stream else {
            throw CompressionError.notInitialized("Decoder not initialized")
        }

        guard !chunk.isEmpty else {
            return Data()
        }

        var output = Data()
        output.reserveCapacity(min(config.chunkSize, max(0, config.maxOutputSize - totalBytesOut)))

        try chunk.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
            guard let baseAddress = inputPointer.baseAddress else {
                throw CompressionError.invalidInput("Invalid chunk buffer")
            }

            var inputBuffer = ZSTD_inBuffer(
                src: UnsafeMutableRawPointer(mutating: baseAddress),
                size: inputPointer.count,
                pos: 0
            )

            var outputChunk = [UInt8](repeating: 0, count: config.chunkSize)
            var previousInputPosition = inputBuffer.pos

            while inputBuffer.pos < inputBuffer.size {
                var produced = 0
                var resultCode: Int = 0

                produced = outputChunk.withUnsafeMutableBytes { destination in
                    var outputBuffer = ZSTD_outBuffer(
                        dst: destination.baseAddress,
                        size: destination.count,
                        pos: 0
                    )

                    resultCode = ZSTD_decompressStream(stream, &outputBuffer, &inputBuffer)
                    return outputBuffer.pos
                }

                guard !ZstdDecoder.isError(resultCode) else {
                    throw CompressionError.decompressionFailed("Zstd decompression failed: \(ZstdDecoder.errorMessage(for: resultCode))")
                }

                if produced > 0 {
                    output.append(outputChunk, count: produced)
                    totalBytesOut += produced

                    // Rule: Enforce maxOutputSize to avoid unbounded output growth.
                    if totalBytesOut > config.maxOutputSize {
                        throw CompressionError.bufferTooSmall("Output exceeded \(config.maxOutputSize) bytes")
                    }
                }

                if produced == 0, inputBuffer.pos == previousInputPosition {
                    throw CompressionError.decompressionFailed("Zstd decompression made no progress")
                }

                previousInputPosition = inputBuffer.pos
            }
        }

        totalBytesIn += chunk.count
        return output
    }

    public func finalize() throws -> Data {
        guard isInitialized, let stream else {
            throw CompressionError.notInitialized("Decoder not initialized")
        }

        var output = Data()
        output.reserveCapacity(min(config.chunkSize, max(0, config.maxOutputSize - totalBytesOut)))
        var outputChunk = [UInt8](repeating: 0, count: config.chunkSize)
        var emptyByte: UInt8 = 0

        try withUnsafeMutableBytes(of: &emptyByte) { emptyBuffer in
            var inputBuffer = ZSTD_inBuffer(
                src: emptyBuffer.baseAddress,
                size: 0,
                pos: 0
            )

            while true {
                var produced = 0
                var resultCode: Int = 0

                produced = outputChunk.withUnsafeMutableBytes { destination in
                    var outputBuffer = ZSTD_outBuffer(
                        dst: destination.baseAddress,
                        size: destination.count,
                        pos: 0
                    )

                    resultCode = ZSTD_decompressStream(stream, &outputBuffer, &inputBuffer)
                    return outputBuffer.pos
                }

                guard !ZstdDecoder.isError(resultCode) else {
                    throw CompressionError.decompressionFailed("Zstd finalization failed: \(ZstdDecoder.errorMessage(for: resultCode))")
                }

                if produced > 0 {
                    output.append(outputChunk, count: produced)
                    totalBytesOut += produced

                    if totalBytesOut > config.maxOutputSize {
                        throw CompressionError.bufferTooSmall("Output exceeded \(config.maxOutputSize) bytes")
                    }
                }

                if resultCode == 0 {
                    break
                }

                if produced == 0 {
                    throw CompressionError.decompressionFailed("Zstd finalization requires more input (truncated stream)")
                }
            }
        }

        cleanup()
        return output
    }

    public func reset() {
        cleanup()
        totalBytesIn = 0
        totalBytesOut = 0
    }

    private func cleanup() {
        if let stream {
            ZSTD_freeDStream(stream)
            self.stream = nil
        }
        isInitialized = false
    }
}
