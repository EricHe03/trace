//
//  IPAddress.swift
//  TracePacket
//
//  Created by Justin on 2026/01/19.
//

import Foundation

public enum IPAddress: Hashable, Sendable, CustomStringConvertible {
    case v4(UInt32)
    case v6((UInt64, UInt64))

    public static func == (lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
        case let (.v4(left), .v4(right)):
            left == right
        case let (.v6((leftHi, leftLo)), .v6((rightHi, rightLo))):
            leftHi == rightHi && leftLo == rightLo
        default:
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .v4(value):
            hasher.combine(0)
            hasher.combine(value)
        case let .v6((hi, lo)):
            hasher.combine(1)
            hasher.combine(hi)
            hasher.combine(lo)
        }
    }

    public var description: String {
        switch self {
        case let .v4(value):
            let a = (value >> 24) & 0xFF
            let b = (value >> 16) & 0xFF
            let c = (value >> 8) & 0xFF
            let d = value & 0xFF
            return "\(a).\(b).\(c).\(d)"
        case let .v6((hi, lo)):
            return String(
                format: "%04x:%04x:%04x:%04x:%04x:%04x:%04x:%04x",
                (hi >> 48) & 0xFFFF,
                (hi >> 32) & 0xFFFF,
                (hi >> 16) & 0xFFFF,
                hi & 0xFFFF,
                (lo >> 48) & 0xFFFF,
                (lo >> 32) & 0xFFFF,
                (lo >> 16) & 0xFFFF,
                lo & 0xFFFF
            )
        }
    }
}
