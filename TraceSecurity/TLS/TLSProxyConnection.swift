//
//  TLSProxyConnection.swift
//  TraceSecurity
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import Network
import Security
import TraceCore
import TraceNetworking

private final class TLSStreamThrottler {
    enum Direction {
        case upload
        case download
    }

    private let queue = DispatchQueue(label: "com.trace.tls.throttler", qos: .utility)
    private var state: NetworkThrottlingState = .disabled
    private var uploadNextTime: TimeInterval = 0
    private var downloadNextTime: TimeInterval = 0

    func process(packet: Data, direction: Direction, handler: @escaping () -> Void) {
        // Fast path: when throttling is disabled, do NOT enqueue to the throttler queue.
        //
        // Rationale: In large downloads, queueing every chunk retains `Data` in pending blocks,
        // which can trigger Network Extension memory kills even when throttling is off.
        let currentSnapshot = NetworkThrottlingController.shared.currentState()
        guard currentSnapshot.activeCondition != nil else {
            handler()
            return
        }

        // Rationale: Queue serialization preserves ordering while simulating bandwidth and latency.
        queue.async {
            if currentSnapshot != self.state {
                self.state = currentSnapshot
                let now = CFAbsoluteTimeGetCurrent()
                self.uploadNextTime = now
                self.downloadNextTime = now
            }

            guard let condition = self.state.activeCondition else {
                handler()
                return
            }

            let loss = max(0.0, min(1.0, condition.packetLoss))
            if loss >= 1.0 {
                // Rule: Drop all packets when packet loss is 100%.
                return
            }
            if loss > 0.0, Double.random(in: 0 ..< 1) < loss {
                return
            }

            let rateKBps = direction == .download ? condition.downloadSpeed : condition.uploadSpeed
            guard rateKBps > 0 else {
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            let rateBytesPerSecond = Double(rateKBps) * 1024.0
            let serializationDelay = Double(packet.count) / rateBytesPerSecond
            let latencySeconds = Double(condition.latency) / 1000.0

            let nextTime = direction == .download ? self.downloadNextTime : self.uploadNextTime
            let baseTime = max(now, nextTime)
            let scheduledTime = baseTime + latencySeconds
            let updatedNextTime = baseTime + serializationDelay

            if direction == .download {
                self.downloadNextTime = updatedNextTime
            } else {
                self.uploadNextTime = updatedNextTime
            }

            let delay = max(0, scheduledTime - now)
            if delay == 0 {
                handler()
            } else {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    handler()
                }
            }
        }
    }
}

/// Handles HTTPS MITM by creating dual TLS connections.
///
/// This bridges decrypted data between the client-facing TLS server connection and the upstream
/// TLS client connection for inspection.
public class TLSProxyConnection: @unchecked Sendable {
    public enum CloseReason {
        case normal
        case failure(String)
    }

    private var logSampleKey: String {
        "tls.proxy.\(targetHost):\(targetPort)"
    }

    private let logSampler = LogSampler()
    private let logThrottle = LogThrottle()

    private func sampledDebug(_ event: LogEvent, first: Int = 2, every: Int = 50) {
        if logSampler.shouldLog(key: logSampleKey, first: first, every: every) {
            TLSLog.debug(event)
        }
    }

    private let targetHost: String
    private let targetPort: UInt16
    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let clientConnection: NWConnection
    private let interceptor: (any InterceptionProviding)?

    private var tlsClientConnection: NWConnection?
    private var tlsServerConnection: NWConnection?
    private var tlsListener: NWListener?
    private var bridgeConnection: NWConnection?

    private var clientBuffer = Data()
    private var serverBuffer = Data()
    private var pendingClientData = Data()

    private var protocolNegotiated = false
    private var isHTTP2 = false
    private var http2Client: HTTP2Connection?
    private var http2Server: HTTP2Connection?
    private var http2Configured = false
    private var waitingForHTTP2Preface = false
    private var clientPrefaceConsumed = false

    // Rule: Default HTTP/2 max frame size is 16,384 (RFC 7540) until SETTINGS are observed.
    // Rationale: Validate incoming frame lengths to avoid buffering pathological frames.
    private var http2MaxFrameSizeClientToServer: UInt32 = HTTP2Settings.minFrameSize
    private var http2MaxFrameSizeServerToClient: UInt32 = HTTP2Settings.minFrameSize
    // Rule: Cap SETTINGS_MAX_FRAME_SIZE to avoid pathological memory usage.
    private let http2MaxFrameSizeHardCap: UInt32 = 64 * 1024

    private var http2StreamManager: HTTP2StreamManager?

    // MARK: - HTTP/2 Capture Pipeline (ordered, single consumer)

    private enum HTTP2CaptureDirection: Sendable {
        case clientToServer
        case serverToClient
    }

    private struct HTTP2CaptureEvent: Sendable {
        let direction: HTTP2CaptureDirection
        let frame: HTTP2Frame
    }

    private var http2CaptureContinuation: AsyncStream<HTTP2CaptureEvent>.Continuation?
    private var http2CaptureTask: Task<Void, Never>?
    private var http2CapturePendingCount = 0
    private var http2CaptureDisabled = false
    // Rule: Keep the capture queue small to avoid retaining large DATA frame payloads in memory.
    private let http2CaptureMaxPending = 200

    // Rationale: HTTP/1.1 is sequential, so keep a FIFO to pair requests with responses.
    private struct CapturedHTTP1Request: Sendable {
        let id: UUID
        let url: String
        let method: String
        let headers: [String: String]
        let body: String?
        let bodyData: Data?
        let startTime: Date
        let wasRewritten: Bool
        let isMocked: Bool
        let isReplayed: Bool
        let appliedScriptName: String?
        let hitBreakpoint: Bool
        let retryAttempts: Int
        let responsePipeline: ResponsePipeline
        let isWebSocketUpgrade: Bool
    }

    private let startTime = Date()
    private var pendingHTTP1Requests: [CapturedHTTP1Request] = []
    private var pendingHTTP1Request: HTTP1MessageState?
    private var pendingHTTP1Response: HTTP1MessageState?
    private var http1InterceptionInFlight = false
    private var http1ResponseInterceptionInFlight = false
    private var bufferedHTTP1ResponseRaw = Data()
    private var http1ResponseForceStreaming = false
    private var currentHTTP1ResponseBuffering = false

    // MARK: - Capture Configuration / Safety Limits

    private let captureConfig: CaptureConfiguration
    private let captureBodies: Bool
    private let maxCapturedBodyBytes: Int

    // Rule: Limit request buffering to 100 MB.
    private let maxRequestSize = 100 * 1024 * 1024

    // Rule: Limit response buffering (headers + initial body bytes) to keep the extension stable.
    private let maxResponseBufferSize: Int

    // MARK: - Streaming body capture (disk spooling)

    private struct CompletedBodyCapture {
        let url: URL
        let bytesWritten: Int
        let truncated: Bool
        let isChunked: Bool
    }

    private struct ActiveBodyCapture {
        let url: URL
        let handle: FileHandle
        var bytesWritten: Int
        var truncated: Bool
        let isChunked: Bool
        var chunkedDecoder: ChunkedTransferDecoder?
    }

    private var activeHTTP1ResponseBodyCapture: ActiveBodyCapture?
    private var completedHTTP1ResponseBodyCapture: CompletedBodyCapture?

    private var delegatedStreamHandlerActive = false
    private var pauseClientReads = false
    private var sseHandler: SSEHandler?
    private var webSocketHandler: WebSocketHandler?

    public var onRequestCaptured: ((NetworkRequest) -> Void)?
    public var onClose: (() -> Void)?
    public var onFailure: ((Data, String) -> Void)?

    public var onHTTP2FrameParsed: (() -> Void)?
    public var onHTTP2ProtocolError: (() -> Void)?
    public var onHTTP2StreamCreated: ((UInt32) -> Void)?
    public var onHTTP2StreamClosed: ((UInt32) -> Void)?
    public var onHTTP2StreamsActiveChanged: ((Int) -> Void)?

    private let connectionId: Int?
    private var isActive = false
    private var isBridging = false
    private let queue = DispatchQueue(label: "com.trace.tlsproxy", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var clientALPN: String?
    private var serverALPN: String?
    private var upstreamTLSInfo: TLSConnectionInfo?
    private var didParseClientHelloALPN = false
    private var clientHelloALPN: [String]?
    private var didStartTLSListener = false
    private var upstreamReady = false
    private var clientHandshakeReady = false
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private let handshakeTimeoutSeconds: TimeInterval = 10
    private let throttler = TLSStreamThrottler()

    private var proxyStartTime: CFAbsoluteTime?
    private var upstreamConnectStartTime: CFAbsoluteTime?
    private var upstreamConnectWatchdog: DispatchWorkItem?
    private var lastUpstreamStateLabel: String = "unknown"

    private var bytesDecryptedFromClient: UInt64 = 0
    private var bytesDecryptedFromServer: UInt64 = 0
    private var bytesSentToUpstream: UInt64 = 0
    private var bytesSentToClient: UInt64 = 0

    public init(
        clientConnection: NWConnection,
        connectionId: Int? = nil,
        targetHost: String,
        targetPort: UInt16 = 443,
        upstreamHost: String? = nil,
        upstreamPort: UInt16? = nil,
        interceptor: (any InterceptionProviding)? = nil
    ) {
        let config = AppGroupStorage.shared.loadConfiguration()
        self.captureConfig = config
        // Rule: Enforce a conservative hard cap inside the Network Extension to avoid OOM/jetsam.
        let requestedBodyBytes = max(0, config.maxBodySize)
        let hardCapBodyBytes = BodyStorage.truncationThreshold // 10 MB (default product limit)
        let cappedBodyBytes = min(requestedBodyBytes, hardCapBodyBytes)
        self.captureBodies = config.captureBody && cappedBodyBytes > 0
        self.maxCapturedBodyBytes = cappedBodyBytes
        // Response buffering is the main risk for large downloads; keep it tightly bounded.
        let headerAllowance = 64 * 1024
        let bodyPreviewBytes = min(BodyStorage.previewSize, cappedBodyBytes)
        self.maxResponseBufferSize = headerAllowance + (self.captureBodies ? bodyPreviewBytes : 0)

        self.clientConnection = clientConnection
        self.connectionId = connectionId
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.upstreamHost = upstreamHost ?? targetHost
        self.upstreamPort = upstreamPort ?? targetPort
        self.interceptor = interceptor
        queue.setSpecific(key: queueKey, value: ())
    }

    private func executeOnQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }

    private struct HeaderMetadata {
        let contentLength: Int?
        let isChunked: Bool
        let expectsContinue: Bool
    }

    private struct HTTP1MessageState {
        let startLine: String
        let headers: [TraceHTTPHeader]
        let metadata: HeaderMetadata
        let timestamp: Date
        var remainingBodyBytes: Int?
        var bodyData = Data()
        var bodyTruncated = false
        var chunkedParser = ChunkedBodyParser()
    }

    private struct ChunkedBodyParser {
        private(set) var isComplete = false
        private var currentChunkSize: Int?

        mutating func consume(
            buffer: Data,
            maxCaptureBytes: Int,
            capturedBody: inout Data,
            bodyTruncated: inout Bool
        ) -> (consumed: Int, complete: Bool, parseError: Bool) {
            var index = 0
            let crlf = Data([0x0D, 0x0A])
            let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

            func appendCapture(_ data: Data) {
                guard maxCaptureBytes > 0 else { return }
                if capturedBody.count >= maxCaptureBytes {
                    bodyTruncated = true
                    return
                }
                let remaining = maxCaptureBytes - capturedBody.count
                if data.count > remaining {
                    capturedBody.append(data.prefix(remaining))
                    bodyTruncated = true
                } else {
                    capturedBody.append(data)
                }
            }

            while index < buffer.count, !isComplete {
                let start = buffer.startIndex
                let currentIndex = buffer.index(start, offsetBy: index)
                if currentChunkSize == nil {
                    guard let sizeRange = buffer.range(of: crlf, options: [], in: currentIndex ..< buffer.endIndex) else {
                        break
                    }
                    let sizeLineData = buffer[currentIndex ..< sizeRange.lowerBound]
                    guard let sizeString = String(data: sizeLineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) else {
                        return (index, false, true)
                    }
                    let sizeToken = sizeString.split(separator: ";", maxSplits: 1).first ?? Substring()
                    guard let size = Int(sizeToken, radix: 16) else {
                        return (index, false, true)
                    }
                    currentChunkSize = size
                    index = buffer.distance(from: start, to: sizeRange.upperBound)

                    if size == 0 {
                        let trailerStart = buffer.index(start, offsetBy: index)
                        if let trailerEnd = buffer.range(of: terminator, options: [], in: trailerStart ..< buffer.endIndex) {
                            index = buffer.distance(from: start, to: trailerEnd.upperBound)
                            isComplete = true
                            currentChunkSize = nil
                            break
                        }
                        break
                    }
                } else if let size = currentChunkSize {
                    let remaining = buffer.count - index
                    let needed = size + 2
                    if remaining < needed {
                        break
                    }
                    let chunkStart = buffer.index(start, offsetBy: index)
                    let chunkEnd = buffer.index(chunkStart, offsetBy: size)
                    appendCapture(Data(buffer[chunkStart ..< chunkEnd]))

                    let crlfEnd = buffer.index(chunkEnd, offsetBy: 2)
                    if buffer[chunkEnd ..< crlfEnd] != crlf {
                        return (index, false, true)
                    }
                    index = buffer.distance(from: start, to: crlfEnd)
                    currentChunkSize = nil
                }
            }

            return (index, isComplete, false)
        }
    }

    private func scheduleHandshakeTimeout() {
        cancelHandshakeTimeout()
        let host = targetHost
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            guard !(self.upstreamReady && self.clientHandshakeReady) else { return }

            let upstream = self.upstreamReady ? "ready" : "pending"
            let client = self.clientHandshakeReady ? "ready" : "pending"
            SecurityLog.tls.warning(
                LogEvent.tls("handshake_timeout")
                    .with("host", value: host, privacy: .hash)
                    .with("connection_id", value: self.connectionId)
                    .with("upstream", value: upstream)
                    .with("client", value: client)
                    .with("upstream_state", value: self.lastUpstreamStateLabel)
                    .with("pending_client_bytes", value: self.pendingClientData.count)
            )
            self.close(reason: .failure("tls_handshake_timeout upstream=\(upstream) client=\(client)"))
        }
        handshakeTimeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + handshakeTimeoutSeconds, execute: work)
    }

    private func cancelHandshakeTimeout() {
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
    }

    private func scheduleUpstreamConnectWatchdog(after delay: TimeInterval = 1.5) {
        cancelUpstreamConnectWatchdog()
        guard let start = upstreamConnectStartTime else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            guard !self.upstreamReady else { return }
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            SecurityLog.tls.warning(
                LogEvent.tls("upstream_connect_stall")
                    .outcome(.pending)
                    .with("host", value: self.targetHost, privacy: .hash)
                    .with("connection_id", value: self.connectionId)
                    .with("elapsed_ms", value: elapsedMs)
                    .with("state", value: self.lastUpstreamStateLabel)
                    .with("pending_client_bytes", value: self.pendingClientData.count)
            )

            // Re-arm while still stalled to give a breadcrumb trail without flooding.
            self.scheduleUpstreamConnectWatchdog(after: 5)
        }

        upstreamConnectWatchdog = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelUpstreamConnectWatchdog() {
        upstreamConnectWatchdog?.cancel()
        upstreamConnectWatchdog = nil
    }

    /// Network.framework may surface transient POSIX read errors while a stream is still usable.
    /// Treat these as retryable to avoid premature bridge teardown during handshake transitions.
    private func isTransientReceiveError(_ error: Error) -> Bool {
        guard let nwError = error as? NWError else { return false }
        guard case let .posix(code) = nwError else { return false }
        return code == .ENODATA || code == .EAGAIN || code == .EINTR
    }

    private func checkHandshakeCompleteAndCancelTimeout() {
        if upstreamReady && clientHandshakeReady {
            cancelHandshakeTimeout()
        }
    }

    // MARK: - Connection Lifecycle

    /// Starts the TLS proxy connection
    public func start() {
        executeOnQueue { [weak self] in
            guard let self else { return }
            self.proxyStartTime = CFAbsoluteTimeGetCurrent()
            SecurityLog.tls.info(
                "event=tls.proxy_start outcome=pending host=\(self.targetHost, privacy: .private(mask: .hash)) port=\(self.targetPort) upstream_host=\(self.upstreamHost, privacy: .private(mask: .hash)) upstream_port=\(self.upstreamPort) connection_id=\(self.connectionId ?? -1)"
            )
            sampledDebug(
                LogEvent.tls("proxy_step")
                    .with("step", value: 0)
                    .with("action", value: "buffer_client_hello")
                    .with("pending_data_bytes", value: self.pendingClientData.count)
                    .with("connection_id", value: self.connectionId)
            )

            self.isActive = true
            self.scheduleHandshakeTimeout()

            // Step 0: Buffer enough of the ClientHello to learn the client's ALPN offer.
            // We must do this BEFORE starting any MITM handshake, so we can align ALPN with upstream
            // and avoid a post-handshake ALPN mismatch close.
            sampledDebug(
                LogEvent.tls("collecting_client_hello")
                    .with("host", value: self.targetHost, privacy: .hash)
            )
            self.collectClientHelloALPN { [weak self] offered in
                guard let self else { return }
                self.clientHelloALPN = offered

                let offeredList = offered?.joined(separator: ",") ?? "none"
                let clientSupportsH2 = offered?.contains("h2") ?? false
                let clientSupportsHTTP1 = offered?.contains("http/1.1") ?? true

                sampledDebug(
                    LogEvent.tls("client_hello_alpn_parsed")
                        .with("offered", value: offeredList, privacy: .hash)
                        .with("supports_h2", value: clientSupportsH2)
                        .with("supports_http1", value: clientSupportsHTTP1)
                )

                // Decide whether interception features are currently active (rules/scripts/breakpoints enabled).
                // If active, prefer negotiating HTTP/1.1 to ensure full interception/modification parity.
                let interceptor = self.interceptor
                Task { [weak self] in
                    let interceptionActive = await interceptor?.requiresHTTP1Interception() ?? false
                    self?.sampledDebug(
                        LogEvent.tls("interception_check")
                            .with("host", value: self?.targetHost ?? "unknown", privacy: .hash)
                            .with("active", value: interceptionActive)
                            .with("connection_id", value: self?.connectionId)
                    )

                    self?.executeOnQueue { [weak self] in
                        guard let self, self.isActive else {
                            self?.sampledDebug(
                                LogEvent.tls("proxy_inactive_after_alpn")
                                    .with("host", value: self?.targetHost ?? "unknown", privacy: .hash)
                            )
                            return
                        }

                        let forceHTTP1 = interceptionActive && clientSupportsHTTP1
                        let requestALPN: [String] =
                            forceHTTP1 ? ["http/1.1"] : (clientSupportsH2 ? TLSHandler.supportedALPNProtocols : ["http/1.1"])

                        self.sampledDebug(
                            LogEvent.tls("proxy_step")
                                .with("step", value: 1)
                                .with("action", value: "connect_upstream_tls")
                                .with("host", value: self.targetHost, privacy: .hash)
                                .with("request_alpn", value: requestALPN.joined(separator: ","), privacy: .hash)
                                .with("force_http1", value: forceHTTP1)
                                .with("interception_active", value: interceptionActive)
                                .with("connection_id", value: self.connectionId)
                        )

                        // Step 1: Create TLS client connection to real server (upstream) first.
                        // Once we know upstream ALPN, we create the local TLS listener offering ONLY that protocol.
                        self.createTLSClientConnection(requestedALPNProtocols: requestALPN)
                    }
                }
            }
        }
    }

    public func enqueuePendingClientData(_ data: Data) {
        executeOnQueue { [weak self] in
            guard let self, !data.isEmpty else { return }
            self.pendingClientData.append(data)
        }
    }

    /// Closes all connections and cleans up
    public func close(reason: CloseReason = .normal) {
        executeOnQueue { [weak self] in
            guard let self, self.isActive else {
                if TLSLog.verboseEnabled {
                    let host = self?.targetHost ?? "unknown"
                    SecurityLog.tls.debug(
                        "event=tls.close_skipped host=\(host, privacy: .private(mask: .hash)) already_inactive=true"
                    )
                }
                return
            }
            self.isActive = false
            self.cancelHandshakeTimeout()
            self.cancelUpstreamConnectWatchdog()
            self.stopHTTP2CapturePipeline()
            self.cleanupActiveHTTP1ResponseBodyCapture()

            let hasClientConn = self.tlsClientConnection != nil
            let hasServerConn = self.tlsServerConnection != nil
            let hasListener = self.tlsListener != nil
            let hasBridge = self.bridgeConnection != nil
            let isHTTP2 = self.isHTTP2
            let upstreamReady = self.upstreamReady
            let clientReady = self.clientHandshakeReady
            let durationMs: Int? = if let start = self.proxyStartTime {
                Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            } else {
                nil
            }

            SecurityLog.tls.info(
                "event=tls.proxy_close_begin host=\(self.targetHost, privacy: .private(mask: .hash)) upstream_ready=\(upstreamReady) client_ready=\(clientReady) is_http2=\(isHTTP2) has_client_conn=\(hasClientConn) has_server_conn=\(hasServerConn) has_listener=\(hasListener) has_bridge=\(hasBridge) connection_id=\(self.connectionId ?? -1) duration_ms=\(durationMs ?? -1) bytes_client_in=\(self.bytesDecryptedFromClient) bytes_server_in=\(self.bytesDecryptedFromServer) bytes_upstream_out=\(self.bytesSentToUpstream) bytes_client_out=\(self.bytesSentToClient) pending_client_bytes=\(self.pendingClientData.count)"
            )

            if let manager = self.http2StreamManager {
                // Flush any partially-captured HTTP/2 streams before we release this connection.
                // Capture `self` strongly so the callback chain can still emit updates during shutdown.
                Task { [self] in
                    await manager.finalizeConnection()
                }
            }

            switch reason {
            case .normal:
                sampledDebug(
                    LogEvent.tls("proxy_close")
                        .success()
                        .with("reason", value: "normal")
                        .with("host", value: self.targetHost, privacy: .hash)
                )
            case let .failure(message):
                SecurityLog.tls.error(
                    LogEvent.tls("proxy_close")
                        .failure()
                        .with("host", value: self.targetHost, privacy: .hash)
                        .with("error", value: message, privacy: .hash)
                )
            }

            self.tlsClientConnection?.cancel()
            self.tlsServerConnection?.cancel()
            self.tlsListener?.cancel()
            self.bridgeConnection?.cancel()
            self.bridgeConnection = nil

            sampledDebug(
                LogEvent.tls("connections_cancelled")
                    .with("host", value: self.targetHost, privacy: .hash)
            )

            switch reason {
            case .normal:
                sampledDebug(
                    LogEvent.tls("invoking_on_close")
                        .with("host", value: self.targetHost, privacy: .hash)
                )
                self.onClose?()
            case let .failure(message):
                sampledDebug(
                    LogEvent.tls("invoking_on_failure")
                        .with("host", value: self.targetHost, privacy: .hash)
                        .with("pending_bytes", value: self.pendingClientData.count)
                )
                self.onFailure?(self.pendingClientData, message)
            }
        }
    }

    // MARK: - TLS Server Setup (for client connection)

    private func createTLSServerListener(alpnProtocols: [String], completion: @escaping @Sendable (Bool, String?) -> Void) {
        SecurityLog.tls.info(
            LogEvent.tls("listener_create_begin")
                .outcome(.pending)
                .with("domain", value: self.targetHost, privacy: .hash)
                .with("alpn", value: alpnProtocols.joined(separator: ","), privacy: .hash)
        )

        // Get TLS options with our generated certificate for this domain
        let alpnList = alpnProtocols.isEmpty ? "none" : alpnProtocols.joined(separator: ",")
        sampledDebug(
            LogEvent.tls("server_options_request")
                .with("domain", value: self.targetHost, privacy: .hash)
                .with("alpn", value: alpnList, privacy: .hash)
        )
        guard let tlsOptions = TLSHandler.createServerTLSOptions(for: self.targetHost, alpnProtocols: alpnProtocols) else {
            SecurityLog.tls.error(
                LogEvent.tls("server_options_create")
                    .failure()
                    .with("domain", value: self.targetHost, privacy: .hash)
            )
            let detail = TLSHandler.lastServerTLSOptionsError()
            SecurityLog.tls.error(
                LogEvent.tls("server_options_error")
                    .with("domain", value: self.targetHost, privacy: .hash)
                    .with("detail", value: detail ?? "unknown")
            )
            completion(false, "tls_server_tls_options_create_failed" + (detail.map { ":\($0)" } ?? ""))
            return
        }
        SecurityLog.tls.info(
            LogEvent.tls("server_options_create")
                .success()
                .with("domain", value: self.targetHost, privacy: .hash)
        )

        // Create TLS parameters
        let parameters = NWParameters(tls: tlsOptions, tcp: .init())
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        // IMPORTANT: The TLS listener is only used as a local MITM endpoint.
        // Bind it to loopback so the bridge connection can always reach it.
        parameters.requiredInterfaceType = .loopback

        // Ensure completion is only called once (listener emits multiple state transitions).
        // Use a class-based box to allow safe mutation from a @Sendable closure.
        final class FinishState: @unchecked Sendable {
            var finished = false
        }
        let state = FinishState()
        @Sendable func finish(_ ok: Bool, _ reason: String?) {
            guard !state.finished else { return }
            state.finished = true
            completion(ok, reason)
        }

        do {
            // Create listener on ephemeral port
            let listener = try NWListener(using: parameters, on: .any)

            // Handle new TLS connections from client
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }

                SecurityLog.tls.info(
                    LogEvent.tls("client_connected")
                        .with("host", value: self.targetHost, privacy: .hash)
                )
                sampledDebug(
                    LogEvent.tls("proxy_step")
                        .with("step", value: 3)
                        .with("action", value: "handshake_client")
                )

                // Store the TLS server connection
                self.tlsServerConnection = connection

                // Set up connection state handler
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .setup:
                        self?.sampledDebug(LogEvent.tls("client_state").with("state", value: "setup"))
                    case .preparing:
                        self?.sampledDebug(LogEvent.tls("client_state").with("state", value: "preparing"))
                    case .ready:
                        guard let self, self.isActive else { return }
                        SecurityLog.tls.info(
                            LogEvent.tls("handshake_client")
                                .success()
                                .with("host", value: self.targetHost ?? "unknown", privacy: .hash)
                        )
                        self.clientHandshakeReady = true
                        self.checkHandshakeCompleteAndCancelTimeout()
                        self.clientALPN = TLSHandler.getNegotiatedALPN(from: connection)
                        self.sampledDebug(
                            LogEvent.tls("client_alpn")
                                .with("protocol", value: self.clientALPN ?? "none", privacy: .hash)
                        )
                        self.reconcileProtocolNegotiation()
                        // Start reading decrypted data from client
                        self.readDecryptedFromClient()
                    case let .waiting(error):
                        if let self, self.logThrottle.shouldLog(
                            key: "tls.client_state.waiting.\(self.targetHost ?? "unknown")",
                            minInterval: 5
                        ) {
                            let host = self.targetHost ?? "unknown"
                            SecurityLog.tls.warning(
                                LogEvent.tls("client_state")
                                    .with("state", value: "waiting")
                                    .with("host", value: host, privacy: .hash)
                                    .with("error", value: error.localizedDescription)
                            )
                        }
                    case let .failed(error):
                        let host = self?.targetHost ?? "unknown"
                        let caTrusted = CertificateManager.shared.isRootCATrusted()
                        let hint = caTrusted ? "possible_pinning_or_strict_trust" : "ca_not_trusted"

                        SecurityLog.tls.error(
                            LogEvent.tls("handshake_client")
                                .failure()
                                .with("host", value: host, privacy: .hash)
                                .with("error", value: error.localizedDescription)
                        )
                        SecurityLog.tls.error(
                            LogEvent.tls("handshake_hint")
                                .with("reason", value: hint)
                        )
                        // Include the hint + concrete error so the UI can distinguish trust vs pinning-like failures.
                        self?.close(reason: .failure("tls_server_connection_failed:\(hint):\(String(describing: error))"))
                    case .cancelled:
                        self?.sampledDebug(LogEvent.tls("client_state").with("state", value: "cancelled"))
                        // If the client cancels before completing TLS handshake, treat it as a failure
                        // so the caller can fall back to passthrough (avoids "CONNECT observed" stalls).
                        if let self, self.isActive, !self.clientHandshakeReady {
                            self.close(reason: .failure("tls_server_connection_cancelled"))
                        } else {
                            self?.close()
                        }
                    default:
                        break
                    }
                }

                connection.start(queue: self.queue)
            }

            // Handle listener state changes
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port else {
                        listener.cancel()
                        finish(false, "tls_listener_port_missing")
                        return
                    }
                    SecurityLog.tls.info(
                        LogEvent.tls("listener_ready")
                            .with("port", value: port.rawValue)
                    )

                    // Redirect client connection to our TLS listener
                    self?.redirectClientToTLSListener(port: port)
                    finish(true, nil)

                case let .waiting(error):
                    if let self, self.logThrottle.shouldLog(
                        key: "tls.listener_state.waiting.\(self.targetHost ?? "unknown")",
                        minInterval: 5
                    ) {
                        let host = self.targetHost ?? "unknown"
                        SecurityLog.tls.warning(
                            LogEvent.tls("listener_state")
                                .with("state", value: "waiting")
                                .with("host", value: host, privacy: .hash)
                                .with("error", value: error.localizedDescription)
                        )
                    }
                    listener.cancel()
                    finish(false, "tls_listener_waiting:\(error.localizedDescription)")

                case let .failed(error):
                    SecurityLog.tls.error(
                        LogEvent.tls("listener_failed")
                            .with("error", value: error.localizedDescription)
                    )
                    listener.cancel()
                    finish(false, "tls_listener_failed:\(error.localizedDescription)")

                case .cancelled:
                    self?.sampledDebug(LogEvent.tls("listener_state").with("state", value: "cancelled"))
                    finish(false, "tls_listener_cancelled")

                default:
                    break
                }
            }

            listener.start(queue: queue)
            self.tlsListener = listener

        } catch {
            SecurityLog.tls.error("event=tls.listener_init outcome=failure error=\(error.localizedDescription)")
            completion(false, "tls_listener_init_failed:\(error.localizedDescription)")
        }
    }

    private func redirectClientToTLSListener(port: NWEndpoint.Port) {
        // Send the raw client traffic to our TLS listener
        // The client will perform TLS handshake with our certificate

        // We need to create a bridge: client's raw connection -> our TLS listener
        // This is done by reading from client and forwarding to localhost:port
        isBridging = true
        clientBuffer.removeAll()

        let endpoint = NWEndpoint.hostPort(
            // Use localhost to prefer loopback and support IPv6-only listeners.
            host: NWEndpoint.Host("localhost"),
            port: port
        )

        let bridgeConnection = NWConnection(to: endpoint, using: .tcp)

        bridgeConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                SecurityLog.tls.info(
                    "event=tls.bridge_ready host=\(self?.targetHost ?? "", privacy: .private(mask: .hash)) connection_id=\(self?.connectionId ?? -1)"
                )
                if let pending = self?.pendingClientData, !pending.isEmpty {
                    bridgeConnection.send(content: pending, completion: .contentProcessed { _ in })
                    self?.pendingClientData.removeAll()
                }
                self?.startBridging(from: self?.clientConnection, to: bridgeConnection)
                if let clientConnection = self?.clientConnection {
                    self?.startBridging(from: bridgeConnection, to: clientConnection)
                }
            case let .waiting(error):
                if let self, self.logThrottle.shouldLog(
                    key: "tls.bridge_state.waiting.\(self.targetHost ?? "unknown")",
                    minInterval: 5
                ) {
                    let host = self.targetHost ?? "unknown"
                    SecurityLog.tls.warning(
                        LogEvent.tls("bridge_state")
                            .with("state", value: "waiting")
                            .with("host", value: host, privacy: .hash)
                            .with("error", value: error.localizedDescription)
                    )
                }
            case let .failed(error):
                SecurityLog.tls.error("event=tls.bridge_failed error=\(error.localizedDescription)")
                self?.close(reason: .failure("tls_bridge_failed:\(error.localizedDescription)"))
            case .cancelled:
                self?.sampledDebug(LogEvent.tls("bridge_state").with("state", value: "cancelled"))
                // If the bridge cancels before we complete handshake, treat as failure for fallback.
                if let self, self.isActive, !self.clientHandshakeReady {
                    self.close(reason: .failure("tls_bridge_cancelled"))
                } else {
                    self?.close()
                }
            default:
                break
            }
        }

        bridgeConnection.start(queue: queue)
        self.bridgeConnection = bridgeConnection
    }

    private func startBridging(from source: NWConnection?, to destination: NWConnection) {
        guard let source, isActive else { return }

        // Read from source and write to destination
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.isActive else { return }

            if let error {
                if self.isTransientReceiveError(error) {
                    if self.logThrottle.shouldLog(
                        key: "tls.bridge_read.retry.\(self.connectionId ?? -1)",
                        minInterval: 5
                    ) {
                        SecurityLog.tls.debug(
                            "event=tls.bridge_read outcome=retry host=\(self.targetHost, privacy: .private(mask: .hash)) connection_id=\(self.connectionId ?? -1) error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                    self.queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                        self?.startBridging(from: source, to: destination)
                    }
                    return
                }
                SecurityLog.tls.error("event=tls.bridge_read outcome=failure error=\(error.localizedDescription)")
                self.close(reason: .failure("tls_bridge_read_failed"))
                return
            }

            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }

            if !isComplete, self.isActive {
                self.startBridging(from: source, to: destination)
            }
        }
    }

    // MARK: - TLS Client Setup (for server connection)

    private func createTLSClientConnection(requestedALPNProtocols: [String]) {
        upstreamConnectStartTime = CFAbsoluteTimeGetCurrent()
        lastUpstreamStateLabel = "init"
        SecurityLog.tls.info(
            "event=tls.upstream_connect_begin sni=\(self.targetHost, privacy: .private(mask: .hash)) connect_host=\(self.upstreamHost, privacy: .private(mask: .hash)) port=\(self.upstreamPort) alpn=\(requestedALPNProtocols.joined(separator: ","), privacy: .private(mask: .hash)) connection_id=\(self.connectionId ?? -1)"
        )
        upstreamReady = false

        sampledDebug(
            LogEvent.tls("creating_client_tls_options")
                .with("sni", value: self.targetHost, privacy: .hash)
        )
        let tlsOptions = TLSHandler.createClientTLSOptions(
            for: targetHost,
            alpnProtocols: requestedALPNProtocols,
            onTrustFailure: { [weak self] _, _, errorCode in
                guard let self else { return }
                let host = self.targetHost
                let code = errorCode
                let reason = if code == Int(errSecHostNameMismatch) {
                    "tls_upstream_hostname_mismatch code=\(code)"
                } else {
                    "tls_upstream_trust_failed code=\(code)"
                }
                self.executeOnQueue { [weak self] in
                    guard let self, self.isActive else { return }
                    guard !self.upstreamReady else { return }
                    SecurityLog.tls.warning(
                        LogEvent.tls("upstream_trust_failed")
                            .with("host", value: host, privacy: .hash)
                            .with("reason", value: reason, privacy: .hash)
                    )
                    self.close(reason: .failure(reason))
                }
            }
        )
        let parameters = NWParameters(tls: tlsOptions, tcp: .init())

        guard let port = NWEndpoint.Port(rawValue: self.upstreamPort) else {
            SecurityLog.tls.error("event=tls.upstream_connect outcome=failure reason=invalid_port port=\(self.upstreamPort)")
            close(reason: .failure("tls_client_invalid_port"))
            return
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(self.upstreamHost),
            port: port
        )
        SecurityLog.tls.info(
            "event=tls.upstream_endpoint_created sni=\(self.targetHost, privacy: .private(mask: .hash)) connect_host=\(self.upstreamHost, privacy: .private(mask: .hash)) port=\(self.upstreamPort) connection_id=\(self.connectionId ?? -1)"
        )

        let connection = NWConnection(to: endpoint, using: parameters)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .setup:
                self?.lastUpstreamStateLabel = "setup"
                self?.sampledDebug(LogEvent.tls("upstream_state").with("state", value: "setup"))

            case .preparing:
                self?.lastUpstreamStateLabel = "preparing"
                self?.sampledDebug(LogEvent.tls("upstream_state").with("state", value: "preparing"))

            case .ready:
                guard let self, self.isActive else { return }
                self.lastUpstreamStateLabel = "ready"
                self.cancelUpstreamConnectWatchdog()
                let connectMs: Int? = if let start = self.upstreamConnectStartTime {
                    Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                } else {
                    nil
                }
                SecurityLog.tls.info(
                    "event=tls.upstream_ready host=\(self.targetHost ?? "", privacy: .private(mask: .hash)) connection_id=\(self.connectionId ?? -1) connect_ms=\(connectMs ?? -1)"
                )
                self.serverALPN = TLSHandler.getNegotiatedALPN(from: connection)
                self.sampledDebug(
                    LogEvent.tls("server_alpn")
                        .with("protocol", value: self.serverALPN ?? "none", privacy: .hash)
                )

                // Note: TLS metadata extraction is intentionally skipped here.
                // Rationale: Some iOS versions have been observed to crash Network Extensions when
                // attempting to copy SecTrust or other TLS metadata from `NWConnection`.
                // (This is diagnostics-only; skipping it must not impact connectivity.)

                self.upstreamReady = true
                self.checkHandshakeCompleteAndCancelTimeout()

                // Choose the client-facing ALPN to match the upstream selection.
                // If upstream did not negotiate ALPN, treat it as HTTP/1.1 (safe default).
                let upstream = self.serverALPN ?? "http/1.1"
                let chosenProtocol: String = (upstream == "h2") ? "h2" : "http/1.1"
                let clientALPNOffer = self.clientHelloALPN ?? []

                // If we can't support a protocol alignment (e.g. upstream wants h2 but client didn't offer it),
                // downgrade upstream to HTTP/1.1 and retry once. This prevents a guaranteed mismatch-close.
                if chosenProtocol == "h2", !clientALPNOffer.contains("h2") {
                    SecurityLog.tls.info("event=tls.alpn_align outcome=skipped reason=client_no_h2 action=retry_http1")
                    self.tlsClientConnection?.cancel()
                    self.tlsClientConnection = nil
                    self.createTLSClientConnection(requestedALPNProtocols: ["http/1.1"])
                    return
                }

                self.sampledDebug(
                    LogEvent.tls("proxy_step")
                        .with("step", value: 2)
                        .with("action", value: "create_listener")
                        .with("aligned_alpn", value: chosenProtocol, privacy: .hash)
                )

                // Create TLS server listener to accept client TLS connection (aligned ALPN).
                if !self.didStartTLSListener {
                    self.didStartTLSListener = true
                    self.createTLSServerListener(alpnProtocols: [chosenProtocol]) { [weak self] success, reason in
                        guard let self else { return }
                        guard success else {
                            let message = reason ?? "tls_listener_create_failed"
                            SecurityLog.tls.error("event=tls.listener_create outcome=failure error=\(message)")
                            self.close(reason: .failure(message))
                            return
                        }
                        SecurityLog.tls.info("event=tls.listener_create outcome=success")
                        // Client handshake begins when the listener redirects the bridge.
                    }
                }

                self.reconcileProtocolNegotiation()
                // Start reading decrypted responses from server
                self.readDecryptedFromServer()

            case let .waiting(error):
                self?.lastUpstreamStateLabel = "waiting"
                if let self, self.logThrottle.shouldLog(
                    key: "tls.upstream_state.waiting.\(self.targetHost ?? "unknown")",
                    minInterval: 5
                ) {
                    let host = self.targetHost ?? "unknown"
                    SecurityLog.tls.warning(
                        LogEvent.tls("upstream_state")
                            .with("state", value: "waiting")
                            .with("host", value: host, privacy: .hash)
                            .with("connection_id", value: self.connectionId)
                            .with("error", value: error.localizedDescription)
                    )
                }

            case let .failed(error):
                self?.lastUpstreamStateLabel = "failed"
                SecurityLog.tls.error("event=tls.upstream_connect outcome=failure error=\(error.localizedDescription)")
                self?.close(reason: .failure("tls_client_connection_failed:\(error.localizedDescription)"))

            case .cancelled:
                self?.lastUpstreamStateLabel = "cancelled"
                self?.sampledDebug(LogEvent.tls("upstream_state").with("state", value: "cancelled"))
                // Treat unexpected upstream cancellation as a failure so the caller can fall back.
                guard let self else { return }
                if let current = self.tlsClientConnection, current === connection, self.isActive, !self.upstreamReady {
                    self.close(reason: .failure("tls_client_connection_cancelled"))
                }

            default:
                break
            }
        }

        connection.start(queue: queue)
        self.tlsClientConnection = connection
        scheduleUpstreamConnectWatchdog(after: 1.5)
        sampledDebug(LogEvent.tls("upstream_started").with("action", value: "awaiting_handshake"))
    }

    // MARK: - Plain Client Communication (before TLS)

    /// Buffers enough of the TLS ClientHello (from the original client connection) to parse ALPN.
    ///
    /// We only need the *client offer* here, so we can choose an upstream ALPN request list and
    /// align the client-facing TLS listener accordingly (preventing post-handshake ALPN mismatch).
    ///
    /// Notes:
    /// - The ClientHello can span multiple TLS records (large hellos, many extensions).
    ///   We buffer just enough bytes to reconstruct the full ClientHello handshake message.
    /// - If we can't parse ALPN (no extension / malformed / fragmented), we return nil and fall
    ///   back to HTTP/1.1 alignment.
    private func collectClientHelloALPN(
        maxBytes: Int = 32768,
        completion: @escaping @Sendable ([String]?) -> Void
    ) {
        if didParseClientHelloALPN {
            completion(clientHelloALPN)
            return
        }

        // Fast-path: do we already have a complete record buffered?
        let (complete, offered) = parseClientHelloALPNIfComplete(from: pendingClientData, maxBytes: maxBytes)
        if complete {
            didParseClientHelloALPN = true
            clientHelloALPN = offered
            completion(offered)
            return
        }

        // Need more bytes from the client before we can parse.
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.isActive else { return }

            if let error {
                SecurityLog.tls.error("event=tls.client_hello_read outcome=failure error=\(error.localizedDescription)")
                self.close(reason: .failure("tls_client_hello_read_failed:\(error.localizedDescription)"))
                return
            }

            if let data, !data.isEmpty {
                self.pendingClientData.append(data)
            }

            // If the client closed before we saw a full ClientHello, proceed without ALPN.
            if isComplete {
                TLSLog.debug("event=tls.client_hello_read outcome=complete bytes=\(self.pendingClientData.count)")
                self.didParseClientHelloALPN = true
                self.clientHelloALPN = nil
                completion(nil)
                return
            }

            self.collectClientHelloALPN(maxBytes: maxBytes, completion: completion)
        }
    }

    /// Returns (complete, offeredALPN) for the ClientHello handshake message in `buffer`.
    /// If we don't yet have enough bytes to reconstruct the ClientHello, returns (false, nil).
    /// If the ClientHello is present but ALPN is absent/unparseable, returns (true, nil).
    private func parseClientHelloALPNIfComplete(from buffer: Data, maxBytes: Int) -> (Bool, [String]?) {
        guard !buffer.isEmpty else { return (false, nil) }

        // Avoid unbounded buffering if the client never sends a normal ClientHello.
        if buffer.count >= maxBytes {
            if logThrottle.shouldLog(key: "tls.client_hello_buffer.max_bytes_exceeded", minInterval: 10) {
                SecurityLog.tls.warning("event=tls.client_hello_buffer outcome=failure reason=max_bytes_exceeded bytes=\(buffer.count)")
            }
            return (true, nil)
        }

        // TLS record header: 1 byte content type, 2 bytes version, 2 bytes length.
        guard buffer.count >= 5 else { return (false, nil) }

        let start = buffer.startIndex

        func byte(_ base: Data.Index, _ offset: Int) -> UInt8 {
            buffer[buffer.index(base, offsetBy: offset)]
        }

        // Expect a handshake record (0x16) with TLS major version 0x03.
        // If it doesn't look like TLS, stop waiting and fall back to HTTP/1.1.
        if byte(start, 0) != 0x16 || byte(start, 1) != 0x03 {
            if logThrottle.shouldLog(key: "tls.client_hello_buffer.not_tls_record", minInterval: 10) {
                SecurityLog.tls.warning(
                    "event=tls.client_hello_buffer outcome=failure reason=not_tls_record first_byte=\(byte(start, 0))"
                )
            }
            return (true, nil)
        }

        // Reconstruct the ClientHello handshake message by concatenating handshake-record payloads.
        var cursor = start
        var handshakeBytes = Data()
        handshakeBytes.reserveCapacity(min(buffer.count, maxBytes))

        var expectedHandshakeTotal: Int?

        let tlsVersionMajor = byte(start, 1)
        let tlsVersionMinor = byte(start, 2)

        while true {
            let remaining = buffer.distance(from: cursor, to: buffer.endIndex)
            guard remaining >= 5 else { return (false, nil) }

            // Each record must be a handshake record for the initial ClientHello sequence.
            if byte(cursor, 0) != 0x16 || byte(cursor, 1) != 0x03 {
                // If the first record isn't handshake/TLS, we already returned above.
                // If subsequent records change type, treat as "can't parse further".
                return (true, nil)
            }

            let recordLen = (Int(byte(cursor, 3)) << 8) | Int(byte(cursor, 4))
            let recordTotalLen = 5 + recordLen

            // Sanity-check: avoid buffering pathological records.
            if recordTotalLen > maxBytes {
                TLSLog.debug("event=tls.client_hello_buffer outcome=failure reason=record_too_large bytes=\(recordTotalLen)")
                return (true, nil)
            }

            guard remaining >= recordTotalLen else { return (false, nil) }

            let payloadStart = buffer.index(cursor, offsetBy: 5)
            let payloadEnd = buffer.index(payloadStart, offsetBy: recordLen)
            handshakeBytes.append(contentsOf: buffer[payloadStart ..< payloadEnd])

            if handshakeBytes.count > maxBytes {
                if logThrottle.shouldLog(key: "tls.client_hello_buffer.handshake_too_large", minInterval: 10) {
                    SecurityLog.tls.warning(
                        "event=tls.client_hello_buffer outcome=failure reason=handshake_too_large bytes=\(handshakeBytes.count)"
                    )
                }
                return (true, nil)
            }

            if expectedHandshakeTotal == nil, handshakeBytes.count >= 4 {
                let hsStart = handshakeBytes.startIndex
                let hsType = handshakeBytes[hsStart]
                if hsType != 0x01 {
                    // Not a ClientHello; stop trying to parse ALPN.
                    if logThrottle.shouldLog(key: "tls.client_hello_buffer.not_client_hello", minInterval: 10) {
                        SecurityLog.tls.warning(
                            "event=tls.client_hello_buffer outcome=failure reason=not_client_hello hs_type=\(hsType)"
                        )
                    }
                    return (true, nil)
                }
                let hsLen =
                    (Int(handshakeBytes[hsStart + 1]) << 16)
                        | (Int(handshakeBytes[hsStart + 2]) << 8)
                        | Int(handshakeBytes[hsStart + 3])
                expectedHandshakeTotal = 4 + hsLen
                if let expectedHandshakeTotal, expectedHandshakeTotal > maxBytes {
                    if logThrottle.shouldLog(key: "tls.client_hello_buffer.handshake_too_large_expected", minInterval: 10) {
                        SecurityLog.tls.warning(
                            "event=tls.client_hello_buffer outcome=failure reason=handshake_too_large bytes=\(expectedHandshakeTotal)"
                        )
                    }
                    return (true, nil)
                }
            }

            if let expectedHandshakeTotal, handshakeBytes.count >= expectedHandshakeTotal {
                // We have the full ClientHello handshake message (might include extra bytes after it).
                let hello = Data(handshakeBytes.prefix(expectedHandshakeTotal))

                // TLSHandler can parse a raw ClientHello handshake message directly.
                let offered = TLSHandler.extractALPN(from: hello)
                return (true, offered)
            }

            // Move to next TLS record
            cursor = buffer.index(cursor, offsetBy: recordTotalLen)

            // If we ran out of complete records, request more bytes.
            if cursor >= buffer.endIndex {
                return (false, nil)
            }
        }
    }

    private func readFromClient() {
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.isActive else { return }

            if let error {
                SecurityLog.tls.error("event=tls.client_read outcome=failure error=\(error.localizedDescription)")
                self.close(reason: .failure("tls_client_read_failed"))
                return
            }

            if self.isBridging {
                if isComplete {
                    self.close()
                }
                return
            }

            if let data, !data.isEmpty {
                self.clientBuffer.append(data)
            }

            if !isComplete {
                self.readFromClient()
            } else {
                self.close()
            }
        }
    }

    // MARK: - Decrypted Data Handling

    private func readDecryptedFromClient() {
        guard let connection = tlsServerConnection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.isActive else { return }

            if let error {
                SecurityLog.tls.error("event=tls.decrypt_client_read outcome=failure error=\(error.localizedDescription)")
                self.close(reason: .failure("tls_client_decrypt_read_failed"))
                return
            }

            if let data, !data.isEmpty {
                self.bytesDecryptedFromClient += UInt64(data.count)
                self.clientBuffer.append(data)
                self.handleDecryptedClientData()
            }

            // If a streaming handler (SSE/WebSocket) has taken over, stop our receive loop to avoid
            // concurrent receives on the same NWConnection.
            if self.delegatedStreamHandlerActive || self.pauseClientReads {
                return
            }

            if !isComplete {
                self.readDecryptedFromClient()
            } else {
                self.close()
            }
        }
    }

    private func readDecryptedFromServer() {
        guard let connection = tlsClientConnection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.isActive else { return }

            if let error {
                SecurityLog.tls.error("event=tls.decrypt_server_read outcome=failure error=\(error.localizedDescription)")
                self.close(reason: .failure("tls_server_decrypt_read_failed"))
                return
            }

            if let data, !data.isEmpty {
                self.bytesDecryptedFromServer += UInt64(data.count)
                self.serverBuffer.append(data)
                self.handleDecryptedServerData()
            }

            // If a streaming handler (SSE/WebSocket) has taken over, stop our receive loop to avoid
            // concurrent receives on the same NWConnection.
            if self.delegatedStreamHandlerActive {
                return
            }

            if !isComplete {
                self.readDecryptedFromServer()
            } else {
                if !self.serverBuffer.isEmpty {
                    self.handleDecryptedServerData(forceComplete: true)
                }
                self.close()
            }
        }
    }

    // MARK: - HTTP Parsing from Decrypted Stream

    private func handleDecryptedClientData() {
        sampledDebug(
            LogEvent.tls("handle_client_data")
                .with("host", value: self.targetHost, privacy: .hash)
                .with("buffer_size", value: self.clientBuffer.count)
                .with("protocol_negotiated", value: self.protocolNegotiated)
                .with("is_http2", value: self.isHTTP2)
        )

        // Detect protocol if not yet negotiated
        if !protocolNegotiated {
            if isHTTP2, waitingForHTTP2Preface {
                sampledDebug(
                    LogEvent.tls("waiting_http2_preface")
                        .with("host", value: self.targetHost, privacy: .hash)
                        .with("buffer_size", value: self.clientBuffer.count)
                )
                if HTTP2Preface.isHTTP2Preface(clientBuffer) {
                    sampledDebug(
                        LogEvent.tls("http2_preface_found")
                            .with("host", value: self.targetHost, privacy: .hash)
                    )
                    forwardHTTP2ToServer(HTTP2Preface.clientPreface)
                    Task { await http2Client?.receivedPreface() }
                    clientBuffer.removeFirst(HTTP2Preface.length)
                    waitingForHTTP2Preface = false
                    clientPrefaceConsumed = true
                    protocolNegotiated = true
                } else if clientBuffer.count >= HTTP2Preface.length {
                    SecurityLog.tls.error(
                        LogEvent.tls("http2_preface")
                            .failure()
                            .with("host", value: self.targetHost, privacy: .hash)
                            .with("buffer_size", value: self.clientBuffer.count)
                            .with("action", value: "close")
                    )
                    close(reason: .failure("http2_preface_missing"))
                    return
                } else {
                    sampledDebug(
                        LogEvent.tls("http2_preface_incomplete")
                            .with("host", value: self.targetHost, privacy: .hash)
                            .with("have", value: self.clientBuffer.count)
                            .with("need", value: HTTP2Preface.length)
                    )
                    return
                }
            } else {
                detectProtocol()
            }

            if !protocolNegotiated {
                sampledDebug(
                    LogEvent.tls("protocol_not_yet_negotiated")
                        .with("host", value: self.targetHost, privacy: .hash)
                        .with("buffer_size", value: self.clientBuffer.count)
                )
                return // Need more data for detection
            }
        }

        // Route to appropriate protocol handler
        if isHTTP2 {
            sampledDebug(
                LogEvent.tls("route_to_http2_handler")
                    .with("host", value: self.targetHost, privacy: .hash)
            )
            handleHTTP2ClientData()
            return
        }

        sampledDebug(
            LogEvent.tls("route_to_http1_handler")
                .with("host", value: self.targetHost, privacy: .hash)
        )
        handleHTTP1ClientData()
    }

    private func handleDecryptedServerData(forceComplete: Bool = false) {
        sampledDebug(
            LogEvent.tls("handle_server_data")
                .with("host", value: self.targetHost, privacy: .hash)
                .with("buffer_size", value: self.serverBuffer.count)
                .with("is_http2", value: self.isHTTP2)
                .with("force_complete", value: forceComplete)
        )

        // Route to appropriate protocol handler
        if isHTTP2 {
            handleHTTP2ServerData()
            return
        }
        handleHTTP1ServerData(forceComplete: forceComplete)
    }

    private func handleHTTP1ClientData() {
        let headerSeparator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

        // When a streaming handler takes over, or while an interception task is pending,
        // pause HTTP parsing to preserve ordering and avoid buffering unbounded requests.
        if delegatedStreamHandlerActive || http1InterceptionInFlight || http1ResponseInterceptionInFlight {
            return
        }
        // Avoid HTTP/1.1 pipelining for now; keep strict request/response ordering.
        if !pendingHTTP1Requests.isEmpty {
            return
        }

        while true {
            if pendingHTTP1Request == nil {
                guard let headerEndRange = clientBuffer.range(of: headerSeparator) else {
                    if clientBuffer.count > 64 * 1024 {
                        SecurityLog.tls.error("event=tls.http1_request_headers outcome=failure reason=size_limit_exceeded bytes=\(self.clientBuffer.count)")
                        close(reason: .failure("http1_request_headers_exceeded"))
                    }
                    return
                }

                let headerData = clientBuffer[..<headerEndRange.lowerBound]
                let bodyStartIndex = headerEndRange.upperBound
                let bodyStartOffset = clientBuffer.distance(from: clientBuffer.startIndex, to: bodyStartIndex)

                guard let (requestLine, headers) = parseHTTPHeaders(headerData) else {
                    SecurityLog.tls.error("event=tls.http_parse outcome=failure type=request_headers")
                    close()
                    return
                }

                let metadata = parseHeaderMetadata(headers)
                var state = HTTP1MessageState(
                    startLine: requestLine,
                    headers: headers,
                    metadata: metadata,
                    timestamp: Date(),
                    remainingBodyBytes: metadata.contentLength
                )

                clientBuffer.removeFirst(bodyStartOffset)

                if metadata.contentLength == nil, !metadata.isChunked {
                    finalizeHTTP1Request(state, effectiveBody: Data())
                    pendingHTTP1Request = nil
                    return
                }

                pendingHTTP1Request = state
            }

            guard var state = pendingHTTP1Request else { return }

            if state.metadata.isChunked {
                let result = state.chunkedParser.consume(
                    buffer: clientBuffer,
                    maxCaptureBytes: maxRequestSize,
                    capturedBody: &state.bodyData,
                    bodyTruncated: &state.bodyTruncated
                )

                if state.bodyTruncated {
                    SecurityLog.tls.error("event=tls.http1_request_body outcome=failure reason=size_limit_exceeded limit=\(self.maxRequestSize)")
                    close(reason: .failure("http1_request_body_too_large"))
                    return
                }

                if result.parseError {
                    SecurityLog.tls.error("event=tls.http_parse outcome=failure type=request_chunked")
                    close()
                    return
                }

                if result.consumed == 0 {
                    pendingHTTP1Request = state
                    return
                }

                clientBuffer.removeFirst(result.consumed)

                if result.complete {
                    finalizeHTTP1Request(state, effectiveBody: state.bodyData)
                    pendingHTTP1Request = nil
                    return
                }

                pendingHTTP1Request = state
                continue
            }

            if let remaining = state.remainingBodyBytes {
                if remaining == 0 {
                    finalizeHTTP1Request(state, effectiveBody: state.bodyData)
                    pendingHTTP1Request = nil
                    return
                }

                guard !clientBuffer.isEmpty else {
                    pendingHTTP1Request = state
                    return
                }

                let available = min(clientBuffer.count, remaining)
                let chunk = Data(clientBuffer.prefix(available))
                // Buffer request body for interception/forwarding (we rebuild request with Content-Length).
                appendCapturedBody(chunk, to: &state, maxBytes: maxRequestSize)
                if state.bodyTruncated {
                    SecurityLog.tls.error("event=tls.http1_request_body outcome=failure reason=size_limit_exceeded limit=\(self.maxRequestSize)")
                    close(reason: .failure("http1_request_body_too_large"))
                    return
                }
                clientBuffer.removeFirst(available)
                state.remainingBodyBytes = remaining - available

                if state.remainingBodyBytes == 0 {
                    finalizeHTTP1Request(state, effectiveBody: state.bodyData)
                    pendingHTTP1Request = nil
                    return
                }

                pendingHTTP1Request = state
                continue
            }

            pendingHTTP1Request = state
            return
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func handleHTTP1ServerData(forceComplete: Bool) {
        let headerSeparator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        let previewLimit = min(maxCapturedBodyBytes, BodyStorage.inlineThreshold)

        if delegatedStreamHandlerActive {
            return
        }
        if http1ResponseInterceptionInFlight {
            return
        }

        func shouldBufferResponse() -> Bool {
            guard !http1ResponseForceStreaming else { return false }
            return pendingHTTP1Requests.first?.responsePipeline == .bufferAndIntercept
        }

        while true {
            if pendingHTTP1Response == nil {
                guard let headerEndRange = serverBuffer.range(of: headerSeparator) else {
                    if serverBuffer.count > 64 * 1024 {
                        SecurityLog.tls.error("event=tls.http1_response_headers outcome=failure reason=size_limit_exceeded bytes=\(self.serverBuffer.count)")
                        close(reason: .failure("http1_response_headers_exceeded"))
                    }
                    return
                }

                let headerData = serverBuffer[..<headerEndRange.lowerBound]
                let bodyStartIndex = headerEndRange.upperBound
                let bodyStartOffset = serverBuffer.distance(from: serverBuffer.startIndex, to: bodyStartIndex)

                guard let (statusLine, headers) = parseHTTPHeaders(headerData) else {
                    SecurityLog.tls.error("event=tls.http_parse outcome=failure type=response_headers")
                    close()
                    return
                }

                let metadata = parseHeaderMetadata(headers)
                let statusCode = parseStatusCode(from: statusLine)
                let rawHeaderData = Data(serverBuffer.prefix(bodyStartOffset))
                var state = HTTP1MessageState(
                    startLine: statusLine,
                    headers: headers,
                    metadata: metadata,
                    timestamp: Date(),
                    remainingBodyBytes: metadata.contentLength
                )

                let code = statusCode ?? 0
                let isInformational = (100 ..< 200).contains(code)

                var buffering = shouldBufferResponse()
                if isInformational {
                    // Never buffer informational responses; clients may be waiting for them.
                    buffering = false
                }
                currentHTTP1ResponseBuffering = buffering

                if buffering {
                    bufferedHTTP1ResponseRaw.removeAll(keepingCapacity: true)
                    bufferedHTTP1ResponseRaw.append(rawHeaderData)
                } else {
                    forwardHTTP1ToClient(rawHeaderData)
                }
                serverBuffer.removeFirst(bodyStartOffset)

                // Streaming protocols: SSE and WebSocket. Hand off as soon as headers are available.
                if let request = pendingHTTP1Requests.first {
                    // SSE detection (Content-Type: text/event-stream)
                    if isSSEResponse(headers) {
                        _ = pendingHTTP1Requests.removeFirst()
                        let initialBodyData = serverBuffer
                        var initial = Data()
                        if buffering { initial.append(bufferedHTTP1ResponseRaw) }
                        initial.append(serverBuffer)
                        let statusMessage: String? = {
                            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                            return (parts.count >= 3) ? String(parts[2]) : nil
                        }()
                        startSSEStream(
                            request: request,
                            responseHeaders: headers,
                            statusCode: statusCode,
                            statusMessage: statusMessage,
                            initialData: initial,
                            initialBodyData: initialBodyData
                        )
                        return
                    }

                    // WebSocket upgrade successful (101 Switching Protocols)
                    let responseHeadersDict = headers.reduce(into: [String: String]()) { dict, header in
                        dict[header.key] = header.value
                    }
                    if request.isWebSocketUpgrade, code == 101, isWebSocketUpgrade(responseHeadersDict) {
                        _ = pendingHTTP1Requests.removeFirst()
                        let initialBodyData = serverBuffer
                        var initial = Data()
                        if buffering { initial.append(bufferedHTTP1ResponseRaw) }
                        initial.append(serverBuffer)
                        startWebSocketStream(
                            request: request,
                            responseHeaders: headers,
                            initialData: initial,
                            initialBodyData: initialBodyData
                        )
                        return
                    }
                }

                if state.remainingBodyBytes == nil, !metadata.isChunked,
                   let statusCode, (100 ..< 200).contains(statusCode) || statusCode == 204 || statusCode == 304 {
                    state.remainingBodyBytes = 0
                }

                pendingHTTP1Response = state
            }

            guard var state = pendingHTTP1Response else { return }

            if state.metadata.isChunked {
                let result = state.chunkedParser.consume(
                    buffer: serverBuffer,
                    maxCaptureBytes: previewLimit,
                    capturedBody: &state.bodyData,
                    bodyTruncated: &state.bodyTruncated
                )

                if result.parseError {
                    SecurityLog.tls.error("event=tls.http_parse outcome=failure type=response_chunked")
                    close()
                    return
                }

                if result.consumed == 0 {
                    pendingHTTP1Response = state
                    return
                }

                let rawBody = Data(serverBuffer.prefix(result.consumed))
                appendToHTTP1ResponseBodyCapture(rawBody, isChunked: true)
                if currentHTTP1ResponseBuffering {
                    bufferedHTTP1ResponseRaw.append(rawBody)
                    // If response grows beyond our buffer limit, flush what we have and switch to streaming passthrough.
                    if bufferedHTTP1ResponseRaw.count > maxResponseBufferSize || state.bodyTruncated {
                        forwardHTTP1ToClient(bufferedHTTP1ResponseRaw)
                        bufferedHTTP1ResponseRaw.removeAll()
                        http1ResponseForceStreaming = true
                        currentHTTP1ResponseBuffering = false
                    }
                } else {
                    forwardHTTP1ToClient(rawBody)
                }
                serverBuffer.removeFirst(result.consumed)

                if result.complete {
                    finalizeHTTP1ResponseBodyCapture()
                    finalizeHTTP1Response(state, effectiveBody: state.bodyData)
                    pendingHTTP1Response = nil
                    if http1ResponseInterceptionInFlight {
                        return
                    }
                    continue
                }

                pendingHTTP1Response = state
                continue
            }

            if let remaining = state.remainingBodyBytes {
                if remaining == 0 {
                    finalizeHTTP1ResponseBodyCapture()
                    finalizeHTTP1Response(state, effectiveBody: state.bodyData)
                    pendingHTTP1Response = nil
                    if http1ResponseInterceptionInFlight {
                        return
                    }
                    continue
                }

                guard !serverBuffer.isEmpty else {
                    pendingHTTP1Response = state
                    return
                }

                let available = min(serverBuffer.count, remaining)
                let chunk = Data(serverBuffer.prefix(available))
                appendToHTTP1ResponseBodyCapture(chunk, isChunked: false)
                if currentHTTP1ResponseBuffering {
                    bufferedHTTP1ResponseRaw.append(chunk)
                } else {
                    forwardHTTP1ToClient(chunk)
                }
                appendCapturedBody(chunk, to: &state, maxBytes: previewLimit)
                if currentHTTP1ResponseBuffering, bufferedHTTP1ResponseRaw.count > maxResponseBufferSize || state.bodyTruncated {
                    forwardHTTP1ToClient(bufferedHTTP1ResponseRaw)
                    bufferedHTTP1ResponseRaw.removeAll()
                    http1ResponseForceStreaming = true
                    currentHTTP1ResponseBuffering = false
                }
                serverBuffer.removeFirst(available)
                state.remainingBodyBytes = remaining - available

                if state.remainingBodyBytes == 0 {
                    finalizeHTTP1ResponseBodyCapture()
                    finalizeHTTP1Response(state, effectiveBody: state.bodyData)
                    pendingHTTP1Response = nil
                    if http1ResponseInterceptionInFlight {
                        return
                    }
                    continue
                }

                pendingHTTP1Response = state
                continue
            }

            if serverBuffer.isEmpty {
                if forceComplete {
                    finalizeHTTP1ResponseBodyCapture()
                    finalizeHTTP1Response(state, effectiveBody: state.bodyData)
                    pendingHTTP1Response = nil
                    if http1ResponseInterceptionInFlight {
                        return
                    }
                } else {
                    pendingHTTP1Response = state
                }
                return
            }

            let chunk = Data(serverBuffer)
            appendToHTTP1ResponseBodyCapture(chunk, isChunked: false)
            if currentHTTP1ResponseBuffering {
                bufferedHTTP1ResponseRaw.append(chunk)
            } else {
                forwardHTTP1ToClient(chunk)
            }
            appendCapturedBody(chunk, to: &state, maxBytes: previewLimit)
            if currentHTTP1ResponseBuffering, bufferedHTTP1ResponseRaw.count > maxResponseBufferSize || state.bodyTruncated {
                forwardHTTP1ToClient(bufferedHTTP1ResponseRaw)
                bufferedHTTP1ResponseRaw.removeAll()
                http1ResponseForceStreaming = true
                currentHTTP1ResponseBuffering = false
            }
            serverBuffer.removeAll()

            if forceComplete {
                finalizeHTTP1ResponseBodyCapture()
                finalizeHTTP1Response(state, effectiveBody: state.bodyData)
                pendingHTTP1Response = nil
                if http1ResponseInterceptionInFlight {
                    return
                }
            } else {
                pendingHTTP1Response = state
            }
            return
        }
    }

    private func appendCapturedBody(_ data: Data, to state: inout HTTP1MessageState, maxBytes: Int) {
        guard maxBytes > 0 else { return }
        if state.bodyData.count >= maxBytes {
            state.bodyTruncated = true
            return
        }
        let remaining = maxBytes - state.bodyData.count
        if data.count > remaining {
            state.bodyData.append(data.prefix(remaining))
            state.bodyTruncated = true
        } else {
            state.bodyData.append(data)
        }
    }

    // MARK: - HTTP/1.1 body spooling (response)

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
            let trailerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

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
                        if let trailerEnd = pending.range(of: trailerTerminator, options: [], in: index ..< pending.count) {
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

    private func ensureActiveHTTP1ResponseBodyCapture(isChunked: Bool) {
        guard captureBodies, maxCapturedBodyBytes > 0 else { return }
        guard activeHTTP1ResponseBodyCapture == nil else { return }
        guard let containerURL = bodyContainerURLForCapture() else { return }

        let bodiesDir = containerURL.appendingPathComponent("Bodies", isDirectory: true)
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)

        let fileURL = bodiesDir.appendingPathComponent(UUID().uuidString + ".bin")
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }

        let decoder: ChunkedTransferDecoder? = isChunked ? ChunkedTransferDecoder() : nil
        activeHTTP1ResponseBodyCapture = ActiveBodyCapture(
            url: fileURL,
            handle: handle,
            bytesWritten: 0,
            truncated: false,
            isChunked: isChunked,
            chunkedDecoder: decoder
        )
    }

    private func appendToHTTP1ResponseBodyCapture(_ data: Data, isChunked: Bool) {
        guard captureBodies, maxCapturedBodyBytes > 0, !data.isEmpty else { return }

        ensureActiveHTTP1ResponseBodyCapture(isChunked: isChunked)
        guard var capture = activeHTTP1ResponseBodyCapture else { return }

        // Safety: If the capture already hit its cap, do not write more.
        let remainingBytes = max(0, maxCapturedBodyBytes - capture.bytesWritten)
        if remainingBytes == 0 {
            capture.truncated = true
            activeHTTP1ResponseBodyCapture = capture
            return
        }

        if isChunked {
            var decoder = capture.chunkedDecoder ?? ChunkedTransferDecoder()
            let (_, parseError) = decoder.feed(data, onBodyChunk: { bodyChunk in
                guard !capture.truncated else { return }
                let remaining = max(0, maxCapturedBodyBytes - capture.bytesWritten)
                guard remaining > 0 else {
                    capture.truncated = true
                    return
                }

                let toWrite = bodyChunk.count <= remaining ? bodyChunk : bodyChunk.prefix(remaining)
                do {
                    try capture.handle.write(contentsOf: toWrite)
                    capture.bytesWritten += toWrite.count
                    if bodyChunk.count > remaining {
                        capture.truncated = true
                    }
                } catch {
                    SecurityLog.tls.error(
                        "event=tls.body_spool_write outcome=failure error=\(error.localizedDescription, privacy: .public)"
                    )
                    capture.truncated = true
                }
            })

            if parseError {
                capture.truncated = true
            }

            capture.chunkedDecoder = decoder
            activeHTTP1ResponseBodyCapture = capture
            return
        }

        let toWrite = data.count <= remainingBytes ? data : data.prefix(remainingBytes)
        do {
            try capture.handle.write(contentsOf: toWrite)
            capture.bytesWritten += toWrite.count
            if data.count > remainingBytes {
                capture.truncated = true
            }
        } catch {
            SecurityLog.tls.error(
                "event=tls.body_spool_write outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            capture.truncated = true
        }

        activeHTTP1ResponseBodyCapture = capture
    }

    private func finalizeHTTP1ResponseBodyCapture() {
        guard let capture = activeHTTP1ResponseBodyCapture else { return }
        do {
            try capture.handle.close()
        } catch {
            // Best-effort close.
        }
        activeHTTP1ResponseBodyCapture = nil

        if capture.bytesWritten <= 0 {
            try? FileManager.default.removeItem(at: capture.url)
            completedHTTP1ResponseBodyCapture = nil
            return
        }

        completedHTTP1ResponseBodyCapture = CompletedBodyCapture(
            url: capture.url,
            bytesWritten: capture.bytesWritten,
            truncated: capture.truncated,
            isChunked: capture.isChunked
        )
    }

    private func takeCompletedHTTP1ResponseBodyCapture() -> CompletedBodyCapture? {
        defer { completedHTTP1ResponseBodyCapture = nil }
        return completedHTTP1ResponseBodyCapture
    }

    private func cleanupActiveHTTP1ResponseBodyCapture() {
        guard let capture = activeHTTP1ResponseBodyCapture else { return }
        do {
            try capture.handle.close()
        } catch {
            // Best-effort close.
        }
        activeHTTP1ResponseBodyCapture = nil
        completedHTTP1ResponseBodyCapture = nil
        try? FileManager.default.removeItem(at: capture.url)
    }

    private func forwardHTTP1ToServer(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let connection = tlsClientConnection else {
            if logThrottle.shouldLog(key: "tls.forward_server_skipped.http1.\(connectionId ?? -1)", minInterval: 5) {
                SecurityLog.tls.warning(
                    "event=tls.forward_server_skipped outcome=skipped proto=http1 reason=no_tls_client_connection host=\(self.targetHost, privacy: .private(mask: .hash)) connection_id=\(self.connectionId ?? -1) bytes=\(data.count)"
                )
            }
            return
        }
        sendToServer(data, connection: connection, logEvent: "tls.forward_request")
    }

    private func forwardHTTP1ToClient(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let connection = tlsServerConnection else {
            if logThrottle.shouldLog(key: "tls.forward_client_skipped.http1.\(connectionId ?? -1)", minInterval: 5) {
                SecurityLog.tls.warning(
                    "event=tls.forward_client_skipped outcome=skipped proto=http1 reason=no_tls_server_connection host=\(self.targetHost, privacy: .private(mask: .hash)) connection_id=\(self.connectionId ?? -1) bytes=\(data.count)"
                )
            }
            return
        }
        sendToClient(data, connection: connection, logEvent: "tls.forward_response")
    }

    private func isWebSocketUpgrade(_ headers: [String: String]) -> Bool {
        let upgrade = headers.first(where: { $0.key.lowercased() == "upgrade" })?.value.lowercased() ?? ""
        let connection = headers.first(where: { $0.key.lowercased() == "connection" })?.value.lowercased() ?? ""
        return upgrade.contains("websocket") && connection.contains("upgrade")
    }

    private func isSSEResponse(_ headers: [TraceHTTPHeader]) -> Bool {
        let contentType = headers.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased() ?? ""
        return contentType.contains("text/event-stream")
    }

    private func startSSEStream(
        request: CapturedHTTP1Request,
        responseHeaders: [TraceHTTPHeader],
        statusCode: Int?,
        statusMessage: String?,
        initialData: Data,
        initialBodyData: Data
    ) {
        guard let clientTLS = tlsServerConnection else {
            close(reason: .failure("sse_no_client_tls_connection"))
            return
        }
        guard let serverTLS = tlsClientConnection else {
            close(reason: .failure("sse_no_server_tls_connection"))
            return
        }

        delegatedStreamHandlerActive = true

        // Forward already-buffered response bytes to client (headers + any initial body).
        if !initialData.isEmpty {
            forwardHTTP1ToClient(initialData)
        }

        let requestHeaders = request.headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
        let responseHeadersDict = responseHeaders.reduce(into: [String: String]()) { dict, header in
            dict[header.key] = header.value
        }
        let requestCharset = BodyStorage.extractCharset(from: request.headers)
        let requestContentEncoding = request.headers.first(where: { $0.key.lowercased() == "content-encoding" })?.value
        let responseCharset = BodyStorage.extractCharset(from: responseHeadersDict)
        let handler = SSEHandler(
            clientConnection: clientTLS,
            serverConnection: serverTLS,
            url: request.url,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders
        )
        var capturePublishThrottle = SSECapturePublishThrottle()
        handler.start(onUpdate: { [weak self] connection in
            guard let self else { return }
            guard capturePublishThrottle.shouldPublish(connection: connection) else { return }
            self.executeOnQueue { [weak self] in
                guard let self else { return }

                let requestBodyStorage: BodyStorage = {
                    guard self.captureBodies, self.maxCapturedBodyBytes > 0 else { return .empty }
                    if let data = request.bodyData, !data.isEmpty {
                        return BodyStorage.from(
                            data: Data(data.prefix(self.maxCapturedBodyBytes)),
                            charset: requestCharset,
                            maxSize: self.maxCapturedBodyBytes,
                            contentEncoding: requestContentEncoding
                        )
                    }
                    if let body = request.body, !body.isEmpty {
                        return BodyStorage.from(
                            string: body,
                            charset: requestCharset,
                            maxSize: self.maxCapturedBodyBytes
                        )
                    }
                    return .empty
                }()

                let responseBodyStorage: BodyStorage = {
                    guard self.captureBodies, self.maxCapturedBodyBytes > 0 else { return .empty }
                    let payload = SSEPayloadSerializer.serialize(events: connection.events)
                    guard !payload.isEmpty else { return .empty }
                    return BodyStorage.from(
                        string: payload,
                        charset: responseCharset,
                        maxSize: self.maxCapturedBodyBytes
                    )
                }()

                var networkRequest = NetworkRequest(
                    id: request.id,
                    url: request.url,
                    method: HTTPMethod(rawValue: request.method) ?? .get,
                    statusCode: statusCode,
                    statusMessage: statusMessage,
                    timestamp: request.startTime,
                    duration: Date().timeIntervalSince(request.startTime),
                    requestHeaders: requestHeaders,
                    responseHeaders: responseHeaders,
                    requestBody: requestBodyStorage,
                    responseBody: responseBodyStorage,
                    protocolVersion: .http11,
                    tlsInfo: self.upstreamTLSInfo
                )
                networkRequest.wasRewritten = request.wasRewritten
                networkRequest.isMocked = request.isMocked
                networkRequest.isReplayed = request.isReplayed
                networkRequest.appliedScriptName = request.appliedScriptName
                networkRequest.hitBreakpoint = request.hitBreakpoint
                networkRequest.retryAttempts = request.retryAttempts
                networkRequest.extractHTTPFields()
                NetworkThrottlingController.shared.applyMetadata(to: &networkRequest)

                DispatchQueue.main.async { [weak self] in
                    self?.onRequestCaptured?(networkRequest)
                }
            }
        }, initialBodyData: initialBodyData)
        sseHandler = handler

        // Clear local HTTP state; SSEHandler owns the stream now.
        pendingHTTP1Request = nil
        pendingHTTP1Response = nil
        clientBuffer.removeAll()
        serverBuffer.removeAll()
        bufferedHTTP1ResponseRaw.removeAll()
    }

    private func startWebSocketStream(
        request: CapturedHTTP1Request,
        responseHeaders: [TraceHTTPHeader],
        initialData: Data,
        initialBodyData: Data
    ) {
        guard let clientTLS = tlsServerConnection else {
            close(reason: .failure("ws_no_client_tls_connection"))
            return
        }
        guard let serverTLS = tlsClientConnection else {
            close(reason: .failure("ws_no_server_tls_connection"))
            return
        }

        delegatedStreamHandlerActive = true

        if !initialData.isEmpty {
            forwardHTTP1ToClient(initialData)
        }

        let requestHeaders = request.headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
        let handler = WebSocketHandler(
            clientConnection: clientTLS,
            serverConnection: serverTLS,
            url: request.url,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders
        )
        handler.start(onUpdate: { _ in }, initialServerData: initialBodyData)
        webSocketHandler = handler

        pendingHTTP1Request = nil
        pendingHTTP1Response = nil
        clientBuffer.removeAll()
        serverBuffer.removeAll()
        bufferedHTTP1ResponseRaw.removeAll()
    }

    private struct ForwardHTTP1Data: Sendable {
        let absoluteURL: String
        let forwardHeaders: [String: String]
        let data: Data
    }

    private struct HTTP1InterceptionContext {
        let flowId: UUID
        let requestStartTime: Date
        let originalAbsoluteURL: String
        let originalMethod: String
        let originalHeaders: [String: String]
        let originalHeaderList: [TraceHTTPHeader]
        let originalBody: Data
        let responsePipeline: ResponsePipeline
        let isWebSocketUpgrade: Bool
    }

    private func buildHTTP1Data(requestLine: String, headers: [TraceHTTPHeader], body: Data) -> Data {
        var headerString = requestLine + "\r\n"
        for header in headers {
            headerString += "\(header.key): \(header.value)\r\n"
        }
        headerString += "\r\n"
        var data = Data()
        data.append(contentsOf: headerString.utf8)
        data.append(body)
        return data
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func removeHeader(_ name: String, from headers: inout [String: String]) {
        if let key = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            headers.removeValue(forKey: key)
        }
    }

    private func normalizeSSERequestEncodings(method: String, headers: inout [String: String]) {
        guard method.caseInsensitiveCompare("GET") == .orderedSame else { return }
        guard let accept = headerValue("accept", in: headers)?.lowercased(),
              accept.contains("text/event-stream")
        else {
            return
        }

        // Rationale: Compressed SSE payloads are often not incrementally parseable in the proxy.
        // Request identity encoding so event parsing remains transparent and reliable.
        removeHeader("accept-encoding", from: &headers)
        headers["Accept-Encoding"] = "identity"
    }

    private func buildForwardHTTP1Data(
        method: String,
        absoluteURL: String,
        originalHeaders: [String: String],
        body: Data
    ) -> ForwardHTTP1Data? {
        guard let components = URLComponents(string: absoluteURL) else { return nil }
        let scheme = (components.scheme ?? "https").lowercased()
        guard scheme == "https" else { return nil }

        let destHost = components.host ?? targetHost
        let destPort = UInt16(components.port ?? Int(targetPort))

        // HTTPS MITM currently supports only same-origin rewrites inside the existing CONNECT tunnel.
        guard destHost.lowercased() == targetHost.lowercased(), destPort == targetPort else {
            SecurityLog.tls.info(
                "event=tls.http1_rewrite_cross_origin outcome=skipped from=\(self.targetHost, privacy: .private(mask: .hash)):\(self.targetPort) to=\(destHost, privacy: .private(mask: .hash)):\(destPort)"
            )
            return nil
        }

        // IMPORTANT: Preserve percent-encoding when reconstructing the request-target.
        // Using `components.query` (decoded) can introduce literal spaces into the HTTP/1.1
        // request line (e.g. `%20` -> `" "`), which yields an invalid request line and can
        // cause upstream servers (e.g. nginx) to return 400 immediately.
        let originTarget: String = {
            var path = components.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let query = components.percentEncodedQuery, !query.isEmpty {
                path += "?\(query)"
            }
            return path
        }()

        // Remove proxy-only headers and normalize content framing.
        var headers = originalHeaders
        headers = headers.filter { key, _ in
            let lower = key.lowercased()
            if lower == "proxy-connection" { return false }
            if lower == "proxy-authorization" { return false }
            if lower == "host" { return false }
            if lower == "content-length" { return false }
            if lower == "transfer-encoding" { return false }
            return true
        }

        let hostNeedsBrackets = destHost.contains(":") && !destHost.hasPrefix("[") && !destHost.hasSuffix("]")
        let hostPart = hostNeedsBrackets ? "[\(destHost)]" : destHost
        let hostHeaderValue: String = (destPort == 443) ? hostPart : "\(hostPart):\(destPort)"
        headers["Host"] = hostHeaderValue
        if !body.isEmpty {
            headers["Content-Length"] = "\(body.count)"
        }
        normalizeSSERequestEncodings(method: method, headers: &headers)

        let forwardHeaders = headers
        let headerList = headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
        let requestLine = "\(method) \(originTarget) HTTP/1.1"
        let data = buildHTTP1Data(requestLine: requestLine, headers: headerList, body: body)

        return ForwardHTTP1Data(
            absoluteURL: absoluteURL,
            forwardHeaders: forwardHeaders,
            data: data
        )
    }

    private func applyHTTP1InterceptionResult(
        _ result: InterceptionResult,
        context: HTTP1InterceptionContext
    ) {
        defer { http1InterceptionInFlight = false }

        switch result {
        case .blocked:
            let response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
            if let responseData = response.data(using: .utf8) {
                forwardHTTP1ToClient(responseData)
            }

            let charset = BodyStorage.extractCharset(from: context.originalHeaders)
            let requestContentEncoding = context.originalHeaders.first { $0.key.lowercased() == "content-encoding" }?.value
            var blockedRequest = NetworkRequest(
                id: context.flowId,
                url: context.originalAbsoluteURL,
                method: HTTPMethod(rawValue: context.originalMethod) ?? .get,
                statusCode: 403,
                statusMessage: "Blocked",
                timestamp: context.requestStartTime,
                duration: Date().timeIntervalSince(context.requestStartTime),
                requestHeaders: context.originalHeaderList,
                responseHeaders: [TraceHTTPHeader(key: "X-Trace-Note", value: "Blocked by rule")],
                requestBody: (self.captureBodies && self.maxCapturedBodyBytes > 0 && !context.originalBody.isEmpty)
                    ? BodyStorage.from(
                        data: Data(context.originalBody.prefix(self.maxCapturedBodyBytes)),
                        charset: charset,
                        maxSize: self.maxCapturedBodyBytes,
                        contentEncoding: requestContentEncoding
                    )
                    : .empty,
                responseBody: .empty,
                protocolVersion: .http11,
                tlsInfo: upstreamTLSInfo
            )
            blockedRequest.wasBlocked = true
            blockedRequest.extractHTTPFields()
            NetworkThrottlingController.shared.applyMetadata(to: &blockedRequest)
            DispatchQueue.main.async { [weak self] in
                self?.onRequestCaptured?(blockedRequest)
            }

            // Continue parsing buffered client data (if any).
            handleHTTP1ClientData()
            if context.isWebSocketUpgrade {
                pauseClientReads = false
                readDecryptedFromClient()
            }

        case let .failed(failure):
            close(reason: .failure("intercept_failed_\(failure.rawValue)"))

        case let .mocked(mockRequest):
            let statusCode = mockRequest.statusCode ?? 200
            var responseString = "HTTP/1.1 \(statusCode)"
            if let statusMessage = mockRequest.statusMessage {
                responseString += " \(statusMessage)"
            }
            responseString += "\r\n"

            for header in mockRequest.responseHeaders {
                responseString += "\(header.key): \(header.value)\r\n"
            }

            let responseBodyData =
                mockRequest.responseBody.getData()
                    ?? mockRequest.responseBody.getString()?.data(using: .utf8)
                    ?? Data()
            responseString += "Content-Length: \(responseBodyData.count)\r\n"
            responseString += "\r\n"

            guard let headerData = responseString.data(using: .utf8) else {
                close()
                return
            }

            var fullResponse = Data()
            fullResponse.append(headerData)
            fullResponse.append(responseBodyData)
            forwardHTTP1ToClient(fullResponse)

            var captured = mockRequest
            captured.tlsInfo = upstreamTLSInfo
            DispatchQueue.main.async { [weak self] in
                self?.onRequestCaptured?(captured)
            }

            // Continue parsing buffered client data (if any).
            handleHTTP1ClientData()
            if context.isWebSocketUpgrade {
                pauseClientReads = false
                readDecryptedFromClient()
            }

        case let .modified(modifiedRequest):
            let method = modifiedRequest.method.rawValue
            let body = modifiedRequest.requestBody.getData() ?? Data()
            let headersDict = modifiedRequest.requestHeaders.reduce(into: [String: String]()) { dict, header in
                dict[header.key] = header.value
            }

            guard let forward = buildForwardHTTP1Data(method: method, absoluteURL: modifiedRequest.url, originalHeaders: headersDict, body: body) else {
                // Best-effort: return an HTTP redirect so the client can reconnect to the new host.
                var redirect = "HTTP/1.1 307 Temporary Redirect\r\n"
                redirect += "Location: \(modifiedRequest.url)\r\n"
                redirect += "Content-Length: 0\r\n\r\n"
                if let redirectData = redirect.data(using: .utf8) {
                    forwardHTTP1ToClient(redirectData)
                }

                var redirected = NetworkRequest(
                    id: context.flowId,
                    url: context.originalAbsoluteURL,
                    method: HTTPMethod(rawValue: context.originalMethod) ?? .get,
                    statusCode: 307,
                    statusMessage: "Temporary Redirect",
                    timestamp: context.requestStartTime,
                    duration: Date().timeIntervalSince(context.requestStartTime),
                    requestHeaders: context.originalHeaderList,
                    responseHeaders: [TraceHTTPHeader(key: "Location", value: modifiedRequest.url)],
                    requestBody: (self.captureBodies && self.maxCapturedBodyBytes > 0 && !context.originalBody.isEmpty)
                        ? BodyStorage.from(
                            data: Data(context.originalBody.prefix(self.maxCapturedBodyBytes)),
                            maxSize: self.maxCapturedBodyBytes
                        )
                        : .empty,
                    responseBody: .empty,
                    protocolVersion: .http11,
                    tlsInfo: upstreamTLSInfo
                )
                redirected.wasRewritten = true
                redirected.extractHTTPFields()
                NetworkThrottlingController.shared.applyMetadata(to: &redirected)
                DispatchQueue.main.async { [weak self] in
                    self?.onRequestCaptured?(redirected)
                }

                handleHTTP1ClientData()
                if context.isWebSocketUpgrade {
                    pauseClientReads = false
                    readDecryptedFromClient()
                }
                return
            }

            // Track this request so we can pair the next response.
            pendingHTTP1Requests.append(
                CapturedHTTP1Request(
                    id: context.flowId,
                    url: forward.absoluteURL,
                    method: method,
                    headers: forward.forwardHeaders,
                    body: modifiedRequest.requestBody.getString(),
                    bodyData: modifiedRequest.requestBody.getData(),
                    startTime: context.requestStartTime,
                    wasRewritten: modifiedRequest.wasRewritten,
                    isMocked: modifiedRequest.isMocked,
                    isReplayed: modifiedRequest.isReplayed,
                    appliedScriptName: modifiedRequest.appliedScriptName,
                    hitBreakpoint: modifiedRequest.hitBreakpoint,
                    retryAttempts: modifiedRequest.retryAttempts,
                    responsePipeline: context.responsePipeline,
                    isWebSocketUpgrade: context.isWebSocketUpgrade
                )
            )

            // Forward request to upstream.
            forwardHTTP1ToServer(forward.data)
        }
    }

    private func finalizeHTTP1Request(_ state: HTTP1MessageState, effectiveBody: Data) {
        if TLSLog.verboseEnabled {
            SecurityLog.tls.debug(
                "event=tls.finalize_http1_request_begin host=\(self.targetHost, privacy: .private(mask: .hash)) body_size=\(effectiveBody.count)"
            )
        }

        guard let parsedRequest = parseHTTPRequestLine(state.startLine, headers: state.headers, bodyData: effectiveBody) else {
            SecurityLog.tls.error(
                "event=tls.http_parse outcome=failure type=request_line host=\(self.targetHost, privacy: .private(mask: .hash)) start_line=\(state.startLine, privacy: .private(mask: .hash))"
            )
            close(reason: .failure("http1_parse_request_line_failed"))
            return
        }
        let absoluteURL = makeAbsoluteURL(
            scheme: "https",
            host: self.targetHost,
            port: self.targetPort,
            requestTarget: parsedRequest.path
        )
        sampledDebug(
            LogEvent.tls("https_request_parsed")
                .with("host", value: self.targetHost, privacy: .hash)
                .with("method", value: parsedRequest.method)
                .with("url", value: absoluteURL, privacy: .hash)
                .with("body_size", value: effectiveBody.count),
            first: 3,
            every: 200
        )

        let flowId = UUID()
        let requestStartTime = state.timestamp

        let headersDict = state.headers.reduce(into: [String: String]()) { dict, header in
            dict[header.key] = header.value
        }
        let requestBodyData = effectiveBody.isEmpty ? nil : effectiveBody
        let isWebSocket = isWebSocketUpgrade(headersDict)

        // For WebSocket upgrades, pause client-side reads immediately so we can safely hand off
        // the decrypted TLS connections to WebSocketHandler after the 101 response.
        if isWebSocket {
            pauseClientReads = true
        }

        http1InterceptionInFlight = true

        Task { [weak self] in
            guard let self else { return }

            let result: InterceptionResult
            if let interceptor = self.interceptor {
                result = await interceptor.interceptRequest(
                    flowId: flowId,
                    url: absoluteURL,
                    method: parsedRequest.method,
                    headers: headersDict,
                    body: requestBodyData
                )
            } else {
                // No interceptor provided: treat as a pass-through modified request.
                let charset = BodyStorage.extractCharset(from: headersDict)
                let contentEncoding = headersDict.first { $0.key.lowercased() == "content-encoding" }?.value
                let requestBody: BodyStorage = {
                    guard self.captureBodies, self.maxCapturedBodyBytes > 0 else { return .empty }
                    guard let requestBodyData else { return .empty }
                    return BodyStorage.from(
                        data: Data(requestBodyData.prefix(self.maxCapturedBodyBytes)),
                        charset: charset,
                        maxSize: self.maxCapturedBodyBytes,
                        contentEncoding: contentEncoding
                    )
                }()

                let fallback = NetworkRequest(
                    id: flowId,
                    url: absoluteURL,
                    method: HTTPMethod(rawValue: parsedRequest.method) ?? .get,
                    statusCode: nil,
                    statusMessage: nil,
                    timestamp: requestStartTime,
                    duration: 0,
                    requestHeaders: parsedRequest.headers,
                    responseHeaders: [],
                    requestBody: requestBody,
                    responseBody: .empty,
                    protocolVersion: .http11,
                    tlsInfo: self.upstreamTLSInfo
                )
                result = .modified(fallback)
            }

            let pipeline: ResponsePipeline =
                if case let .modified(modified) = result, let interceptor = self.interceptor {
                    await interceptor.responsePipeline(for: modified.url)
                } else {
                    .bufferAndIntercept
                }

            self.executeOnQueue { [weak self] in
                let context = HTTP1InterceptionContext(
                    flowId: flowId,
                    requestStartTime: requestStartTime,
                    originalAbsoluteURL: absoluteURL,
                    originalMethod: parsedRequest.method,
                    originalHeaders: headersDict,
                    originalHeaderList: parsedRequest.headers,
                    originalBody: requestBodyData ?? Data(),
                    responsePipeline: pipeline,
                    isWebSocketUpgrade: isWebSocket
                )
                self?.applyHTTP1InterceptionResult(result, context: context)
            }
        }
    }

    private func finalizeHTTP1Response(_ state: HTTP1MessageState, effectiveBody: Data) {
        guard let parsedResponse = parseHTTPResponseLine(state.startLine, headers: state.headers, bodyData: effectiveBody) else {
            SecurityLog.tls.error("event=tls.http_parse outcome=failure type=response_line")
            close()
            return
        }

        SecurityLog.tls.info("event=tls.https_response status=\(parsedResponse.statusCode) host=\(self.targetHost, privacy: .private(mask: .hash))")

        if (100 ..< 200).contains(parsedResponse.statusCode) {
            if let capture = takeCompletedHTTP1ResponseBodyCapture() {
                try? FileManager.default.removeItem(at: capture.url)
            }
            return
        }

        guard !pendingHTTP1Requests.isEmpty else {
            if let capture = takeCompletedHTTP1ResponseBodyCapture() {
                try? FileManager.default.removeItem(at: capture.url)
            }
            return
        }
        let request = pendingHTTP1Requests.removeFirst()

        let responseHeadersDict = parsedResponse.headers.reduce(into: [String: String]()) { dict, header in
            dict[header.key] = header.value
        }
        let responseCharset = BodyStorage.extractCharset(from: responseHeadersDict)
        let originalContentEncoding = responseHeadersDict.first { $0.key.lowercased() == "content-encoding" }?.value
        let bodyData = parsedResponse.bodyData ?? Data()
        let bodyCapture = takeCompletedHTTP1ResponseBodyCapture()

        let requestCharset = BodyStorage.extractCharset(from: request.headers)
        let requestContentEncoding = request.headers.first(where: { $0.key.lowercased() == "content-encoding" })?.value
        let requestBodyStorage: BodyStorage = {
            guard self.captureBodies, self.maxCapturedBodyBytes > 0 else { return .empty }
            if let data = request.bodyData, !data.isEmpty {
                return BodyStorage.from(
                    data: Data(data.prefix(self.maxCapturedBodyBytes)),
                    charset: requestCharset,
                    maxSize: self.maxCapturedBodyBytes,
                    contentEncoding: requestContentEncoding
                )
            }
            if let body = request.body, !body.isEmpty {
                return BodyStorage.from(
                    string: body,
                    charset: requestCharset,
                    maxSize: self.maxCapturedBodyBytes
                )
            }
            return .empty
        }()
        // Default response body uses the in-memory preview (sufficient for interception and small bodies).
        var responseBodyStorage: BodyStorage = {
            guard self.captureBodies, self.maxCapturedBodyBytes > 0, !bodyData.isEmpty else { return .empty }
            return BodyStorage.from(
                data: bodyData,
                charset: responseCharset,
                maxSize: self.maxCapturedBodyBytes,
                contentEncoding: originalContentEncoding
            )
        }()

        var networkRequest = NetworkRequest(
            id: request.id,
            url: request.url,
            method: HTTPMethod(rawValue: request.method) ?? .get,
            statusCode: parsedResponse.statusCode,
            statusMessage: parsedResponse.statusMessage,
            timestamp: request.startTime,
            duration: Date().timeIntervalSince(request.startTime),
            requestHeaders: request.headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) },
            responseHeaders: parsedResponse.headers,
            requestBody: requestBodyStorage,
            responseBody: responseBodyStorage,
            protocolVersion: .http11,
            tlsInfo: upstreamTLSInfo
        )
        networkRequest.wasRewritten = request.wasRewritten
        networkRequest.isMocked = request.isMocked
        networkRequest.isReplayed = request.isReplayed
        networkRequest.appliedScriptName = request.appliedScriptName
        networkRequest.hitBreakpoint = request.hitBreakpoint
        networkRequest.retryAttempts = request.retryAttempts

        networkRequest.extractHTTPFields()
        NetworkThrottlingController.shared.applyMetadata(to: &networkRequest)

        let shouldInterceptResponse =
            request.responsePipeline == .bufferAndIntercept &&
            interceptor != nil &&
            !http1ResponseForceStreaming

        // If a file-backed capture exists (large streaming body), prefer it for the emitted request.
        // When response interception is active, drop the spool file to avoid orphaning it (we emit the modified response).
        if let bodyCapture {
            if shouldInterceptResponse {
                try? FileManager.default.removeItem(at: bodyCapture.url)
            } else if captureBodies, maxCapturedBodyBytes > 0 {
                if bodyCapture.truncated {
                    let preview = Data(bodyData.prefix(BodyStorage.previewSize))
                    try? FileManager.default.removeItem(at: bodyCapture.url)
                    let totalHint = state.metadata.contentLength ?? (max(bodyCapture.bytesWritten, preview.count) + 1)
                    responseBodyStorage = .truncated(preview, totalSize: totalHint, charset: responseCharset, compressionInfo: nil)
                } else if bodyCapture.bytesWritten <= BodyStorage.inlineThreshold,
                          let data = try? Data(contentsOf: bodyCapture.url) {
                    try? FileManager.default.removeItem(at: bodyCapture.url)
                    responseBodyStorage = BodyStorage.from(
                        data: data,
                        charset: responseCharset,
                        maxSize: maxCapturedBodyBytes,
                        contentEncoding: originalContentEncoding
                    )
                } else {
                    responseBodyStorage = .file(bodyCapture.url, charset: responseCharset, compressionInfo: nil)
                }
            }
        }

        // Ensure the emitted/intercepted request sees the chosen storage.
        networkRequest.responseBody = responseBodyStorage

        if shouldInterceptResponse, let interceptor {
            http1ResponseInterceptionInFlight = true
            Task { [weak self] in
                guard let self else { return }
                let modified = await interceptor.interceptResponse(
                    request: networkRequest,
                    statusCode: parsedResponse.statusCode,
                    statusMessage: parsedResponse.statusMessage ?? "",
                    headers: parsedResponse.headers,
                    body: bodyData.isEmpty ? nil : bodyData
                )

                self.executeOnQueue { [weak self] in
                    guard let self else { return }

                    // Build and send the modified response back to client.
                    let statusCode = modified.statusCode ?? parsedResponse.statusCode
                    var responseString = "HTTP/1.1 \(statusCode)"
                    if let msg = modified.statusMessage {
                        responseString += " \(msg)"
                    }
                    responseString += "\r\n"

                    let decompressed = networkRequest.responseBody.getCompressionInfo()?.decompressionSuccess == true
                    let hadContentEncodingHeader = (originalContentEncoding != nil && !(originalContentEncoding ?? "").isEmpty && originalContentEncoding?.lowercased() != "identity")

                    let sanitizedHeaders = modified.responseHeaders.filter {
                        let lower = $0.key.lowercased()
                        if lower == "transfer-encoding" || lower == "content-length" {
                            return false
                        }
                        if decompressed && hadContentEncodingHeader && lower == "content-encoding" {
                            return false
                        }
                        return true
                    }

                    for header in sanitizedHeaders {
                        responseString += "\(header.key): \(header.value)\r\n"
                    }

                    let modifiedBodyData =
                        modified.responseBody.getData()
                            ?? modified.responseBody.getString()?.data(using: .utf8)
                            ?? Data()
                    responseString += "Content-Length: \(modifiedBodyData.count)\r\n"
                    responseString += "\r\n"

                    guard let headersData = responseString.data(using: .utf8) else {
                        self.close()
                        return
                    }
                    var out = Data()
                    out.append(headersData)
                    out.append(modifiedBodyData)

                    var captured = modified
                    captured.tlsInfo = self.upstreamTLSInfo
                    DispatchQueue.main.async { [weak self] in
                        self?.onRequestCaptured?(captured)
                    }

                    self.forwardHTTP1ToClient(out)
                    self.bufferedHTTP1ResponseRaw.removeAll()
                    self.http1ResponseForceStreaming = false
                    self.currentHTTP1ResponseBuffering = false
                    self.http1ResponseInterceptionInFlight = false
                    // Process any bytes that arrived while interception was in-flight.
                    self.handleHTTP1ServerData(forceComplete: false)
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onRequestCaptured?(networkRequest)
            }
            if request.responsePipeline == .bufferAndIntercept, !http1ResponseForceStreaming, !bufferedHTTP1ResponseRaw.isEmpty {
                // No response interception (or it was disabled). If we buffered, flush the original bytes.
                forwardHTTP1ToClient(bufferedHTTP1ResponseRaw)
            }
            bufferedHTTP1ResponseRaw.removeAll()
            http1ResponseForceStreaming = false
            http1ResponseInterceptionInFlight = false
            currentHTTP1ResponseBuffering = false
        }
    }

    // MARK: - HTTP Parsing Helpers

    private func parseHTTPHeaders(_ headerData: Data.SubSequence) -> (String, [TraceHTTPHeader])? {
        guard let headerString = String(data: Data(headerData), encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }

        var headers: [TraceHTTPHeader] = []
        for (index, line) in lines.enumerated() {
            if index == 0 { continue }
            if line.isEmpty { break }

            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex])
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers.append(TraceHTTPHeader(key: key, value: value))
            }
        }

        return (firstLine, headers)
    }

    private func parseHeaderMetadata(_ headers: [TraceHTTPHeader]) -> HeaderMetadata {
        var contentLength: Int?
        var isChunked = false
        var expectsContinue = false

        for header in headers {
            let lowerKey = header.key.lowercased()
            let value = header.value
            if lowerKey == "content-length" {
                if let length = Int(value.trimmingCharacters(in: .whitespaces)) {
                    contentLength = length
                }
            }
            if lowerKey == "transfer-encoding", value.lowercased().contains("chunked") {
                isChunked = true
            }
            if lowerKey == "expect", value.lowercased().contains("100-continue") {
                expectsContinue = true
            }
        }

        return HeaderMetadata(contentLength: contentLength, isChunked: isChunked, expectsContinue: expectsContinue)
    }

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let headers: [TraceHTTPHeader]
        let body: String?
        let bodyData: Data
    }

    private struct ParsedHTTPResponse {
        let statusCode: Int
        let statusMessage: String?
        let headers: [TraceHTTPHeader]
        let bodyData: Data?
    }

    private func parseHTTPRequestLine(
        _ requestLine: String,
        headers: [TraceHTTPHeader],
        bodyData: Data
    ) -> ParsedHTTPRequest? {
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])
        let body = bodyData.isEmpty ? nil : String(data: bodyData, encoding: .utf8)
        return ParsedHTTPRequest(method: method, path: path, headers: headers, body: body, bodyData: bodyData)
    }

    private func parseHTTPResponseLine(
        _ statusLine: String,
        headers: [TraceHTTPHeader],
        bodyData: Data
    ) -> ParsedHTTPResponse? {
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let statusCode = Int(parts[1]) else { return nil }
        let statusMessage = parts.count >= 3 ? String(parts[2]) : nil
        let body = bodyData.isEmpty ? nil : bodyData
        return ParsedHTTPResponse(statusCode: statusCode, statusMessage: statusMessage, headers: headers, bodyData: body)
    }

    private func parseStatusCode(from statusLine: String) -> Int? {
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private func originFormTarget(from requestTarget: String) -> String {
        // Origin-form or asterisk-form.
        if requestTarget.hasPrefix("/") || requestTarget == "*" {
            return requestTarget
        }

        // Absolute-form: strip scheme+authority.
        if let components = URLComponents(string: requestTarget) {
            // IMPORTANT: Preserve percent-encoding for the origin-form target; see comment in
            // `buildForwardHTTP1Data`.
            var path = components.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let query = components.percentEncodedQuery, !query.isEmpty {
                path += "?\(query)"
            }
            return path
        }

        // Fallback: best-effort.
        return requestTarget.hasPrefix("/") ? requestTarget : "/\(requestTarget)"
    }

    private func makeAbsoluteURL(
        scheme: String,
        host: String,
        port: UInt16,
        requestTarget: String
    ) -> String {
        let target = originFormTarget(from: requestTarget)
        let normalizedTarget = (target == "*") ? "/" : (target.hasPrefix("/") ? target : "/\(target)")

        let defaultPort: UInt16 = (scheme.lowercased() == "https") ? 443 : 80
        let hostNeedsBrackets = host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]")
        let hostPart = hostNeedsBrackets ? "[\(host)]" : host
        let authority = (port == defaultPort) ? hostPart : "\(hostPart):\(port)"

        return "\(scheme)://\(authority)\(normalizedTarget)"
    }

    private func isChunkedBodyComplete(_ body: Data) -> Bool {
        var index = 0
        let crlf = Data([0x0D, 0x0A])
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        while index < body.count {
            guard let sizeRange = body.range(of: crlf, options: [], in: index ..< body.count) else {
                return false
            }

            let sizeLineData = body[index ..< sizeRange.lowerBound]
            guard let sizeString = String(data: sizeLineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }

            let sizeToken = sizeString.split(separator: ";", maxSplits: 1).first ?? Substring()
            guard let chunkSize = Int(sizeToken, radix: 16) else {
                return false
            }

            index = sizeRange.upperBound

            if chunkSize == 0 {
                if let trailerEnd = body.range(of: terminator, options: [], in: index ..< body.count) {
                    return trailerEnd.upperBound <= body.count
                }
                return false
            }

            let chunkEnd = index + chunkSize
            let crlfEnd = chunkEnd + 2

            guard chunkEnd <= body.count, crlfEnd <= body.count else {
                return false
            }

            if body[chunkEnd ..< crlfEnd] != crlf {
                return false
            }

            index = crlfEnd
        }

        return false
    }

    private func chunkedBodyLength(_ body: Data) -> Int? {
        var index = 0
        let crlf = Data([0x0D, 0x0A])
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        while index < body.count {
            guard let sizeRange = body.range(of: crlf, options: [], in: index ..< body.count) else {
                return nil
            }

            let sizeLineData = body[index ..< sizeRange.lowerBound]
            guard let sizeString = String(data: sizeLineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }

            let sizeToken = sizeString.split(separator: ";", maxSplits: 1).first ?? Substring()
            guard let chunkSize = Int(sizeToken, radix: 16) else {
                return nil
            }

            index = sizeRange.upperBound

            if chunkSize == 0 {
                if let trailerEnd = body.range(of: terminator, options: [], in: index ..< body.count) {
                    return trailerEnd.upperBound
                }
                return nil
            }

            let chunkEnd = index + chunkSize
            let crlfEnd = chunkEnd + 2

            guard chunkEnd <= body.count, crlfEnd <= body.count else {
                return nil
            }

            if body[chunkEnd ..< crlfEnd] != crlf {
                return nil
            }

            index = crlfEnd
        }

        return nil
    }

    private func decodeChunkedBody(_ body: Data) -> Data? {
        var index = 0
        let crlf = Data([0x0D, 0x0A])
        var decoded = Data()

        while index < body.count {
            guard let sizeRange = body.range(of: crlf, options: [], in: index ..< body.count) else {
                return nil
            }

            let sizeLineData = body[index ..< sizeRange.lowerBound]
            guard let sizeString = String(data: sizeLineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }

            let sizeToken = sizeString.split(separator: ";", maxSplits: 1).first ?? Substring()
            guard let chunkSize = Int(sizeToken, radix: 16) else {
                return nil
            }

            index = sizeRange.upperBound

            if chunkSize == 0 {
                return decoded
            }

            let chunkEnd = index + chunkSize
            let crlfEnd = chunkEnd + 2

            guard chunkEnd <= body.count, crlfEnd <= body.count else {
                return nil
            }

            decoded.append(body[index ..< chunkEnd])

            if body[chunkEnd ..< crlfEnd] != crlf {
                return nil
            }

            index = crlfEnd
        }

        return nil
    }

    // MARK: - HTTP/2 Protocol Detection

    private func detectProtocol() {
        sampledDebug(
            LogEvent.tls("detect_protocol_begin")
                .with("host", value: self.targetHost, privacy: .hash)
                .with("buffer_size", value: self.clientBuffer.count)
        )

        // Check for HTTP/2 connection preface
        if HTTP2Preface.isHTTP2Preface(clientBuffer) {
            sampledDebug(
                LogEvent.tls("protocol_detect")
                    .with("protocol", value: "http2")
                    .with("host", value: self.targetHost, privacy: .hash)
                    .with("action", value: "setup_http2")
            )
            if !http2Configured {
                isHTTP2 = true
                setupHTTP2Connections()
            }
            forwardHTTP2ToServer(HTTP2Preface.clientPreface)
            Task { await http2Client?.receivedPreface() }
            clientBuffer.removeFirst(HTTP2Preface.length)
            clientPrefaceConsumed = true
            protocolNegotiated = true
            SecurityLog.tls.info(
                "event=tls.protocol_negotiated protocol=http2 host=\(self.targetHost, privacy: .private(mask: .hash))"
            )
            return
        }

        // Check for HTTP/1.x request
        if let requestString = String(data: clientBuffer, encoding: .utf8),
           requestString.hasPrefix("GET ") || requestString.hasPrefix("POST ") ||
           requestString.hasPrefix("PUT ") || requestString.hasPrefix("DELETE ") ||
           requestString.hasPrefix("HEAD ") || requestString.hasPrefix("OPTIONS ") ||
           requestString.hasPrefix("PATCH ") {
            sampledDebug(
                LogEvent.tls("protocol_detect")
                    .with("protocol", value: "http1")
                    .with("host", value: self.targetHost, privacy: .hash)
            )
            isHTTP2 = false
            protocolNegotiated = true
            SecurityLog.tls.info(
                "event=tls.protocol_negotiated protocol=http1 host=\(self.targetHost, privacy: .private(mask: .hash))"
            )
            return
        }

        // Need more data to detect
        sampledDebug(
            LogEvent.tls("detect_protocol_need_more_data")
                .with("host", value: self.targetHost, privacy: .hash)
                .with("buffer_size", value: self.clientBuffer.count)
        )
    }

    private func setupHTTP2Connections() {
        guard !http2Configured else { return }
        http2Configured = true

        // Setup client-side HTTP/2 connection state
        http2Client = HTTP2Connection()

        // Setup server-side HTTP/2 connection state
        http2Server = HTTP2Connection()

        // Setup HTTP/2 stream manager for capture
        let manager = HTTP2StreamManager(targetHost: self.targetHost, targetPort: self.targetPort)
        http2StreamManager = manager
        startHTTP2CapturePipeline(manager: manager)

        // Wire HTTP/2 metrics hooks (optional)
        Task { [weak self] in
            await manager.setMetricsCallbacks(
                onStreamCreated: { [weak self] streamId in
                    self?.onHTTP2StreamCreated?(streamId)
                },
                onStreamClosed: { [weak self] streamId in
                    self?.onHTTP2StreamClosed?(streamId)
                },
                onStreamsActiveChanged: { [weak self] count in
                    self?.onHTTP2StreamsActiveChanged?(count)
                },
                onProtocolError: { [weak self] in
                    self?.onHTTP2ProtocolError?()
                }
            )
        }

        // Set up the callback for captured requests
        Task { [weak self] in
            await manager.setOnRequestComplete { [weak self] request in
                guard let self else { return }
                self.executeOnQueue { [weak self] in
                    guard let self else { return }
                    var updated = request
                    updated.tlsInfo = self.upstreamTLSInfo
                    DispatchQueue.main.async { [weak self] in
                        self?.onRequestCaptured?(updated)
                    }
                }
            }
        }
    }

    private func startHTTP2CapturePipeline(manager: HTTP2StreamManager) {
        // Defensive: only one pipeline per TLSProxyConnection.
        stopHTTP2CapturePipeline()

        executeOnQueue { [weak self] in
            self?.http2CapturePendingCount = 0
            self?.http2CaptureDisabled = false
        }

        let stream = AsyncStream<HTTP2CaptureEvent>(
            bufferingPolicy: .bufferingOldest(http2CaptureMaxPending)
        ) { continuation in
            // We cannot drop frames without breaking HPACK / stream correctness.
            // If capture ever lags, we disable capture to avoid unbounded growth.
            self.http2CaptureContinuation = continuation
        }

        http2CaptureTask = Task { [stream, weak self] in
            for await event in stream {
                if Task.isCancelled { break }

                switch event.direction {
                case .clientToServer:
                    await TLSProxyConnection.processClientFrame(event.frame, manager: manager)
                case .serverToClient:
                    await TLSProxyConnection.processServerFrame(event.frame, manager: manager)
                }

                self?.executeOnQueue { [weak self] in
                    guard let self else { return }
                    if self.http2CapturePendingCount > 0 {
                        self.http2CapturePendingCount -= 1
                    }
                }
            }
        }
    }

    private func stopHTTP2CapturePipeline() {
        http2CaptureContinuation?.finish()
        http2CaptureContinuation = nil
        http2CaptureTask?.cancel()
        http2CaptureTask = nil
        http2CapturePendingCount = 0
    }

    private func enqueueHTTP2CaptureEvent(_ event: HTTP2CaptureEvent) {
        executeOnQueue { [weak self] in
            guard let self else { return }
            guard !self.http2CaptureDisabled else { return }
            guard self.http2CapturePendingCount < self.http2CaptureMaxPending else {
                self.http2CaptureDisabled = true
                SecurityLog.tls.warning(
                    "event=tls.http2_capture_disabled outcome=failure pending=\(self.http2CapturePendingCount) limit=\(self.http2CaptureMaxPending)"
                )
                self.stopHTTP2CapturePipeline()
                return
            }

            self.http2CapturePendingCount += 1
            self.http2CaptureContinuation?.yield(event)
        }
    }

    private func reconcileProtocolNegotiation() {
        guard !protocolNegotiated else {
            sampledDebug(
                LogEvent.tls("alpn_reconcile_skip")
                    .with("host", value: self.targetHost, privacy: .hash)
                    .with("already_negotiated", value: true)
            )
            return
        }
        guard let clientALPN, let serverALPN else {
            sampledDebug(
                LogEvent.tls("alpn_reconcile")
                    .outcome(.pending)
                    .with("host", value: self.targetHost, privacy: .hash)
                    .with("client", value: self.clientALPN ?? "pending", privacy: .hash)
                    .with("server", value: self.serverALPN ?? "pending", privacy: .hash)
            )
            return
        }

        sampledDebug(
            LogEvent.tls("alpn_reconcile_begin")
                .with("host", value: self.targetHost, privacy: .hash)
                .with("client", value: clientALPN, privacy: .hash)
                .with("server", value: serverALPN, privacy: .hash)
        )

        guard clientALPN == serverALPN else {
            SecurityLog.tls.error(
                "event=tls.alpn_mismatch host=\(self.targetHost, privacy: .private(mask: .hash)) client=\(clientALPN) server=\(serverALPN) action=close connection_id=\(self.connectionId ?? -1)"
            )
            close(reason: .failure("alpn_mismatch_client_\(clientALPN)_server_\(serverALPN)"))
            return
        }

        SecurityLog.tls.info(
            "event=tls.alpn_reconcile outcome=success host=\(self.targetHost, privacy: .private(mask: .hash)) protocol=\(clientALPN, privacy: .private(mask: .hash)) connection_id=\(self.connectionId ?? -1)"
        )

        if clientALPN == "h2" {
            sampledDebug(
                LogEvent.tls("protocol_setup")
                    .with("protocol", value: "http2")
                    .with("host", value: self.targetHost, privacy: .hash)
                    .with("action", value: "setup_http2")
            )
            isHTTP2 = true
            waitingForHTTP2Preface = true
            setupHTTP2Connections()
        } else {
            sampledDebug(
                LogEvent.tls("protocol_setup")
                    .with("protocol", value: "http1")
                    .with("host", value: self.targetHost, privacy: .hash)
            )
            isHTTP2 = false
            protocolNegotiated = true
        }
    }

    // MARK: - HTTP/2 Data Handling

    private func handleHTTP2ClientData() {
        guard !clientBuffer.isEmpty else { return }

        // Parse frames from buffer while forwarding
        while let frame = parseNextFrame(from: &clientBuffer, maxFrameSize: http2MaxFrameSizeClientToServer) {
            onHTTP2FrameParsed?()

            // Track client SETTINGS_MAX_FRAME_SIZE for validating server->client frames.
            if frame.header.frameType == .settings, !frame.header.frameFlags.contains(.ack),
               let settings = HTTP2Settings.parse(from: frame.payload) {
                // Safety: Clamp to a conservative maximum to avoid buffering huge frames in-memory.
                http2MaxFrameSizeServerToClient = min(
                    max(settings.maxFrameSize, HTTP2Settings.minFrameSize),
                    http2MaxFrameSizeHardCap
                )
            }

            // Forward the raw frame immediately (transparency)
            let rawFrame = frame.header.serialize() + frame.payload
            forwardHTTP2ToServer(rawFrame)

            // Enqueue for ordered capture processing (HPACK/stream state is order-dependent).
            enqueueHTTP2CaptureEvent(HTTP2CaptureEvent(direction: .clientToServer, frame: frame))
        }
    }

    private func handleHTTP2ServerData() {
        guard !serverBuffer.isEmpty else { return }

        // Parse frames from buffer while forwarding
        while let frame = parseNextFrame(from: &serverBuffer, maxFrameSize: http2MaxFrameSizeServerToClient) {
            onHTTP2FrameParsed?()

            // Track server SETTINGS_MAX_FRAME_SIZE for validating client->server frames.
            if frame.header.frameType == .settings, !frame.header.frameFlags.contains(.ack),
               let settings = HTTP2Settings.parse(from: frame.payload) {
                // Safety: Clamp to a conservative maximum to avoid buffering huge frames in-memory.
                http2MaxFrameSizeClientToServer = min(
                    max(settings.maxFrameSize, HTTP2Settings.minFrameSize),
                    http2MaxFrameSizeHardCap
                )
            }

            // Forward the raw frame immediately (transparency)
            let rawFrame = frame.header.serialize() + frame.payload
            forwardHTTP2ToClient(rawFrame)

            // Enqueue for ordered capture processing (avoid reordering vs client frames).
            enqueueHTTP2CaptureEvent(HTTP2CaptureEvent(direction: .serverToClient, frame: frame))
        }
    }

    /// Parse the next HTTP/2 frame from the buffer
    /// Returns nil if buffer doesn't contain a complete frame
    private func parseNextFrame(from buffer: inout Data, maxFrameSize: UInt32) -> HTTP2Frame? {
        guard buffer.count >= HTTP2FrameHeader.size else { return nil }
        // NOTE: Foundation.Data indices are not guaranteed to be 0-based offsets after mutations
        // (e.g. removeFirst/append). Never subscript with literal indices like [0].
        let start = buffer.startIndex
        let length = UInt32(buffer[start]) << 16 | UInt32(buffer[start + 1]) << 8 | UInt32(buffer[start + 2])
        let type = buffer[start + 3]
        let flags = buffer[start + 4]
        let streamId =
            (UInt32(buffer[start + 5]) & 0x7F) << 24
                | UInt32(buffer[start + 6]) << 16
                | UInt32(buffer[start + 7]) << 8
                | UInt32(buffer[start + 8])

        // RFC 7540 §4.2: frame payload length must not exceed peer's SETTINGS_MAX_FRAME_SIZE.
        if length > maxFrameSize {
            SecurityLog.tls.warning(
                "event=tls.http2_frame_size outcome=failure length=\(length, privacy: .public) max=\(maxFrameSize, privacy: .public) action=close"
            )
            onHTTP2ProtocolError?()
            buffer.removeAll()
            close(reason: .failure("http2_frame_size_exceeded length=\(length) max=\(maxFrameSize)"))
            return nil
        }

        let header = HTTP2FrameHeader(length: length, type: type, flags: flags, streamId: streamId)

        let totalSize = HTTP2FrameHeader.size + Int(header.length)
        guard buffer.count >= totalSize else { return nil }

        let payloadStart = buffer.index(start, offsetBy: HTTP2FrameHeader.size)
        let payloadEnd = buffer.index(payloadStart, offsetBy: Int(header.length))
        let payload = Data(buffer[payloadStart ..< payloadEnd])
        let frame = HTTP2Frame(header: header, payload: payload)

        buffer.removeFirst(totalSize)
        return frame
    }

    /// Process a frame from the client (client -> server direction).
    /// Static to avoid capturing non-thread-safe `self` from concurrency Tasks.
    private static func processClientFrame(_ frame: HTTP2Frame, manager: HTTP2StreamManager) async {
        switch frame.header.frameType {
        case .headers:
            await manager.handleClientHeaders(frame)
        case .data:
            await manager.handleClientData(frame)
        case .continuation:
            await manager.handleClientContinuation(frame)
        case .settings:
            await manager.handleSettings(frame, fromClient: true)
        case .rstStream:
            await manager.handleRstStream(frame)
        case .goaway:
            await manager.handleGoaway(frame)
        default:
            break // Other frames don't need capture processing
        }
    }

    /// Process a frame from the server (server -> client direction).
    /// Static to avoid capturing non-thread-safe `self` from concurrency Tasks.
    private static func processServerFrame(_ frame: HTTP2Frame, manager: HTTP2StreamManager) async {
        switch frame.header.frameType {
        case .headers:
            await manager.handleServerHeaders(frame)
        case .data:
            await manager.handleServerData(frame)
        case .continuation:
            await manager.handleServerContinuation(frame)
        case .settings:
            await manager.handleSettings(frame, fromClient: false)
        case .rstStream:
            await manager.handleRstStream(frame)
        case .goaway:
            await manager.handleGoaway(frame)
        default:
            break // Other frames don't need capture processing
        }
    }

    private func forwardHTTP2ToServer(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let connection = tlsClientConnection else {
            if logThrottle.shouldLog(key: "tls.forward_server_skipped.http2.\(connectionId ?? -1)", minInterval: 5) {
                SecurityLog.tls.warning(
                    "event=tls.forward_server_skipped outcome=skipped proto=http2 reason=no_tls_client_connection host=\(self.targetHost, privacy: .private(mask: .hash)) connection_id=\(self.connectionId ?? -1) bytes=\(data.count)"
                )
            }
            return
        }
        sendToServer(data, connection: connection, logEvent: "tls.http2_forward_server")
    }

    private func forwardHTTP2ToClient(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let connection = tlsServerConnection else {
            if logThrottle.shouldLog(key: "tls.forward_client_skipped.http2.\(connectionId ?? -1)", minInterval: 5) {
                SecurityLog.tls.warning(
                    "event=tls.forward_client_skipped outcome=skipped proto=http2 reason=no_tls_server_connection host=\(self.targetHost, privacy: .private(mask: .hash)) connection_id=\(self.connectionId ?? -1) bytes=\(data.count)"
                )
            }
            return
        }
        sendToClient(data, connection: connection, logEvent: "tls.http2_forward_client")
    }

    private func sendToServer(_ data: Data, connection: NWConnection, logEvent: String) {
        throttler.process(packet: data, direction: .upload) { [weak self] in
            self?.executeOnQueue { [weak self] in
                guard let self, self.isActive else { return }
                self.bytesSentToUpstream += UInt64(data.count)
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    let host = self?.targetHost ?? "unknown"
                    let connId = self?.connectionId ?? -1
                    SecurityLog.tls.error(
                        "event=\(logEvent) outcome=failure host=\(host, privacy: .private(mask: .hash)) connection_id=\(connId) error=\(error.localizedDescription)"
                    )
                    self?.close()
                }
            })
        }
    }

    private func sendToClient(_ data: Data, connection: NWConnection, logEvent: String) {
        throttler.process(packet: data, direction: .download) { [weak self] in
            self?.executeOnQueue { [weak self] in
                guard let self, self.isActive else { return }
                self.bytesSentToClient += UInt64(data.count)
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    let host = self?.targetHost ?? "unknown"
                    let connId = self?.connectionId ?? -1
                    SecurityLog.tls.error(
                        "event=\(logEvent) outcome=failure host=\(host, privacy: .private(mask: .hash)) connection_id=\(connId) error=\(error.localizedDescription)"
                    )
                    self?.close()
                }
            })
        }
    }
}

// MARK: - Helper Models

public struct ParsedHTTPSRequest {
    public let method: String
    public let path: String
    public let headers: [TraceHTTPHeader]
    public var body: String?
    public var bodyData: Data?
    public let timestamp: Date
}
