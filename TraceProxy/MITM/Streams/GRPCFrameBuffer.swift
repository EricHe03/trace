//
//  GRPCFrameBuffer.swift
//  TraceProxy
//
//  Thread-safe buffer for reassembling gRPC length-prefixed frames
//  across multiple TCP/HTTP/2 data chunks.
//

import Foundation

/// Holds the result of appending one chunk to the frame buffer.
struct GRPCCompleteFrames {
    /// Complete gRPC data frames extracted from the buffer.
    let dataFrames: [(isCompressed: Bool, payload: Data, rawFrame: Data)]
    /// Embedded gRPC-Web trailer frames (flag & 0x80 != 0).
    let trailerFrames: [(payload: Data, rawFrame: Data)]
}

/// A lock-protected byte buffer that accumulates incoming data chunks and
/// extracts complete gRPC length-prefixed frames.
final class GRPCFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Append a new chunk and extract all complete frames.
    /// Partial frames are retained in the buffer for the next call.
    func append(_ chunk: Data) -> GRPCCompleteFrames {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(chunk)
        return extractFrames()
    }

    /// Reset the buffer (e.g., when the stream closes).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Private

    private func extractFrames() -> GRPCCompleteFrames {
        var dataFrames: [(isCompressed: Bool, payload: Data, rawFrame: Data)] = []
        var trailerFrames: [(payload: Data, rawFrame: Data)] = []
        var offset = buffer.startIndex

        while offset + 5 <= buffer.endIndex {
            let flag = buffer[offset]
            let len = Int(buffer[offset + 1]) << 24
                | Int(buffer[offset + 2]) << 16
                | Int(buffer[offset + 3]) << 8
                | Int(buffer[offset + 4])
            guard len >= 0,
                  let next = buffer.index(offset, offsetBy: 5 + len, limitedBy: buffer.endIndex) else {
                break // Incomplete frame — wait for more data.
            }

            let rawFrame = Data(buffer[offset ..< next])
            let payload = Data(buffer[(offset + 5) ..< next])

            if flag & 0x80 != 0 {
                // gRPC-Web embedded trailer frame — high bit set, not a data message.
                trailerFrames.append((payload: payload, rawFrame: rawFrame))
            } else if flag == 0 || flag == 1 {
                dataFrames.append((isCompressed: flag == 1, payload: payload, rawFrame: rawFrame))
            }
            // Unknown flag (not 0, 1, or 0x80): stop gracefully to avoid protocol corruption.
            else { break }

            offset = next
        }

        // Consume processed bytes from the buffer.
        if offset > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex ..< offset)
        }

        return GRPCCompleteFrames(dataFrames: dataFrames, trailerFrames: trailerFrames)
    }
}
