//
//  GzipWrapper.swift
//  TraceCore
//
//  Created by Justin on 2026/02/04.
//

import Foundation

enum GzipWrapper {
    /// Removes the gzip header/trailer, returning the raw DEFLATE payload.
    /// This supports optional gzip header fields (FEXTRA/FNAME/FCOMMENT/FHCRC).
    static func strip(from data: Data) -> Data? {
        // Minimum gzip header is 10 bytes + 8-byte footer (CRC32 + ISIZE)
        guard data.count > 18 else { return nil }
        guard data[0] == 0x1F, data[1] == 0x8B else { return nil }

        var index = 10 // ID1, ID2, CM, FLG, MTIME(4), XFL, OS
        let flags = data[3]

        // FEXTRA
        if flags & 0x04 != 0 {
            guard index + 2 <= data.count else { return nil }
            let xlen = Int(data[index]) | (Int(data[index + 1]) << 8)
            index += 2 + xlen
        }

        // FNAME
        if flags & 0x08 != 0 {
            while index < data.count, data[index] != 0 {
                index += 1
            }
            index += 1
        }

        // FCOMMENT
        if flags & 0x10 != 0 {
            while index < data.count, data[index] != 0 {
                index += 1
            }
            index += 1
        }

        // FHCRC
        if flags & 0x02 != 0 {
            index += 2
        }

        let footerLength = 8 // CRC32 + ISIZE
        guard index + footerLength <= data.count else { return nil }

        let deflatedRange = index ..< (data.count - footerLength)
        return data.subdata(in: deflatedRange)
    }
}
