//
//  PCAPReader.swift
//  TracePacket
//
//  Created by Justin on 2026/01/23.
//

import Foundation

public struct PCAPPacket: Sendable {
    public let timestamp: Date
    public let data: Data

    public init(timestamp: Date, data: Data) {
        self.timestamp = timestamp
        self.data = data
    }
}

public enum PCAPReaderError: Error {
    case invalidHeader
    case unsupportedFormat
    case truncatedRecord
    case packetTooLarge
}

public final class PCAPReader {
    private let handle: FileHandle

    public init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    public func forEachPacket(_ handler: (PCAPPacket) -> Void) throws {
        try forEachPacketInternal { packet in
            handler(packet)
        }
    }

    public func forEachPacket(throwing handler: (PCAPPacket) throws -> Void) throws {
        try forEachPacketInternal { packet in
            try handler(packet)
        }
    }

    private enum ByteOrder {
        case littleEndian
        case bigEndian
    }

    private struct PCAPFormat {
        let byteOrder: ByteOrder
        let timestampDivisor: Double
        let snaplen: UInt32
    }

    private func forEachPacketInternal(_ handler: (PCAPPacket) throws -> Void) throws {
        let header = try readExactly(count: 24)
        guard header.count == 24 else { throw PCAPReaderError.invalidHeader }

        let format = try parseGlobalHeader(header)
        let readUInt32: (Data, Int) -> UInt32 = { data, offset in
            switch format.byteOrder {
            case .littleEndian:
                self.readUInt32LE(data, offset: offset)
            case .bigEndian:
                self.readUInt32BE(data, offset: offset)
            }
        }

        while true {
            let recordHeader = try readExactly(count: 16)
            if recordHeader.isEmpty { break }
            guard recordHeader.count == 16 else { throw PCAPReaderError.truncatedRecord }

            let tsSec = readUInt32(recordHeader, 0)
            let tsSubsec = readUInt32(recordHeader, 4)
            let inclLen = readUInt32(recordHeader, 8)

            if inclLen == 0 {
                continue
            }

            if format.snaplen > 0, inclLen > format.snaplen {
                throw PCAPReaderError.packetTooLarge
            }

            guard let inclLenInt = Int(exactly: inclLen) else { throw PCAPReaderError.packetTooLarge }
            let packetData = try readExactly(count: inclLenInt)
            guard packetData.count == inclLenInt else { throw PCAPReaderError.truncatedRecord }

            let timestamp = Date(timeIntervalSince1970: Double(tsSec) + (Double(tsSubsec) / format.timestampDivisor))
            try handler(PCAPPacket(timestamp: timestamp, data: packetData))
        }
    }

    private func parseGlobalHeader(_ header: Data) throws -> PCAPFormat {
        let magicLE = readUInt32LE(header, offset: 0)
        let magicBE = readUInt32BE(header, offset: 0)

        let microMagic: UInt32 = 0xA1B2_C3D4
        let nanoMagic: UInt32 = 0xA1B2_3C4D

        let (byteOrder, timestampDivisor): (ByteOrder, Double)
        if magicLE == microMagic {
            byteOrder = .littleEndian
            timestampDivisor = 1_000_000.0
        } else if magicBE == microMagic {
            byteOrder = .bigEndian
            timestampDivisor = 1_000_000.0
        } else if magicLE == nanoMagic {
            byteOrder = .littleEndian
            timestampDivisor = 1_000_000_000.0
        } else if magicBE == nanoMagic {
            byteOrder = .bigEndian
            timestampDivisor = 1_000_000_000.0
        } else {
            throw PCAPReaderError.unsupportedFormat
        }

        let snaplen: UInt32 = switch byteOrder {
        case .littleEndian:
            readUInt32LE(header, offset: 16)
        case .bigEndian:
            readUInt32BE(header, offset: 16)
        }

        return PCAPFormat(byteOrder: byteOrder, timestampDivisor: timestampDivisor, snaplen: snaplen)
    }

    private func readExactly(count: Int) throws -> Data {
        guard count > 0 else { return Data() }

        var result = Data()
        result.reserveCapacity(count)
        var remaining = count

        while remaining > 0 {
            let chunk: Data = if #available(iOS 13.0, *) {
                try handle.read(upToCount: remaining) ?? Data()
            } else {
                handle.readData(ofLength: remaining)
            }

            if chunk.isEmpty {
                break
            }
            result.append(chunk)
            remaining -= chunk.count
        }

        return result
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }
}
