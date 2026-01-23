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
    public let type: String
    public let msg: String
}

/// Writes an append-only NDJSON log backed by a file in the app group container.
/// - Note: Writes are serialized on a private queue to keep each event on its own line.
public final class NDJSONLogWriter {
    private let queue = DispatchQueue(label: "ndjson.log.queue", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let url: URL
    private var handle: FileHandle?
    private static let newline = Data([0x0A])

    /// Creates (or opens) the log file in the app group container and seeks to the end.
    public init(appGroupID: String, fileName: String) throws {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw NSError(domain: "NDJSONLogWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "App group missing"])
        }
        self.url = dir.appendingPathComponent(fileName)
        self.queue.setSpecific(key: queueKey, value: ())

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle?.seekToEnd()
    }

    private func isOnQueue() -> Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    private func writeEvent(_ event: NDJSONLogEvent, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(event)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Self.newline)
    }

    /// Enqueues a log event append.
    /// - Note: This is best-effort and logs on failure; it does not throw.
    public func append(type: String, msg: String) {
        let event = NDJSONLogEvent(ts: Date().timeIntervalSince1970, type: type, msg: msg)
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            do {
                try self.writeEvent(event, to: h)
            } catch {
                ProxyLog.metrics.error("event=ndjson.write outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Appends an event and waits for the write to complete.
    ///
    /// Rationale: Use this for critical lifecycle events (e.g. tunnel stop) to avoid losing
    /// the final log lines if the extension exits immediately after completion.
    public func appendSync(type: String, msg: String) {
        let event = NDJSONLogEvent(ts: Date().timeIntervalSince1970, type: type, msg: msg)
        let writeBlock = { [weak self] in
            guard let self, let h = self.handle else { return }
            do {
                try self.writeEvent(event, to: h)
            } catch {
                ProxyLog.metrics.error("event=ndjson.write_sync outcome=failure error=\(error.localizedDescription, privacy: .public)")
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
                if #available(iOS 13.0, macOS 10.15, *) {
                    try h.close()
                } else {
                    h.closeFile()
                }
            } catch {
                ProxyLog.metrics.error("event=ndjson.close outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
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
