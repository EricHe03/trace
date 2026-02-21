//
//  TransparentProxyMetadata.swift
//  TraceCore
//
//  Created by Codex on 2026/02/20.
//

import Foundation
import NIOCore

public enum TransparentProxyMetadata {
    public struct UpstreamHint: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        public let addressTypeRaw: UInt8

        public init(host: String, port: UInt16, addressTypeRaw: UInt8) {
            self.host = host
            self.port = port
            self.addressTypeRaw = addressTypeRaw
        }
    }

    public enum DecodeResult: Sendable, Equatable {
        case absent
        case needMore
        case invalid(String)
        case value(UpstreamHint, consumedBytes: Int)
    }

    private static let magic = Array("TRACEUP1".utf8)
    private static let version: UInt8 = 1
    private static let fixedHeaderLength = magic.count + 1 + 1 + 2 // magic + version + address type + host length
    private static let maxHostLength = 1024

    public static func encodeUpstreamHint(host: String, port: UInt16, addressTypeRaw: UInt8) -> [UInt8]? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { return nil }
        guard let hostData = normalizedHost.data(using: .utf8), !hostData.isEmpty else { return nil }
        guard hostData.count <= maxHostLength else { return nil }
        guard port > 0 else { return nil }

        var payload: [UInt8] = []
        payload.reserveCapacity(fixedHeaderLength + hostData.count + 2)
        payload.append(contentsOf: magic)
        payload.append(version)
        payload.append(addressTypeRaw)
        let hostLength = UInt16(hostData.count)
        payload.append(UInt8((hostLength >> 8) & 0xFF))
        payload.append(UInt8(hostLength & 0xFF))
        payload.append(contentsOf: hostData)
        payload.append(UInt8((port >> 8) & 0xFF))
        payload.append(UInt8(port & 0xFF))
        return payload
    }

    public static func decodeUpstreamHintPrefix(from buffer: ByteBuffer) -> DecodeResult {
        let readableBytes = buffer.readableBytes
        guard readableBytes > 0 else { return .absent }

        switch magicMatchState(in: buffer) {
        case .absent:
            return .absent
        case .needMore:
            return .needMore
        case .matched:
            break
        }

        let baseIndex = buffer.readerIndex
        guard readableBytes >= fixedHeaderLength else {
            return .needMore
        }

        guard let parsedVersion = buffer.getInteger(at: baseIndex + magic.count, as: UInt8.self) else {
            return .needMore
        }
        guard parsedVersion == version else {
            return .invalid("unsupported_version_\(parsedVersion)")
        }

        guard let addressTypeRaw = buffer.getInteger(at: baseIndex + magic.count + 1, as: UInt8.self),
              let hostLength = buffer.getInteger(at: baseIndex + magic.count + 2, as: UInt16.self)
        else {
            return .needMore
        }

        let hostLengthInt = Int(hostLength)
        guard hostLengthInt > 0, hostLengthInt <= maxHostLength else {
            return .invalid("invalid_host_length_\(hostLengthInt)")
        }

        let hostStart = baseIndex + fixedHeaderLength
        let portStart = hostStart + hostLengthInt
        let consumedBytes = fixedHeaderLength + hostLengthInt + 2
        guard readableBytes >= consumedBytes else {
            return .needMore
        }

        guard let hostBytes = buffer.getBytes(at: hostStart, length: hostLengthInt),
              let hostString = String(bytes: hostBytes, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostString.isEmpty
        else {
            return .invalid("invalid_host")
        }

        guard let port = buffer.getInteger(at: portStart, as: UInt16.self), port > 0 else {
            return .invalid("invalid_port")
        }

        return .value(
            UpstreamHint(host: hostString, port: port, addressTypeRaw: addressTypeRaw),
            consumedBytes: consumedBytes
        )
    }

    private enum MagicMatchState {
        case absent
        case needMore
        case matched
    }

    private static func magicMatchState(in buffer: ByteBuffer) -> MagicMatchState {
        let readableBytes = buffer.readableBytes
        guard readableBytes > 0 else { return .absent }

        let prefixLength = min(readableBytes, magic.count)
        guard let prefixBytes = buffer.getBytes(at: buffer.readerIndex, length: prefixLength) else {
            return .needMore
        }

        for index in 0 ..< prefixLength where prefixBytes[index] != magic[index] {
            return .absent
        }

        if prefixLength < magic.count {
            return .needMore
        }

        return .matched
    }
}
