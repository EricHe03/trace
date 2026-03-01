//
//  NDJSONLogWriter.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import OSLog
import TraceCore

/// Represents a single NDJSON log event stored as one JSON object per line.
public struct NDJSONLogEvent: Codable {
    public let ts: Double
    public let msg: String
    public let type: String
}

/// Writes an append-only NDJSON log backed by a file in the app group container.
/// - Note: Writes are serialized on a private queue to keep each event on its own line.
public final class NDJSONLogWriter {
    private let queue = DispatchQueue(label: "ndjson.log.queue", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let url: URL
    private let flushEventThreshold: Int
    private let flushByteThreshold: Int
    private let flushInterval: TimeInterval
    private let encoder = JSONEncoder()
    private var handle: FileHandle?
    private var bufferedData = Data()
    private var bufferedEventCount = 0
    private var scheduledFlush: DispatchWorkItem?
    private static let newline = Data([0x0A])
    private static let prefixData = Data("{\"ts\":".utf8)
    private static let messageKeyData = Data(",\"msg\":".utf8)
    private static let typeKeyData = Data(",\"type\":".utf8)
    private static let suffixData = Data("}".utf8)

    init(
        logFileURL: URL,
        flushEventThreshold: Int = 64,
        flushByteThreshold: Int = 64 * 1024,
        flushInterval: TimeInterval = 0.2
    ) throws {
        url = logFileURL
        self.flushEventThreshold = max(1, flushEventThreshold)
        self.flushByteThreshold = max(1024, flushByteThreshold)
        self.flushInterval = max(0.05, flushInterval)
        self.queue.setSpecific(key: queueKey, value: ())

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle?.seekToEnd()
    }

    /// Creates (or opens) the log file in the app group container and seeks to the end.
    public convenience init(appGroupID: String, fileName: String) throws {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw NSError(domain: "NDJSONLogWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "App group missing"])
        }
        try self.init(logFileURL: dir.appendingPathComponent(fileName))
    }

    private func isOnQueue() -> Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    private func jsonStringLiteral(_ value: String) throws -> Data {
        try encoder.encode(value)
    }

    private func jsonNumberLiteral(_ value: Double) throws -> Data {
        try encoder.encode(value)
    }

    private func encodedLine(for event: NDJSONLogEvent) throws -> Data {
        let tsData = try jsonNumberLiteral(event.ts)
        let msgData = try jsonStringLiteral(event.msg)
        let typeData = try jsonStringLiteral(event.type)

        // Keep a stable field order across all NDJSON lines: ts, msg, type.
        var data = Data()
        data.reserveCapacity(
            Self.prefixData.count +
                tsData.count +
                Self.messageKeyData.count +
                msgData.count +
                Self.typeKeyData.count +
                typeData.count +
                Self.suffixData.count +
                Self.newline.count
        )
        data.append(Self.prefixData)
        data.append(tsData)
        data.append(Self.messageKeyData)
        data.append(msgData)
        data.append(Self.typeKeyData)
        data.append(typeData)
        data.append(Self.suffixData)
        data.append(Self.newline)
        return data
    }

    private func clearBufferedStateLocked() {
        bufferedData.removeAll(keepingCapacity: false)
        bufferedEventCount = 0
    }

    private func scheduleFlushLocked() {
        guard scheduledFlush == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let h = self.handle else {
                self.scheduledFlush = nil
                self.clearBufferedStateLocked()
                return
            }
            do {
                try self.flushBufferedLocked(to: h)
            } catch {
                ProxyLog.metrics.error("event=ndjson.flush_timer outcome=failure error=\(error.localizedDescription, privacy: .public)")
                self.clearBufferedStateLocked()
            }
        }
        scheduledFlush = workItem
        queue.asyncAfter(deadline: .now() + flushInterval, execute: workItem)
    }

    private func flushBufferedLocked(to handle: FileHandle) throws {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard !bufferedData.isEmpty else { return }
        try handle.write(contentsOf: bufferedData)
        clearBufferedStateLocked()
    }

    private func appendEncodedLineLocked(_ line: Data, to handle: FileHandle) throws {
        bufferedData.append(line)
        bufferedEventCount += 1

        if bufferedEventCount >= flushEventThreshold || bufferedData.count >= flushByteThreshold {
            try flushBufferedLocked(to: handle)
        } else {
            scheduleFlushLocked()
        }
    }

    /// Enqueues a log event append.
    /// - Note: This is best-effort and logs on failure; it does not throw.
    public func append(type: String, msg: String) {
        let event = NDJSONLogEvent(ts: Date().timeIntervalSince1970, msg: msg, type: type)
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            do {
                let line = try self.encodedLine(for: event)
                try self.appendEncodedLineLocked(line, to: h)
            } catch {
                ProxyLog.metrics.error("event=ndjson.write outcome=failure error=\(error.localizedDescription, privacy: .public)")
                self.clearBufferedStateLocked()
            }
        }
    }

    /// Appends an event and waits for the write to complete.
    ///
    /// Rationale: Use this for critical lifecycle events (e.g. tunnel stop) to avoid losing
    /// the final log lines if the extension exits immediately after completion.
    public func appendSync(type: String, msg: String) {
        let event = NDJSONLogEvent(ts: Date().timeIntervalSince1970, msg: msg, type: type)
        let writeBlock = { [weak self] in
            guard let self, let h = self.handle else { return }
            do {
                try self.flushBufferedLocked(to: h)
                let line = try self.encodedLine(for: event)
                try h.write(contentsOf: line)
            } catch {
                ProxyLog.metrics.error("event=ndjson.write_sync outcome=failure error=\(error.localizedDescription, privacy: .public)")
                self.clearBufferedStateLocked()
            }
        }

        if isOnQueue() {
            writeBlock()
        } else {
            queue.sync(execute: writeBlock)
        }
    }

    /// Drains pending writes and closes the underlying file handle.
    public func close() {
        let closeBlock = { [weak self] in
            guard let self, let h = self.handle else { return }
            self.handle = nil
            do {
                try self.flushBufferedLocked(to: h)
                if #available(iOS 13.0, macOS 10.15, *) {
                    try h.close()
                } else {
                    h.closeFile()
                }
            } catch {
                ProxyLog.metrics.error("event=ndjson.close outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
            self.scheduledFlush?.cancel()
            self.scheduledFlush = nil
            self.clearBufferedStateLocked()
        }

        if isOnQueue() {
            closeBlock()
        } else {
            queue.sync(execute: closeBlock)
        }
    }

    deinit {
        close()
    }
}
