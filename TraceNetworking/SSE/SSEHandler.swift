//
//  SSEHandler.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import Network
import TraceCompression
import TraceCore

/// Manages Server-Sent Events connections and streaming.
///
/// Discussion: Detects SSE streams, parses events incrementally, and relays data to the client.
public class SSEHandler {
    private let clientConnection: NWConnection
    private var serverConnection: NWConnection?

    private let url: String
    private let connectionID: UUID
    private var connection: SSEConnection
    private var sseParser: SSEParser
    private var onConnectionUpdate: ((SSEConnection) -> Void)?
    private var utf8Remainder = Data()
    private var isChunkedDecodeEnabled: Bool
    private let contentEncodingAlgorithm: String?
    private var chunkedDecoder = ChunkedTransferDecoder()
    private var contentDecoder: (any StreamingDecoderProtocol)?

    private let persistenceQueue = DispatchQueue(label: "com.trace.sse.handler.persist", qos: .utility)
    private let stateQueue = DispatchQueue(label: "com.trace.sse.handler.state", qos: .utility)
    private let stateQueueKey = DispatchSpecificKey<Void>()

    private let maxEvents = 1000
    private let maxTotalBytes = 10 * 1024 * 1024 // 10MB

    /// Initializes an SSE handler for a proxied connection.
    public init(
        clientConnection: NWConnection,
        serverConnection: NWConnection?,
        url: String,
        requestHeaders: [TraceHTTPHeader],
        responseHeaders: [TraceHTTPHeader]
    ) {
        self.clientConnection = clientConnection
        self.serverConnection = serverConnection
        self.url = url
        self.connectionID = UUID()
        self.sseParser = SSEParser()
        let hasChunkedTransferEncoding = responseHeaders.contains {
            $0.key.lowercased() == "transfer-encoding" &&
                $0.value.lowercased().contains("chunked")
        }
        self.isChunkedDecodeEnabled = hasChunkedTransferEncoding
        let contentEncodingHeader = responseHeaders.first { $0.key.lowercased() == "content-encoding" }?.value
        self.contentEncodingAlgorithm = Self.normalizedCompressionAlgorithm(from: contentEncodingHeader)

        self.connection = SSEConnection(
            id: connectionID,
            url: url,
            startTime: Date(),
            status: .streaming,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            totalBytesReceived: 0
        )

        stateQueue.setSpecific(key: stateQueueKey, value: ())

        if let contentEncodingAlgorithm {
            do {
                contentDecoder = try Self.makeStreamingDecoder(
                    algorithm: contentEncodingAlgorithm,
                    maxOutputBytes: maxTotalBytes
                )
            } catch {
                NetworkLog.sse.warning("event=sse.content_decoder_init outcome=failure algorithm=\(contentEncodingAlgorithm, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        if let contentEncodingAlgorithm {
            NetworkLog.sse.info("event=sse.content_encoding_detected outcome=success algorithm=\(contentEncodingAlgorithm, privacy: .public)")
        } else if let contentEncodingHeader,
                  !Self.isIdentityContentEncoding(contentEncodingHeader) {
            NetworkLog.sse.warning("event=sse.content_encoding_detected outcome=unsupported encoding=\(contentEncodingHeader, privacy: .public)")
        }
    }

    // MARK: - Connection Management

    /// Starts the SSE handler and begins proxying server-to-client traffic.
    /// - Parameters:
    ///   - onUpdate: Callback invoked whenever the captured connection is updated.
    ///   - initialBodyData: Response body bytes already forwarded by the caller that must be parsed
    ///     to preserve event boundaries and UTF-8 state.
    public func start(onUpdate: @escaping (SSEConnection) -> Void, initialBodyData: Data = Data()) {
        withState {
            self.onConnectionUpdate = onUpdate
            self.saveConnectionLocked()

            if !initialBodyData.isEmpty {
                self.parseSSEDataLocked(initialBodyData)
            }
        }

        readFromServer()

        NetworkLog.sse.info("event=sse.connection_open outcome=success url=\(self.url, privacy: .private(mask: .hash))")
    }

    /// Closes the SSE connection and persists the final snapshot.
    public func close() {
        withState {
            self.flushContentDecoderLocked()
            self.connection.close()
            self.saveConnectionLocked()
            self.onConnectionUpdate = nil
        }

        clientConnection.cancel()
        serverConnection?.cancel()

        NetworkLog.sse.info("event=sse.connection_close outcome=success url=\(self.url, privacy: .private(mask: .hash))")
    }

    // MARK: - Server -> Client Proxying

    private func readFromServer() {
        serverConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NetworkLog.sse.error("event=sse.server_error outcome=failure error=\(error, privacy: .public)")
                self.failAndClose()
                return
            }

            if let data, !data.isEmpty {
                // Rule: Forward bytes immediately to keep the proxy transparent.
                self.clientConnection.send(content: data, completion: .contentProcessed { sendError in
                    if let sendError {
                        NetworkLog.sse.error("event=sse.client_send outcome=failure error=\(sendError, privacy: .public)")
                        self.failAndClose()
                        return
                    }
                })

                self.withState {
                    self.parseSSEDataLocked(data)
                }
            }

            if !isComplete {
                self.readFromServer()
            } else {
                self.close()
            }
        }
    }

    // MARK: - SSE Event Parsing

    private func parseSSEDataLocked(_ data: Data) {
        connection.totalBytesReceived += data.count

        // Rule: Stop parsing when limits are exceeded but keep proxying.
        if connection.events.count >= maxEvents || connection.totalBytesReceived >= maxTotalBytes {
            if !connection.isTruncated {
                connection.isTruncated = true
                NetworkLog.sse.warning("event=sse.connection_truncated outcome=skipped event_count=\(self.connection.events.count, privacy: .public) bytes=\(self.connection.totalBytesReceived, privacy: .public)")
                saveConnectionLocked()
            }
            return
        }

        if isChunkedDecodeEnabled {
            let (_, parseError) = chunkedDecoder.feed(data) { [self] chunk in
                parseBodyPayloadLocked(chunk)
            }
            if parseError {
                NetworkLog.sse.warning("event=sse.chunked_decode outcome=fallback_to_raw url=\(self.url, privacy: .private(mask: .hash))")
                isChunkedDecodeEnabled = false
                parseBodyPayloadLocked(data)
            }
            return
        }

        parseBodyPayloadLocked(data)
    }

    private func parseBodyPayloadLocked(_ data: Data) {
        guard !data.isEmpty else { return }

        guard let contentEncodingAlgorithm, let contentDecoder else {
            parseDecodedSSEPayloadLocked(data)
            return
        }

        do {
            let decoded = try contentDecoder.decompress(chunk: data)
            if !decoded.isEmpty {
                parseDecodedSSEPayloadLocked(decoded)
            }
        } catch {
            // If decoding fails, continue with raw parsing to preserve capture visibility.
            NetworkLog.sse.warning("event=sse.content_decode outcome=fallback_to_raw algorithm=\(contentEncodingAlgorithm, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            self.contentDecoder = nil
            parseDecodedSSEPayloadLocked(data)
        }
    }

    private func parseDecodedSSEPayloadLocked(_ data: Data) {
        guard !data.isEmpty else { return }

        // Rule: Preserve UTF-8 boundary state across chunks.
        let combined = utf8Remainder + data
        let dataString: String
        if let decoded = String(data: combined, encoding: .utf8) {
            dataString = decoded
            utf8Remainder.removeAll()
        } else {
            var decoded: String?
            var splitIndex = combined.count
            let maxTail = min(3, combined.count)
            for drop in 1 ... maxTail {
                let endIndex = combined.count - drop
                guard endIndex > 0 else { break }
                if let candidate = String(data: combined.subdata(in: 0 ..< endIndex), encoding: .utf8) {
                    decoded = candidate
                    splitIndex = endIndex
                    break
                }
            }

            guard let decoded else {
                utf8Remainder = combined
                return
            }

            dataString = decoded
            utf8Remainder = combined.subdata(in: splitIndex ..< combined.count)
        }

        let events = sseParser.parse(dataString)

        for event in events {
            connection.addEvent(event)
        }

        if !events.isEmpty {
            NetworkLog.sse.info("event=sse.events_parsed outcome=success parsed_count=\(events.count, privacy: .public) total_events=\(self.connection.events.count, privacy: .public)")
            saveConnectionLocked()
        }
    }

    private static func normalizedCompressionAlgorithm(from contentEncodingHeader: String?) -> String? {
        guard let contentEncodingHeader else { return nil }
        let tokens = contentEncodingHeader
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }

        guard tokens.count == 1, let token = tokens.first else { return nil }
        switch token {
        case "gzip", "x-gzip":
            return "gzip"
        case "deflate", "zlib":
            return "deflate"
        case "br", "brotli":
            return "br"
        default:
            return nil
        }
    }

    private static func isIdentityContentEncoding(_ contentEncodingHeader: String) -> Bool {
        let tokens = contentEncodingHeader
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { $0 == "identity" }
    }

    private static func makeStreamingDecoder(
        algorithm: String,
        maxOutputBytes: Int
    ) throws -> any StreamingDecoderProtocol {
        let config = StreamingDecoderConfig(
            chunkSize: 64 * 1024,
            maxOutputSize: maxOutputBytes
        )

        let decoder: any StreamingDecoderProtocol
        switch algorithm {
        case "gzip", "deflate":
            decoder = StreamingDeflateDecoder(config: config)
        case "br":
            decoder = StreamingBrotliDecoder(config: config)
        default:
            throw NSError(
                domain: "SSEHandler",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported content encoding: \(algorithm)"]
            )
        }

        try decoder.initialize()
        return decoder
    }

    private func flushContentDecoderLocked() {
        guard let contentDecoder else { return }
        defer { self.contentDecoder = nil }

        do {
            let trailingDecoded = try contentDecoder.finalize()
            if !trailingDecoded.isEmpty {
                parseDecodedSSEPayloadLocked(trailingDecoded)
            }
        } catch {
            NetworkLog.sse.warning("event=sse.content_decode_finalize outcome=failure error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private struct ChunkedTransferDecoder {
        private var pending = Data()
        private var currentChunkSize: Int?
        private(set) var isComplete = false

        mutating func feed(
            _ data: Data,
            onBodyChunk: (Data) -> Void
        ) -> (complete: Bool, parseError: Bool) {
            guard !data.isEmpty else { return (isComplete, false) }
            pending.append(data)

            var index = 0
            let crlf = Data([0x0D, 0x0A])
            let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

            while index < pending.count, !isComplete {
                if currentChunkSize == nil {
                    guard let sizeRange = pending.range(of: crlf, options: [], in: index ..< pending.count) else {
                        break
                    }

                    let sizeLineData = pending.subdata(in: index ..< sizeRange.lowerBound)
                    let sizeString = String(decoding: sizeLineData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let sizeToken = sizeString.split(separator: ";", maxSplits: 1).first ?? Substring()
                    guard let size = Int(sizeToken, radix: 16) else {
                        return (isComplete, true)
                    }

                    currentChunkSize = size
                    index = sizeRange.upperBound

                    if size == 0 {
                        if let trailerEnd = pending.range(of: terminator, options: [], in: index ..< pending.count) {
                            index = trailerEnd.upperBound
                            isComplete = true
                            currentChunkSize = nil
                            break
                        }

                        let crlfEnd = index + 2
                        if crlfEnd <= pending.count, pending[index ..< crlfEnd] == crlf {
                            index = crlfEnd
                            isComplete = true
                            currentChunkSize = nil
                            break
                        }

                        break
                    }
                } else if let size = currentChunkSize {
                    let remaining = pending.count - index
                    let needed = size + 2
                    guard remaining >= needed else {
                        break
                    }

                    if size > 0 {
                        let chunkStart = index
                        let chunkEnd = index + size
                        onBodyChunk(pending.subdata(in: chunkStart ..< chunkEnd))
                    }

                    let crlfStart = index + size
                    let crlfEnd = crlfStart + 2
                    guard crlfEnd <= pending.count, pending[crlfStart ..< crlfEnd] == crlf else {
                        return (isComplete, true)
                    }

                    index = crlfEnd
                    currentChunkSize = nil
                }
            }

            if index > 0, index <= pending.count {
                pending.removeSubrange(0 ..< index)
            }

            return (isComplete, false)
        }
    }

    // MARK: - Storage

    private func saveConnectionLocked() {
        let snapshot = connection
        NetworkLog.sse.info("event=sse.save_connection_locked outcome=start connection_id=\(snapshot.id.uuidString, privacy: .public) event_count=\(snapshot.events.count, privacy: .public)")
        onConnectionUpdate?(snapshot)

        persistenceQueue.async {
            do {
                try AppGroupStorage.shared.saveSSEConnection(snapshot)
                NetworkLog.sse.info("event=sse.storage_save outcome=success connection_id=\(snapshot.id.uuidString, privacy: .public)")
            } catch {
                NetworkLog.sse.error("event=sse.storage_save outcome=failure connection_id=\(snapshot.id.uuidString, privacy: .public) error=\(error, privacy: .public)")
            }
        }
    }

    private func failAndClose() {
        withState {
            self.flushContentDecoderLocked()
            self.connection.status = .failed
            self.connection.endTime = Date()
            self.saveConnectionLocked()
            self.onConnectionUpdate = nil
        }

        clientConnection.cancel()
        serverConnection?.cancel()
    }

    private func withState(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            work()
        } else {
            stateQueue.sync(execute: work)
        }
    }

    #if DEBUG
    /// Test-only hook to feed SSE bytes without starting network reads.
    func testParseSSEData(_ data: Data) {
        withState {
            self.parseSSEDataLocked(data)
        }
    }

    /// Test-only hook to inspect the current connection snapshot.
    func testConnectionSnapshot() -> SSEConnection {
        var snapshot: SSEConnection?
        withState {
            snapshot = self.connection
        }
        return snapshot ?? connection
    }
    #endif
}
