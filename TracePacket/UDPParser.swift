//
//  UDPParser.swift
//  TracePacket
//
//  Created by Justin on 2026/01/20.
//

import Foundation

public enum UDPParser {
    public static func parse(_ data: Data) -> UDPPacket? {
        guard data.count >= 8 else { return nil }
        let srcPort = UInt16(data[0]) << 8 | UInt16(data[1])
        let dstPort = UInt16(data[2]) << 8 | UInt16(data[3])
        let length = UInt16(data[4]) << 8 | UInt16(data[5])
        guard length >= 8, data.count >= Int(length) else { return nil }
        let payload = data.subdata(in: 8 ..< Int(length))
        return UDPPacket(
            sourcePort: srcPort,
            destinationPort: dstPort,
            length: length,
            payload: payload
        )
    }
}
