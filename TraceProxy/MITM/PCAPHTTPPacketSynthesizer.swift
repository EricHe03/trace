//
//  PCAPHTTPPacketSynthesizer.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/01.
//

import Foundation

/// Synthesizes minimal IPv4+TCP packets for writing application payloads into PCAP.
///
/// Note: This is intentionally not a full TCP/IP implementation. It exists only to wrap
/// HTTP/1.1 bytes into a PCAP record so tools can display them as TCP payload.
enum PCAPHTTPPacketSynthesizer {
    /// Builds a minimal IPv4+TCP packet for the provided payload.
    ///
    /// - Returns: Packet bytes, or `nil` if payload cannot be represented.
    static func makePacket(payload: Data, proxyPort: UInt16, isRequest: Bool) -> Data? {
        // IPv4 total length is UInt16 and includes 20-byte IP header + 20-byte TCP header + payload.
        let maxIPv4PayloadBytes = Int(UInt16.max) - 40
        guard maxIPv4PayloadBytes > 0 else { return nil }
        let cappedPayload = (payload.count > maxIPv4PayloadBytes) ? Data(payload.prefix(maxIPv4PayloadBytes)) : payload

        var packet = Data()
        packet.reserveCapacity(40 + cappedPayload.count)

        let totalLength = UInt16(20 + 20 + cappedPayload.count)
        packet.append(createIPv4Header(
            totalLength: totalLength,
            srcIP: isRequest ? Data([127, 0, 0, 1]) : Data([0, 0, 0, 0]),
            dstIP: isRequest ? Data([0, 0, 0, 0]) : Data([127, 0, 0, 1])
        ))

        packet.append(createTCPHeader(
            srcPort: isRequest ? 12345 : proxyPort,
            dstPort: isRequest ? proxyPort : 12345
        ))

        packet.append(cappedPayload)
        return packet
    }

    private static func createIPv4Header(totalLength: UInt16, srcIP: Data, dstIP: Data) -> Data {
        var header = Data(count: 20)
        header[0] = 0x45 // Version 4, IHL 5.
        header[1] = 0x00 // DSCP/ECN.
        header[2] = UInt8((totalLength >> 8) & 0xFF)
        header[3] = UInt8(totalLength & 0xFF)
        header[4] = 0x00 // ID.
        header[5] = 0x00
        header[6] = 0x40 // Don't fragment.
        header[7] = 0x00 // Fragment offset.
        header[8] = 64 // TTL.
        header[9] = 6 // TCP.
        header[10] = 0x00 // Checksum (left zero).
        header[11] = 0x00
        header.replaceSubrange(12 ..< 16, with: srcIP)
        header.replaceSubrange(16 ..< 20, with: dstIP)
        return header
    }

    private static func createTCPHeader(srcPort: UInt16, dstPort: UInt16) -> Data {
        var header = Data(count: 20)
        header[0] = UInt8((srcPort >> 8) & 0xFF)
        header[1] = UInt8(srcPort & 0xFF)
        header[2] = UInt8((dstPort >> 8) & 0xFF)
        header[3] = UInt8(dstPort & 0xFF)
        header[4] = 0x00 // Sequence number.
        header[5] = 0x00
        header[6] = 0x00
        header[7] = 0x01
        header[8] = 0x00 // Ack number.
        header[9] = 0x00
        header[10] = 0x00
        header[11] = 0x00
        header[12] = 0x50 // Data offset = 20 bytes.
        header[13] = 0x18 // PSH + ACK (arbitrary; best-effort).
        header[14] = 0xFF // Window size.
        header[15] = 0xFF
        header[16] = 0x00 // Checksum (left zero).
        header[17] = 0x00
        header[18] = 0x00 // Urgent pointer.
        header[19] = 0x00
        return header
    }
}
