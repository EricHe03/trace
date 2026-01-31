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
        let header = try read(count: 24)
        guard header.count == 24 else { throw PCAPReaderError.invalidHeader }

        let magic = readUInt32LE(header, offset: 0)
        guard magic == 0xA1B2_C3D4 else {
            throw PCAPReaderError.unsupportedFormat
        }

        while true {
            let recordHeader = try read(count: 16)
            if recordHeader.isEmpty { break }
            guard recordHeader.count == 16 else { throw PCAPReaderError.truncatedRecord }

            let tsSec = readUInt32LE(recordHeader, offset: 0)
            let tsUsec = readUInt32LE(recordHeader, offset: 4)
            let inclLen = readUInt32LE(recordHeader, offset: 8)
            if inclLen == 0 {
                continue
            }

            let packetData = try read(count: Int(inclLen))
            guard packetData.count == inclLen else { throw PCAPReaderError.truncatedRecord }

            let timestamp = Date(timeIntervalSince1970: Double(tsSec) + (Double(tsUsec) / 1_000_000.0))
            handler(PCAPPacket(timestamp: timestamp, data: packetData))
        }
    }

    public func forEachPacket(throwing handler: (PCAPPacket) throws -> Void) throws {
        let header = try read(count: 24)
        guard header.count == 24 else { throw PCAPReaderError.invalidHeader }

        let magic = readUInt32LE(header, offset: 0)
        guard magic == 0xA1B2_C3D4 else {
            throw PCAPReaderError.unsupportedFormat
        }

        while true {
            let recordHeader = try read(count: 16)
            if recordHeader.isEmpty { break }
            guard recordHeader.count == 16 else { throw PCAPReaderError.truncatedRecord }

            let tsSec = readUInt32LE(recordHeader, offset: 0)
            let tsUsec = readUInt32LE(recordHeader, offset: 4)
            let inclLen = readUInt32LE(recordHeader, offset: 8)
            if inclLen == 0 {
                continue
            }

            let packetData = try read(count: Int(inclLen))
            guard packetData.count == inclLen else { throw PCAPReaderError.truncatedRecord }

            let timestamp = Date(timeIntervalSince1970: Double(tsSec) + (Double(tsUsec) / 1_000_000.0))
            try handler(PCAPPacket(timestamp: timestamp, data: packetData))
        }
    }

    private func read(count: Int) throws -> Data {
        if #available(iOS 13.0, *) {
            try handle.read(upToCount: count) ?? Data()
        } else {
            handle.readData(ofLength: count)
        }
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }
}
