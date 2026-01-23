//
//  RollingPCAPWriter.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/20.
//

import Foundation

/// Writes packet captures to a rolling set of PCAP files in the app group container.
public final class RollingPCAPWriter: PCAPWriting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "pcap.writer.rolling.queue", qos: .utility)
    private let appGroupID: String
    private let fileName: String
    private let maxFileSize: UInt64
    private let maxFiles: Int
    private var handle: FileHandle?
    private var fileURL: URL?
    private var currentSize: UInt64 = 0

    /// Creates a rolling PCAP writer.
    /// - Parameters:
    ///   - appGroupID: App group identifier where the PCAP files are stored.
    ///   - fileName: Base PCAP file name (active writer).
    ///   - maxFileSize: Max size per PCAP file in bytes before rotation.
    ///   - maxFiles: Number of rotated files to keep (including the active file).
    public init(appGroupID: String, fileName: String, maxFileSize: UInt64, maxFiles: Int) throws {
        self.appGroupID = appGroupID
        self.fileName = fileName
        self.maxFileSize = maxFileSize
        self.maxFiles = max(1, maxFiles)
        try openWriter()
    }

    deinit {
        try? handle?.close()
    }

    public func writePacket(_ packet: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let recordSize = UInt64(16 + packet.count)
            if self.maxFileSize > 0, self.currentSize + recordSize > self.maxFileSize {
                self.rotateFiles()
            }
            self.writeRecord(packet)
        }
    }

    public func currentFileSize() -> UInt64 {
        queue.sync {
            currentSize
        }
    }

    public func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
            fileURL = nil
            currentSize = 0
        }
    }

    public var supportsRolling: Bool {
        true
    }

    private func openWriter() throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw PCAPWriterError.appGroupMissing
        }

        let url = container.appendingPathComponent(fileName)
        fileURL = url

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw PCAPWriterError.cannotOpenFile
        }
        self.handle = handle

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        if size == 0 {
            try writeGlobalHeader()
            currentSize = UInt64(MemoryLayout<PCAPGlobalHeader>.size)
        } else {
            try handle.seekToEnd()
            currentSize = size
        }
    }

    private func rotateFiles() {
        guard let currentURL = fileURL else { return }
        try? handle?.close()
        handle = nil

        let container = currentURL.deletingLastPathComponent()
        let maxRotations = max(0, maxFiles - 1)
        if maxRotations == 0 {
            try? FileManager.default.removeItem(at: currentURL)
            try? openWriter()
            return
        }
        let oldest = container.appendingPathComponent(rotateName(maxRotations))
        if FileManager.default.fileExists(atPath: oldest.path) {
            try? FileManager.default.removeItem(at: oldest)
        }
        if maxRotations > 1 {
            for index in stride(from: maxRotations - 1, through: 1, by: -1) {
                let from = container.appendingPathComponent(rotateName(index))
                let to = container.appendingPathComponent(rotateName(index + 1))
                if FileManager.default.fileExists(atPath: from.path) {
                    try? FileManager.default.moveItem(at: from, to: to)
                }
            }
        }

        let firstRotation = container.appendingPathComponent(rotateName(1))
        if FileManager.default.fileExists(atPath: firstRotation.path) {
            try? FileManager.default.removeItem(at: firstRotation)
        }
        try? FileManager.default.moveItem(at: currentURL, to: firstRotation)

        try? openWriter()
        ProxyLog.metrics.info(
            "event=pcap.rollover outcome=success file=\(firstRotation.lastPathComponent, privacy: .public)"
        )
    }

    private func rotateName(_ index: Int) -> String {
        let stem = fileName.replacingOccurrences(of: ".pcap", with: "")
        return "\(stem)_\(index).pcap"
    }

    private func writeRecord(_ packet: Data) {
        guard let handle else { return }
        let now = Date()
        let seconds = UInt32(now.timeIntervalSince1970)
        let usec = UInt32((now.timeIntervalSince1970 - Double(seconds)) * 1_000_000.0)

        var record = Data()
        record.appendUInt32LE(seconds)
        record.appendUInt32LE(usec)
        record.appendUInt32LE(UInt32(packet.count))
        record.appendUInt32LE(UInt32(packet.count))

        do {
            try handle.write(contentsOf: record)
            try handle.write(contentsOf: packet)
            currentSize += UInt64(record.count + packet.count)
        } catch {
            ProxyLog.metrics.error("event=pcap.write outcome=failure error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeGlobalHeader() throws {
        var hdr = Data()
        hdr.appendUInt32LE(0xA1B2_C3D4)
        hdr.appendUInt16LE(2)
        hdr.appendUInt16LE(4)
        hdr.appendUInt32LE(0)
        hdr.appendUInt32LE(0)
        hdr.appendUInt32LE(65535)
        hdr.appendUInt32LE(101)
        try handle?.write(contentsOf: hdr)
    }
}

private struct PCAPGlobalHeader {
    var magic: UInt32 = 0xA1B2_C3D4
    var major: UInt16 = 2
    var minor: UInt16 = 4
    var zone: UInt32 = 0
    var sigfigs: UInt32 = 0
    var snaplen: UInt32 = 65535
    var network: UInt32 = 101
}

private extension Data {
    mutating func appendUInt16LE(_ v: UInt16) {
        var x = v.littleEndian
        self.append(UnsafeBufferPointer(start: &x, count: 1))
    }

    mutating func appendUInt32LE(_ v: UInt32) {
        var x = v.littleEndian
        self.append(UnsafeBufferPointer(start: &x, count: 1))
    }
}
