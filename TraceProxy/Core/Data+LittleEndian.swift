//
//  Data+LittleEndian.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/01.
//

import Foundation

extension Data {
    // Rationale: Centralize little-endian helpers for binary formats (PCAP).
    mutating func appendUInt16LE(_ value: UInt16) {
        var x = value.littleEndian
        self.append(UnsafeBufferPointer(start: &x, count: 1))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var x = value.littleEndian
        self.append(UnsafeBufferPointer(start: &x, count: 1))
    }
}

