//
//  PCAPWriter.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import OSLog
import TraceCore

public protocol PCAPWriting: AnyObject, Sendable {
    func writePacket(_ packet: Data)
    func writePackets(_ packets: [Data])
    func currentFileSize() -> UInt64
    func close()
    var supportsRolling: Bool { get }
}

public extension PCAPWriting {
    func writePackets(_ packets: [Data]) {
        for packet in packets {
            writePacket(packet)
        }
    }
}

/// Defines errors thrown when creating a PCAP writer.
public enum PCAPWriterError: Error {
    case appGroupMissing
    case cannotOpenFile
}

/// Writes an append-only PCAP file stored in the app group container.
/// - Important: Writes are serialized on an internal queue to keep packet records contiguous.
public final class PCAPWriter: PCAPWriting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "pcap.writer.queue", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let handle: FileHandle
    private let fileURL: URL
    private var isClosed = false

    /// Creates or opens a PCAP file and writes the global header if the file is empty.
    /// - Parameters:
    ///   - appGroupID: App group identifier where the PCAP file is stored.
    ///   - fileName: File name relative to the app group container.
    public init(appGroupID: String, fileName: String) throws {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw PCAPWriterError.appGroupMissing
        }
        let url = dir.appendingPathComponent(fileName)
        self.fileURL = url
        queue.setSpecific(key: queueKey, value: ())

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw PCAPWriterError.cannotOpenFile
        }
        self.handle = h

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size == 0 {
            try writeGlobalHeader()
        } else {
            try handle.seekToEnd()
        }
    }

    deinit {
        close()
    }

    /// Enqueues a packet write with a PCAP record header timestamped at enqueue time.
    /// - Note: This is best-effort and logs on failure; it does not throw.
    public func writePacket(_ packet: Data) {
        writePackets([packet])
    }

    public func writePackets(_ packets: [Data]) {
        queue.async { [weak self] in
            guard let self, !self.isClosed, !packets.isEmpty else { return }

            do {
                for packet in packets {
                    try self.writeRecord(packet)
                }
            } catch {
                ProxyLog.metrics.error("event=pcap.write outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Returns the current file size on disk.
    public func currentFileSize() -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
            .uint64Value
        return size ?? 0
    }

    public func close() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeLocked()
        } else {
            queue.sync {
                closeLocked()
            }
        }
    }

    public var supportsRolling: Bool {
        false
    }

    private func closeLocked() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    private func writeGlobalHeader() throws {
        var hdr = Data()
        hdr.appendUInt32LE(0xA1B2_C3D4)
        hdr.appendUInt16LE(2)
        hdr.appendUInt16LE(4)
        hdr.appendUInt32LE(0)
        hdr.appendUInt32LE(0)
        hdr.appendUInt32LE(65535)
        hdr.appendUInt32LE(101) // Uses LINKTYPE_RAW for raw IP packets without a link layer.
        try handle.write(contentsOf: hdr)
    }

    private func writeRecord(_ packet: Data) throws {
        let now = Date()
        let seconds = UInt32(now.timeIntervalSince1970)
        let usec = UInt32((now.timeIntervalSince1970 - Double(seconds)) * 1_000_000.0)

        var record = Data()
        record.reserveCapacity(16 + packet.count)
        record.appendUInt32LE(seconds)
        record.appendUInt32LE(usec)
        record.appendUInt32LE(UInt32(packet.count))
        record.appendUInt32LE(UInt32(packet.count))
        record.append(packet)
        try handle.write(contentsOf: record)
    }
}
