//
//  TCPParser.swift
//  TracePacket
//
//  Created by Justin on 2026/01/19.
//

import Foundation

public enum TCPParser {
    public static func parse(_ data: Data) -> TCPPacket? {
        guard data.count >= 20 else { return nil }

        let srcPort = UInt16(data[0]) << 8 | UInt16(data[1])
        let dstPort = UInt16(data[2]) << 8 | UInt16(data[3])
        let seq = readUInt32(data, offset: 4)
        let ack = readUInt32(data, offset: 8)
        let dataOffset = Int((data[12] >> 4) * 4)
        guard dataOffset >= 20, data.count >= dataOffset else { return nil }
        let flags = TCPPacket.Flags(rawValue: data[13] & 0x3F)
        let window = UInt16(data[14]) << 8 | UInt16(data[15])
        let options = parseOptions(data: data, headerLength: dataOffset)
        let payload = data.subdata(in: dataOffset ..< data.count)

        return TCPPacket(
            sourcePort: srcPort,
            destinationPort: dstPort,
            sequenceNumber: seq,
            acknowledgmentNumber: ack,
            dataOffset: dataOffset,
            flags: flags,
            windowSize: window,
            options: options,
            payload: payload
        )
    }

    private static func parseOptions(data: Data, headerLength: Int) -> TCPPacket.Options {
        guard headerLength > 20 else {
            return TCPPacket.Options(mss: nil, windowScale: nil, sackPermitted: false, timestamps: nil)
        }

        var mss: UInt16?
        var windowScale: UInt8?
        var sackPermitted = false
        var timestamps: TCPPacket.TimestampOption?

        var index = 20
        while index < headerLength {
            let kind = data[index]
            if kind == 0 {
                break
            } else if kind == 1 {
                index += 1
                continue
            }

            guard index + 1 < headerLength else { break }
            let length = Int(data[index + 1])
            guard length >= 2, index + length <= headerLength else { break }

            switch kind {
            case 2 where length == 4:
                let value = UInt16(data[index + 2]) << 8 | UInt16(data[index + 3])
                mss = mss ?? value
            case 3 where length == 3:
                windowScale = windowScale ?? data[index + 2]
            case 4 where length == 2:
                sackPermitted = true
            case 8 where length >= 10:
                let tsVal = UInt32(data[index + 2]) << 24 |
                    UInt32(data[index + 3]) << 16 |
                    UInt32(data[index + 4]) << 8 |
                    UInt32(data[index + 5])
                let tsEcr = UInt32(data[index + 6]) << 24 |
                    UInt32(data[index + 7]) << 16 |
                    UInt32(data[index + 8]) << 8 |
                    UInt32(data[index + 9])
                timestamps = timestamps ?? TCPPacket.TimestampOption(value: tsVal, echo: tsEcr)
            default:
                break
            }

            index += length
        }

        return TCPPacket.Options(
            mss: mss,
            windowScale: windowScale,
            sackPermitted: sackPermitted,
            timestamps: timestamps
        )
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }
}
