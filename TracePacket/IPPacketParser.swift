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

        // If this is a non-initial fragment, we can't reliably parse transport headers.
        // We intentionally drop non-first fragments instead of mis-parsing them as TCP/UDP.
        let fragmentOffset = Int((UInt16(data[6] & 0x1F) << 8) | UInt16(data[7]))
        if fragmentOffset != 0 {
            return nil
        }

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
        var nextHeader = data[6]
        let totalLength = 40 + payloadLength
        guard data.count >= totalLength else { return nil }
        let src = readIPv6(data, offset: 8)
        let dst = readIPv6(data, offset: 24)

        var headerLength = 40
        if payloadLength > 0 {
            guard let (finalHeader, finalOffset) = parseIPv6NextHeaderChain(
                data: data,
                totalLength: totalLength,
                initialNextHeader: nextHeader,
                initialOffset: 40
            ) else {
                return nil
            }
            nextHeader = finalHeader
            headerLength = finalOffset
        }

        let payload = headerLength <= totalLength ? data.subdata(in: headerLength ..< totalLength) : Data()
        return IPPacket(
            version: 6,
            headerLength: headerLength,
            totalLength: totalLength,
            protocolNumber: nextHeader,
            source: src,
            destination: dst,
            payload: payload
        )
    }

    private static func parseIPv6NextHeaderChain(
        data: Data,
        totalLength: Int,
        initialNextHeader: UInt8,
        initialOffset: Int
    ) -> (finalHeader: UInt8, finalOffset: Int)? {
        var nextHeader = initialNextHeader
        var offset = initialOffset

        while true {
            switch nextHeader {
            case 0, 43, 60:
                // Hop-by-Hop Options (0), Routing (43), Destination Options (60)
                guard offset + 2 <= totalLength else { return nil }
                let newNext = data[offset]
                let hdrExtLen = Int(data[offset + 1])
                let headerBytes = (hdrExtLen + 1) * 8
                guard headerBytes >= 8, offset + headerBytes <= totalLength else { return nil }
                nextHeader = newNext
                offset += headerBytes
            case 44:
                // Fragment header (fixed 8 bytes)
                guard offset + 8 <= totalLength else { return nil }
                let newNext = data[offset]
                let offsetAndFlags = (UInt16(data[offset + 2]) << 8) | UInt16(data[offset + 3])
                let fragmentOffset = offsetAndFlags >> 3
                if fragmentOffset != 0 {
                    // Non-first fragment: transport header may not be present.
                    return nil
                }
                nextHeader = newNext
                offset += 8
            case 51:
                // Authentication Header (AH): length is in 32-bit words, minus 2.
                guard offset + 2 <= totalLength else { return nil }
                let newNext = data[offset]
                let payloadLen = Int(data[offset + 1])
                let headerBytes = (payloadLen + 2) * 4
                guard headerBytes >= 8, offset + headerBytes <= totalLength else { return nil }
                nextHeader = newNext
                offset += headerBytes
            case 50:
                // ESP: encrypted payload; stop here.
                return (nextHeader, offset)
            case 59:
                // No Next Header
                return (nextHeader, offset)
            default:
                return (nextHeader, offset)
            }

            if offset >= totalLength {
                return (nextHeader, offset)
            }
        }
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
