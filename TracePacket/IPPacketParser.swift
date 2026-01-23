//
//  IPPacketParser.swift
//  TracePacket
//
//  Created by Justin on 2026/01/19.
//

import Foundation

public enum IPPacketParser {
    public static func parse(_ data: Data) -> IPPacket? {
        guard data.count >= 1 else { return nil }
        let version = data[0] >> 4
        switch version {
        case 4:
            return parseIPv4(data)
        case 6:
            return parseIPv6(data)
        default:
            return nil
        }
    }

    private static func parseIPv4(_ data: Data) -> IPPacket? {
        guard data.count >= 20 else { return nil }
        let ihl = Int(data[0] & 0x0F) * 4
        guard ihl >= 20, data.count >= ihl else { return nil }
        let totalLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        guard totalLength >= ihl, data.count >= totalLength else { return nil }
        let proto = data[9]
        let src = readIPv4(data, offset: 12)
        let dst = readIPv4(data, offset: 16)
        let payload = data.subdata(in: ihl ..< totalLength)
        return IPPacket(
            version: 4,
            headerLength: ihl,
            totalLength: totalLength,
            protocolNumber: proto,
            source: src,
            destination: dst,
            payload: payload
        )
    }

    private static func parseIPv6(_ data: Data) -> IPPacket? {
        guard data.count >= 40 else { return nil }
        let payloadLength = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        let nextHeader = data[6]
        let totalLength = 40 + payloadLength
        guard data.count >= totalLength else { return nil }
        let src = readIPv6(data, offset: 8)
        let dst = readIPv6(data, offset: 24)
        let payload = data.subdata(in: 40 ..< totalLength)
        return IPPacket(
            version: 6,
            headerLength: 40,
            totalLength: totalLength,
            protocolNumber: nextHeader,
            source: src,
            destination: dst,
            payload: payload
        )
    }

    private static func readIPv4(_ data: Data, offset: Int) -> IPAddress {
        let value = UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
        return .v4(value)
    }

    private static func readIPv6(_ data: Data, offset: Int) -> IPAddress {
        let hi = readUInt64(data, offset: offset)
        let lo = readUInt64(data, offset: offset + 8)
        return .v6((hi, lo))
    }

    private static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }
}
