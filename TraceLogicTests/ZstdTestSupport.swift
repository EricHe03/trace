//
//  ZstdTestSupport.swift
//  TraceTests
//
//  Created by Justin on 2026/02/11.
//

import Foundation
import libzstd
@testable import TraceCompression
import XCTest

enum ZstdTestSupportError: Error {
    case compressionFailed(String)
}

func requireZstdSupport(
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    try XCTSkipIf(!ZstdDecoder.isSupported, "Zstandard compression is unavailable on this SDK", file: file, line: line)
}

func compressZstd(
    _ data: Data,
    level: Int32 = 3
) throws -> Data {
    guard !data.isEmpty else { return Data() }

    let bound = Int(ZSTD_compressBound(data.count))
    var compressed = Data(count: bound)

    let written = compressed.withUnsafeMutableBytes { (outputBuffer: UnsafeMutableRawBufferPointer) -> Int in
        data.withUnsafeBytes { (inputBuffer: UnsafeRawBufferPointer) -> Int in
            guard let outputBase = outputBuffer.baseAddress,
                  let inputBase = inputBuffer.baseAddress else {
                return 0
            }

            return ZSTD_compress(
                outputBase,
                outputBuffer.count,
                inputBase,
                inputBuffer.count,
                level
            )
        }
    }

    guard !ZstdDecoder.isError(written) else {
        throw ZstdTestSupportError.compressionFailed(String(cString: ZSTD_getErrorName(written)))
    }

    compressed.count = written
    return compressed
}
