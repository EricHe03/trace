//
//  TransparentProxyMetadata.swift
//  TraceCore
//
//  Created by Codex on 2026/02/20.
//

import Foundation
import NIOCore

public enum TransparentProxyMetadata {
    public enum MetadataVersion: UInt8, Sendable, Equatable {
        case v1 = 1
        case v2 = 2
    }

    public struct UpstreamHint: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        public let addressTypeRaw: UInt8
        public let flowID: UInt64?
        public let policyModeRaw: UInt8?
        public let version: MetadataVersion

        public init(
            host: String,
            port: UInt16,
            addressTypeRaw: UInt8,
            flowID: UInt64? = nil,
            policyModeRaw: UInt8? = nil,
            version: MetadataVersion = .v1
        ) {
            self.host = host
            self.port = port
            self.addressTypeRaw = addressTypeRaw
            self.flowID = flowID
            self.policyModeRaw = policyModeRaw
            self.version = version
        }
    }

    public enum DecodeResult: Sendable, Equatable {
        case absent
        case needMore
        case invalid(String)
        case value(UpstreamHint, consumedBytes: Int)
    }

    private static let magicV1 = Array("TRACEUP1".utf8)
    private static let magicV2 = Array("TRACEUP2".utf8)
    private static let fixedHeaderLengthV1 = magicV1.count + 1 + 1 + 2 // magic + version + address type + host length
    private static let fixedHeaderLengthV2 = magicV2.count + 1 + 1 + 2 // magic + version + address type + host length
    private static let maxHostLength = 1024

    public static func encodeUpstreamHint(host: String, port: UInt16, addressTypeRaw: UInt8) -> [UInt8]? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { return nil }
        guard let hostData = normalizedHost.data(using: .utf8), !hostData.isEmpty else { return nil }
        guard hostData.count <= maxHostLength else { return nil }
        guard port > 0 else { return nil }

        var payload: [UInt8] = []
        payload.reserveCapacity(fixedHeaderLengthV1 + hostData.count + 2)
        payload.append(contentsOf: magicV1)
        payload.append(MetadataVersion.v1.rawValue)
        payload.append(addressTypeRaw)
        let hostLength = UInt16(hostData.count)
        payload.append(UInt8((hostLength >> 8) & 0xFF))
        payload.append(UInt8(hostLength & 0xFF))
        payload.append(contentsOf: hostData)
        payload.append(UInt8((port >> 8) & 0xFF))
        payload.append(UInt8(port & 0xFF))
        return payload
    }

    public static func encodeUpstreamHintV2(
        host: String,
        port: UInt16,
        addressTypeRaw: UInt8,
        flowID: UInt64? = nil,
        policyModeRaw: UInt8? = nil
    ) -> [UInt8]? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { return nil }
        guard let hostData = normalizedHost.data(using: .utf8), !hostData.isEmpty else { return nil }
        guard hostData.count <= maxHostLength else { return nil }
        guard port > 0 else { return nil }

        let hasFlowID = flowID != nil
        let hasPolicyMode = policyModeRaw != nil

        var payload: [UInt8] = []
        payload.reserveCapacity(
            fixedHeaderLengthV2 + hostData.count + 2 + 1 + (hasFlowID ? 8 : 0) + (hasPolicyMode ? 1 : 0)
        )
        payload.append(contentsOf: magicV2)
        payload.append(MetadataVersion.v2.rawValue)
        payload.append(addressTypeRaw)
        let hostLength = UInt16(hostData.count)
        payload.append(UInt8((hostLength >> 8) & 0xFF))
        payload.append(UInt8(hostLength & 0xFF))
        payload.append(contentsOf: hostData)
        payload.append(UInt8((port >> 8) & 0xFF))
        payload.append(UInt8(port & 0xFF))

        var flags: UInt8 = 0
        if hasFlowID {
            flags |= 0b0000_0001
        }
        if hasPolicyMode {
            flags |= 0b0000_0010
        }
        payload.append(flags)

        if let flowID {
            payload.append(UInt8((flowID >> 56) & 0xFF))
            payload.append(UInt8((flowID >> 48) & 0xFF))
            payload.append(UInt8((flowID >> 40) & 0xFF))
            payload.append(UInt8((flowID >> 32) & 0xFF))
            payload.append(UInt8((flowID >> 24) & 0xFF))
            payload.append(UInt8((flowID >> 16) & 0xFF))
            payload.append(UInt8((flowID >> 8) & 0xFF))
            payload.append(UInt8(flowID & 0xFF))
        }

        if let policyModeRaw {
            payload.append(policyModeRaw)
        }

        return payload
    }

    public static func decodeUpstreamHintPrefix(from buffer: ByteBuffer) -> DecodeResult {
        let readableBytes = buffer.readableBytes
        guard readableBytes > 0 else { return .absent }

        let versionMatch = metadataVersionMatch(in: buffer)
        switch versionMatch {
        case .absent:
            return .absent
        case .needMore:
            return .needMore
        case let .matched(version):
            return decodeVersionedHint(version: version, from: buffer)
        }
    }

    private enum MagicMatchState {
        case absent
        case needMore
        case matched(MetadataVersion)
    }

    private static func metadataVersionMatch(in buffer: ByteBuffer) -> MagicMatchState {
        let readableBytes = buffer.readableBytes
        guard readableBytes > 0 else { return .absent }

        let prefixLength = min(readableBytes, magicV1.count)
        guard let prefixBytes = buffer.getBytes(at: buffer.readerIndex, length: prefixLength) else {
            return .needMore
        }

        var couldMatchV1 = true
        var couldMatchV2 = true
        for index in 0 ..< prefixLength {
            if prefixBytes[index] != magicV1[index] {
                couldMatchV1 = false
            }
            if prefixBytes[index] != magicV2[index] {
                couldMatchV2 = false
            }
        }

        if !couldMatchV1, !couldMatchV2 {
            return .absent
        }

        if prefixLength < magicV1.count {
            return .needMore
        }

        if couldMatchV2 {
            return .matched(.v2)
        }
        if couldMatchV1 {
            return .matched(.v1)
        }
        return .absent
    }

    private static func decodeVersionedHint(
        version: MetadataVersion,
        from buffer: ByteBuffer
    ) -> DecodeResult {
        switch version {
        case .v1:
            decodeV1Hint(from: buffer)
        case .v2:
            decodeV2Hint(from: buffer)
        }
    }

    private static func decodeV1Hint(from buffer: ByteBuffer) -> DecodeResult {
        let readableBytes = buffer.readableBytes
        let baseIndex = buffer.readerIndex
        guard readableBytes >= fixedHeaderLengthV1 else {
            return .needMore
        }

        guard let parsedVersion = buffer.getInteger(at: baseIndex + magicV1.count, as: UInt8.self) else {
            return .needMore
        }
        guard parsedVersion == MetadataVersion.v1.rawValue else {
            return .invalid("unsupported_version_\(parsedVersion)")
        }

        guard let addressTypeRaw = buffer.getInteger(at: baseIndex + magicV1.count + 1, as: UInt8.self),
              let hostLength = buffer.getInteger(at: baseIndex + magicV1.count + 2, as: UInt16.self)
        else {
            return .needMore
        }

        let hostLengthInt = Int(hostLength)
        guard hostLengthInt > 0, hostLengthInt <= maxHostLength else {
            return .invalid("invalid_host_length_\(hostLengthInt)")
        }

        let hostStart = baseIndex + fixedHeaderLengthV1
        let portStart = hostStart + hostLengthInt
        let consumedBytes = fixedHeaderLengthV1 + hostLengthInt + 2
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
            UpstreamHint(
                host: hostString,
                port: port,
                addressTypeRaw: addressTypeRaw,
                version: .v1
            ),
            consumedBytes: consumedBytes
        )
    }

    private static func decodeV2Hint(from buffer: ByteBuffer) -> DecodeResult {
        let readableBytes = buffer.readableBytes
        let baseIndex = buffer.readerIndex
        guard readableBytes >= fixedHeaderLengthV2 else {
            return .needMore
        }

        guard let parsedVersion = buffer.getInteger(at: baseIndex + magicV2.count, as: UInt8.self) else {
            return .needMore
        }
        guard parsedVersion == MetadataVersion.v2.rawValue else {
            return .invalid("unsupported_version_\(parsedVersion)")
        }

        guard let addressTypeRaw = buffer.getInteger(at: baseIndex + magicV2.count + 1, as: UInt8.self),
              let hostLength = buffer.getInteger(at: baseIndex + magicV2.count + 2, as: UInt16.self)
        else {
            return .needMore
        }

        let hostLengthInt = Int(hostLength)
        guard hostLengthInt > 0, hostLengthInt <= maxHostLength else {
            return .invalid("invalid_host_length_\(hostLengthInt)")
        }

        let hostStart = baseIndex + fixedHeaderLengthV2
        let portStart = hostStart + hostLengthInt
        let flagsIndex = portStart + 2
        guard readableBytes >= (flagsIndex - baseIndex + 1) else {
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

        guard let flags = buffer.getInteger(at: flagsIndex, as: UInt8.self) else {
            return .needMore
        }

        let hasFlowID = (flags & 0b0000_0001) != 0
        let hasPolicyMode = (flags & 0b0000_0010) != 0

        var readIndex = flagsIndex + 1
        var flowID: UInt64?
        if hasFlowID {
            guard readableBytes >= (readIndex - baseIndex + 8),
                  let parsedFlowID = buffer.getInteger(at: readIndex, as: UInt64.self)
            else {
                return .needMore
            }
            flowID = parsedFlowID
            readIndex += 8
        }

        var policyModeRaw: UInt8?
        if hasPolicyMode {
            guard readableBytes >= (readIndex - baseIndex + 1),
                  let parsedPolicyModeRaw = buffer.getInteger(at: readIndex, as: UInt8.self)
            else {
                return .needMore
            }
            policyModeRaw = parsedPolicyModeRaw
            readIndex += 1
        }

        let consumedBytes = readIndex - baseIndex
        return .value(
            UpstreamHint(
                host: hostString,
                port: port,
                addressTypeRaw: addressTypeRaw,
                flowID: flowID,
                policyModeRaw: policyModeRaw,
                version: .v2
            ),
            consumedBytes: consumedBytes
        )
    }
}
