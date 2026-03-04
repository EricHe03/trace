//
//  NIOMITMSSECaptureState.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/20.
//

import Foundation
import NIOCore
import NIOHTTP1
import TraceCompression
import TraceCore

final class NIOMITMSSECaptureState: @unchecked Sendable {
    static let persistenceQueue = DispatchQueue(
        label: "com.trace.proxy.nio.sse.capture.persist",
        qos: .utility
    )

    let lock = NSLock()
    let baseRequest: NetworkRequest
    var responseStatusCode: Int?
    var responseStatusMessage: String?
    var responseHeaders: [TraceHTTPHeader] = []
    var connection: SSEConnection?
    var parser = SSEParser()
    var utf8Remainder = Data()
    var publishThrottle = SSECapturePublishThrottle()
    var finished = false
    var streamSequence: Int64 = 0
    let persistStreamEvents: Bool
    let sessionID: UUID?
    private var contentDecoder: (any StreamingDecoderProtocol)?
    private var didFailContentDecoding = false
    private var didEmitInitialRequestSnapshot = false

    let maxInMemoryEvents = 1000

    init(baseRequest: NetworkRequest, sessionID: UUID? = nil, persistStreamEvents: Bool = true) {
        self.baseRequest = baseRequest
        self.sessionID = sessionID
        self.persistStreamEvents = persistStreamEvents
    }

    func beginResponse(
        head: HTTPResponseHead,
        captureConfig: CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        responseStatusCode = Int(head.status.code)
        responseStatusMessage = head.status.reasonPhrase
        responseHeaders = captureConfig.captureHeaders
            ? head.headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) }
            : []
        configureContentDecoderIfNeededLocked(head: head, captureConfig: captureConfig)

        if connection == nil {
            connection = SSEConnection(
                id: sessionID ?? UUID(),
                url: baseRequest.url,
                startTime: Date(),
                status: .streaming,
                requestHeaders: captureConfig.captureHeaders ? baseRequest.requestHeaders : [],
                responseHeaders: responseHeaders
            )
            if let snapshot = connection {
                persist(snapshot)
                persistStreamSession(
                    StreamSession(
                        id: snapshot.id,
                        protocolType: .sse,
                        url: snapshot.url,
                        startTime: snapshot.startTime,
                        endTime: snapshot.endTime,
                        status: .streaming,
                        requestHeaders: snapshot.requestHeaders,
                        responseHeaders: snapshot.responseHeaders,
                        metadata: [:],
                        eventCount: 0,
                        bytesIn: snapshot.totalBytesReceived,
                        bytesOut: 0
                    )
                )
            }
        } else {
            connection?.responseHeaders = responseHeaders
            if let snapshot = connection {
                persistStreamSession(
                    StreamSession(
                        id: snapshot.id,
                        protocolType: .sse,
                        url: snapshot.url,
                        startTime: snapshot.startTime,
                        endTime: snapshot.endTime,
                        status: .streaming,
                        requestHeaders: snapshot.requestHeaders,
                        responseHeaders: snapshot.responseHeaders,
                        metadata: [:],
                        eventCount: Int(streamSequence),
                        bytesIn: snapshot.totalBytesReceived,
                        bytesOut: 0
                    )
                )
            }
        }

        if !didEmitInitialRequestSnapshot, let snapshot = connection {
            didEmitInitialRequestSnapshot = true
            emitRequestSnapshotLocked(
                connection: snapshot,
                captureConfig: captureConfig,
                onRequestCaptured: onRequestCaptured
            )
        }
    }

    func consume(
        bodyChunk: Data,
        captureConfig: CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?
    ) {
        guard !bodyChunk.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard var snapshot = connection else { return }

        snapshot.totalBytesReceived += bodyChunk.count

        let parseChunk = decompressedChunkForParsingLocked(bodyChunk, snapshot: &snapshot)
        guard !parseChunk.isEmpty else {
            connection = snapshot
            persistStreamSession(
                StreamSession(
                    id: snapshot.id,
                    protocolType: .sse,
                    url: snapshot.url,
                    startTime: snapshot.startTime,
                    endTime: snapshot.endTime,
                    status: .streaming,
                    requestHeaders: snapshot.requestHeaders,
                    responseHeaders: snapshot.responseHeaders,
                    metadata: [:],
                    eventCount: Int(streamSequence),
                    bytesIn: snapshot.totalBytesReceived,
                    bytesOut: 0
                )
            )
            return
        }

        guard let decoded = decodeUTF8ChunkLocked(parseChunk), !decoded.isEmpty else {
            connection = snapshot
            persistStreamSession(
                StreamSession(
                    id: snapshot.id,
                    protocolType: .sse,
                    url: snapshot.url,
                    startTime: snapshot.startTime,
                    endTime: snapshot.endTime,
                    status: .streaming,
                    requestHeaders: snapshot.requestHeaders,
                    responseHeaders: snapshot.responseHeaders,
                    metadata: [:],
                    eventCount: Int(streamSequence),
                    bytesIn: snapshot.totalBytesReceived,
                    bytesOut: 0
                )
            )
            return
        }

        let events = parser.parse(decoded)
        if !events.isEmpty {
            for event in events {
                streamSequence += 1
                if persistStreamEvents {
                    persistStreamEvent(
                        StreamEvent(
                            sessionID: snapshot.id,
                            sequence: streamSequence,
                            timestamp: event.timestamp,
                            direction: .received,
                            kind: .sseEvent,
                            payload: .text(event.data, contentType: "text/event-stream; charset=utf-8"),
                            metadata: [
                                "event_id": event.eventId ?? "",
                                "event_type": event.eventType ?? "",
                                "retry": event.retry.map(String.init) ?? ""
                            ]
                        )
                    )
                }
                snapshot.addEvent(event)
                if snapshot.events.count > maxInMemoryEvents {
                    snapshot.events.removeFirst(snapshot.events.count - maxInMemoryEvents)
                }
            }
            connection = snapshot
            persistStreamSession(
                StreamSession(
                    id: snapshot.id,
                    protocolType: .sse,
                    url: snapshot.url,
                    startTime: snapshot.startTime,
                    endTime: snapshot.endTime,
                    status: .streaming,
                    requestHeaders: snapshot.requestHeaders,
                    responseHeaders: snapshot.responseHeaders,
                    metadata: [:],
                    eventCount: Int(streamSequence),
                    bytesIn: snapshot.totalBytesReceived,
                    bytesOut: 0
                )
            )
            if publishThrottle.shouldPublish(connection: snapshot) {
                persist(snapshot)
                emitRequestSnapshotLocked(
                    connection: snapshot,
                    captureConfig: captureConfig,
                    onRequestCaptured: onRequestCaptured
                )
            }
        } else {
            connection = snapshot
        }
    }

    func finish(
        succeeded: Bool,
        captureConfig: CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true

        var snapshot = connection ?? SSEConnection(
            id: sessionID ?? UUID(),
            url: baseRequest.url,
            startTime: Date(),
            status: .streaming,
            requestHeaders: captureConfig.captureHeaders ? baseRequest.requestHeaders : [],
            responseHeaders: responseHeaders
        )
        if let decoder = contentDecoder {
            do {
                let tail = try decoder.finalize()
                if !tail.isEmpty {
                    let decoded = decodeUTF8ChunkLocked(tail) ?? ""
                    let events = parser.parse(decoded)
                    if !events.isEmpty {
                        for event in events {
                            streamSequence += 1
                            if persistStreamEvents {
                                persistStreamEvent(
                                    StreamEvent(
                                        sessionID: snapshot.id,
                                        sequence: streamSequence,
                                        timestamp: event.timestamp,
                                        direction: .received,
                                        kind: .sseEvent,
                                        payload: .text(event.data, contentType: "text/event-stream; charset=utf-8"),
                                        metadata: [
                                            "event_id": event.eventId ?? "",
                                            "event_type": event.eventType ?? "",
                                            "retry": event.retry.map(String.init) ?? ""
                                        ]
                                    )
                                )
                            }
                            snapshot.addEvent(event)
                            if snapshot.events.count > maxInMemoryEvents {
                                snapshot.events.removeFirst(snapshot.events.count - maxInMemoryEvents)
                            }
                        }
                    }
                }
            } catch {
                snapshot.isTruncated = true
            }
            contentDecoder = nil
        }
        snapshot.status = succeeded ? .closed : .failed
        snapshot.endTime = Date()
        connection = snapshot
        persist(snapshot)
        persistStreamSession(
            StreamSession(
                id: snapshot.id,
                protocolType: .sse,
                url: snapshot.url,
                startTime: snapshot.startTime,
                endTime: snapshot.endTime,
                status: succeeded ? .closed : .failed,
                requestHeaders: snapshot.requestHeaders,
                responseHeaders: snapshot.responseHeaders,
                metadata: [:],
                eventCount: Int(streamSequence),
                bytesIn: snapshot.totalBytesReceived,
                bytesOut: 0
            )
        )
        emitRequestSnapshotLocked(
            connection: snapshot,
            captureConfig: captureConfig,
            onRequestCaptured: onRequestCaptured
        )
    }

    private func configureContentDecoderIfNeededLocked(head: HTTPResponseHead, captureConfig: CaptureConfiguration) {
        guard contentDecoder == nil, !didFailContentDecoding else { return }

        let encoding = head.headers[canonicalForm: "Content-Encoding"]
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: true) }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first(where: { !$0.isEmpty && $0 != "identity" })

        guard let encoding else { return }

        let maxOutputSize = max(
            StreamingDecoderConfig.default.maxOutputSize,
            max(0, captureConfig.maxBodySize)
        )
        let config = StreamingDecoderConfig(
            chunkSize: StreamingDecoderConfig.default.chunkSize,
            maxOutputSize: maxOutputSize
        )

        let decoder: (any StreamingDecoderProtocol)? = switch encoding {
        case "deflate", "gzip", "zlib":
            StreamingDeflateDecoder(config: config)
        case "br", "brotli":
            StreamingBrotliDecoder(config: config)
        case "zstd", "zst":
            StreamingZstdDecoder(config: config)
        default:
            nil
        }

        guard let decoder else { return }

        do {
            try decoder.initialize()
            contentDecoder = decoder
        } catch {
            didFailContentDecoding = true
            contentDecoder = nil
        }
    }

    private func decompressedChunkForParsingLocked(_ bodyChunk: Data, snapshot: inout SSEConnection) -> Data {
        guard !bodyChunk.isEmpty else { return Data() }
        guard let decoder = contentDecoder else {
            return bodyChunk
        }

        do {
            return try decoder.decompress(chunk: bodyChunk)
        } catch {
            snapshot.isTruncated = true
            didFailContentDecoding = true
            contentDecoder = nil
            persist(snapshot)
            return Data()
        }
    }

    func decodeUTF8ChunkLocked(_ data: Data) -> String? {
        let combined = utf8Remainder + data
        if let decoded = String(data: combined, encoding: .utf8) {
            utf8Remainder.removeAll(keepingCapacity: false)
            return decoded
        }

        var splitIndex = combined.count
        var decodedString: String?
        let maxTail = min(3, combined.count)
        for drop in 1 ... maxTail {
            let endIndex = combined.count - drop
            guard endIndex > 0 else { break }
            if let candidate = String(data: combined.subdata(in: 0 ..< endIndex), encoding: .utf8) {
                decodedString = candidate
                splitIndex = endIndex
                break
            }
        }

        guard let decodedString else {
            utf8Remainder = combined
            return nil
        }

        utf8Remainder = combined.subdata(in: splitIndex ..< combined.count)
        return decodedString
    }

    func emitRequestSnapshotLocked(
        connection: SSEConnection,
        captureConfig: CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?
    ) {
        guard let onRequestCaptured else { return }

        var snapshot = baseRequest
        snapshot.statusCode = responseStatusCode ?? 200
        snapshot.statusMessage = responseStatusMessage ?? "OK"
        snapshot.responseHeaders = captureConfig.captureHeaders ? responseHeaders : []
        if captureConfig.captureBody, captureConfig.maxBodySize > 0 {
            let payload = SSEPayloadSerializer.serialize(events: connection.events)
            if payload.isEmpty {
                snapshot.responseBody = .empty
            } else {
                let charset = BodyStorage.extractCharset(from: snapshot.responseHeaders)
                snapshot.responseBody = BodyStorage.from(
                    string: payload,
                    charset: charset,
                    maxSize: max(0, captureConfig.maxBodySize)
                )
            }
        } else {
            snapshot.responseBody = .empty
        }
        snapshot.duration = Date().timeIntervalSince(snapshot.timestamp)
        snapshot.extractHTTPFields()
        NetworkThrottlingController.shared.applyMetadata(to: &snapshot)
        onRequestCaptured(snapshot)
    }

    func persist(_ snapshot: SSEConnection) {
        Self.persistenceQueue.async {
            do {
                try AppGroupStorage.shared.saveSSEConnection(snapshot)
            } catch {
                ProxyLog.mitm.warning(
                    "event=proxy.nio_sse_capture_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func persistStreamSession(_ session: StreamSession) {
        Self.persistenceQueue.async {
            do {
                try AppGroupStorage.shared.upsertStreamSession(session)
            } catch {
                ProxyLog.mitm.warning(
                    "event=proxy.nio_sse_stream_session_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func persistStreamEvent(_ event: StreamEvent) {
        Self.persistenceQueue.async {
            do {
                try AppGroupStorage.shared.appendStreamEvent(event)
            } catch {
                ProxyLog.mitm.warning(
                    "event=proxy.nio_sse_stream_event_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
