//
//  HTTP2StreamManager.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import TraceCore

/// Manages HTTP/2 streams for request and response capture.
///
/// Discussion: Handles frame parsing, HPACK decoding, and `NetworkRequest` emission.
public actor HTTP2StreamManager {
    // MARK: - Stream State

    private var streams: [UInt32: HTTP2StreamState] = [:]

    /// Rule: Limits concurrent streams to protect memory.
    private let maxStreams: Int = 1000

    private let captureConfig: CaptureConfiguration

    private let captureBodies: Bool

    /// Rule: Limit per-side body retention to a bounded buffer.
    /// Long-lived streams flip to `BodyStorage.truncated` once exceeded.
    private let maxBodySize: Int

    // MARK: - Body spooling (disk-backed capture)

    private struct ActiveBodyCapture {
        let url: URL
        let handle: FileHandle
        var bytesWritten: Int
        var truncated: Bool
    }

    private var requestBodyCaptures: [UInt32: ActiveBodyCapture] = [:]
    private var responseBodyCaptures: [UInt32: ActiveBodyCapture] = [:]

    /// Rule: Limit per-stream frame records to protect UI and storage size.
    private let maxFramesPerStream: Int = 500

    /// Rule: Throttle update emissions per stream.
    private let minEmitInterval: TimeInterval = 0.5
    private let logSampler = LogSampler()
    private let warningThrottle = LogThrottle()

    // MARK: - HPACK Decoders

    private var clientHPACK = HPACKCoder()

    private var serverHPACK = HPACKCoder()

    // MARK: - Settings

    private var localSettings = HTTP2Settings()
    private var remoteSettings = HTTP2Settings()

    // MARK: - Connection Info

    private let targetHost: String
    private let targetPort: UInt16
    private let connectionStartTime = Date()
    private var connectionEndTime: Date?

    private var settingsFromClient: [String: Int] = [:]
    private var settingsFromServer: [String: Int] = [:]
    private var goAwayReceived: Bool = false
    private var goAwayLastStreamId: Int?
    private var lastCleanupAt: Date = .init()

    // MARK: - Callbacks

    private var onRequestComplete: ((NetworkRequest) -> Void)?

    /// Sets the callback for completed request snapshots.
    public func setOnRequestComplete(_ callback: @escaping (NetworkRequest) -> Void) {
        onRequestComplete = callback
    }

    // MARK: - Metrics Callbacks (optional)

    private var onStreamCreated: (@Sendable (UInt32) -> Void)?
    private var onStreamClosed: (@Sendable (UInt32) -> Void)?
    private var onStreamsActiveChanged: (@Sendable (Int) -> Void)?
    private var onProtocolError: (@Sendable () -> Void)?

    /// Sets optional callbacks for stream metrics and protocol errors.
    public func setMetricsCallbacks(
        onStreamCreated: (@Sendable (UInt32) -> Void)? = nil,
        onStreamClosed: (@Sendable (UInt32) -> Void)? = nil,
        onStreamsActiveChanged: (@Sendable (Int) -> Void)? = nil,
        onProtocolError: (@Sendable () -> Void)? = nil
    ) {
        self.onStreamCreated = onStreamCreated
        self.onStreamClosed = onStreamClosed
        self.onStreamsActiveChanged = onStreamsActiveChanged
        self.onProtocolError = onProtocolError
    }

    // MARK: - Initialization

    /// Initializes a stream manager for the target host and port.
    public init(targetHost: String, targetPort: UInt16) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        let config = AppGroupStorage.shared.loadConfiguration()
        self.captureConfig = config
        self.captureBodies = config.captureBody
        // Rule: Keep a conservative cap inside the Network Extension for stability.
        // Large bodies should be streamed, not retained in-memory.
        let hardCapBodyBytes = BodyStorage.truncationThreshold // 10 MB (default product limit)
        self.maxBodySize = min(max(0, config.maxBodySize), hardCapBodyBytes)
    }

    private func extractStatusCode(from headers: [TraceHTTPHeader]?) -> Int? {
        guard let headers else { return nil }
        guard let statusValue = headers.first(where: { $0.key == ":status" })?.value else { return nil }
        return Int(statusValue)
    }

    private func isInformationalStatus(_ headers: [TraceHTTPHeader]) -> Bool {
        guard let statusCode = extractStatusCode(from: headers) else { return false }
        return (100 ... 199).contains(statusCode)
    }

    private func stripPseudoHeaders(_ headers: [TraceHTTPHeader]) -> [TraceHTTPHeader] {
        headers.filter { !$0.key.hasPrefix(":") }
    }

    private func recordFrame(_ frame: HTTP2Frame, to stream: inout HTTP2StreamState) {
        let frameType = frame.header.frameType?.description ?? "UNKNOWN"
        let flags = frame.header.frameFlags.toStringArray()
        let entry = HTTP2DataFrame(
            frameType: frameType,
            flags: flags,
            payloadSize: frame.payload.count,
            timestamp: Date(),
            rawData: nil
        )

        if stream.dataFrames.count < maxFramesPerStream {
            stream.dataFrames.append(entry)
        } else {
            stream.droppedFrameCount += 1
        }
    }

    private func applyDecodedResponseHeaderBlock(
        _ headers: [TraceHTTPHeader],
        to stream: inout HTTP2StreamState,
        streamId: UInt32
    ) {
        if isInformationalStatus(headers) {
            stream.responseHeaders = headers
            stream.responseHeadersComplete = true
            return
        }

        // Rule: First non-informational response headers replace any prior informational headers.
        let priorHeadersWereInformational: Bool = if let existingHeaders = stream.responseHeaders {
            isInformationalStatus(existingHeaders)
        } else {
            false
        }

        if stream.responseHeaders == nil || priorHeadersWereInformational {
            stream.responseHeaders = headers
            stream.responseHeadersComplete = true
            return
        }

        // Rule: Additional headers before END_STREAM are trailers and must not include pseudo-headers.
        if !stream.responseComplete {
            let trailers = stripPseudoHeaders(headers)
            if !trailers.isEmpty {
                stream.responseHeaders?.append(contentsOf: trailers)
            }
            stream.responseHeadersComplete = true
            return
        }

        NetworkLog.http2.warning(
            "event=http2.server_headers outcome=skipped stream_id=\(streamId, privacy: .public) error=unexpected_headers_after_end_stream"
        )
        onProtocolError?()
    }

    private func unpadPayload(
        _ payload: Data,
        flags: HTTP2FrameFlags,
        streamId: UInt32,
        context: String
    ) async -> Data? {
        guard flags.contains(.padded) else {
            return payload
        }

        guard !payload.isEmpty else {
            if warningThrottle.shouldLog(key: "http2.unpad_payload.\(streamId).empty", minInterval: 5) {
                NetworkLog.http2.warning(
                    "event=http2.unpad_payload outcome=failure stream_id=\(streamId, privacy: .public) context=\(context, privacy: .public) error=empty_payload"
                )
            }
            return nil
        }

        let padLength = Int(payload[0])
        let available = payload.count - 1

        guard padLength <= available else {
            if warningThrottle.shouldLog(key: "http2.unpad_payload.\(streamId).pad_length", minInterval: 5) {
                NetworkLog.http2.warning(
                    "event=http2.unpad_payload outcome=failure stream_id=\(streamId, privacy: .public) context=\(context, privacy: .public) error=invalid_pad_length pad_length=\(padLength, privacy: .public)"
                )
            }
            return nil
        }

        let dataStart = payload.startIndex + 1
        let dataEnd = payload.endIndex - padLength

        return payload.subdata(in: dataStart ..< dataEnd)
    }

    // MARK: - Client Frame Handling (Client -> Server)

    /// Handles a HEADERS frame from the client.
    public func handleClientHeaders(_ frame: HTTP2Frame) async {
        let streamId = frame.header.streamId
        let flags = frame.header.frameFlags

        // Rule: Skip connection-level frames (stream 0).
        guard streamId > 0 else { return }

        if streams.count >= maxStreams && streams[streamId] == nil {
            NetworkLog.http2.warning("event=http2.stream_open outcome=skipped stream_id=\(streamId, privacy: .public) error=stream_limit_reached")
            return
        }

        guard var payload = await unpadPayload(frame.payload, flags: flags, streamId: streamId, context: "client HEADERS") else {
            if streams[streamId] != nil {
                cleanupCaptures(streamId: streamId, removeFiles: true)
                streams.removeValue(forKey: streamId)
            }
            return
        }

        let isNewStream = (streams[streamId] == nil)
        var stream = streams[streamId] ?? HTTP2StreamState(streamId: streamId)
        stream.state = .open
        stream.lastActivity = Date()
        recordFrame(frame, to: &stream)

        if flags.contains(.priority) {
            guard payload.count >= 5 else {
                NetworkLog.http2.warning("event=http2.client_headers outcome=failure stream_id=\(streamId, privacy: .public) error=truncated_priority_data")
                cleanupCaptures(streamId: streamId, removeFiles: true)
                streams.removeValue(forKey: streamId)
                return
            }
            if let priority = HTTP2Priority.parse(from: Data(payload.prefix(5))) {
                stream.priority = HTTP2StreamInfo.StreamPriority(
                    exclusive: priority.exclusive,
                    dependsOn: Int(priority.streamDependency),
                    weight: Int(priority.weight)
                )
            }
            payload = Data(payload.dropFirst(5))
        }

        stream.pendingRequestHeaderFragment.append(contentsOf: payload)

        if flags.contains(.endHeaders) {
            do {
                let headers = try clientHPACK.decode(Data(stream.pendingRequestHeaderFragment))
                if stream.requestHeaders == nil {
                    stream.requestHeaders = headers
                } else {
                    // Rule: Append request trailers while excluding pseudo-headers.
                    let trailers = stripPseudoHeaders(headers)
                    if !trailers.isEmpty {
                        stream.requestHeaders?.append(contentsOf: trailers)
                    }
                }
                stream.requestHeadersComplete = true
                stream.pendingRequestHeaderFragment.removeAll()

                if logSampler.shouldLog(key: "http2.request_headers_decode.\(streamId)", first: 1, every: 50) {
                    NetworkLog.http2.debug(
                        "event=http2.request_headers_decode outcome=success stream_id=\(streamId, privacy: .public) header_count=\(headers.count, privacy: .public)"
                    )
                }
            } catch {
                if warningThrottle.shouldLog(key: "http2.hpack_decode.client.\(streamId)", minInterval: 5) {
                    NetworkLog.http2.error(
                        "event=http2.hpack_decode outcome=failure stream_id=\(streamId, privacy: .public) error=\(error, privacy: .public)"
                    )
                }
                onProtocolError?()
                cleanupCaptures(streamId: streamId, removeFiles: true)
                streams.removeValue(forKey: streamId)
                return
            }
        }

        // Rule: END_STREAM completes the request body.
        if flags.contains(.endStream) {
            stream.requestComplete = true
            stream.state = stream.responseComplete ? .closed : .halfClosedLocal
            finalizeRequestBodyCapture(streamId: streamId)
        }

        streams[streamId] = stream

        if isNewStream {
            onStreamCreated?(streamId)
            onStreamsActiveChanged?(streams.count)
        }

        // Rule: Emit or update the request as soon as headers are available.
        markStreamDirty(streamId: streamId)
    }

    /// Handles a DATA frame from the client.
    public func handleClientData(_ frame: HTTP2Frame) async {
        let streamId = frame.header.streamId
        let flags = frame.header.frameFlags

        guard streamId > 0, var stream = streams[streamId] else { return }

        guard let payload = await unpadPayload(frame.payload, flags: flags, streamId: streamId, context: "client DATA") else {
            cleanupCaptures(streamId: streamId, removeFiles: true)
            streams.removeValue(forKey: streamId)
            return
        }

        stream.lastActivity = Date()
        recordFrame(frame, to: &stream)

        // Rule: Track bytes seen even when body capture is truncated.
        stream.requestBodyBytesSeen += payload.count

        if captureBodies, maxBodySize > 0, !stream.requestBodyTruncated {
            let remainingCapture = max(0, maxBodySize - stream.requestBodyBytesCaptured)
            if remainingCapture == 0 {
                stream.requestBodyTruncated = true
                if var capture = requestBodyCaptures[streamId] {
                    capture.truncated = true
                    requestBodyCaptures[streamId] = capture
                }
            } else {
                let toCapture = min(remainingCapture, payload.count)
                let willNeedFile =
                    stream.requestBodyFileURL != nil ||
                    (stream.requestBodyBytesCaptured + toCapture) > BodyStorage.inlineThreshold

                if willNeedFile {
                    if stream.requestBodyFileURL == nil {
                        _ = ensureRequestBodyCapture(streamId: streamId, stream: &stream)
                    }
                    if var capture = requestBodyCaptures[streamId] {
                        do {
                            try capture.handle.write(contentsOf: payload.prefix(toCapture))
                            capture.bytesWritten += toCapture
                            requestBodyCaptures[streamId] = capture
                        } catch {
                            stream.requestBodyTruncated = true
                            capture.truncated = true
                            requestBodyCaptures[streamId] = capture
                            try? FileManager.default.removeItem(at: capture.url)
                            requestBodyCaptures.removeValue(forKey: streamId)
                        }
                    }

                    if stream.requestBodyData.count < BodyStorage.previewSize {
                        let previewRemaining = BodyStorage.previewSize - stream.requestBodyData.count
                        let toPreview = min(previewRemaining, toCapture)
                        if toPreview > 0 {
                            stream.requestBodyData.append(contentsOf: payload.prefix(toPreview))
                        }
                    }
                } else {
                    stream.requestBodyData.append(contentsOf: payload.prefix(toCapture))
                }

                stream.requestBodyBytesCaptured += toCapture
                if payload.count > toCapture {
                    stream.requestBodyTruncated = true
                    if var capture = requestBodyCaptures[streamId] {
                        capture.truncated = true
                        requestBodyCaptures[streamId] = capture
                    }
                }
            }
        }

        // Rule: END_STREAM completes the request body.
        if flags.contains(.endStream) {
            stream.requestComplete = true
            stream.state = stream.responseComplete ? .closed : .halfClosedLocal
            finalizeRequestBodyCapture(streamId: streamId)
        }

        streams[streamId] = stream

        markStreamDirty(streamId: streamId)
    }

    /// Handles a CONTINUATION frame from the client.
    public func handleClientContinuation(_ frame: HTTP2Frame) async {
        let streamId = frame.header.streamId
        let flags = frame.header.frameFlags

        guard streamId > 0, var stream = streams[streamId] else { return }

        stream.lastActivity = Date()
        recordFrame(frame, to: &stream)

        stream.pendingRequestHeaderFragment.append(contentsOf: frame.payload)

        if flags.contains(.endHeaders) {
            do {
                let headers = try clientHPACK.decode(Data(stream.pendingRequestHeaderFragment))
                if stream.requestHeaders == nil {
                    stream.requestHeaders = headers
                } else {
                    let trailers = stripPseudoHeaders(headers)
                    if !trailers.isEmpty {
                        stream.requestHeaders?.append(contentsOf: trailers)
                    }
                }
                stream.requestHeadersComplete = true
                stream.pendingRequestHeaderFragment.removeAll()
            } catch {
                if warningThrottle.shouldLog(key: "http2.hpack_decode.client_cont.\(streamId)", minInterval: 5) {
                    NetworkLog.http2.error(
                        "event=http2.hpack_decode outcome=failure stream_id=\(streamId, privacy: .public) context=client_continuation error=\(error, privacy: .public)"
                    )
                }
                onProtocolError?()
                cleanupCaptures(streamId: streamId, removeFiles: true)
                streams.removeValue(forKey: streamId)
                return
            }
        }

        streams[streamId] = stream

        markStreamDirty(streamId: streamId)
    }

    // MARK: - Server Frame Handling (Server -> Client)

    /// Handles a HEADERS frame from the server.
    public func handleServerHeaders(_ frame: HTTP2Frame) async {
        let streamId = frame.header.streamId
        let flags = frame.header.frameFlags

        guard streamId > 0, var stream = streams[streamId] else {
            // Note: Servers may send headers for unknown streams (push or stale).
            NetworkLog.http2.warning("event=http2.server_headers outcome=skipped stream_id=\(streamId, privacy: .public) error=unknown_stream")
            return
        }

        stream.lastActivity = Date()
        recordFrame(frame, to: &stream)

        guard var payload = await unpadPayload(frame.payload, flags: flags, streamId: streamId, context: "server HEADERS") else {
            cleanupCaptures(streamId: streamId, removeFiles: true)
            streams.removeValue(forKey: streamId)
            return
        }

        // Note: Servers rarely send PRIORITY, but the spec allows it.
        if flags.contains(.priority) {
            guard payload.count >= 5 else {
                NetworkLog.http2.warning("event=http2.server_headers outcome=failure stream_id=\(streamId, privacy: .public) error=truncated_priority_data")
                cleanupCaptures(streamId: streamId, removeFiles: true)
                streams.removeValue(forKey: streamId)
                return
            }
            payload = Data(payload.dropFirst(5))
        }

        stream.pendingResponseHeaderFragment.append(contentsOf: payload)

        if flags.contains(.endHeaders) {
            do {
                let headers = try serverHPACK.decode(Data(stream.pendingResponseHeaderFragment))
                applyDecodedResponseHeaderBlock(headers, to: &stream, streamId: streamId)
                stream.pendingResponseHeaderFragment.removeAll()

                if logSampler.shouldLog(key: "http2.response_headers_decode.\(streamId)", first: 1, every: 50) {
                    NetworkLog.http2.debug(
                        "event=http2.response_headers_decode outcome=success stream_id=\(streamId, privacy: .public) header_count=\(headers.count, privacy: .public)"
                    )
                }
            } catch {
                if warningThrottle.shouldLog(key: "http2.hpack_decode.server_headers.\(streamId)", minInterval: 5) {
                    NetworkLog.http2.error(
                        "event=http2.hpack_decode outcome=failure stream_id=\(streamId, privacy: .public) context=server_headers error=\(error, privacy: .public)"
                    )
                }
                onProtocolError?()
                cleanupCaptures(streamId: streamId, removeFiles: true)
                streams.removeValue(forKey: streamId)
                return
            }
        }

        // Rule: END_STREAM completes the response body.
        if flags.contains(.endStream) {
            stream.responseComplete = true
            stream.state = stream.requestComplete ? .closed : .halfClosedRemote
            finalizeResponseBodyCapture(streamId: streamId)
        }

        streams[streamId] = stream

        markStreamDirty(streamId: streamId)
    }

    /// Handles a DATA frame from the server.
    public func handleServerData(_ frame: HTTP2Frame) async {
        let streamId = frame.header.streamId
        let flags = frame.header.frameFlags

        guard streamId > 0, var stream = streams[streamId] else { return }

        guard let payload = await unpadPayload(frame.payload, flags: flags, streamId: streamId, context: "server DATA") else {
            cleanupCaptures(streamId: streamId, removeFiles: true)
            streams.removeValue(forKey: streamId)
            return
        }

        stream.lastActivity = Date()
        recordFrame(frame, to: &stream)

        stream.responseBodyBytesSeen += payload.count

        if captureBodies, maxBodySize > 0, !stream.responseBodyTruncated {
            let remainingCapture = max(0, maxBodySize - stream.responseBodyBytesCaptured)
            if remainingCapture == 0 {
                stream.responseBodyTruncated = true
                if var capture = responseBodyCaptures[streamId] {
                    capture.truncated = true
                    responseBodyCaptures[streamId] = capture
                }
            } else {
                let toCapture = min(remainingCapture, payload.count)
                let willNeedFile =
                    stream.responseBodyFileURL != nil ||
                    (stream.responseBodyBytesCaptured + toCapture) > BodyStorage.inlineThreshold

                if willNeedFile {
                    if stream.responseBodyFileURL == nil {
                        _ = ensureResponseBodyCapture(streamId: streamId, stream: &stream)
                    }
                    if var capture = responseBodyCaptures[streamId] {
                        do {
                            try capture.handle.write(contentsOf: payload.prefix(toCapture))
                            capture.bytesWritten += toCapture
                            responseBodyCaptures[streamId] = capture
                        } catch {
                            stream.responseBodyTruncated = true
                            capture.truncated = true
                            responseBodyCaptures[streamId] = capture
                            try? FileManager.default.removeItem(at: capture.url)
                            responseBodyCaptures.removeValue(forKey: streamId)
                        }
                    }

                    if stream.responseBodyData.count < BodyStorage.previewSize {
                        let previewRemaining = BodyStorage.previewSize - stream.responseBodyData.count
                        let toPreview = min(previewRemaining, toCapture)
                        if toPreview > 0 {
                            stream.responseBodyData.append(contentsOf: payload.prefix(toPreview))
                        }
                    }
                } else {
                    stream.responseBodyData.append(contentsOf: payload.prefix(toCapture))
                }

                stream.responseBodyBytesCaptured += toCapture
                if payload.count > toCapture {
                    stream.responseBodyTruncated = true
                    if var capture = responseBodyCaptures[streamId] {
                        capture.truncated = true
                        responseBodyCaptures[streamId] = capture
                    }
                }
            }
        }

        // Rule: END_STREAM completes the response body.
        if flags.contains(.endStream) {
            stream.responseComplete = true
            stream.state = stream.requestComplete ? .closed : .halfClosedRemote
            finalizeResponseBodyCapture(streamId: streamId)
        }

        streams[streamId] = stream

        markStreamDirty(streamId: streamId)
    }

    /// Handles a CONTINUATION frame from the server.
    public func handleServerContinuation(_ frame: HTTP2Frame) async {
        let streamId = frame.header.streamId
        let flags = frame.header.frameFlags

        guard streamId > 0, var stream = streams[streamId] else { return }

        stream.lastActivity = Date()
        recordFrame(frame, to: &stream)

        stream.pendingResponseHeaderFragment.append(contentsOf: frame.payload)

        if flags.contains(.endHeaders) {
            do {
                let headers = try serverHPACK.decode(Data(stream.pendingResponseHeaderFragment))
                applyDecodedResponseHeaderBlock(headers, to: &stream, streamId: streamId)
                stream.pendingResponseHeaderFragment.removeAll()
            } catch {
                if warningThrottle.shouldLog(key: "http2.hpack_decode.server_continuation.\(streamId)", minInterval: 5) {
                    NetworkLog.http2.error(
                        "event=http2.hpack_decode outcome=failure stream_id=\(streamId, privacy: .public) context=server_continuation error=\(error, privacy: .public)"
                    )
                }
                onProtocolError?()
                cleanupCaptures(streamId: streamId, removeFiles: true)
                streams.removeValue(forKey: streamId)
                return
            }
        }

        streams[streamId] = stream

        markStreamDirty(streamId: streamId)
    }

    // MARK: - Settings Handling

    /// Handles a SETTINGS frame.
    public func handleSettings(_ frame: HTTP2Frame, fromClient: Bool) async {
        let flags = frame.header.frameFlags

        // Rule: SETTINGS with ACK must not carry a payload.
        if flags.contains(.ack) {
            return
        }

        guard let settings = HTTP2Settings.parse(from: frame.payload) else {
            NetworkLog.http2.warning("event=http2.settings_parse outcome=failure error=invalid_settings_frame")
            onProtocolError?()
            return
        }

        func toDict(_ s: HTTP2Settings) -> [String: Int] {
            var dict: [String: Int] = [
                "HEADER_TABLE_SIZE": Int(s.headerTableSize),
                "ENABLE_PUSH": s.enablePush ? 1 : 0,
                "INITIAL_WINDOW_SIZE": Int(s.initialWindowSize),
                "MAX_FRAME_SIZE": Int(s.maxFrameSize)
            ]
            if let v = s.maxConcurrentStreams { dict["MAX_CONCURRENT_STREAMS"] = Int(v) }
            if let v = s.maxHeaderListSize { dict["MAX_HEADER_LIST_SIZE"] = Int(v) }
            return dict
        }

        if fromClient {
            // Rule: Client settings constrain server->client header decoding.
            remoteSettings = settings
            settingsFromClient = toDict(settings)
            serverHPACK.setMaxDynamicTableSize(Int(settings.headerTableSize))
        } else {
            // Rule: Server settings constrain client->server header decoding.
            localSettings = settings
            settingsFromServer = toDict(settings)
            clientHPACK.setMaxDynamicTableSize(Int(settings.headerTableSize))
        }

        if logSampler.shouldLog(key: "http2.settings_update", first: 1, every: 100) {
            NetworkLog.http2.debug(
                "event=http2.settings_update outcome=success max_frame_size=\(settings.maxFrameSize, privacy: .public) header_table_size=\(settings.headerTableSize, privacy: .public)"
            )
        }
    }

    // MARK: - Stream Management

    /// Handles an RST_STREAM frame.
    public func handleRstStream(_ frame: HTTP2Frame) async {
        let streamId = frame.header.streamId

        guard streamId > 0 else { return }

        var errorCode: UInt32 = 0
        if frame.payload.count >= 4 {
            errorCode = UInt32(frame.payload[0]) << 24 |
                UInt32(frame.payload[1]) << 16 |
                UInt32(frame.payload[2]) << 8 |
                UInt32(frame.payload[3])
        }

        if logSampler.shouldLog(key: "http2.rst_stream.\(streamId)", first: 3, every: 200) {
            NetworkLog.http2.debug(
                "event=http2.rst_stream outcome=success stream_id=\(streamId, privacy: .public) error_code=\(errorCode, privacy: .public)"
            )
        }

        // Rule: Emit a final snapshot before removal so resets are not dropped.
        markStreamDirty(streamId: streamId, forceImmediate: true)

        if streams.removeValue(forKey: streamId) != nil {
            onStreamClosed?(streamId)
            onStreamsActiveChanged?(streams.count)
        }
    }

    /// Handles a GOAWAY frame.
    public func handleGoaway(_ frame: HTTP2Frame) async {
        guard frame.payload.count >= 8 else { return }

        let lastStreamId = UInt32(frame.payload[0] & 0x7F) << 24 |
            UInt32(frame.payload[1]) << 16 |
            UInt32(frame.payload[2]) << 8 |
            UInt32(frame.payload[3])

        let errorCode = UInt32(frame.payload[4]) << 24 |
            UInt32(frame.payload[5]) << 16 |
            UInt32(frame.payload[6]) << 8 |
            UInt32(frame.payload[7])

        NetworkLog.http2.info("event=http2.goaway outcome=success last_stream_id=\(lastStreamId, privacy: .public) error_code=\(errorCode, privacy: .public)")

        goAwayReceived = true
        goAwayLastStreamId = Int(lastStreamId)

        // Rule: Streams above last_stream_id will not be processed; emit and remove them.
        let abandoned = streams.keys.filter { $0 > lastStreamId }
        var removedAny = false
        for streamId in abandoned {
            markStreamDirty(streamId: streamId, forceImmediate: true)
            if streams.removeValue(forKey: streamId) != nil {
                removedAny = true
                onStreamClosed?(streamId)
            }
        }
        if removedAny {
            onStreamsActiveChanged?(streams.count)
        }
    }

    // MARK: - Request Emission (initial + updates)

    private func markStreamDirty(streamId: UInt32, forceImmediate: Bool = false) {
        guard var stream = streams[streamId] else { return }

        let now = Date()
        stream.lastActivity = now

        if now.timeIntervalSince(lastCleanupAt) > 60 {
            lastCleanupAt = now
            cleanupStaleStreams()
        }

        // Rule: Do not emit snapshots until request headers are complete.
        guard stream.requestHeadersComplete else {
            streams[streamId] = stream
            return
        }

        let isFinal = stream.requestComplete && stream.responseComplete
        let lastEmit = stream.lastEmittedAt ?? .distantPast
        let eligibleByTime = now.timeIntervalSince(lastEmit) >= minEmitInterval

        if !stream.emitted || forceImmediate || isFinal || eligibleByTime {
            emitNetworkRequest(stream, isFinal: isFinal)
            stream.emitted = true
            stream.emitScheduled = false
            stream.lastEmittedAt = now
            streams[streamId] = stream

            if isFinal {
                // Ensure file handles are closed and maps are cleaned up.
                cleanupCaptures(streamId: streamId, removeFiles: false)
                streams.removeValue(forKey: streamId)
                onStreamClosed?(streamId)
                onStreamsActiveChanged?(streams.count)
            }
            return
        }

        // Rule: Coalesce updates when within the throttling interval.
        guard !stream.emitScheduled else {
            streams[streamId] = stream
            return
        }

        stream.emitScheduled = true
        streams[streamId] = stream

        let remaining = max(0, minEmitInterval - now.timeIntervalSince(lastEmit))
        let delayNs = UInt64(remaining * 1_000_000_000)
        Task { [streamId, delayNs] in
            if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
            await self.performScheduledEmit(streamId: streamId)
        }
    }

    private func performScheduledEmit(streamId: UInt32) async {
        guard var stream = streams[streamId] else { return }
        stream.emitScheduled = false

        guard stream.requestHeadersComplete else {
            streams[streamId] = stream
            return
        }

        let now = Date()
        let isFinal = stream.requestComplete && stream.responseComplete
        let lastEmit = stream.lastEmittedAt ?? .distantPast
        let elapsed = now.timeIntervalSince(lastEmit)

        if !isFinal && elapsed < minEmitInterval {
            // Rule: Reschedule once more if still within the throttling interval.
            stream.emitScheduled = true
            streams[streamId] = stream
            let remaining = max(0, minEmitInterval - elapsed)
            let delayNs = UInt64(remaining * 1_000_000_000)
            Task { [streamId, delayNs] in
                if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
                await self.performScheduledEmit(streamId: streamId)
            }
            return
        }

        emitNetworkRequest(stream, isFinal: isFinal)
        stream.emitted = true
        stream.lastEmittedAt = now
        streams[streamId] = stream

        if isFinal {
            cleanupCaptures(streamId: streamId, removeFiles: false)
            streams.removeValue(forKey: streamId)
            onStreamClosed?(streamId)
            onStreamsActiveChanged?(streams.count)
        }
    }

    // MARK: - Body spooling helpers

    private func bodyContainerURLForCapture() -> URL? {
        if let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupConfiguration.appGroupIdentifier
        ) {
            return groupContainer
        }

        if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documentsURL.appendingPathComponent("AppGroupFallback")
        }

        return nil
    }

    private func ensureRequestBodyCapture(streamId: UInt32, stream: inout HTTP2StreamState) -> ActiveBodyCapture? {
        if let existing = requestBodyCaptures[streamId] {
            return existing
        }
        guard let containerURL = bodyContainerURLForCapture() else { return nil }

        let bodiesDir = containerURL.appendingPathComponent("Bodies", isDirectory: true)
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)

        let fileURL = bodiesDir.appendingPathComponent(UUID().uuidString + ".bin")
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }

        // Seed the file with any already-captured in-memory bytes.
        if !stream.requestBodyData.isEmpty {
            try? handle.write(contentsOf: stream.requestBodyData)
        }

        let capture = ActiveBodyCapture(
            url: fileURL,
            handle: handle,
            bytesWritten: stream.requestBodyBytesCaptured,
            truncated: stream.requestBodyTruncated
        )
        requestBodyCaptures[streamId] = capture
        stream.requestBodyFileURL = fileURL
        return capture
    }

    private func ensureResponseBodyCapture(streamId: UInt32, stream: inout HTTP2StreamState) -> ActiveBodyCapture? {
        if let existing = responseBodyCaptures[streamId] {
            return existing
        }
        guard let containerURL = bodyContainerURLForCapture() else { return nil }

        let bodiesDir = containerURL.appendingPathComponent("Bodies", isDirectory: true)
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)

        let fileURL = bodiesDir.appendingPathComponent(UUID().uuidString + ".bin")
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }

        if !stream.responseBodyData.isEmpty {
            try? handle.write(contentsOf: stream.responseBodyData)
        }

        let capture = ActiveBodyCapture(
            url: fileURL,
            handle: handle,
            bytesWritten: stream.responseBodyBytesCaptured,
            truncated: stream.responseBodyTruncated
        )
        responseBodyCaptures[streamId] = capture
        stream.responseBodyFileURL = fileURL
        return capture
    }

    private func finalizeRequestBodyCapture(streamId: UInt32) {
        guard let capture = requestBodyCaptures.removeValue(forKey: streamId) else { return }
        try? capture.handle.close()
    }

    private func finalizeResponseBodyCapture(streamId: UInt32) {
        guard let capture = responseBodyCaptures.removeValue(forKey: streamId) else { return }
        try? capture.handle.close()
    }

    private func cleanupCaptures(streamId: UInt32, removeFiles: Bool) {
        if let capture = requestBodyCaptures.removeValue(forKey: streamId) {
            try? capture.handle.close()
            if removeFiles {
                try? FileManager.default.removeItem(at: capture.url)
            }
        }
        if let capture = responseBodyCaptures.removeValue(forKey: streamId) {
            try? capture.handle.close()
            if removeFiles {
                try? FileManager.default.removeItem(at: capture.url)
            }
        }
    }

    private func makeBodyStorage(
        data: Data,
        bytesSeen: Int,
        bytesCaptured: Int,
        fileURL: URL?,
        isTruncated: Bool,
        charset: String?,
        contentEncoding: String? = nil,
        isFinal: Bool
    ) -> BodyStorage {
        guard captureBodies, maxBodySize > 0 else { return .empty }
        guard bytesSeen > 0 else { return .empty }

        let preview = Data(data.prefix(BodyStorage.previewSize))

        if isTruncated {
            if isFinal, let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return .truncated(preview, totalSize: bytesSeen, charset: charset, compressionInfo: nil)
        }

        // Tradeoff: Avoid `.file(...)` during live updates to prevent many body files.
        if !isFinal {
            if bytesSeen <= BodyStorage.inlineThreshold, data.count == bytesSeen {
                return .inline(data, charset: charset, compressionInfo: nil)
            }
            return .truncated(preview, totalSize: bytesSeen, charset: charset, compressionInfo: nil)
        }

        if let fileURL {
            // Small bodies may still be file-backed if they crossed the threshold in one chunk;
            // prefer inline for those cases.
            if bytesCaptured <= BodyStorage.inlineThreshold,
               let full = try? Data(contentsOf: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                let maxSizeForFinal: Int? = (maxBodySize > 0) ? maxBodySize : nil
                return BodyStorage.from(data: full, charset: charset, maxSize: maxSizeForFinal, contentEncoding: contentEncoding)
            }
            return .file(fileURL, charset: charset, compressionInfo: nil)
        }

        // Rule: Allow decompression and file storage in the final snapshot (bounded for stability).
        let maxSizeForFinal: Int? = (maxBodySize > 0) ? maxBodySize : nil
        return BodyStorage.from(data: data, charset: charset, maxSize: maxSizeForFinal, contentEncoding: contentEncoding)
    }

    private func makeConnectionInfoSnapshot() -> HTTP2ConnectionInfo {
        HTTP2ConnectionInfo(
            settingsReceived: settingsFromServer,
            settingsSent: settingsFromClient,
            goAwayReceived: goAwayReceived,
            lastStreamId: goAwayLastStreamId,
            connectionStartTime: connectionStartTime,
            connectionEndTime: connectionEndTime,
            hpackTableSnapshot: serverHPACK.captureSnapshot(),
            hpackTableEvents: serverHPACK.recordEvents ? serverHPACK.getTableEvents() : nil
        )
    }

    /// Build and emit a `NetworkRequest` snapshot from current stream state.
    private func emitNetworkRequest(_ stream: HTTP2StreamState, isFinal: Bool) {
        guard let requestHeaders = stream.requestHeaders else { return }

        let method = requestHeaders.first { $0.key == ":method" }?.value ?? "GET"
        let path = requestHeaders.first { $0.key == ":path" }?.value ?? "/"
        let scheme = requestHeaders.first { $0.key == ":scheme" }?.value ?? "https"
        let authority = requestHeaders.first { $0.key == ":authority" }?.value ?? targetHost

        // Rule: Include a non-default port when :authority omits it.
        var host = authority.isEmpty ? targetHost : authority
        let defaultPort: UInt16 = (scheme.lowercased() == "https") ? 443 : 80

        func authorityHasExplicitPort(_ value: String) -> Bool {
            // Rule: IPv6 bracket form allows optional port after "]:".
            if value.hasPrefix("[") {
                return value.contains("]:")
            }
            // Rule: Unbracketed IPv6 literals do not imply a port.
            let colonCount = value.reduce(0) { $1 == ":" ? $0 + 1 : $0 }
            if colonCount > 1 {
                return false
            }
            // Rule: Hostname/IPv4 with one colon implies a port.
            return colonCount == 1
        }

        if targetPort != defaultPort, !authorityHasExplicitPort(host) {
            let needsBrackets = host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]")
            let hostPart = needsBrackets ? "[\(host)]" : host
            host = "\(hostPart):\(targetPort)"
        }

        let url = "\(scheme)://\(host)\(path)"

        let statusCode: Int? = extractStatusCode(from: stream.responseHeaders)
        let statusMessage: String? = (statusCode == nil) ? "response pending" : nil

        let filteredRequestHeaders = stripPseudoHeaders(requestHeaders)
        let filteredResponseHeaders = stripPseudoHeaders(stream.responseHeaders ?? [])

        let requestContentType = filteredRequestHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value
        let responseContentType = filteredResponseHeaders.first(where: { $0.key.lowercased() == "content-type" })?.value
        let responseContentEncoding = filteredResponseHeaders.first(where: { $0.key.lowercased() == "content-encoding" })?.value

        let requestCharset = BodyStorage.extractCharset(from: requestContentType)
        let responseCharset = BodyStorage.extractCharset(from: responseContentType)

        let duration = Date().timeIntervalSince(stream.timestamp)

        var networkRequest = NetworkRequest(
            id: stream.requestId,
            url: url,
            method: HTTPMethod(rawValue: method) ?? .get,
            statusCode: statusCode,
            statusMessage: statusMessage,
            timestamp: stream.timestamp,
            duration: duration,
            requestHeaders: filteredRequestHeaders,
            responseHeaders: filteredResponseHeaders,
            requestBody: makeBodyStorage(
                data: stream.requestBodyData,
                bytesSeen: stream.requestBodyBytesSeen,
                bytesCaptured: stream.requestBodyBytesCaptured,
                fileURL: stream.requestBodyFileURL,
                isTruncated: stream.requestBodyTruncated,
                charset: requestCharset,
                isFinal: isFinal
            ),
            responseBody: makeBodyStorage(
                data: stream.responseBodyData,
                bytesSeen: stream.responseBodyBytesSeen,
                bytesCaptured: stream.responseBodyBytesCaptured,
                fileURL: stream.responseBodyFileURL,
                isTruncated: stream.responseBodyTruncated,
                charset: responseCharset,
                contentEncoding: responseContentEncoding,
                isFinal: isFinal
            ),
            protocolVersion: .http2
        )

        let combinedStreamHeaders = requestHeaders + (stream.responseHeaders ?? [])
        networkRequest.http2Streams = [
            HTTP2StreamInfo(
                streamId: Int(stream.streamId),
                headers: combinedStreamHeaders,
                dataFrames: stream.dataFrames,
                state: stream.state.toHTTP2StreamState(),
                priority: stream.priority,
                windowSize: Int(localSettings.initialWindowSize),
                totalDataSize: stream.requestBodyBytesSeen + stream.responseBodyBytesSeen,
                startTime: stream.timestamp,
                endTime: isFinal ? Date() : nil
            )
        ]
        networkRequest.http2ConnectionInfo = makeConnectionInfoSnapshot()

        networkRequest.extractHTTPFields()

        NetworkThrottlingController.shared.applyMetadata(to: &networkRequest)

        onRequestComplete?(networkRequest)

        let phase = stream.emitted ? "update" : "initial"
        let streamId = stream.streamId
        let requestId = stream.requestId.uuidString
        if isFinal || logSampler.shouldLog(key: "http2.request_capture:\(streamId)", first: 1, every: 20) {
            NetworkLog.http2.debug(
                "event=http2.request_capture outcome=success phase=\(phase, privacy: .public) stream_id=\(streamId, privacy: .public) request_id=\(requestId, privacy: .public) method=\(method, privacy: .public) url=\(url, privacy: .private(mask: .hash)) status=\(statusCode ?? 0, privacy: .public)"
            )
        }
    }

    // MARK: - Cleanup

    /// Flushes and closes the connection from a capture perspective.
    ///
    /// Contract: Call this when the underlying TCP/TLS connection closes to avoid leaking state.
    public func finalizeConnection() async {
        connectionEndTime = Date()
        let ids = Array(streams.keys)
        for id in ids {
            markStreamDirty(streamId: id, forceImmediate: true)
        }
        let remaining = Array(streams.keys)
        if !remaining.isEmpty {
            for id in remaining {
                onStreamClosed?(id)
            }
        }
        // Cleanup any leftover capture handles/files for streams that did not finalize cleanly.
        let captureIds = Set(requestBodyCaptures.keys).union(responseBodyCaptures.keys)
        for id in captureIds {
            cleanupCaptures(streamId: id, removeFiles: true)
        }
        streams.removeAll()
        onStreamsActiveChanged?(0)
    }

    /// Cleans up completed streams that have been idle for a while.
    ///
    /// Rule: Do not remove open streams to avoid splitting long-lived gRPC/SSE streams.
    func cleanupStaleStreams(olderThan timeout: TimeInterval = 300) {
        let now = Date()
        let staleStreamIds = streams.compactMap { streamId, stream -> UInt32? in
            let idle = now.timeIntervalSince(stream.lastActivity) > timeout
            let finished = stream.requestComplete && stream.responseComplete
            let closed = stream.state == .closed
            return (idle && (finished || closed)) ? streamId : nil
        }

        for streamId in staleStreamIds {
            cleanupCaptures(streamId: streamId, removeFiles: true)
            if streams.removeValue(forKey: streamId) != nil {
                onStreamClosed?(streamId)
            }
        }

        if !staleStreamIds.isEmpty {
            onStreamsActiveChanged?(streams.count)
            if logSampler.shouldLog(key: "http2.cleanup_stale_streams", first: 1, every: 20) {
                NetworkLog.http2.debug(
                    "event=http2.cleanup_stale_streams outcome=success count=\(staleStreamIds.count, privacy: .public)"
                )
            }
        }
    }

    /// Returns the current stream count.
    public func getStreamCount() -> Int {
        streams.count
    }
}

// MARK: - HTTP2 Stream State

/// Represents internal HTTP/2 stream state tracking.
public struct HTTP2StreamState {
    public let streamId: UInt32
    public let requestId: UUID
    public var state: StreamStateInternal = .idle
    public let timestamp: Date
    public var lastActivity: Date

    /// Indicates whether at least one `NetworkRequest` snapshot has been emitted.
    /// Subsequent emissions update the same request ID.
    public var emitted: Bool = false
    public var emitScheduled: Bool = false
    public var lastEmittedAt: Date?

    public var requestHeaders: [TraceHTTPHeader]?
    public var requestHeadersComplete: Bool = false
    public var pendingRequestHeaderFragment: [UInt8] = []
    public var requestBodyData: Data = .init()
    public var requestBodyBytesSeen: Int = 0
    public var requestBodyBytesCaptured: Int = 0
    public var requestBodyTruncated: Bool = false
    public var requestBodyFileURL: URL?
    public var requestComplete: Bool = false
    public var priority: HTTP2StreamInfo.StreamPriority?

    public var responseHeaders: [TraceHTTPHeader]?
    public var responseHeadersComplete: Bool = false
    public var pendingResponseHeaderFragment: [UInt8] = []
    public var responseBodyData: Data = .init()
    public var responseBodyBytesSeen: Int = 0
    public var responseBodyBytesCaptured: Int = 0
    public var responseBodyTruncated: Bool = false
    public var responseBodyFileURL: URL?
    public var responseComplete: Bool = false

    public var dataFrames: [HTTP2DataFrame] = []
    public var droppedFrameCount: Int = 0

    /// Initializes a stream state container for the given stream ID.
    public init(streamId: UInt32) {
        self.streamId = streamId
        self.requestId = UUID()
        let now = Date()
        self.timestamp = now
        self.lastActivity = now
    }

    /// Defines internal stream state transitions.
    public enum StreamStateInternal {
        case idle
        case open
        case halfClosedLocal
        case halfClosedRemote
        case closed

        func toHTTP2StreamState() -> HTTP2StreamInfo.StreamState {
            switch self {
            case .idle: .idle
            case .open: .open
            case .halfClosedLocal: .halfClosedLocal
            case .halfClosedRemote: .halfClosedRemote
            case .closed: .closed
            }
        }
    }
}
