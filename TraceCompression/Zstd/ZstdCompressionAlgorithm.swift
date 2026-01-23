//
//  ZstdCompressionAlgorithm.swift
//  TraceCompression
//
//  Created by Justin on 2026/01/10.
//

import Compression

/// Selects a supported Zstandard algorithm at runtime.
public enum ZstdCompressionAlgorithm {
    // Rule: Probe candidate raw values because SDKs expose different Zstd constants.
    public static let supportedAlgorithm: compression_algorithm? = {
        let candidates: [compression_algorithm] = [
            compression_algorithm(rawValue: 0xD03),
            compression_algorithm(rawValue: 0xD01),
            compression_algorithm(rawValue: 0xD02),
            compression_algorithm(rawValue: 0xD04),
            compression_algorithm(rawValue: 0xD05)
        ]

        for candidate in candidates {
            let tempBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            defer { tempBuffer.deallocate() }
            var stream = compression_stream(
                dst_ptr: tempBuffer,
                dst_size: 0,
                src_ptr: UnsafePointer(tempBuffer),
                src_size: 0,
                state: nil
            )
            let status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, candidate)
            if status != COMPRESSION_STATUS_ERROR {
                compression_stream_destroy(&stream)
                return candidate
            }
        }

        return nil
    }()
}
