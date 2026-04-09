//
//  NIOMITMInitialIngressHandler+TLSProbe.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/20.
//

import Foundation
import NIOCore

extension NIOMITMInitialIngressHandler {
    func tlsProbeState(for buffer: ByteBuffer) -> TLSProbeState {
        guard let firstByte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
            return .needMore
        }
        guard firstByte == 0x16 else {
            return .notTLS
        }
        guard buffer.readableBytes >= 6 else {
            return .needMore
        }

        guard let majorVersion = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
              let handshakeType = buffer.getInteger(at: buffer.readerIndex + 5, as: UInt8.self)
        else {
            return .needMore
        }
        guard majorVersion == 0x03, handshakeType == 0x01 else {
            return .notTLS
        }
        return .tlsClientHello
    }

    func parseTLSSNI(from buffer: ByteBuffer) -> String? {
        var copy = buffer
        let data = Data(copy.readableBytesView)
        return parseTLSSNI(from: data)
    }

    func parseTLSALPNProtocols(from buffer: ByteBuffer) -> [String] {
        var copy = buffer
        let data = Data(copy.readableBytesView)
        return parseTLSALPNProtocols(from: data)
    }

    func parseTLSALPNProtocols(from data: Data) -> [String] {
        func u16(_ i: Int) -> Int? {
            guard i + 1 < data.count else { return nil }
            return (Int(data[i]) << 8) | Int(data[i + 1])
        }

        func u24(_ i: Int) -> Int? {
            guard i + 2 < data.count else { return nil }
            return (Int(data[i]) << 16) | (Int(data[i + 1]) << 8) | Int(data[i + 2])
        }

        guard data.count >= 5 else { return [] }
        guard data[0] == 0x16 else { return [] }
        guard data[1] == 0x03 else { return [] }
        guard let recordLen = u16(3) else { return [] }
        let recordEnd = 5 + recordLen
        guard recordEnd <= data.count else { return [] }

        let hsStart = 5
        guard data[hsStart] == 0x01 else { return [] }
        guard let hsLen = u24(hsStart + 1) else { return [] }
        let hsEnd = hsStart + 4 + hsLen
        guard hsEnd <= data.count else { return [] }

        var i = hsStart + 4
        i += 2 + 32
        guard i < hsEnd else { return [] }

        let sessionIDLen = Int(data[i]); i += 1
        i += sessionIDLen
        guard i + 2 <= hsEnd else { return [] }

        guard let cipherLen = u16(i) else { return [] }
        i += 2 + cipherLen
        guard i < hsEnd else { return [] }

        let compLen = Int(data[i]); i += 1
        i += compLen
        guard i + 2 <= hsEnd else { return [] }

        guard let extTotalLen = u16(i) else { return [] }
        i += 2
        let extEnd = i + extTotalLen
        guard extEnd <= hsEnd else { return [] }

        while i + 4 <= extEnd {
            guard let extType = u16(i), let extLen = u16(i + 2) else { return [] }
            i += 4
            let extDataEnd = i + extLen
            guard extDataEnd <= extEnd else { return [] }

            if extType == 0x0010 {
                guard i + 2 <= extDataEnd, let listLen = u16(i) else { return [] }
                var j = i + 2
                let listEnd = j + listLen
                guard listEnd <= extDataEnd else { return [] }

                var protocols: [String] = []
                var seen = Set<String>()
                while j < listEnd {
                    guard j < listEnd else { return protocols }
                    let protoLen = Int(data[j]); j += 1
                    guard j + protoLen <= listEnd else { return protocols }
                    let protoData = data.subdata(in: j ..< (j + protoLen))
                    // RFC 7301: protocol names are opaque octets. No whitespace-trimming or
                    // case-folding is permitted; names must be forwarded as-is.
                    if let proto = String(data: protoData, encoding: .utf8),
                       !proto.isEmpty,
                       !seen.contains(proto) {
                        protocols.append(proto)
                        seen.insert(proto)
                    }
                    j += protoLen
                }
                return protocols
            }

            i = extDataEnd
        }

        return []
    }

    // swiftlint:disable:next cyclomatic_complexity
    func parseTLSSNI(from data: Data) -> String? {
        func u16(_ i: Int) -> Int? {
            guard i + 1 < data.count else { return nil }
            return (Int(data[i]) << 8) | Int(data[i + 1])
        }

        func u24(_ i: Int) -> Int? {
            guard i + 2 < data.count else { return nil }
            return (Int(data[i]) << 16) | (Int(data[i + 1]) << 8) | Int(data[i + 2])
        }

        guard data.count >= 5 else { return nil }
        guard data[0] == 0x16 else { return nil }
        guard data[1] == 0x03 else { return nil }
        guard let recordLen = u16(3) else { return nil }
        let recordEnd = 5 + recordLen
        guard recordEnd <= data.count else { return nil }

        let hsStart = 5
        guard data[hsStart] == 0x01 else { return nil }
        guard let hsLen = u24(hsStart + 1) else { return nil }
        let hsEnd = hsStart + 4 + hsLen
        guard hsEnd <= data.count else { return nil }

        var i = hsStart + 4
        i += 2 + 32
        guard i < hsEnd else { return nil }

        let sessionIDLen = Int(data[i]); i += 1
        i += sessionIDLen
        guard i + 2 <= hsEnd else { return nil }

        guard let cipherLen = u16(i) else { return nil }
        i += 2 + cipherLen
        guard i < hsEnd else { return nil }

        let compLen = Int(data[i]); i += 1
        i += compLen
        guard i + 2 <= hsEnd else { return nil }

        guard let extTotalLen = u16(i) else { return nil }
        i += 2
        let extEnd = i + extTotalLen
        guard extEnd <= hsEnd else { return nil }

        while i + 4 <= extEnd {
            guard let extType = u16(i), let extLen = u16(i + 2) else { return nil }
            i += 4
            let extDataEnd = i + extLen
            guard extDataEnd <= extEnd else { return nil }

            if extType == 0x0000 {
                guard i + 2 <= extDataEnd, let listLen = u16(i) else { return nil }
                var j = i + 2
                let listEnd = j + listLen
                guard listEnd <= extDataEnd else { return nil }

                while j + 3 <= listEnd {
                    let nameType = data[j]; j += 1
                    guard let nameLen = u16(j) else { return nil }
                    j += 2
                    guard j + nameLen <= listEnd else { return nil }
                    if nameType == 0x00 {
                        let nameData = data.subdata(in: j ..< (j + nameLen))
                        guard let hostname = String(data: nameData, encoding: .utf8) else { return nil }
                        // RFC 6066 §3: IP address literals are not permitted in SNI.
                        guard !isIPLiteral(hostname) else { return nil }
                        // RFC 6066 §3: hostname must be an FQDN without a trailing dot.
                        guard !hostname.hasSuffix(".") else { return nil }
                        return hostname
                    }
                    j += nameLen
                }
            }

            i = extDataEnd
        }

        return nil
    }

    /// Returns true if the string looks like an IPv4 or IPv6 address literal.
    ///
    /// RFC 6066 §3: "Literal IPv4 and IPv6 addresses are not permitted in 'HostName'."
    private func isIPLiteral(_ hostname: String) -> Bool {
        // IPv6 address literal: enclosed in brackets (e.g. "[::1]") or contains a colon.
        if hostname.hasPrefix("["), hostname.hasSuffix("]") { return true }
        if hostname.contains(":") { return true }
        // IPv4 address literal: four decimal octets separated by dots.
        let parts = hostname.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }
}
