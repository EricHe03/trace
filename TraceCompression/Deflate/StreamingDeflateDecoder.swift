//
//  StreamingDeflateDecoder.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import zlib

/// Provides streaming gzip and zlib decompression using zlib.
public class StreamingDeflateDecoder: StreamingDecoderProtocol {
    private var stream: z_stream
    private var config: StreamingDecoderConfig
    public private(set) var isInitialized: Bool = false
    public private(set) var totalBytesIn: Int = 0
    public private(set) var totalBytesOut: Int = 0
    private var didReachStreamEnd: Bool = false
    private var buffer: Data

    /// Creates a decoder with the provided configuration.
    /// - Parameter config: Decoder configuration.
    public init(config: StreamingDecoderConfig = .default) {
        self.config = config
        self.stream = z_stream()
        self.buffer = Data(capacity: config.chunkSize)
    }

    deinit {
        if isInitialized {
            inflateEnd(&stream)
        }
    }

    public func initialize() throws {
        guard !isInitialized else { return }

        // Rule: Use MAX_WBITS + 32 to enable gzip and zlib wrapper autodetection.
        let result = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))

        guard result == Z_OK else {
            throw CompressionError.initializationFailed("inflateInit2 failed with code \(result)")
        }

        isInitialized = true
    }

    public func decompress(chunk: Data) throws -> Data {
        guard isInitialized else {
            throw CompressionError.notInitialized("Decoder not initialized")
        }

        guard !chunk.isEmpty else {
            return Data()
        }

        var output = Data()
        var outputBuffer = [UInt8](repeating: 0, count: config.chunkSize)

        try chunk.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
            stream.avail_in = UInt32(chunk.count)
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: inputPointer.baseAddress?.assumingMemoryBound(to: UInt8.self))

            repeat {
                try outputBuffer.withUnsafeMutableBufferPointer { outputPointer in
                    stream.avail_out = UInt32(config.chunkSize)
                    stream.next_out = outputPointer.baseAddress

                    let result = inflate(&stream, Z_NO_FLUSH)

                    guard result == Z_OK || result == Z_STREAM_END else {
                        throw CompressionError.decompressionFailed("inflate failed with code \(result)")
                    }

                    if result == Z_STREAM_END {
                        didReachStreamEnd = true
                    }

                    let bytesProduced = config.chunkSize - Int(stream.avail_out)
                    if bytesProduced > 0, let baseAddress = outputPointer.baseAddress {
                        output.append(baseAddress, count: bytesProduced)
                        totalBytesOut += bytesProduced
                    }

                    // Rule: Enforce maxOutputSize to avoid unbounded output growth.
                    if totalBytesOut > config.maxOutputSize {
                        throw CompressionError.bufferTooSmall("Output exceeded \(config.maxOutputSize) bytes")
                    }
                }
            } while stream.avail_out == 0
        }

        totalBytesIn += chunk.count
        return output
    }

    public func finalize() throws -> Data {
        guard isInitialized else {
            throw CompressionError.notInitialized("Decoder not initialized")
        }

        if totalBytesIn == 0 {
            inflateEnd(&stream)
            isInitialized = false
            didReachStreamEnd = false
            return Data()
        }

        if didReachStreamEnd {
            inflateEnd(&stream)
            isInitialized = false
            didReachStreamEnd = false
            return Data()
        }

        var output = Data()
        var outputBuffer = [UInt8](repeating: 0, count: config.chunkSize)

        stream.avail_in = 0
        stream.next_in = nil

        var result: Int32 = Z_OK
        repeat {
            let inflateResult = try outputBuffer.withUnsafeMutableBufferPointer { outputPointer -> Int32 in
                stream.avail_out = UInt32(config.chunkSize)
                stream.next_out = outputPointer.baseAddress

                let result = inflate(&stream, Z_FINISH)

                guard result == Z_OK || result == Z_STREAM_END else {
                    throw CompressionError.decompressionFailed("inflate finalize failed with code \(result)")
                }

                if result == Z_STREAM_END {
                    didReachStreamEnd = true
                }

                let bytesProduced = config.chunkSize - Int(stream.avail_out)
                if bytesProduced > 0, let baseAddress = outputPointer.baseAddress {
                    output.append(baseAddress, count: bytesProduced)
                    totalBytesOut += bytesProduced
                }

                return result
            }
            result = inflateResult
        } while result != Z_STREAM_END && stream.avail_out == 0

        inflateEnd(&stream)
        isInitialized = false
        didReachStreamEnd = false

        return output
    }

    public func reset() {
        if isInitialized {
            inflateEnd(&stream)
        }
        stream = z_stream()
        isInitialized = false
        totalBytesIn = 0
        totalBytesOut = 0
        didReachStreamEnd = false
        buffer.removeAll(keepingCapacity: true)
    }
}
