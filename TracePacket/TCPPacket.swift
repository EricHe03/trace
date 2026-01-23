//
//  TCPPacket.swift
//  TracePacket
//
//  Created by Justin on 2026/01/19.
//

import Foundation

public struct TCPPacket: Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let fin = Flags(rawValue: 0x01)
        public static let syn = Flags(rawValue: 0x02)
        public static let rst = Flags(rawValue: 0x04)
        public static let psh = Flags(rawValue: 0x08)
        public static let ack = Flags(rawValue: 0x10)
        public static let urg = Flags(rawValue: 0x20)
    }

    public struct TimestampOption: Sendable {
        public let value: UInt32
        public let echo: UInt32

        public init(value: UInt32, echo: UInt32) {
            self.value = value
            self.echo = echo
        }
    }

    public struct Options: Sendable {
        public let mss: UInt16?
        public let windowScale: UInt8?
        public let sackPermitted: Bool
        public let timestamps: TimestampOption?

        public init(
            mss: UInt16?,
            windowScale: UInt8?,
            sackPermitted: Bool,
            timestamps: TimestampOption?
        ) {
            self.mss = mss
            self.windowScale = windowScale
            self.sackPermitted = sackPermitted
            self.timestamps = timestamps
        }
    }

    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let sequenceNumber: UInt32
    public let acknowledgmentNumber: UInt32
    public let dataOffset: Int
    public let flags: Flags
    public let windowSize: UInt16
    public let options: Options
    public let payload: Data
}
