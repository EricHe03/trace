//
//  MITMProxyServer.swift
//  TraceProxy
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import Network
import OSLog
import TraceCore
import TraceNetworking
import TraceSecurity
#if canImport(TraceFeatures)
import TraceFeatures
#endif

/// Provides a MITM HTTP/HTTPS proxy server.
/// Runs inside the Network Extension and handles HTTP/HTTPS traffic routed to the local proxy
/// (proxy-only mode via the tunnel's `proxySettings`).
public class MITMProxyServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [ProxyConnection] = []
    // Concurrency: Serialize listener callbacks and connection bookkeeping to avoid data races.
    private let queue = DispatchQueue(label: "com.trace.proxy", qos: .userInitiated)
    // Concurrency: Enable re-entrancy checks so we can skip sync hops on the queue.
    private let queueKey = DispatchSpecificKey<Void>()

    private var configuration: [String: Any] = [:]
    private var cleanupTimer: DispatchSourceTimer?
    private var mitmAllowlist: [String] = []
    private var mitmEnabled = false
    // Rule: Transparent TLS accepts raw ClientHello bytes without an HTTP CONNECT and must be
    // explicitly enabled because it is outside the explicit HTTP proxy contract.
    private var transparentTLSModeEnabled = false
    // Rationale: Inject the event log to avoid multiple writers racing on the same file.
    private weak var eventLog: NDJSONLogWriter?
    private let throttler = PacketThrottler()
    private var pcapWriter: PCAPWriter?
    private var rawCaptureEnabled = false
    private var rawCaptureLimit: UInt64 = 0
    // Rule: Track bytes written to cap captures and avoid unbounded disk usage.
    private var rawCaptureBytes: UInt64 = 0
    private var logSampler = LogSampler()
    private var samplingSequence: Int = 0

    /// Creates a local-only MITM proxy bound to loopback, with an optional shared event log sink.
    public init(port: UInt16, eventLog: NDJSONLogWriter? = nil) {
        self.port = port
        self.eventLog = eventLog
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Updates the throttling state.
    public func updateThrottlingState(_ state: NetworkThrottlingState) {
        throttler.updateState(state)
    }

    /// Configures raw capture settings.
    public func configureRawCapture(enabled: Bool, writer: PCAPWriter?, limit: UInt64) {
        performOnQueue {
            self.rawCaptureEnabled = enabled
            self.pcapWriter = writer
            self.rawCaptureLimit = limit
            self.rawCaptureBytes = writer?.currentFileSize() ?? 0
        }
    }

    /// Updates the capture size limit without restarting capture.
    public func updateRawCaptureLimit(_ limit: UInt64) {
        performOnQueue {
            self.rawCaptureLimit = limit
        }
    }

    private func writeToPCAP(_ data: Data, isRequest: Bool) {
        guard self.rawCaptureEnabled, let writer = self.pcapWriter else { return }

        // Rationale: PCAP expects IP packets, so synthesize minimal IPv4 and TCP headers.
        var packet = Data()

        let totalLength = UInt16(20 + 20 + data.count) // Includes IP and TCP headers plus payload.
        let ipHeader = createIPv4Header(
            totalLength: totalLength,
            srcIP: isRequest ? Data([127, 0, 0, 1]) : Data([0, 0, 0, 0]),
            dstIP: isRequest ? Data([0, 0, 0, 0]) : Data([127, 0, 0, 1])
        )
        packet.append(ipHeader)

        let tcpHeader = createTCPHeader(
            srcPort: isRequest ? 12345 : self.port,
            dstPort: isRequest ? self.port : 12345
        )
        packet.append(tcpHeader)

        packet.append(data)

        if self.rawCaptureLimit > 0 {
            let projected = self.rawCaptureBytes + UInt64(packet.count)
            if projected > self.rawCaptureLimit {
                // Rule: Disable further capture to keep the PCAP bounded and avoid truncating packets.
                self.rawCaptureEnabled = false
                ProxyLog.metrics.warning("event=pcap.capture_limit_reached outcome=disabled limit=\(self.rawCaptureLimit) current=\(self.rawCaptureBytes)")
                return
            }
            self.rawCaptureBytes = projected
        }

        writer.writePacket(packet)
    }

    private func createIPv4Header(totalLength: UInt16, srcIP: Data, dstIP: Data) -> Data {
        var header = Data(count: 20)
        header[0] = 0x45 // Sets version 4 and IHL 5.
        header[1] = 0x00 // Sets DSCP/ECN to zero.
        header[2] = UInt8((totalLength >> 8) & 0xFF)
        header[3] = UInt8(totalLength & 0xFF)
        header[4] = 0x00 // Sets the IP ID to zero.
        header[5] = 0x00
        header[6] = 0x40 // Sets "don't fragment".
        header[7] = 0x00 // Sets fragment offset to zero.
        header[8] = 64 // Sets TTL to 64.
        header[9] = 6 // Sets protocol to TCP.
        header[10] = 0x00 // Leaves checksum disabled.
        header[11] = 0x00
        header.replaceSubrange(12 ..< 16, with: srcIP)
        header.replaceSubrange(16 ..< 20, with: dstIP)
        return header
    }

    private func createTCPHeader(srcPort: UInt16, dstPort: UInt16) -> Data {
        var header = Data(count: 20)
        header[0] = UInt8((srcPort >> 8) & 0xFF)
        header[1] = UInt8(srcPort & 0xFF)
        header[2] = UInt8((dstPort >> 8) & 0xFF)
        header[3] = UInt8(dstPort & 0xFF)
        header[4] = 0x00 // Sets sequence number to zero.
        header[5] = 0x00
        header[6] = 0x00
        header[7] = 0x01
        header[8] = 0x00 // Sets ack number to zero.
        header[9] = 0x00
        header[10] = 0x00
        header[11] = 0x00
        header[12] = 0x50 // Sets data offset to 20 bytes.
        header[13] = 0x18 // Sets PSH and ACK flags.
        header[14] = 0xFF // Sets window size.
        header[15] = 0xFF
        header[16] = 0x00 // Leaves checksum disabled.
        header[17] = 0x00
        header[18] = 0x00 // Sets urgent pointer to zero.
        header[19] = 0x00
        return header
    }

    // MARK: - Server Lifecycle

    /// Starts the listener and housekeeping timers.
    /// - Throws: `ProxyServerError.invalidPort` if the port is not a valid NW endpoint.
    public func start() throws {
        let parameters = NWParameters.tcp

        parameters.acceptLocalOnly = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ProxyServerError.invalidPort(port)
        }
        let listener: NWListener
        do {
            // Rationale: Bind to loopback so proxy settings targeting 127.0.0.1 always connect.
            // Rule: If requiredLocalEndpoint includes a port, do not pass a port to
            // NWListener(using:on:) or Network.framework logs a conflict.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
            listener = try NWListener(using: parameters)
        } catch {
            // Rationale: Fall back to a local-only listener to keep the proxy functional.
            let fallback = NWParameters.tcp
            fallback.acceptLocalOnly = true
            listener = try NWListener(using: fallback, on: nwPort)
        }

        listener.newConnectionHandler = { [weak self] connection in
            let connId = ObjectIdentifier(connection).hashValue
            ProxyLog.mitm.info(
                "event=proxy.connection_new outcome=pending conn_id=\(connId) endpoint=\(String(describing: connection.endpoint), privacy: .private(mask: .hash))"
            )
            self?.handleNewConnection(connection)
        }

        let listenerPort = port
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                ProxyLog.mitm.info("event=proxy.listener_ready outcome=success port=\(listenerPort, privacy: .public)")
            case let .waiting(error):
                ProxyLog.mitm.warning("event=proxy.listener_waiting outcome=pending error=\(error.localizedDescription, privacy: .public)")
            case .setup:
                ProxyLog.mitm.debug("event=proxy.listener_setup outcome=pending")
            case let .failed(error):
                ProxyLog.mitm.error("event=proxy.listener_failed outcome=failure error=\(error.localizedDescription, privacy: .public)")
            case .cancelled:
                ProxyLog.mitm.info("event=proxy.listener_cancelled outcome=success")
            @unknown default:
                ProxyLog.mitm.debug("event=proxy.listener_unknown outcome=pending")
            }
        }

        listener.start(queue: queue)
        self.listener = listener

        startCleanupTimer()

        ProxyLog.mitm.info("event=proxy.server_start outcome=success")
    }

    /// Stops the listener and closes all active connections.
    public func stop() {
        cleanupTimer?.cancel()
        cleanupTimer = nil

        listener?.cancel()
        listener = nil

        let connectionsToClose = performOnQueueSync {
            let currentConnections = connections
            connections.removeAll()
            return currentConnections
        }
        connectionsToClose.forEach { $0.close() }

        ProxyLog.mitm.info("event=proxy.server_stop outcome=success")
    }

    // MARK: - Connection Cleanup

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.cleanupStaleConnections()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func cleanupStaleConnections() {
        let removed = performOnQueueSync {
            let before = connections.count
            connections.removeAll { connection in
                connection.isClosed
            }
            return before - connections.count
        }
        if removed > 0 {
            ProxyLog.mitm.debug("event=proxy.cleanup outcome=success count=\(removed)")
        }
    }

    /// Applies runtime configuration flags (kept dynamic for long-lived NE sessions).
    public func updateConfiguration(_ config: [String: Any]) {
        performOnQueue {
            self.configuration = config
            // Rule: Transparent TLS mode must be explicitly enabled and defaults to off to match
            // explicit proxy behavior.
            if let enabled = config["transparentTLSModeEnabled"] as? Bool {
                self.transparentTLSModeEnabled = enabled
            } else if let enabled = config["enableTransparentTLSMode"] as? Bool {
                self.transparentTLSModeEnabled = enabled
            }
            ProxyLog.mitm.debug("event=proxy.config_update outcome=success")
        }
    }

    /// Updates the allowlist used to decide which hosts may be MITM'd.
    public func setMitmAllowlist(_ list: [String]) {
        performOnQueue {
            // Rule: Trim, lowercase, and never allow an empty list to disable MITM.
            let sanitized = list
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            self.mitmAllowlist = sanitized.isEmpty ? ["*"] : sanitized

            ProxyLog.mitm.info("event=proxy.allowlist_update outcome=success count=\(self.mitmAllowlist.count)")
            self.eventLog?.append(type: "mitm_allowlist", msg: "size=\(self.mitmAllowlist.count)")
        }
    }

    /// Enables or disables MITM globally (used by hardening and UI toggles).
    public func setMitmEnabled(_ enabled: Bool) {
        performOnQueue {
            self.mitmEnabled = enabled
            ProxyLog.mitm.info("event=proxy.mitm_toggle outcome=success enabled=\(enabled, privacy: .public)")
            self.eventLog?.append(type: "mitm_enabled", msg: "\(enabled)")
        }
    }

    // MARK: - Connection Handling

    private var connectionCount: Int = 0

    /// Returns the number of active client proxy connections.
    ///
    /// Discussion: This is useful for diagnosing memory pressure and connection churn in the
    /// Network Extension process, where a large number of concurrent connections can trigger
    /// watchdog/jetsam termination.
    public func activeConnectionCount() -> Int {
        performOnQueueSync { connections.count }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connectionCount += 1
        let connNum = connectionCount
        let connId = ObjectIdentifier(connection).hashValue

        ProxyLog.mitm.info(
            "event=proxy.connection_accept outcome=success conn_num=\(connNum) conn_id=\(connId) total=\(self.connectionCount)"
        )

        // Rationale: Snapshot capture config at accept time so per-connection buffering stays bounded.
        // Note: This config can change at runtime; new connections will pick up new values.
        let captureConfig = AppGroupStorage.shared.loadConfiguration()
        let proxyConnection = ProxyConnection(
            connection: connection,
            mitmAllowlist: mitmAllowlist,
            mitmEnabled: mitmEnabled,
            transparentTLSModeEnabled: transparentTLSModeEnabled,
            eventLog: eventLog,
            throttler: throttler,
            captureConfig: captureConfig
        )

        proxyConnection.onClose = { [weak self, weak proxyConnection] in
            guard let proxyConnection else { return }
            ProxyLog.mitm.debug("event=proxy.connection_close outcome=success conn_num=\(connNum)")
            self?.performOnQueue {
                self?.connections.removeAll { $0 === proxyConnection }
            }
        }

        proxyConnection.onRequestCaptured = { [weak self] request in
            if self?.logSampler.shouldLog(key: "proxy.request_captured", first: 10, every: 200) == true {
                ProxyLog.mitm.debug(
                    "event=proxy.request_captured outcome=success method=\(request.method.rawValue, privacy: .public) url=\(request.url, privacy: .private(mask: .hash)) request_id=\(request.id.uuidString, privacy: .public)"
                )
            }
            // Concurrency: Serialize storage writes to avoid cross-connection I/O races.
            self?.performOnQueue {
                guard let self else { return }
                guard self.shouldPersist(request, using: captureConfig) else { return }
                self.saveCapturedRequest(request)
            }
        }

        performOnQueue { [weak self] in
            self?.connections.append(proxyConnection)
        }

        proxyConnection.start()
    }

    private func performOnQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            // Concurrency: Avoid sync from outside to keep NW callbacks non-blocking.
            queue.async(execute: block)
        }
    }

    private func performOnQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return block()
        }
        // Concurrency: Use sync only when not already on the queue.
        return queue.sync(execute: block)
    }

    private func saveCapturedRequest(_ request: NetworkRequest) {
        let samplingConfig = AppGroupStorage.shared.loadSamplingConfig()
        guard shouldSample(using: samplingConfig) else { return }
        do {
            try AppGroupStorage.shared.saveRequest(request)
            if logSampler.shouldLog(key: "proxy.request_saved", first: 10, every: 200) {
                ProxyLog.mitm.debug(
                    "event=proxy.request_saved outcome=success method=\(request.method.rawValue, privacy: .public) url=\(request.url, privacy: .private(mask: .hash)) request_id=\(request.id.uuidString, privacy: .public)"
                )
            }

            if rawCaptureEnabled, pcapWriter != nil {
                captureRequestToPCAP(request)
            }
        } catch {
            ProxyLog.mitm.error("event=proxy.request_saved outcome=failure error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldPersist(_ request: NetworkRequest, using config: CaptureConfiguration) -> Bool {
        switch config.filterMode {
        case .all:
            return true
        case .whitelist:
            guard !config.domainFilters.isEmpty else { return false }
        case .blacklist:
            break
        }

        guard let host = URL(string: request.url)?.host?.lowercased(), !host.isEmpty else {
            return config.filterMode != .whitelist
        }

        let matches = config.domainFilters.contains { pattern in
            domainFilterMatches(host: host, pattern: pattern)
        }

        switch config.filterMode {
        case .all:
            return true
        case .whitelist:
            return matches
        case .blacklist:
            return !matches
        }
    }

    private func domainFilterMatches(host: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let p = trimmed.lowercased()
        if p == "*" { return true }
        if p.contains("*") {
            return StringMatcher(matchType: .wildcard, pattern: p, caseSensitive: false).matches(host)
        }
        return host == p || host.hasSuffix("." + p)
    }

    private func shouldSample(using config: SamplingConfig) -> Bool {
        guard config.enabled else { return true }
        let rate = max(0.0, min(1.0, config.sampleRate))
        if rate <= 0 { return false }
        if rate >= 1 { return true }

        switch config.strategy {
        case .random:
            return Double.random(in: 0 ..< 1) < rate
        case .periodic:
            samplingSequence &+= 1
            let interval = max(1, Int((1.0 / rate).rounded()))
            return samplingSequence % interval == 0
        case .adaptive:
            let activeConnections = max(1, connections.count)
            let scale = 50.0 / Double(max(50, activeConnections))
            let adjustedRate = min(rate, rate * scale)
            return Double.random(in: 0 ..< 1) < adjustedRate
        }
    }

    private func captureRequestToPCAP(_ request: NetworkRequest) {
        var requestData = Data()
        let urlComponents = URLComponents(string: request.url)
        let requestPath: String = {
            let path = urlComponents?.path
            let query = urlComponents?.percentEncodedQuery
            if let path, !path.isEmpty {
                if let query, !query.isEmpty {
                    return "\(path)?\(query)"
                }
                return path
            }
            if let query, !query.isEmpty {
                return "/?\(query)"
            }
            return "/"
        }()
        let requestLine = "\(request.method.rawValue) \(requestPath) HTTP/1.1\r\n"
        if let data = requestLine.data(using: .utf8) {
            requestData.append(data)
        }
        for header in request.requestHeaders {
            if let data = "\(header.key): \(header.value)\r\n".data(using: .utf8) {
                requestData.append(data)
            }
        }
        if let crlf = "\r\n".data(using: .utf8) {
            requestData.append(crlf)
        }
        if let body = request.requestBody.getData() {
            requestData.append(body)
        }
        writeToPCAP(requestData, isRequest: true)

        if let statusCode = request.statusCode {
            var responseData = Data()
            let statusLine = "HTTP/1.1 \(statusCode) \(request.statusMessage ?? "OK")\r\n"
            if let data = statusLine.data(using: .utf8) {
                responseData.append(data)
            }
            for header in request.responseHeaders {
                if let data = "\(header.key): \(header.value)\r\n".data(using: .utf8) {
                    responseData.append(data)
                }
            }
            if let crlf = "\r\n".data(using: .utf8) {
                responseData.append(crlf)
            }
            if let body = request.responseBody.getData() {
                responseData.append(body)
            }
            writeToPCAP(responseData, isRequest: false)
        }
    }
}

// MARK: - Proxy Connection

/// Represents a single proxy connection (client <-> proxy <-> server).
public class ProxyConnection: @unchecked Sendable {
    private let clientConnection: NWConnection
    private var serverConnection: NWConnection?
    private let mitmAllowlist: [String]
    private let mitmEnabled: Bool
    private let transparentTLSModeEnabled: Bool
    private weak var eventLog: NDJSONLogWriter?
    private let throttler: PacketThrottler
    private let connectionId: Int
    private let logSampler = LogSampler()
    private let logThrottle = LogThrottle()

    // Concurrency: Confine connection state to this serial queue to avoid data races.
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()

    private var requestBuffer = Data()
    private var responseBuffer = Data()
    private var isHTTPS = false
    private var isWebSocket = false
    private var isSSE = false
    // Concurrency: Stop the client receive loop during handoff to avoid concurrent `receive` calls.
    private var pauseClientReads = false
    private var isHandingOffToTLS = false
    private var isPassthroughTunnel = false
    private var targetHost: String?
    private var targetPort: UInt16 = 80
    private var webSocketHandler: WebSocketHandler?
    private var sseHandler: SSEHandler?

    private var tlsProxyConnection: TLSProxyConnection?

    private let hostsManager = HostsManager.shared

    private let startTime = Date()
    private var capturedRequest: CapturedRequest?
    private var _isClosed = false
    public var isClosed: Bool {
        performOnQueueSync { _isClosed }
    }

    private var headersComplete = false
    private var expectedContentLength: Int?
    private var isChunkedTransfer = false
    private var responseHeaderEndOffset: Int?

    private var responsePipeline: ResponsePipeline = .bufferAndIntercept
    private var didForwardInitialResponseBufferToClient = false
    private var responseBodyBytesReceived: Int = 0
    private var finalChunkMarkerSeen = false
    private var chunkedTail = Data()

    // MARK: - Capture Configuration / Safety Limits

    private let captureConfig: CaptureConfiguration
    private let captureBodies: Bool
    private let maxCapturedBodyBytes: Int

    private func capturedRequestHeaders(from headers: [String: String]) -> [TraceHTTPHeader] {
        guard captureConfig.captureHeaders else { return [] }
        return headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
    }

    private func capturedResponseHeaders(_ headers: [TraceHTTPHeader]) -> [TraceHTTPHeader] {
        captureConfig.captureHeaders ? headers : []
    }

    // MARK: - Streaming body capture (disk spooling)

    private struct CompletedBodyCapture {
        let url: URL
        let bytesWritten: Int
        let truncated: Bool
    }

    private struct ActiveBodyCapture {
        let url: URL
        let handle: FileHandle
        var bytesWritten: Int
        var truncated: Bool
        var chunkedDecoder: ChunkedTransferDecoder?
    }

    private var activeResponseBodyCapture: ActiveBodyCapture?
    private var completedResponseBodyCapture: CompletedBodyCapture?

    // Rule: Cap request buffering to avoid unbounded memory growth.
    // Note: This is a proxy parsing buffer, not a total transfer cap.
    private let maxRequestSize: Int

    // Rule: Cap response buffering/capture buffer to avoid unbounded memory growth.
    // This buffer includes headers + initial body bytes (used in both buffered and streaming modes).
    private let maxResponseBufferSize: Int

    public var onClose: (() -> Void)?
    public var onRequestCaptured: ((NetworkRequest) -> Void)?

    public init(
        connection: NWConnection,
        mitmAllowlist: [String],
        mitmEnabled: Bool,
        transparentTLSModeEnabled: Bool,
        eventLog: NDJSONLogWriter?,
        throttler: PacketThrottler,
        captureConfig: CaptureConfiguration
    ) {
        self.clientConnection = connection
        self.connectionId = ObjectIdentifier(connection).hashValue
        self.mitmAllowlist = mitmAllowlist
        self.mitmEnabled = mitmEnabled
        self.transparentTLSModeEnabled = transparentTLSModeEnabled
        self.eventLog = eventLog
        self.throttler = throttler
        self.captureConfig = captureConfig

        // Rule: Enforce a conservative hard cap inside the Network Extension to avoid OOM/jetsam.
        // Users can still configure larger capture sizes, but the extension must remain stable.
        //
        // IMPORTANT: This is a *capture* cap (stored to disk), not an in-memory buffering cap.
        // In-memory buffering is governed separately by `maxResponseBufferSize`.
        let requestedBodyBytes = max(0, captureConfig.maxBodySize)
        let hardCapBodyBytes = 200 * 1024 * 1024 // 200 MB absolute cap for body spooling.
        let cappedBodyBytes = min(requestedBodyBytes, hardCapBodyBytes)
        self.captureBodies = captureConfig.captureBody && cappedBodyBytes > 0
        self.maxCapturedBodyBytes = cappedBodyBytes

        // Request header cap is enforced separately (8 KB). This cap protects against huge bodies.
        // Keep it higher than response because request parsing may require buffering until complete.
        self.maxRequestSize = 100 * 1024 * 1024 // 100 MB (parsing guardrail; not a capture limit)

        // Response buffering is the main risk for large downloads; keep it tightly bounded.
        // Include header allowance so we don't under-count header bytes.
        //
        // IMPORTANT: This buffer is *not* the body capture limit. It exists only to:
        // - parse response headers reliably
        // - keep a small preview of the body in memory
        // Large bodies are captured by streaming spooling to disk.
        let headerAllowance = 64 * 1024
        let bodyPreviewBytes = min(BodyStorage.previewSize, cappedBodyBytes)
        self.maxResponseBufferSize = headerAllowance + (self.captureBodies ? bodyPreviewBytes : 0)
        self.queue = DispatchQueue(
            label: "com.trace.proxy.connection.\(UUID().uuidString)",
            qos: .userInitiated
        )
        self.queue.setSpecific(key: queueKey, value: ())
    }

    // MARK: - Throttled Send Methods

    private func sendToClient(_ data: Data, completion: NWConnection.SendCompletion) {
        throttler.process(packet: data, direction: .download) { [weak self] in
            self?.clientConnection.send(content: data, completion: completion)
        }
    }

    private func sendToServer(_ data: Data, completion: NWConnection.SendCompletion) {
        throttler.process(packet: data, direction: .upload) { [weak self] in
            self?.serverConnection?.send(content: data, completion: completion)
        }
    }

    // MARK: - Connection Lifecycle

    /// Starts receiving on the client connection and begins request parsing on this queue.
    public func start() {
        let connId = connectionId
        ProxyLog.mitm.info("event=proxy.connection_start_begin connection_id=\(connId)")

        clientConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.performOnQueue {
                switch state {
                case .setup:
                    ProxyLog.mitm.debug("event=proxy.client_state state=setup connection_id=\(connId)")
                case .preparing:
                    ProxyLog.mitm.debug("event=proxy.client_state state=preparing connection_id=\(connId)")
                case .ready:
                    ProxyLog.mitm.info("event=proxy.client_ready outcome=success connection_id=\(connId)")
                    self.readFromClient()
                case let .waiting(error):
                    if self.logSampler.shouldLog(key: "proxy.client_state.waiting.\(connId)", first: 3, every: 50) {
                        ProxyLog.mitm.warning(
                            "event=proxy.client_state state=waiting connection_id=\(connId) error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                case let .failed(error):
                    ProxyLog.mitm.error("event=proxy.client_failed outcome=failure connection_id=\(connId) error=\(error.localizedDescription, privacy: .public)")
                    self.close()
                case .cancelled:
                    ProxyLog.mitm.debug("event=proxy.client_state state=cancelled connection_id=\(connId)")
                    self.close()
                @unknown default:
                    ProxyLog.mitm.debug("event=proxy.client_state state=unknown connection_id=\(connId)")
                }
            }
        }

        clientConnection.start(queue: queue)
        ProxyLog.mitm.debug("event=proxy.connection_start_dispatched connection_id=\(connId)")
    }

    /// Closes client/server sockets and tears down any TLS proxy state.
    public func close() {
        performOnQueue { [weak self] in
            guard let self else { return }
            guard !self._isClosed else {
                ProxyLog.mitm.debug("event=proxy.close_already_closed host=\(self.targetHost ?? "unknown", privacy: .private(mask: .hash))")
                return
            }
            self._isClosed = true

            let host = self.targetHost ?? "unknown"
            let hasTlsProxy = self.tlsProxyConnection != nil
            let hasServerConn = self.serverConnection != nil
            ProxyLog.mitm.info(
                "event=proxy.connection_close_begin host=\(host, privacy: .private(mask: .hash)) has_tls_proxy=\(hasTlsProxy) has_server_conn=\(hasServerConn) is_https=\(self.isHTTPS) is_passthrough=\(self.isPassthroughTunnel)"
            )

            self.tlsProxyConnection?.close()
            self.tlsProxyConnection = nil

            self.clientConnection.cancel()
            self.serverConnection?.cancel()

            ProxyLog.mitm.debug("event=proxy.connection_close_complete host=\(host, privacy: .private(mask: .hash))")
            self.onClose?()
        }
    }

    // MARK: - Client Communication

    private func readFromClient() {
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                ProxyLog.mitm.error("event=proxy.client_read outcome=failure error=\(error.localizedDescription, privacy: .public)")
                self.close()
                return
            }

            if let data, !data.isEmpty {
                self.requestBuffer.append(data)
                // Rule: Cap request buffering to avoid unbounded memory growth.
                // Note: This is a defensive safeguard. Large uploads should ideally be streamed,
                // but until then we prefer closing a single connection over killing the extension.
                if self.requestBuffer.count > self.maxRequestSize {
                    ProxyLog.mitm.warning("event=proxy.request_size_exceeded outcome=failure max_size=\(self.maxRequestSize)")
                    self.close()
                    return
                }
                self.handleClientData()
            }

            if !isComplete {
                if !self.isHandingOffToTLS, !self.pauseClientReads {
                    self.readFromClient()
                }
            } else {
                self.close()
            }
        }
    }

    private func handleClientData() {
        guard !isHandingOffToTLS else { return }
        // Rationale: In explicit proxy mode, HTTPS arrives as CONNECT, not raw TLS.
        // Rule: Only attempt ClientHello sniffing when transparent TLS is explicitly enabled.
        if looksLikeTLSClientHello(requestBuffer) {
            if transparentTLSModeEnabled {
                handleTransparentTLSClientHello()
            } else {
                ProxyLog.mitm.warning("event=proxy.unexpected_tls_before_connect outcome=failure action=close")
                eventLog?.append(type: "unexpected_tls_before_connect", msg: "buffer=\(requestBuffer.count)")
                close()
            }
            return
        }
        if requestBuffer.starts(with: "CONNECT ".data(using: .utf8)!) {
            handleCONNECTRequest()
        } else if isHTTPS {
            handleHTTPSData()
        } else {
            handleHTTPRequest()
        }
    }

    // MARK: - Transparent TLS Handling (no CONNECT)

    private func looksLikeTLSClientHello(_ data: Data) -> Bool {
        // Rationale: Check the TLS record header and handshake type to minimize false positives.
        guard data.count >= 6 else { return false }
        let bytes = [UInt8](data.prefix(6))
        guard bytes[0] == 0x16 else { return false } // Requires a handshake record type.
        guard bytes[1] == 0x03 else { return false } // Requires the TLS major version.
        // The minor version may be 0x00..0x04 (SSL3..TLS1.3 record versions).
        // The handshake type byte after the record header should be ClientHello (0x01).
        return bytes[5] == 0x01
    }

    private func handleTransparentTLSClientHello() {
        guard let sniHost = parseTLSSNI(from: requestBuffer) else {
            // Edge case: Wait for more bytes when the ClientHello is fragmented.
            if requestBuffer.count < 4096 {
                return
            }
            ProxyLog.mitm.error("event=proxy.tls_sni_missing outcome=failure buffer_size=\(self.requestBuffer.count)")
            eventLog?.append(type: "tls_sni_missing", msg: "buffer=\(requestBuffer.count)")
            close()
            return
        }

        targetHost = sniHost
        targetPort = 443
        isHTTPS = true
        isHandingOffToTLS = true

        let bypassReason = mitmBypassReason(host: sniHost)
        let allowMITM = (bypassReason == nil)
        ProxyLog.mitm.info(
            "event=proxy.mitm_check host=\(sniHost, privacy: .private(mask: .hash)) enabled=\(self.mitmEnabled) allow=\(allowMITM) reason=\(bypassReason ?? "allowed", privacy: .public) allowlist_size=\(self.mitmAllowlist.count) connection_id=\(self.connectionId)"
        )

        let sniHash = LogRedaction.hash(sniHost)
        eventLog?.append(
            type: "tls_sni",
            msg: "\(sniHash):443 allowMITM=\(allowMITM) enabled=\(mitmEnabled) reason=\(bypassReason ?? "allowed")"
        )

        let initialData = requestBuffer
        requestBuffer.removeAll()

        if allowMITM {
            ProxyLog.mitm.info("event=proxy.mitm_start outcome=success host=\(sniHost, privacy: .private(mask: .hash)) port=443 mode=transparent")
            Task { await ProxyNetworkMetrics.shared.recordMITMIntercepted() }
            eventLog?.append(type: "mitm_intercept", msg: "\(sniHash):443 (transparent)")

            // Rationale: Apply host overrides for HTTPS while preserving SNI for certificate validation.
            var upstreamHost = sniHost
            var upstreamPort: UInt16 = 443
            if let match = hostsManager.matchingEntry(for: sniHost) {
                ProxyLog.mitm.info(
                    "event=proxy.host_override outcome=success from=\(sniHost, privacy: .private(mask: .hash)) to=\(match.targetIP, privacy: .private(mask: .hash))"
                )
                upstreamHost = match.targetIP
                if let overridePort = match.targetPort {
                    upstreamPort = UInt16(overridePort)
                    ProxyLog.mitm.info("event=proxy.port_override outcome=success from=443 to=\(upstreamPort)")
                }
            }

            let tlsProxy = TLSProxyConnection(
                clientConnection: self.clientConnection,
                targetHost: sniHost,
                targetPort: 443,
                upstreamHost: upstreamHost,
                upstreamPort: upstreamPort,
                interceptor: RequestInterceptor.shared
            )
            tlsProxy.enqueuePendingClientData(initialData)
            tlsProxy.onRequestCaptured = { [weak self] request in
                self?.onRequestCaptured?(request)
            }
            tlsProxy.onHTTP2FrameParsed = {
                Task { await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed() }
            }
            tlsProxy.onHTTP2ProtocolError = {
                Task { await ProxyNetworkMetrics.shared.recordHTTP2ProtocolError() }
            }
            tlsProxy.onHTTP2StreamCreated = { _ in
                Task { await ProxyNetworkMetrics.shared.recordHTTP2StreamCreated() }
            }
            tlsProxy.onHTTP2StreamClosed = { _ in
                Task { await ProxyNetworkMetrics.shared.recordHTTP2StreamClosed() }
            }
            tlsProxy.onHTTP2StreamsActiveChanged = { count in
                Task { await ProxyNetworkMetrics.shared.updateHTTP2StreamsActive(count) }
            }
            tlsProxy.onFailure = { [weak self] pending, reason in
                guard let self, let targetHost = self.targetHost, !self.isClosed else { return }
                ProxyLog.mitm.error("event=proxy.mitm_failed outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=443 mode=transparent reason=\(reason, privacy: .public)")
                Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
                let targetHash = LogRedaction.hash(targetHost)
                self.eventLog?.append(type: "mitm_failed", msg: "\(targetHash):443 (transparent) reason=\(reason)")
                self.eventLog?.append(type: "not_decryptable", msg: "\(targetHash):443")
                self.maybeRecordMITMAutoBypass(host: targetHost, reason: reason)
                // Rationale: Ensure the UI receives a record even when MITM fails before any HTTP.
                self.emitNotDecryptableTLSRequest(host: targetHost, port: 443, reason: "MITM failed (transparent) \(reason)")
                self.tlsProxyConnection = nil
                self.startPassthroughTunnel(host: targetHost, port: 443, initialData: pending)
            }
            tlsProxy.onClose = { [weak self] in
                self?.tlsProxyConnection = nil
                self?.close()
            }
            self.tlsProxyConnection = tlsProxy
            tlsProxy.start()
        } else {
            let reason = bypassReason ?? "unknown"
            ProxyLog.mitm.info("event=proxy.mitm_bypass outcome=skipped host=\(sniHost, privacy: .private(mask: .hash)) port=443 mode=transparent reason=\(reason, privacy: .public)")
            Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
            eventLog?.append(type: "mitm_bypass", msg: "\(sniHash):443 (transparent) reason=\(reason)")
            emitNotDecryptableTLSRequest(host: sniHost, port: 443, reason: "transparent \(reason)")
            startPassthroughTunnel(host: sniHost, port: 443, initialData: initialData)
        }
    }

    private func emitNotDecryptableTLSRequest(host: String, port: UInt16, reason: String) {
        // Rationale: Emit a lightweight UI marker for HTTPS without exposing decrypted contents.
        let url = "https://\(host):\(port)/"
        let now = Date()
        let requestHeaders: [TraceHTTPHeader] = captureConfig.captureHeaders
            ? [
                TraceHTTPHeader(key: "Host", value: host),
                TraceHTTPHeader(key: "X-Trace-Note", value: "TLS not decryptable (\(reason))")
            ]
            : []

        let req = NetworkRequest(
            url: url,
            method: .connect,
            statusCode: nil,
            statusMessage: "TLS passthrough",
            timestamp: startTime,
            duration: now.timeIntervalSince(startTime),
            requestHeaders: requestHeaders,
            responseHeaders: [],
            requestBody: .empty,
            responseBody: .empty
        )
        onRequestCaptured?(req)
    }

    private func parseTLSSNI(from data: Data) -> String? {
        // Rationale: Parse only the minimal ClientHello SNI fields with defensive bounds checks.
        func u16(_ i: Int) -> Int? {
            guard i + 1 < data.count else { return nil }
            return (Int(data[i]) << 8) | Int(data[i + 1])
        }

        func u24(_ i: Int) -> Int? {
            guard i + 2 < data.count else { return nil }
            return (Int(data[i]) << 16) | (Int(data[i + 1]) << 8) | Int(data[i + 2])
        }

        guard data.count >= 5 else { return nil }
        guard data[0] == 0x16 else { return nil }
        guard data[1] == 0x03 else { return nil }
        guard let recordLen = u16(3) else { return nil }
        let recordEnd = 5 + recordLen
        guard recordEnd <= data.count else { return nil }

        let hsStart = 5
        guard data[hsStart] == 0x01 else { return nil } // Requires ClientHello.
        guard let hsLen = u24(hsStart + 1) else { return nil }
        let hsEnd = hsStart + 4 + hsLen
        guard hsEnd <= data.count else { return nil }

        var i = hsStart + 4
        // Skips client_version (2) + random (32).
        i += 2 + 32
        guard i < hsEnd else { return nil }

        guard i < hsEnd else { return nil }
        let sessionIDLen = Int(data[i]); i += 1
        i += sessionIDLen
        guard i + 2 <= hsEnd else { return nil }

        guard let cipherLen = u16(i) else { return nil }
        i += 2 + cipherLen
        guard i < hsEnd else { return nil }

        guard i < hsEnd else { return nil }
        let compLen = Int(data[i]); i += 1
        i += compLen
        guard i + 2 <= hsEnd else { return nil }

        guard let extTotalLen = u16(i) else { return nil }
        i += 2
        let extEnd = i + extTotalLen
        guard extEnd <= hsEnd else { return nil }

        while i + 4 <= extEnd {
            guard let extType = u16(i), let extLen = u16(i + 2) else { return nil }
            i += 4
            let extDataEnd = i + extLen
            guard extDataEnd <= extEnd else { return nil }

            if extType == 0x0000 {
                guard i + 2 <= extDataEnd, let listLen = u16(i) else { return nil }
                var j = i + 2
                let listEnd = j + listLen
                guard listEnd <= extDataEnd else { return nil }

                while j + 3 <= listEnd {
                    let nameType = data[j]; j += 1
                    guard let nameLen = u16(j) else { return nil }
                    j += 2
                    guard j + nameLen <= listEnd else { return nil }
                    if nameType == 0x00 {
                        let nameData = data.subdata(in: j ..< (j + nameLen))
                        return String(data: nameData, encoding: .utf8)
                    }
                    j += nameLen
                }
            }

            i = extDataEnd
        }

        return nil
    }

    // MARK: - HTTP CONNECT Handling (for HTTPS)

    private func handleCONNECTRequest() {
        if logSampler.shouldLog(key: "proxy.connect_request_begin.\(connectionId)", first: 3, every: 200) {
            ProxyLog.mitm.debug("event=proxy.connect_request_begin buffer_size=\(self.requestBuffer.count)")
        }

        let headerEndMarker = "\r\n\r\n".data(using: .utf8)!
        guard let headerEndRange = requestBuffer.range(of: headerEndMarker) else {
            // Rule: Cap CONNECT headers at 8 KB to avoid unbounded buffering.
            if requestBuffer.count > 8192 {
                ProxyLog.mitm.error("event=proxy.connect_headers_exceeded outcome=failure max_size=8192 actual_size=\(self.requestBuffer.count)")
                close()
            } else {
                ProxyLog.mitm.debug("event=proxy.connect_headers_incomplete buffer_size=\(self.requestBuffer.count)")
            }
            return
        }

        let headerData = requestBuffer[..<headerEndRange.lowerBound]
        let remainingData = Data(requestBuffer[headerEndRange.upperBound...])

        guard let requestString = String(data: headerData, encoding: .utf8) else {
            ProxyLog.mitm.error("event=proxy.connect_decode outcome=failure")
            close()
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            ProxyLog.mitm.error("event=proxy.connect_empty outcome=failure")
            close()
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            ProxyLog.mitm.error("event=proxy.connect_invalid_format outcome=failure")
            close()
            return
        }

        let hostPort = String(parts[1])
        guard let (host, port) = parseHostPort(hostPort) else {
            ProxyLog.mitm.error("event=proxy.connect_invalid_hostport outcome=failure")
            close()
            return
        }

        targetHost = host
        targetPort = port

        isHTTPS = true
        isHandingOffToTLS = true

        ProxyLog.mitm.info(
            "event=proxy.connect_request host=\(self.targetHost!, privacy: .private(mask: .hash)) port=\(self.targetPort)"
        )

        let bypassReason = mitmBypassReason(host: host)
        let allowMITM = (bypassReason == nil)
        ProxyLog.mitm.info(
            "event=proxy.mitm_check host=\(host, privacy: .private(mask: .hash)) enabled=\(self.mitmEnabled) allow=\(allowMITM) reason=\(bypassReason ?? "allowed", privacy: .public) allowlist_size=\(self.mitmAllowlist.count)"
        )

        // Rationale: Emit a marker at CONNECT so "connected but 0 captured" cases are visible.
        if allowMITM {
            let url = "https://\(host):\(port)/"
            let now = Date()
            let req = NetworkRequest(
                url: url,
                method: .connect,
                statusCode: 200,
                statusMessage: "CONNECT established",
                timestamp: startTime,
                duration: now.timeIntervalSince(startTime),
                requestHeaders: captureConfig.captureHeaders
                    ? [
                        TraceHTTPHeader(key: "Host", value: host),
                        TraceHTTPHeader(key: "X-Trace-Note", value: "CONNECT observed; awaiting decrypted HTTP")
                    ]
                    : [],
                responseHeaders: [],
                requestBody: .empty,
                responseBody: .empty
            )
            onRequestCaptured?(req)
        }

        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        guard let responseData = response.data(using: .utf8) else {
            ProxyLog.mitm.error("event=proxy.connect_response_encode outcome=failure")
            close()
            return
        }

        sendToClient(
            responseData,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }

                if let error {
                    ProxyLog.mitm.error("event=proxy.connect_response_send outcome=failure error=\(error.localizedDescription, privacy: .public)")
                    self.close()
                    return
                }

                self.requestBuffer.removeAll()

                guard let targetHost = self.targetHost else {
                    self.close()
                    return
                }

                if allowMITM {
                    ProxyLog.mitm.info(
                        "event=proxy.mitm_start outcome=pending host=\(targetHost, privacy: .private(mask: .hash)) port=\(self.targetPort) mode=connect"
                    )
                    Task { await ProxyNetworkMetrics.shared.recordMITMIntercepted() }
                    let targetHash = LogRedaction.hash(targetHost)
                    self.eventLog?.append(type: "mitm_intercept", msg: "\(targetHash):\(self.targetPort)")

                    // Rationale: Apply host overrides for HTTPS while preserving SNI for cert validation.
                    var upstreamHost = targetHost
                    var upstreamPort = self.targetPort
                    if let match = self.hostsManager.matchingEntry(for: targetHost) {
                        ProxyLog.mitm.info(
                            "event=proxy.host_override outcome=success from=\(targetHost, privacy: .private(mask: .hash)) to=\(match.targetIP, privacy: .private(mask: .hash))"
                        )
                        upstreamHost = match.targetIP
                        if let overridePort = match.targetPort {
                            upstreamPort = UInt16(overridePort)
                            ProxyLog.mitm.info("event=proxy.port_override outcome=success from=\(self.targetPort) to=\(upstreamPort)")
                        }
                    }

                    ProxyLog.mitm.info(
                        "event=proxy.tls_proxy_create_begin host=\(targetHost, privacy: .private(mask: .hash)) upstream_host=\(upstreamHost, privacy: .private(mask: .hash)) upstream_port=\(upstreamPort) connection_id=\(self.connectionId)"
                    )

                    let tlsProxy = TLSProxyConnection(
                        clientConnection: self.clientConnection,
                        targetHost: targetHost,
                        targetPort: self.targetPort,
                        upstreamHost: upstreamHost,
                        upstreamPort: upstreamPort,
                        interceptor: RequestInterceptor.shared
                    )

                    let remainingDataCount = remainingData.count
                    if self.logSampler.shouldLog(key: "proxy.tls_proxy_enqueue_pending.\(self.connectionId)", first: 2, every: 50) {
                        ProxyLog.mitm.debug(
                            "event=proxy.tls_proxy_enqueue_pending host=\(targetHost, privacy: .private(mask: .hash)) pending_bytes=\(remainingDataCount) connection_id=\(self.connectionId)"
                        )
                    }
                    tlsProxy.enqueuePendingClientData(remainingData)

                    tlsProxy.onRequestCaptured = { [weak self] request in
                        guard let self else { return }
                        if self.logSampler.shouldLog(key: "proxy.tls_request_captured.\(self.connectionId)", first: 5, every: 200) {
                            ProxyLog.mitm.debug(
                                "event=proxy.tls_request_captured host=\(targetHost, privacy: .private(mask: .hash)) url=\(request.url, privacy: .private(mask: .hash)) method=\(request.method.rawValue, privacy: .public) connection_id=\(self.connectionId)"
                            )
                        }
                        self.onRequestCaptured?(request)
                    }

                    tlsProxy.onHTTP2FrameParsed = {
                        Task { await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed() }
                    }
                    tlsProxy.onHTTP2ProtocolError = { [weak self] in
                        guard let self else { return }
                        ProxyLog.mitm.warning("event=proxy.http2_protocol_error host=\(targetHost, privacy: .private(mask: .hash)) connection_id=\(self.connectionId)")
                        Task { await ProxyNetworkMetrics.shared.recordHTTP2ProtocolError() }
                    }
                    tlsProxy.onHTTP2StreamCreated = { [weak self] streamId in
                        guard let self else { return }
                        if self.logSampler.shouldLog(key: "proxy.http2_stream_created.\(self.connectionId)", first: 3, every: 100) {
                            ProxyLog.mitm.debug(
                                "event=proxy.http2_stream_created host=\(targetHost, privacy: .private(mask: .hash)) stream_id=\(streamId) connection_id=\(self.connectionId)"
                            )
                        }
                        Task { await ProxyNetworkMetrics.shared.recordHTTP2StreamCreated() }
                    }
                    tlsProxy.onHTTP2StreamClosed = { [weak self] streamId in
                        guard let self else { return }
                        if self.logSampler.shouldLog(key: "proxy.http2_stream_closed.\(self.connectionId)", first: 3, every: 100) {
                            ProxyLog.mitm.debug(
                                "event=proxy.http2_stream_closed host=\(targetHost, privacy: .private(mask: .hash)) stream_id=\(streamId) connection_id=\(self.connectionId)"
                            )
                        }
                        Task { await ProxyNetworkMetrics.shared.recordHTTP2StreamClosed() }
                    }
                    tlsProxy.onHTTP2StreamsActiveChanged = { count in
                        Task { await ProxyNetworkMetrics.shared.updateHTTP2StreamsActive(count) }
                    }

                    tlsProxy.onFailure = { [weak self] pending, reason in
                        guard let self, let targetHost = self.targetHost, !self.isClosed else { return }
                        ProxyLog.mitm.error("event=proxy.mitm_failed outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(self.targetPort) mode=connect reason=\(reason, privacy: .public) pending_bytes=\(pending.count)")
                        Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
                        let targetHash = LogRedaction.hash(targetHost)
                        self.eventLog?.append(type: "mitm_failed", msg: "\(targetHash):\(self.targetPort) reason=\(reason)")
                        self.eventLog?.append(type: "not_decryptable", msg: "\(targetHash):\(self.targetPort)")
                        self.maybeRecordMITMAutoBypass(host: targetHost, reason: reason)
                        // Rationale: Ensure the UI receives a record even when MITM fails before any HTTP.
                        ProxyLog.mitm.debug("event=proxy.mitm_fallback_to_passthrough host=\(targetHost, privacy: .private(mask: .hash)) reason=\(reason, privacy: .public)")
                        self.emitNotDecryptableTLSRequest(host: targetHost, port: self.targetPort, reason: "MITM failed \(reason)")
                        self.tlsProxyConnection = nil
                        self.startPassthroughTunnel(host: targetHost, port: self.targetPort, initialData: pending)
                    }

                    tlsProxy.onClose = { [weak self] in
                        ProxyLog.mitm.debug("event=proxy.tls_proxy_closed host=\(targetHost, privacy: .private(mask: .hash))")
                        self?.tlsProxyConnection = nil
                        self?.close()
                    }

                    self.tlsProxyConnection = tlsProxy
                    ProxyLog.mitm.debug(
                        "event=proxy.tls_proxy_start host=\(targetHost, privacy: .private(mask: .hash))"
                    )
                    tlsProxy.start()
                } else {
                    let reason = bypassReason ?? "unknown"
                    ProxyLog.mitm.info("event=proxy.mitm_bypass outcome=skipped host=\(targetHost, privacy: .private(mask: .hash)) port=\(self.targetPort) mode=connect reason=\(reason, privacy: .public)")
                    Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
                    let targetHash = LogRedaction.hash(targetHost)
                    self.eventLog?.append(
                        type: "mitm_bypass",
                        msg: "\(targetHash):\(self.targetPort) reason=\(reason)"
                    )
                    self.emitNotDecryptableTLSRequest(
                        host: targetHost,
                        port: self.targetPort,
                        reason: "CONNECT \(reason)"
                    )
                    self.startPassthroughTunnel(host: targetHost, port: self.targetPort, initialData: remainingData)
                }
            }
        )
    }

    private func startPassthroughTunnel(host: String, port: UInt16, initialData: Data) {
        ProxyLog.mitm.info(
            "event=proxy.passthrough_tunnel_start_begin host=\(host, privacy: .private(mask: .hash)) port=\(port) initial_data_bytes=\(initialData.count)"
        )
        isPassthroughTunnel = true

        // Rationale: Apply host overrides for passthrough to keep HTTP/HTTPS behavior consistent.
        var finalHost = host
        var finalPort = port
        if let match = hostsManager.matchingEntry(for: host) {
            ProxyLog.mitm.info(
                "event=proxy.host_override outcome=success from=\(host, privacy: .private(mask: .hash)) to=\(match.targetIP, privacy: .private(mask: .hash)) mode=passthrough"
            )
            finalHost = match.targetIP
            if let overridePort = match.targetPort {
                finalPort = UInt16(overridePort)
                ProxyLog.mitm.info("event=proxy.port_override outcome=success from=\(port) to=\(finalPort) mode=passthrough")
            }
        }

        guard let nwPort = NWEndpoint.Port(rawValue: finalPort) else {
            ProxyLog.mitm.error("event=proxy.passthrough_invalid_port outcome=failure port=\(finalPort)")
            close()
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(finalHost), port: nwPort)
        ProxyLog.mitm.info(
            "event=proxy.passthrough_connecting host=\(finalHost, privacy: .private(mask: .hash)) port=\(finalPort)"
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        serverConnection = conn

        let capturedHost = finalHost
        let capturedPort = finalPort
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup:
                ProxyLog.mitm.debug(
                    "event=proxy.passthrough_state state=setup host=\(capturedHost, privacy: .private(mask: .hash))"
                )
            case .preparing:
                ProxyLog.mitm.debug(
                    "event=proxy.passthrough_state state=preparing host=\(capturedHost, privacy: .private(mask: .hash))"
                )
            case .ready:
                ProxyLog.mitm.info(
                    "event=proxy.passthrough_ready outcome=success host=\(capturedHost, privacy: .private(mask: .hash)) port=\(capturedPort)"
                )
                let capturedHash = LogRedaction.hash(capturedHost)
                self.eventLog?.append(type: "passthrough_ready", msg: "\(capturedHash):\(capturedPort)")
                if !initialData.isEmpty {
                    ProxyLog.mitm.debug("event=proxy.passthrough_send_initial host=\(capturedHost, privacy: .private(mask: .hash)) bytes=\(initialData.count)")
                    self.sendToServer(initialData, completion: .contentProcessed { _ in })
                }
                self.pipeClientToServer()
                self.pipeServerToClient()
            case let .waiting(error):
                if logThrottle.shouldLog(key: "proxy.passthrough_state.waiting.\(capturedHost)", minInterval: 5) {
                    ProxyLog.mitm.debug(
                        "event=proxy.passthrough_state state=waiting host=\(capturedHost, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            case let .failed(error):
                ProxyLog.mitm.error("event=proxy.passthrough_failed outcome=failure host=\(capturedHost, privacy: .private(mask: .hash)) port=\(capturedPort) error=\(error.localizedDescription, privacy: .public)")
                let capturedHash = LogRedaction.hash(capturedHost)
                let errorType = String(describing: type(of: error))
                let errorHash = LogRedaction.hash(error.localizedDescription)
                self.eventLog?.append(
                    type: "passthrough_failed",
                    msg: "\(capturedHash):\(capturedPort) error_type=\(errorType) error_hash=\(errorHash)"
                )
                self.close()
            case .cancelled:
                ProxyLog.mitm.debug("event=proxy.passthrough_state state=cancelled host=\(capturedHost, privacy: .private(mask: .hash))")
            @unknown default:
                ProxyLog.mitm.debug("event=proxy.passthrough_state state=unknown host=\(capturedHost, privacy: .private(mask: .hash))")
            }
        }
        conn.start(queue: queue)
    }

    private func pipeClientToServer() {
        guard let serverConnection else { close(); return }
        guard !isClosed else { return }
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard !self.isClosed else { return }
            if let error {
                ProxyLog.mitm.error("event=proxy.passthrough_client_read outcome=failure error=\(error.localizedDescription, privacy: .public)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.sendToServer(data, completion: .contentProcessed { _ in })
            }
            if isComplete {
                self.close()
            } else if !self.isClosed {
                self.pipeClientToServer()
            }
        }
    }

    private func pipeServerToClient() {
        guard !isClosed else { return }
        serverConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard !self.isClosed else { return }
            if let error {
                ProxyLog.mitm.error("event=proxy.passthrough_server_read outcome=failure error=\(error.localizedDescription, privacy: .public)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.sendToClient(data, completion: .contentProcessed { _ in })
            }
            if isComplete {
                self.close()
            } else if !self.isClosed {
                self.pipeServerToClient()
            }
        }
    }

    private func handleHTTPSData() {
        // Rule: HTTPS payloads after CONNECT must be handled by TLSProxyConnection.

        if tlsProxyConnection != nil {
            requestBuffer.removeAll()
            return
        }

        ProxyLog.mitm.warning("event=proxy.https_data_no_tls outcome=failure")

        // Rationale: Fall back to passthrough forwarding when TLS proxy setup fails.
        forwardToServer(requestBuffer)
        requestBuffer.removeAll()
    }

    // MARK: - HTTP Handling

    private func handleHTTPRequest() {
        let headerEndMarker = "\r\n\r\n".data(using: .utf8)!
        guard let headerEndRange = requestBuffer.range(of: headerEndMarker) else {
            // Rule: Cap header size at 8 KB.
            if requestBuffer.count > 8192 {
                ProxyLog.mitm.error("event=proxy.http_headers_exceeded outcome=failure max_size=8192")
                close()
            }
            return
        }

        let headerData = requestBuffer[..<headerEndRange.lowerBound]
        let bodyData = Data(requestBuffer[headerEndRange.upperBound...])

        guard let headersString = String(data: headerData, encoding: .utf8) else {
            ProxyLog.mitm.error("event=proxy.http_headers_decode outcome=failure")
            close()
            return
        }

        let headerMetadata = parseRequestHeaders(headersString)
        if let contentLength = headerMetadata.contentLength, bodyData.count < contentLength {
            return
        }

        if headerMetadata.isChunked, !isChunkedBodyComplete(bodyData) {
            return
        }

        let rawBodyLength: Int =
            if let contentLength = headerMetadata.contentLength {
                contentLength
            } else if headerMetadata.isChunked, let chunkedEndIndex = HTTPParser.chunkedBodyEndIndex(bodyData) {
                chunkedEndIndex
            } else {
                0
            }

        let bodySlice = Data(bodyData.prefix(rawBodyLength))
        let effectiveBodyData: Data =
            if headerMetadata.isChunked, let decoded = HTTPParser.decodeChunkedBody(bodySlice) {
                decoded
            } else {
                bodySlice
            }

        let requestEndIndex = headerEndRange.upperBound + rawBodyLength
        guard requestEndIndex <= requestBuffer.count else {
            return
        }

        let remainingData = Data(requestBuffer[requestEndIndex...])
        requestBuffer = remainingData

        guard let parsedRequest = parseHTTPRequest(headersString, bodyData: effectiveBodyData) else {
            ProxyLog.mitm.error("event=proxy.http_parse outcome=failure")
            close()
            return
        }

        if isWebSocketUpgrade(parsedRequest.headers) {
            // Concurrency: Pause client reads during WebSocket handoff to avoid concurrent receives.
            pauseClientReads = true
            handleWebSocketUpgrade(parsedRequest, body: effectiveBodyData)
            return
        }

        guard
            let resolved = resolveHTTPDestination(
                requestTarget: parsedRequest.url,
                headers: parsedRequest.headers
            )
        else {
            ProxyLog.mitm.error("event=proxy.http_no_destination outcome=failure")
            close()
            return
        }
        targetHost = resolved.host
        targetPort = resolved.port

        let flowId = UUID()
        if logSampler.shouldLog(key: "proxy.request_received.\(connectionId)", first: 5, every: 200) {
            ProxyLog.mitm.info(
                "event=proxy.request_received outcome=success method=\(parsedRequest.method, privacy: .public) url=\(resolved.absoluteURL, privacy: .private(mask: .hash)) request_id=\(flowId.uuidString, privacy: .public) connection_id=\(self.connectionId)"
            )
        }
        capturedRequest = CapturedRequest(
            id: flowId,
            url: resolved.absoluteURL,
            method: parsedRequest.method,
            headers: parsedRequest.headers,
            body: parsedRequest.body,
            bodyData: parsedRequest.bodyData,
            // Rationale: Use per-request timing so keep-alive requests do not share timestamps.
            startTime: Date(),
            wasRewritten: false,
            isMocked: false,
            isReplayed: false,
            appliedScriptName: nil,
            hitBreakpoint: false,
            retryAttempts: 0
        )

        Task { [weak self] in
            guard let self else { return }

            let requestBodyData = effectiveBodyData.isEmpty ? nil : effectiveBodyData
            let result = await RequestInterceptor.shared.interceptRequest(
                flowId: flowId,
                url: resolved.absoluteURL,
                method: parsedRequest.method,
                headers: parsedRequest.headers,
                body: requestBodyData
            )

            switch result {
            case .blocked:
                self.performOnQueue {
                    ProxyLog.interceptor.info(
                        "event=intercept.request_blocked outcome=success url=\(resolved.absoluteURL, privacy: .private(mask: .hash)) request_id=\(flowId.uuidString, privacy: .public)"
                    )
                    let shouldClose = self.shouldCloseConnection(for: parsedRequest)
                    let response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"
                    guard let responseData = response.data(using: .utf8) else {
                        ProxyLog.mitm.error("event=proxy.response_encode outcome=failure")
                        self.close()
                        return
                    }
                    let charset = BodyStorage.extractCharset(from: parsedRequest.headers)
                    let blockedRequestBody = requestBodyData ?? Data()
                    var blockedRequest = NetworkRequest(
                        id: flowId,
                        url: resolved.absoluteURL,
                        method: HTTPMethod(rawValue: parsedRequest.method) ?? .get,
                        statusCode: 403,
                        statusMessage: "Blocked",
                        timestamp: self.capturedRequest?.startTime ?? Date(),
                        duration: Date().timeIntervalSince(self.capturedRequest?.startTime ?? Date()),
                        requestHeaders: self.capturedRequestHeaders(from: parsedRequest.headers),
                        responseHeaders: self.captureConfig.captureHeaders
                            ? [TraceHTTPHeader(key: "X-Trace-Note", value: "Blocked by rule")]
                            : [],
                        requestBody: (self.captureBodies && self.maxCapturedBodyBytes > 0 && !blockedRequestBody.isEmpty)
                            ? BodyStorage.from(
                                data: Data(blockedRequestBody.prefix(self.maxCapturedBodyBytes)),
                                charset: charset,
                                maxSize: self.maxCapturedBodyBytes
                            )
                            : .empty,
                        responseBody: .empty
                    )
                    blockedRequest.wasBlocked = true
                    blockedRequest.extractHTTPFields()
                    NetworkThrottlingController.shared.applyMetadata(to: &blockedRequest)
                    self.onRequestCaptured?(blockedRequest)
                    self.sendToClient(responseData, completion: .contentProcessed { _ in })
                    if shouldClose {
                        self.close()
                    } else if !self.requestBuffer.isEmpty {
                        self.handleClientData()
                    }
                }

            case let .failed(failure):
                self.performOnQueue {
                    ProxyLog.interceptor.warning(
                        "event=intercept.request_failed outcome=simulated failure=\(failure.rawValue, privacy: .public) url=\(resolved.absoluteURL, privacy: .private(mask: .hash)) request_id=\(flowId.uuidString, privacy: .public)"
                    )
                    switch failure {
                    case .timeout:
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            self?.close()
                        }
                    case .connectionReset, .dropConnection, .packetLoss:
                        self.close()
                    }
                }

            case let .mocked(mockRequest):
                self.performOnQueue {
                    ProxyLog.interceptor.info(
                        "event=intercept.request_mocked outcome=success url=\(resolved.absoluteURL, privacy: .private(mask: .hash)) request_id=\(flowId.uuidString, privacy: .public)"
                    )
                    let shouldClose = self.shouldCloseConnection(for: parsedRequest)

                    var responseString = "HTTP/1.1 \(mockRequest.statusCode)"
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
                    if !responseBodyData.isEmpty {
                        responseString += "Content-Length: \(responseBodyData.count)\r\n"
                    }

                    responseString += "\r\n"

                    guard let responseData = responseString.data(using: .utf8) else {
                        ProxyLog.mitm.error("event=proxy.mock_response_encode outcome=failure")
                        self.close()
                        return
                    }
                    var fullResponse = Data()
                    fullResponse.append(responseData)
                    if !responseBodyData.isEmpty {
                        fullResponse.append(responseBodyData)
                    }
                    self.sendToClient(fullResponse, completion: .contentProcessed { _ in })

                    self.onRequestCaptured?(mockRequest)
                    if shouldClose {
                        self.close()
                    } else if !self.requestBuffer.isEmpty {
                        self.handleClientData()
                    }
                }

            case let .modified(modifiedRequest):
                let pipeline = await self.determineResponsePipeline(for: modifiedRequest.url)
                self.performOnQueue {
                    ProxyLog.interceptor.info(
                        "event=intercept.request_modified outcome=success url=\(modifiedRequest.url, privacy: .private(mask: .hash)) request_id=\(flowId.uuidString, privacy: .public)"
                    )

                    // Rationale: Preserve the original per-request start time from initial parsing.
                    let requestStartTime = self.capturedRequest?.startTime ?? Date()

                    var headersDict = Dictionary(uniqueKeysWithValues: modifiedRequest.requestHeaders.map { ($0.key, $0.value) })
                    let originalBodyData = requestBodyData ?? Data()
                    let body: Data
                    if modifiedRequest.requestBodyModified {
                        if let encodingKey = headersDict.keys.first(where: { $0.lowercased() == "content-encoding" }) {
                            headersDict.removeValue(forKey: encodingKey)
                        }
                        body = modifiedRequest.requestBody.getData() ?? Data()
                    } else {
                        body = originalBodyData
                    }

                    guard
                        let forward = self.buildForwardHTTPData(
                            method: modifiedRequest.method.rawValue,
                            requestTarget: modifiedRequest.url,
                            originalHeaders: headersDict,
                            body: body
                        )
                    else {
                        self.close()
                        return
                    }

                    self.responsePipeline = pipeline
                    self.didForwardInitialResponseBufferToClient = false
                    self.responseBodyBytesReceived = 0
                    self.finalChunkMarkerSeen = false
                    self.chunkedTail.removeAll()

                    self.targetHost = forward.host
                    self.targetPort = forward.port
                    self.capturedRequest = CapturedRequest(
                        id: flowId,
                        url: forward.absoluteURL,
                        method: modifiedRequest.method.rawValue,
                        headers: forward.forwardHeaders,
                        body: modifiedRequest.requestBody.getString(),
                        bodyData: modifiedRequest.requestBody.getData(),
                        startTime: requestStartTime,
                        wasRewritten: modifiedRequest.wasRewritten,
                        isMocked: modifiedRequest.isMocked,
                        isReplayed: modifiedRequest.isReplayed,
                        appliedScriptName: modifiedRequest.appliedScriptName,
                        hitBreakpoint: modifiedRequest.hitBreakpoint,
                        retryAttempts: modifiedRequest.retryAttempts
                    )

                    self.forwardToServer(forward.data)

                    if !self.requestBuffer.isEmpty && !self.isClosed {
                        self.handleClientData()
                    }
                }
            }
        }
    }

    // MARK: - Server Communication

    private func forwardToServer(_ data: Data) {
        guard let host = targetHost else {
            ProxyLog.mitm.error("event=proxy.forward_no_host outcome=failure")
            close()
            return
        }

        guard !isClosed else {
            ProxyLog.mitm.debug("event=proxy.forward_closed outcome=skipped")
            return
        }

        if serverConnection == nil {
            var finalHost = host
            var finalPort = targetPort

            if let match = hostsManager.matchingEntry(for: host) {
                ProxyLog.mitm.info("event=proxy.host_override outcome=success from=\(host, privacy: .private(mask: .hash)) to=\(match.targetIP, privacy: .private(mask: .hash))")
                finalHost = match.targetIP
                if let overridePort = match.targetPort {
                    finalPort = UInt16(overridePort)
                    ProxyLog.mitm.info("event=proxy.port_override outcome=success from=\(self.targetPort) to=\(finalPort)")
                }
            }

            guard let port = NWEndpoint.Port(rawValue: finalPort) else {
                ProxyLog.mitm.error("event=proxy.invalid_port outcome=failure port=\(finalPort)")
                close()
                return
            }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(finalHost),
                port: port
            )

            let connection = NWConnection(to: endpoint, using: .tcp)

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    ProxyLog.mitm.info(
                        "event=proxy.server_connected outcome=success host=\(host, privacy: .private(mask: .hash)) port=\(self?.targetPort ?? 0)"
                    )
                    self?.readFromServer()
                case let .failed(error):
                    ProxyLog.mitm.error("event=proxy.server_connect_failed outcome=failure error=\(error.localizedDescription, privacy: .public)")
                    self?.close()
                default:
                    break
                }
            }

            connection.start(queue: queue)
            serverConnection = connection
        }

        sendToServer(data, completion: .contentProcessed { error in
            if let error {
                ProxyLog.mitm.error("event=proxy.server_send outcome=failure error=\(error.localizedDescription, privacy: .public)")
            }
        })
    }

    private func readFromServer() {
        serverConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                ProxyLog.mitm.error("event=proxy.server_read outcome=failure error=\(error.localizedDescription, privacy: .public)")
                self.close()
                return
            }

            if let data, !data.isEmpty {
                if self.capturedRequest != nil {
                    switch self.responsePipeline {
                    case .bufferAndIntercept:
                        // Rationale: Buffer the full response so it can be intercepted before sending.
                        self.responseBuffer.append(data)

                        if !self.headersComplete {
                            self.parseResponseHeaders()

                            if self.headersComplete && self.isSSEResponse() {
                                self.handleSSEStream()
                                return
                            }

                            // Rationale: Switch to streaming when declared size exceeds the buffer limit.
                            if self.headersComplete,
                               let length = self.expectedContentLength,
                               length > self.maxResponseBufferSize {
                                ProxyLog.mitm.info("event=proxy.response_stream_switch outcome=success reason=content_length_exceeds_buffer length=\(length) limit=\(self.maxResponseBufferSize)")
                                self.switchToStreamingResponsePipelineAndFlushInitialBuffer(onFlushed: { [weak self] in
                                    guard let self else { return }
                                    if self.isStreamingResponseComplete() {
                                        self.finishStreamingResponseAndReset()
                                    }
                                    if !isComplete {
                                        self.readFromServer()
                                    } else {
                                        self.close()
                                    }
                                })
                                return
                            }
                        }

                        if self.responseBuffer.count > self.maxResponseBufferSize {
                            if self.headersComplete {
                                ProxyLog.mitm.warning("event=proxy.response_size_exceeded outcome=streaming max_size=\(self.maxResponseBufferSize)")
                                self.switchToStreamingResponsePipelineAndFlushInitialBuffer(onFlushed: { [weak self] in
                                    guard let self else { return }
                                    if self.isStreamingResponseComplete() {
                                        self.finishStreamingResponseAndReset()
                                    }
                                    if !isComplete {
                                        self.readFromServer()
                                    } else {
                                        self.close()
                                    }
                                })
                                return
                            }

                            if self.responseBuffer.range(of: "\r\n\r\n".data(using: .utf8)!) == nil {
                                ProxyLog.mitm.error("event=proxy.response_headers_exceeded outcome=failure max_size=\(self.maxResponseBufferSize)")
                                self.close()
                                return
                            }
                        }

                        if let completeRange = self.completeResponseRange() {
                            let responseData = Data(self.responseBuffer[..<completeRange.upperBound])
                            let remainder = Data(self.responseBuffer[completeRange.upperBound...])
                            self.processCompleteResponse(responseData)
                            self.responseBuffer = remainder
                            self.resetResponseState(preserveBuffer: !self.responseBuffer.isEmpty)

                            if self.capturedRequest == nil, !self.responseBuffer.isEmpty {
                                // No pending capture: forward remainder to keep the proxy transparent.
                                self.sendToClient(self.responseBuffer, completion: .contentProcessed { _ in })
                                self.responseBuffer.removeAll()
                            }
                        }

                    case .streamAndCapture:
                        let result = self.handleStreamingServerData(data)
                        if result.didStartSSE {
                            return
                        }

                        if let toSend = result.dataToSend {
                            self.sendToClient(toSend, completion: .contentProcessed { _ in
                                if result.didCompleteResponse {
                                    self.finishStreamingResponseAndReset()
                                }
                                if !isComplete {
                                    self.readFromServer()
                                } else {
                                    self.close()
                                }
                            })
                        } else {
                            if !isComplete {
                                self.readFromServer()
                            } else {
                                self.finishStreamingResponseAndReset()
                                self.close()
                            }
                        }
                        return
                    }
                } else {
                    self.sendToClient(data, completion: .contentProcessed { _ in })
                }
            }

            if !isComplete {
                self.readFromServer()
            } else {
                if self.capturedRequest != nil {
                    switch self.responsePipeline {
                    case .bufferAndIntercept:
                        if let completeRange = self.completeResponseRange(allowConnectionClose: true) {
                            let responseData = Data(self.responseBuffer[..<completeRange.upperBound])
                            let remainder = Data(self.responseBuffer[completeRange.upperBound...])
                            self.processCompleteResponse(responseData)
                            self.responseBuffer = remainder
                            self.resetResponseState(preserveBuffer: !self.responseBuffer.isEmpty)

                            if self.capturedRequest == nil, !self.responseBuffer.isEmpty {
                                self.sendToClient(self.responseBuffer, completion: .contentProcessed { _ in })
                                self.responseBuffer.removeAll()
                            }
                        } else if !self.responseBuffer.isEmpty {
                            // No framing info: best-effort forward whatever is left.
                            self.sendToClient(self.responseBuffer, completion: .contentProcessed { _ in })
                            self.responseBuffer.removeAll()
                        }
                    case .streamAndCapture:
                        self.finishStreamingResponseAndReset()
                    }
                }
                self.close()
            }
        }
    }

    private func resetResponseState(preserveBuffer: Bool = false) {
        // Safety: If a response capture was mid-flight, close and delete the partial spool file.
        cleanupActiveResponseBodyCapture()
        completedResponseBodyCapture = nil

        if !preserveBuffer {
            responseBuffer.removeAll()
        }
        headersComplete = false
        expectedContentLength = nil
        isChunkedTransfer = false
        responseHeaderEndOffset = nil
        responsePipeline = .bufferAndIntercept
        didForwardInitialResponseBufferToClient = false
        responseBodyBytesReceived = 0
        finalChunkMarkerSeen = false
        chunkedTail.removeAll()
        capturedRequest = nil
    }

    // MARK: - Response Buffering and Parsing

    private func parseResponseHeaders() {
        guard let headerEndMarker = "\r\n\r\n".data(using: .utf8),
              let headerEndRange = responseBuffer.range(of: headerEndMarker)
        else {
            return
        }

        headersComplete = true
        responseHeaderEndOffset = headerEndRange.upperBound

        let headerData = responseBuffer[..<headerEndRange.lowerBound]
        guard let headersString = String(data: headerData, encoding: .utf8) else {
            return
        }

        let lines = headersString.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-length:"),
               let colonIndex = line.firstIndex(of: ":") {
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(
                    in: .whitespaces)
                expectedContentLength = Int(value)
            }

            if line.lowercased().hasPrefix("transfer-encoding:"),
               line.lowercased().contains("chunked") {
                isChunkedTransfer = true
            }
        }
    }

    private func completeResponseRange(allowConnectionClose: Bool = false) -> Range<Int>? {
        guard let headerEndMarker = "\r\n\r\n".data(using: .utf8),
              let headerEndRange = responseBuffer.range(of: headerEndMarker)
        else {
            return nil
        }

        if !headersComplete {
            parseResponseHeaders()
        }

        let bodyStart = headerEndRange.upperBound
        let bodySlice = Data(responseBuffer[bodyStart...])

        if isChunkedTransfer {
            guard let endInBody = HTTPParser.chunkedBodyEndIndex(bodySlice) else {
                return nil
            }
            return responseBuffer.startIndex ..< (bodyStart + endInBody)
        }

        if let expectedLength = expectedContentLength {
            guard bodySlice.count >= expectedLength else { return nil }
            return responseBuffer.startIndex ..< (bodyStart + expectedLength)
        }

        if allowConnectionClose {
            return responseBuffer.startIndex ..< responseBuffer.endIndex
        }

        return nil
    }

    private func processCompleteResponse(_ responseData: Data) {
        guard let capturedRequest else {
            sendToClient(responseData, completion: .contentProcessed { _ in })
            return
        }

        guard let headerEndMarker = "\r\n\r\n".data(using: .utf8),
              let headerEndRange = responseData.range(of: headerEndMarker)
        else {
            sendToClient(responseData, completion: .contentProcessed { _ in })
            return
        }

        let headerData = responseData[..<headerEndRange.lowerBound]
        guard let headersString = String(data: headerData, encoding: .utf8),
              let statusLine = headersString.components(separatedBy: "\r\n").first
        else {
            sendToClient(responseData, completion: .contentProcessed { _ in })
            return
        }

        let parts = statusLine.split(separator: " ", maxSplits: 2)
        let statusCode = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        let statusMessage = parts.count >= 3 ? String(parts[2]) : nil

        // Rationale: Preserve duplicate headers (for example, Set-Cookie).
        let responseHeaders = parseResponseHeaders(headersString)

        var bodyData = Data(responseData[headerEndRange.upperBound...])
        let wasChunked = isChunkedTransfer
        var decodedChunked = false

        if isChunkedTransfer, let decoded = HTTPParser.decodeChunkedBody(bodyData) {
            bodyData = decoded
            decodedChunked = true
        }

        // Rationale: Extract charset for correct text decoding.
        let charset = BodyStorage.extractCharset(from: responseHeaders)
        let originalContentEncoding = responseHeaders.first(where: { $0.key.lowercased() == "content-encoding" })?.value

        if wasChunked && !decodedChunked {
            let passthroughData = responseData
            Task { [weak self] in
                guard let self else { return }
                let requestCharset = BodyStorage.extractCharset(from: capturedRequest.headers)
                let requestContentEncoding = capturedRequest.headers.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                let requestBodyStorage: BodyStorage = {
                    guard self.captureBodies, self.maxCapturedBodyBytes > 0 else { return .empty }
                    if let data = capturedRequest.bodyData, !data.isEmpty {
                        return BodyStorage.from(
                            data: data,
                            charset: requestCharset,
                            maxSize: self.maxCapturedBodyBytes,
                            contentEncoding: requestContentEncoding
                        )
                    }
                    if let body = capturedRequest.body, !body.isEmpty {
                        return BodyStorage.from(
                            string: body,
                            charset: requestCharset,
                            maxSize: self.maxCapturedBodyBytes
                        )
                    }
                    return .empty
                }()
                let responseBodyStorage: BodyStorage = {
                    guard self.captureBodies, self.maxCapturedBodyBytes > 0, !bodyData.isEmpty else { return .empty }
                    return BodyStorage.from(
                        data: bodyData,
                        charset: charset,
                        maxSize: self.maxCapturedBodyBytes,
                        contentEncoding: originalContentEncoding
                    )
                }()
                var networkRequest = NetworkRequest(
                    id: capturedRequest.id,
                    url: capturedRequest.url,
                    method: HTTPMethod(rawValue: capturedRequest.method) ?? .get,
                    statusCode: statusCode,
                    statusMessage: statusMessage,
                    timestamp: capturedRequest.startTime,
                    duration: Date().timeIntervalSince(capturedRequest.startTime),
                    requestHeaders: self.capturedRequestHeaders(from: capturedRequest.headers),
                    responseHeaders: self.capturedResponseHeaders(responseHeaders),
                    requestBody: requestBodyStorage,
                    responseBody: responseBodyStorage
                )
                networkRequest.wasRewritten = capturedRequest.wasRewritten
                networkRequest.isMocked = capturedRequest.isMocked
                networkRequest.isReplayed = capturedRequest.isReplayed
                networkRequest.appliedScriptName = capturedRequest.appliedScriptName
                networkRequest.hitBreakpoint = capturedRequest.hitBreakpoint
                networkRequest.retryAttempts = capturedRequest.retryAttempts
                networkRequest.extractHTTPFields()
                NetworkThrottlingController.shared.applyMetadata(to: &networkRequest)
                self.onRequestCaptured?(networkRequest)
                self.performOnQueue {
                    self.sendToClient(passthroughData, completion: .contentProcessed { _ in })
                }
            }
            return
        }

        Task {
            let requestCharset = BodyStorage.extractCharset(from: capturedRequest.headers)
            let requestContentEncoding = capturedRequest.headers.first(where: { $0.key.lowercased() == "content-encoding" })?.value
            let requestBodyStorage: BodyStorage = {
                guard self.captureBodies, self.maxCapturedBodyBytes > 0 else { return .empty }
                if let data = capturedRequest.bodyData, !data.isEmpty {
                    return BodyStorage.from(
                        data: data,
                        charset: requestCharset,
                        maxSize: self.maxCapturedBodyBytes,
                        contentEncoding: requestContentEncoding
                    )
                }
                if let body = capturedRequest.body, !body.isEmpty {
                    return BodyStorage.from(
                        string: body,
                        charset: requestCharset,
                        maxSize: self.maxCapturedBodyBytes
                    )
                }
                return .empty
            }()
            let responseBodyStorage: BodyStorage = {
                guard self.captureBodies, self.maxCapturedBodyBytes > 0, !bodyData.isEmpty else { return .empty }
                return BodyStorage.from(
                    data: bodyData,
                    charset: charset,
                    maxSize: self.maxCapturedBodyBytes,
                    contentEncoding: originalContentEncoding
                )
            }()
            var networkRequest = NetworkRequest(
                id: capturedRequest.id,
                url: capturedRequest.url,
                method: HTTPMethod(rawValue: capturedRequest.method) ?? .get,
                statusCode: statusCode,
                statusMessage: statusMessage,
                timestamp: capturedRequest.startTime,
                duration: Date().timeIntervalSince(capturedRequest.startTime),
                requestHeaders: capturedRequestHeaders(from: capturedRequest.headers),
                responseHeaders: capturedResponseHeaders(responseHeaders),
                requestBody: requestBodyStorage,
                responseBody: responseBodyStorage
            )
            networkRequest.wasRewritten = capturedRequest.wasRewritten
            networkRequest.isMocked = capturedRequest.isMocked
            networkRequest.isReplayed = capturedRequest.isReplayed
            networkRequest.appliedScriptName = capturedRequest.appliedScriptName
            networkRequest.hitBreakpoint = capturedRequest.hitBreakpoint
            networkRequest.retryAttempts = capturedRequest.retryAttempts

            networkRequest.extractHTTPFields()

            NetworkThrottlingController.shared.applyMetadata(to: &networkRequest)
            let responseBodyData = bodyData.isEmpty ? nil : bodyData
            let modifiedRequest = await RequestInterceptor.shared.interceptResponse(
                request: networkRequest,
                statusCode: statusCode,
                statusMessage: statusMessage ?? "",
                headers: responseHeaders,
                body: responseBodyData
            )

            self.performOnQueue { [weak self] in
                guard let self else { return }
                let decompressed = networkRequest.responseBody.getCompressionInfo()?.decompressionSuccess == true
                let hadContentEncodingHeader = (originalContentEncoding != nil && !(originalContentEncoding ?? "").isEmpty && originalContentEncoding?.lowercased() != "identity")

                var modifiedResponseString = "HTTP/1.1 \(modifiedRequest.statusCode)"
                if let statusMsg = modifiedRequest.statusMessage {
                    modifiedResponseString += " \(statusMsg)"
                }
                modifiedResponseString += "\r\n"

                let sanitizedHeaders: [TraceHTTPHeader] = {
                    if wasChunked && !decodedChunked {
                        return modifiedRequest.responseHeaders.filter { $0.key.lowercased() != "content-length" }
                    }
                    return modifiedRequest.responseHeaders.filter {
                        let lower = $0.key.lowercased()
                        if lower == "transfer-encoding" || lower == "content-length" {
                            return false
                        }
                        if decompressed && hadContentEncodingHeader && lower == "content-encoding" {
                            return false
                        }
                        return true
                    }
                }()

                for header in sanitizedHeaders {
                    modifiedResponseString += "\(header.key): \(header.value)\r\n"
                }

                let modifiedBodyData =
                    modifiedRequest.responseBody.getData()
                        ?? modifiedRequest.responseBody.getString()?.data(using: .utf8)
                        ?? Data()
                if !wasChunked || decodedChunked {
                    modifiedResponseString += "Content-Length: \(modifiedBodyData.count)\r\n"
                }

                modifiedResponseString += "\r\n"

                guard let headersData = modifiedResponseString.data(using: .utf8) else {
                    ProxyLog.mitm.error("event=proxy.response_headers_encode outcome=failure")
                    return
                }
                var modifiedData = Data()
                modifiedData.append(headersData)
                modifiedData.append(modifiedBodyData)

                self.onRequestCaptured?(modifiedRequest)
                self.sendToClient(modifiedData, completion: .contentProcessed { _ in })
            }
        }
    }

    private func captureTruncatedResponse() {
        guard let capturedRequest else { return }

        let headerEndMarker = "\r\n\r\n".data(using: .utf8)!
        var statusCode = 0
        var statusMessage: String?
        var headers: [String: String] = [:]
        var bodyData = Data()

        if let headerEndRange = responseBuffer.range(of: headerEndMarker),
           let headersString = String(
               data: responseBuffer[..<headerEndRange.lowerBound], encoding: .utf8
           ),
           let statusLine = headersString.components(separatedBy: "\r\n").first {
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            statusCode = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
            statusMessage = parts.count >= 3 ? String(parts[2]) : nil

            let lines = headersString.components(separatedBy: "\r\n")
            for (index, line) in lines.enumerated() {
                if index == 0 { continue }
                if line.isEmpty { break }

                if let colonIndex = line.firstIndex(of: ":") {
                    let key = String(line[..<colonIndex])
                    let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(
                        in: .whitespaces)
                    headers[key] = value
                }
            }

            bodyData = Data(responseBuffer[headerEndRange.upperBound...])
        }

        let charset = BodyStorage.extractCharset(from: headers)
        let responseContentEncoding = headers.first(where: { $0.key.lowercased() == "content-encoding" })?.value
        let requestCharset = BodyStorage.extractCharset(from: capturedRequest.headers)
        let requestContentEncoding = capturedRequest.headers.first(where: { $0.key.lowercased() == "content-encoding" })?.value
        let requestBodyStorage: BodyStorage = {
            guard self.captureBodies, self.maxCapturedBodyBytes > 0 else { return .empty }
            if let data = capturedRequest.bodyData, !data.isEmpty {
                return BodyStorage.from(
                    data: data,
                    charset: requestCharset,
                    maxSize: self.maxCapturedBodyBytes,
                    contentEncoding: requestContentEncoding
                )
            }
            if let body = capturedRequest.body, !body.isEmpty {
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

            if let capture = self.completedResponseBodyCapture, capture.bytesWritten > 0 {
                if capture.truncated {
                    // Keep only a preview when the configured capture limit was exceeded.
                    let preview: Data = {
                        guard let handle = try? FileHandle(forReadingFrom: capture.url) else { return Data() }
                        defer { try? handle.close() }
                        return (try? handle.read(upToCount: BodyStorage.previewSize)) ?? Data()
                    }()
                    try? FileManager.default.removeItem(at: capture.url)

                    let totalHint = (self.expectedContentLength ?? (capture.bytesWritten + 1))
                    return .truncated(preview, totalSize: totalHint, charset: charset, compressionInfo: nil)
                }

                // Small bodies: inline for easier sharing/export and to reduce file churn.
                if capture.bytesWritten <= BodyStorage.inlineThreshold,
                   let data = try? Data(contentsOf: capture.url) {
                    try? FileManager.default.removeItem(at: capture.url)
                    return .inline(data, charset: charset, compressionInfo: nil)
                }

                return .file(capture.url, charset: charset, compressionInfo: nil)
            }

            guard !bodyData.isEmpty else { return .empty }
            return BodyStorage.from(
                data: bodyData,
                charset: charset,
                maxSize: self.maxCapturedBodyBytes,
                contentEncoding: responseContentEncoding
            )
        }()

        var networkRequest = NetworkRequest(
            id: capturedRequest.id,
            url: capturedRequest.url,
            method: HTTPMethod(rawValue: capturedRequest.method) ?? .get,
            statusCode: statusCode,
            statusMessage: statusMessage,
            timestamp: capturedRequest.startTime,
            duration: Date().timeIntervalSince(capturedRequest.startTime),
            requestHeaders: capturedRequestHeaders(from: capturedRequest.headers),
            responseHeaders: capturedResponseHeaders(headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }),
            requestBody: requestBodyStorage,
            responseBody: responseBodyStorage
        )
        networkRequest.wasRewritten = capturedRequest.wasRewritten
        networkRequest.isMocked = capturedRequest.isMocked
        networkRequest.isReplayed = capturedRequest.isReplayed
        networkRequest.appliedScriptName = capturedRequest.appliedScriptName
        networkRequest.hitBreakpoint = capturedRequest.hitBreakpoint
        networkRequest.retryAttempts = capturedRequest.retryAttempts

        networkRequest.extractHTTPFields()

        NetworkThrottlingController.shared.applyMetadata(to: &networkRequest)
        onRequestCaptured?(networkRequest)
    }

    // MARK: - HTTP Parsing

    private func parseHTTPRequest(_ headersString: String, bodyData: Data) -> ParsedHTTPRequest? {
        let lines = headersString.components(separatedBy: "\r\n")

        guard let firstLine = lines.first else {
            return nil
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            return nil
        }

        let method = String(parts[0])
        let url = String(parts[1])

        var headers: [String: String] = [:]

        for (index, line) in lines.enumerated() {
            if index == 0 { continue }
            if line.isEmpty { break }

            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex])
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(
                    in: .whitespaces)
                headers[key] = value
            }
        }

        // Rule: Never retain an unbounded HTTP body in memory for capture display.
        // Capture is limited by `CaptureConfiguration.maxBodySize` (clamped for extension stability).
        let capturedBodyData = if captureBodies, maxCapturedBodyBytes > 0, !bodyData.isEmpty {
            Data(bodyData.prefix(maxCapturedBodyBytes))
        } else {
            Data()
        }
        let bodyString = capturedBodyData.isEmpty ? nil : String(data: capturedBodyData, encoding: .utf8)

        let httpVersion = parts.count >= 3 ? String(parts[2]) : nil
        return ParsedHTTPRequest(
            method: method,
            url: url,
            httpVersion: httpVersion,
            headers: headers,
            body: bodyString,
            bodyData: capturedBodyData
        )
    }

    /// Parses request headers to extract metadata without allocating a full request object.
    private func parseRequestHeaders(_ headersString: String) -> (
        contentLength: Int?, isChunked: Bool
    ) {
        let lines = headersString.components(separatedBy: "\r\n")
        var contentLength: Int?
        var isChunked = false

        for (index, line) in lines.enumerated() {
            if index == 0 { continue }
            if line.isEmpty { break }

            let lowercasedLine = line.lowercased()
            if lowercasedLine.hasPrefix("content-length:"),
               let colonIndex = line.firstIndex(of: ":") {
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(
                    in: .whitespaces)
                contentLength = Int(value)
            }

            if lowercasedLine.hasPrefix("transfer-encoding:"),
               lowercasedLine.contains("chunked") {
                isChunked = true
            }
        }

        if isChunked {
            contentLength = nil
        }

        return (contentLength, isChunked)
    }

    /// Checks if a chunked body buffer has received the terminating chunk.
    private func isChunkedBodyComplete(_ body: Data) -> Bool {
        HTTPParser.chunkedBodyEndIndex(body) != nil
    }

    // MARK: - WebSocket Handling

    private func isWebSocketUpgrade(_ headers: [String: String]) -> Bool {
        let upgrade = headers.first(where: { $0.key.lowercased() == "upgrade" })?.value.lowercased() ?? ""
        let connection = headers.first(where: { $0.key.lowercased() == "connection" })?.value.lowercased() ?? ""

        return upgrade.contains("websocket") && connection.contains("upgrade")
    }

    // MARK: - SSE Handling

    private func isSSEResponse() -> Bool {
        guard let headerEndMarker = "\r\n\r\n".data(using: .utf8),
              let headerEndRange = responseBuffer.range(of: headerEndMarker)
        else {
            return false
        }

        let headerData = responseBuffer[..<headerEndRange.lowerBound]
        guard let headersString = String(data: headerData, encoding: .utf8) else {
            return false
        }

        let lines = headersString.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("content-type:") {
                return SSEParser.isSSEContentType(line)
            }
        }
        return false
    }

    private func handleSSEStream() {
        ProxyLog.mitm.info("event=proxy.sse_detected outcome=success url=\(self.capturedRequest?.url ?? "unknown", privacy: .private(mask: .hash))")

        isSSE = true

        guard let headerEndMarker = "\r\n\r\n".data(using: .utf8),
              let headerEndRange = responseBuffer.range(of: headerEndMarker)
        else {
            return
        }

        let headerData = responseBuffer[..<headerEndRange.lowerBound]
        guard let headersString = String(data: headerData, encoding: .utf8) else {
            return
        }

        let bodyStartIndex = headerEndRange.upperBound
        let initialBodyData: Data =
            (bodyStartIndex < responseBuffer.endIndex)
                ? Data(responseBuffer[bodyStartIndex ..< responseBuffer.endIndex])
                : Data()

        let responseHeaders = parseResponseHeaders(headersString)
        let requestHeaders =
            capturedRequest.map { capturedRequestHeaders(from: $0.headers) } ?? []

        let handler = SSEHandler(
            clientConnection: clientConnection,
            serverConnection: serverConnection,
            url: capturedRequest?.url ?? "",
            requestHeaders: requestHeaders,
            responseHeaders: capturedResponseHeaders(responseHeaders)
        )

        handler.start(onUpdate: { _ in }, initialBodyData: initialBodyData)

        sseHandler = handler

        sendToClient(responseBuffer, completion: .contentProcessed { _ in })

        requestBuffer.removeAll()
        responseBuffer.removeAll()
        capturedRequest = nil
    }

    private func handleWebSocketUpgrade(_ request: ParsedHTTPRequest, body: Data) {
        ProxyLog.mitm.info("event=proxy.websocket_upgrade outcome=success url=\(request.url, privacy: .private(mask: .hash))")

        isWebSocket = true

        guard
            let forward = buildForwardHTTPData(
                method: request.method,
                requestTarget: request.url,
                originalHeaders: request.headers,
                body: body
            )
        else {
            ProxyLog.mitm.error("event=proxy.websocket_no_destination outcome=failure")
            close()
            return
        }

        targetHost = forward.host
        targetPort = forward.port
        capturedRequest = CapturedRequest(
            id: UUID(),
            url: forward.absoluteURL,
            method: request.method,
            headers: forward.forwardHeaders,
            body: request.body,
            bodyData: request.bodyData,
            startTime: startTime,
            wasRewritten: false,
            isMocked: false,
            isReplayed: false,
            appliedScriptName: nil,
            hitBreakpoint: false,
            retryAttempts: 0
        )

        if serverConnection == nil {
            guard let host = targetHost else {
                close()
                return
            }

            guard let port = NWEndpoint.Port(rawValue: self.targetPort) else {
                ProxyLog.mitm.error("event=proxy.websocket_invalid_port outcome=failure port=\(self.targetPort)")
                close()
                return
            }

            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: port
            )

            let connection = NWConnection(to: endpoint, using: .tcp)

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }

                switch state {
                case .ready:
                    ProxyLog.mitm.debug("event=proxy.websocket_server_ready outcome=success host=\(host, privacy: .private(mask: .hash)) port=\(self.targetPort)")

                    self.serverConnection?.send(
                        content: forward.data,
                        completion: .contentProcessed { [weak self] error in
                            if let error {
                                ProxyLog.mitm.error("event=proxy.websocket_upgrade_send outcome=failure error=\(error.localizedDescription, privacy: .public)")
                                self?.close()
                            } else {
                                self?.readWebSocketUpgradeResponse()
                            }
                        }
                    )
                case let .failed(error):
                    ProxyLog.mitm.error("event=proxy.websocket_server_failed outcome=failure error=\(error.localizedDescription, privacy: .public)")
                    self.close()
                default:
                    break
                }
            }

            connection.start(queue: queue)
            serverConnection = connection
        }
    }

    private func readWebSocketUpgradeResponse() {
        serverConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                ProxyLog.mitm.error("event=proxy.websocket_upgrade_read outcome=failure error=\(error.localizedDescription, privacy: .public)")
                self.close()
                return
            }

            if let data, !data.isEmpty {
                // Edge case: The upgrade response may be split and may include frames after headers.
                self.responseBuffer.append(data)

                self.sendToClient(
                    data,
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }

                        if let error {
                            ProxyLog.mitm.error("event=proxy.websocket_upgrade_response outcome=failure error=\(error.localizedDescription, privacy: .public)")
                            self.close()
                            return
                        }

                        guard let headerEndMarker = "\r\n\r\n".data(using: .utf8),
                              let headerEndRange = self.responseBuffer.range(of: headerEndMarker)
                        else {
                            self.readWebSocketUpgradeResponse()
                            return
                        }

                        let headerData = self.responseBuffer[..<headerEndRange.lowerBound]
                        let initialServerData: Data =
                            (headerEndRange.upperBound < self.responseBuffer.endIndex)
                                ? Data(self.responseBuffer[headerEndRange.upperBound ..< self.responseBuffer.endIndex])
                                : Data()

                        guard let responseString = String(data: headerData, encoding: .utf8) else {
                            self.close()
                            return
                        }

                        let responseHeaders = self.parseResponseHeaders(responseString)
                        let requestHeaders =
                            self.capturedRequest.map { self.capturedRequestHeaders(from: $0.headers) } ?? []

                        ProxyLog.mitm.info("event=proxy.websocket_upgrade_complete outcome=success")

                        // Edge case: Buffered bytes after the HTTP request must be forwarded explicitly.
                        let initialClientData = self.requestBuffer

                        let wsHandler = WebSocketHandler(
                            clientConnection: self.clientConnection,
                            serverConnection: self.serverConnection,
                            url: self.capturedRequest?.url ?? "",
                            requestHeaders: requestHeaders,
                            responseHeaders: self.capturedResponseHeaders(responseHeaders)
                        )

                        wsHandler.start(
                            onUpdate: { _ in },
                            initialClientData: initialClientData,
                            initialServerData: initialServerData
                        )

                        self.webSocketHandler = wsHandler
                        self.requestBuffer.removeAll()
                        self.responseBuffer.removeAll()
                        self.capturedRequest = nil

                        if !initialClientData.isEmpty {
                            self.sendToServer(initialClientData, completion: .contentProcessed { _ in })
                        }
                    }
                )
            }
        }
    }

    private func parseResponseHeaders(_ responseString: String) -> [TraceHTTPHeader] {
        let lines = responseString.components(separatedBy: "\r\n")
        var headers: [TraceHTTPHeader] = []

        for (index, line) in lines.enumerated() {
            if index == 0 { continue }
            if line.isEmpty { break }

            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex])
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(
                    in: .whitespaces)
                headers.append(TraceHTTPHeader(key: key, value: value))
            }
        }

        return headers
    }

    private func buildHTTPData(requestLine: String, headers: [TraceHTTPHeader], body: Data) -> Data {
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

    private func shouldCloseConnection(for request: ParsedHTTPRequest) -> Bool {
        let connectionHeader = request.headers.first { $0.key.lowercased() == "connection" }?.value.lowercased()
        if let connectionHeader, connectionHeader.contains("close") {
            return true
        }

        if let version = request.httpVersion, version.uppercased().hasPrefix("HTTP/1.0") {
            return connectionHeader?.contains("keep-alive") != true
        }

        return false
    }

    private func performOnQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }

    private func performOnQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return block()
        }
        return queue.sync(execute: block)
    }

    // MARK: - Standard proxy request normalization (absolute-form -> origin-form)

    private struct ResolvedHTTPDestination {
        let host: String
        let port: UInt16
        let absoluteURL: String
        let originTarget: String
    }

    private struct ForwardHTTPData {
        let host: String
        let port: UInt16
        let absoluteURL: String
        let originTarget: String
        let forwardHeaders: [String: String]
        let data: Data
    }

    private func resolveHTTPDestination(
        requestTarget: String,
        headers: [String: String]
    ) -> ResolvedHTTPDestination? {
        // Handles absolute-form targets like "http(s)://host[:port]/path?query".
        if let url = URL(string: requestTarget), let scheme = url.scheme, let host = url.host {
            let lowerScheme = scheme.lowercased()
            let defaultPort: UInt16 = (lowerScheme == "https" || lowerScheme == "wss") ? 443 : 80
            let port = UInt16(url.port ?? Int(defaultPort))
            let originTarget = originFormTarget(from: requestTarget)
            return ResolvedHTTPDestination(
                host: host,
                port: port,
                absoluteURL: requestTarget,
                originTarget: originTarget
            )
        }

        // Handles origin-form targets like "/path?query" when the Host header is present.
        guard let hostValue = headers.first(where: { $0.key.lowercased() == "host" })?.value else {
            return nil
        }
        guard let (host, port) = parseHostAndOptionalPort(hostValue, defaultPort: 80) else {
            return nil
        }
        let originTarget = originFormTarget(from: requestTarget)
        let absoluteURL = makeAbsoluteURL(
            scheme: "http",
            host: host,
            port: port,
            requestTarget: originTarget
        )
        return ResolvedHTTPDestination(
            host: host,
            port: port,
            absoluteURL: absoluteURL,
            originTarget: originTarget
        )
    }

    private func buildForwardHTTPData(
        method: String,
        requestTarget: String,
        originalHeaders: [String: String],
        body: Data
    ) -> ForwardHTTPData? {
        guard let resolved = resolveHTTPDestination(requestTarget: requestTarget, headers: originalHeaders) else {
            return nil
        }

        // Rationale: Remove proxy-only headers and normalize content framing.
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

        let hostHeaderValue: String = if resolved.port == 80 {
            resolved.host
        } else {
            "\(resolved.host):\(resolved.port)"
        }
        headers["Host"] = hostHeaderValue

        // Rationale: Rebuild request bodies as identity bytes and use Content-Length framing.
        if !body.isEmpty {
            headers["Content-Length"] = "\(body.count)"
        }

        let forwardHeaders = headers
        let headerList = headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
        let requestLine = "\(method) \(resolved.originTarget) HTTP/1.1"
        let data = buildHTTPData(requestLine: requestLine, headers: headerList, body: body)

        return ForwardHTTPData(
            host: resolved.host,
            port: resolved.port,
            absoluteURL: resolved.absoluteURL,
            originTarget: resolved.originTarget,
            forwardHeaders: forwardHeaders,
            data: data
        )
    }

    private func originFormTarget(from requestTarget: String) -> String {
        // Handles origin-form or asterisk-form targets.
        if requestTarget.hasPrefix("/") || requestTarget == "*" {
            return requestTarget
        }
        // Strips scheme and authority from absolute-form targets.
        if let components = URLComponents(string: requestTarget) {
            // IMPORTANT: Preserve percent-encoding when reconstructing the request-target.
            // Using `components.query` (decoded) can introduce literal spaces into the HTTP/1.1
            // request line (e.g. `%20` -> `" "`), which yields an invalid request line and can
            // cause upstream servers (e.g. nginx) to return 400 immediately.
            var path = components.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let query = components.percentEncodedQuery, !query.isEmpty {
                path += "?\(query)"
            }
            return path
        }
        // Rationale: Fall back to best-effort when URL parsing fails.
        return requestTarget
    }

    private func makeAbsoluteURL(scheme: String, host: String, port: UInt16, requestTarget: String) -> String {
        let target: String = requestTarget.hasPrefix("/") ? requestTarget : (requestTarget == "*" ? "/" : "/\(requestTarget)")
        let authority: String = (port == 80) ? host : "\(host):\(port)"
        return "\(scheme)://\(authority)\(target)"
    }

    private func parseHostAndOptionalPort(_ value: String, defaultPort: UInt16) -> (String, UInt16)? {
        let hostPort = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostPort.isEmpty else { return nil }

        // Handles IPv6 bracket forms like "[::1]" or "[::1]:8080".
        if hostPort.hasPrefix("[") {
            guard let end = hostPort.firstIndex(of: "]") else { return nil }
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex) ..< end])
            let remainder = hostPort[hostPort.index(after: end)...]
            if remainder.hasPrefix(":") {
                guard let port = UInt16(remainder.dropFirst()) else { return nil }
                return (host, port)
            }
            return (host, defaultPort)
        }

        // Handles hostnames or IPv4 addresses with optional ":port".
        if let lastColon = hostPort.lastIndex(of: ":") {
            let hostPart = String(hostPort[..<lastColon])
            let portPart = hostPort[hostPort.index(after: lastColon)...]
            if let port = UInt16(portPart), !hostPart.isEmpty {
                return (hostPart, port)
            }
        }

        return (hostPort, defaultPort)
    }

    // MARK: - Streaming response mode helpers

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

    private func ensureActiveResponseBodyCapture() {
        guard captureBodies, maxCapturedBodyBytes > 0 else { return }
        guard activeResponseBodyCapture == nil else { return }
        guard let containerURL = bodyContainerURLForCapture() else { return }

        let bodiesDir = containerURL.appendingPathComponent("Bodies", isDirectory: true)
        try? FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)

        let fileURL = bodiesDir.appendingPathComponent(UUID().uuidString + ".bin")
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }

        let decoder: ChunkedTransferDecoder? = isChunkedTransfer ? ChunkedTransferDecoder() : nil
        activeResponseBodyCapture = ActiveBodyCapture(
            url: fileURL,
            handle: handle,
            bytesWritten: 0,
            truncated: false,
            chunkedDecoder: decoder
        )
    }

    private func appendToResponseBodyCapture(_ data: Data) {
        guard captureBodies, maxCapturedBodyBytes > 0, !data.isEmpty else { return }
        ensureActiveResponseBodyCapture()
        guard var capture = activeResponseBodyCapture else { return }

        // Even if capture is truncated, we still parse chunked framing to keep decoder state bounded.
        let remainingBytes = max(0, maxCapturedBodyBytes - capture.bytesWritten)
        if remainingBytes == 0 {
            capture.truncated = true
            if isChunkedTransfer {
                var decoder = capture.chunkedDecoder ?? ChunkedTransferDecoder()
                _ = decoder.feed(data, onBodyChunk: { _ in })
                capture.chunkedDecoder = decoder
            }
            activeResponseBodyCapture = capture
            return
        }

        if isChunkedTransfer {
            var decoder = capture.chunkedDecoder ?? ChunkedTransferDecoder()
            let (_, parseError) = decoder.feed(data, onBodyChunk: { chunk in
                guard !capture.truncated else { return }
                let remaining = max(0, maxCapturedBodyBytes - capture.bytesWritten)
                guard remaining > 0 else {
                    capture.truncated = true
                    return
                }

                let toWrite = chunk.count <= remaining ? chunk : chunk.prefix(remaining)
                do {
                    try capture.handle.write(contentsOf: toWrite)
                    capture.bytesWritten += toWrite.count
                    if chunk.count > remaining {
                        capture.truncated = true
                    }
                } catch {
                    ProxyLog.mitm.error(
                        "event=proxy.body_spool_write outcome=failure error=\(error.localizedDescription, privacy: .public)"
                    )
                    capture.truncated = true
                }
            })

            if parseError {
                capture.truncated = true
            }

            capture.chunkedDecoder = decoder
            activeResponseBodyCapture = capture
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
            ProxyLog.mitm.error(
                "event=proxy.body_spool_write outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            capture.truncated = true
        }

        activeResponseBodyCapture = capture
    }

    private func finalizeResponseBodyCapture() {
        guard let capture = activeResponseBodyCapture else { return }
        do {
            try capture.handle.close()
        } catch {
            // Best-effort close.
        }
        activeResponseBodyCapture = nil

        if capture.bytesWritten <= 0 {
            try? FileManager.default.removeItem(at: capture.url)
            completedResponseBodyCapture = nil
            return
        }

        completedResponseBodyCapture = CompletedBodyCapture(
            url: capture.url,
            bytesWritten: capture.bytesWritten,
            truncated: capture.truncated
        )
    }

    private func cleanupActiveResponseBodyCapture() {
        guard let capture = activeResponseBodyCapture else { return }
        do {
            try capture.handle.close()
        } catch {
            // Best-effort close.
        }
        activeResponseBodyCapture = nil
        completedResponseBodyCapture = nil
        try? FileManager.default.removeItem(at: capture.url)
    }

    private func determineResponsePipeline(for url: String) async -> ResponsePipeline {
        #if canImport(TraceFeatures)
        // Rationale: Use the interceptor's snapshot-driven pipeline to avoid MainActor hops.
        return await RequestInterceptor.shared.responsePipeline(for: url)
        #else
        return .streamAndCapture
        #endif
    }

    private func switchToStreamingResponsePipelineAndFlushInitialBuffer(onFlushed: @escaping () -> Void) {
        guard headersComplete else {
            onFlushed()
            return
        }

        responsePipeline = .streamAndCapture

        finalChunkMarkerSeen = false
        chunkedTail.removeAll()

        // Rationale: Initialize streaming counters and capture any body bytes already buffered.
        if let headerEnd = responseHeaderEndOffset {
            responseBodyBytesReceived = max(0, responseBuffer.count - headerEnd)
            if headerEnd < responseBuffer.count {
                let initialBody = Data(responseBuffer[headerEnd...])
                appendToResponseBodyCapture(initialBody)
                updateChunkedTerminationState(with: initialBody)
            }
        } else {
            responseBodyBytesReceived = 0
        }

        // Rationale: Forward buffered headers/body bytes as soon as streaming is enabled.
        if !didForwardInitialResponseBufferToClient {
            didForwardInitialResponseBufferToClient = true
            let toSend = responseBuffer

            // Memory: Keep only a bounded preview in memory; the full body is captured to disk.
            if responseBuffer.count > maxResponseBufferSize {
                responseBuffer = Data(responseBuffer.prefix(maxResponseBufferSize))
            }

            sendToClient(toSend, completion: .contentProcessed { _ in
                onFlushed()
            })
            return
        }

        onFlushed()
    }

    private func handleStreamingServerData(
        _ data: Data
    ) -> (dataToSend: Data?, didCompleteResponse: Bool, didStartSSE: Bool) {
        // Rationale: Keep a bounded header/preview buffer and spool full bodies to disk.
        if !headersComplete {
            responseBuffer.append(data)
            if responseBuffer.count > 64 * 1024, responseBuffer.range(of: "\r\n\r\n".data(using: .utf8)!) == nil {
                // Rule: Cap header buffering at 64 KB in streaming mode.
                ProxyLog.mitm.error("event=proxy.response_headers_exceeded outcome=failure max_size=65536")
                close()
                return (nil, false, false)
            }

            parseResponseHeaders()
            if headersComplete && isSSEResponse() {
                handleSSEStream()
                return (nil, false, true)
            }

            guard headersComplete else {
                return (nil, false, false)
            }

            if let headerEnd = responseHeaderEndOffset {
                responseBodyBytesReceived = max(0, responseBuffer.count - headerEnd)
                if headerEnd < responseBuffer.count {
                    let initialBody = Data(responseBuffer[headerEnd...])
                    appendToResponseBodyCapture(initialBody)
                    updateChunkedTerminationState(with: initialBody)
                }
            }

            if !didForwardInitialResponseBufferToClient {
                didForwardInitialResponseBufferToClient = true
                let toSend = responseBuffer

                if responseBuffer.count > maxResponseBufferSize {
                    responseBuffer = Data(responseBuffer.prefix(maxResponseBufferSize))
                }

                return (toSend, isStreamingResponseComplete(), false)
            }

            return (nil, isStreamingResponseComplete(), false)
        }

        // Body bytes: forward immediately and spool to disk (bounded by capture cap).
        responseBodyBytesReceived += data.count
        updateChunkedTerminationState(with: data)
        appendToResponseBodyCapture(data)

        if responseBuffer.count < maxResponseBufferSize {
            let remaining = maxResponseBufferSize - responseBuffer.count
            if data.count <= remaining {
                responseBuffer.append(data)
            } else if remaining > 0 {
                responseBuffer.append(data.prefix(remaining))
            }
        }

        return (data, isStreamingResponseComplete(), false)
    }

    private func finishStreamingResponseAndReset() {
        // Rationale: Emit a capture when streaming completes.
        finalizeResponseBodyCapture()
        captureTruncatedResponse()
        resetResponseState()
    }

    private func updateChunkedTerminationState(with data: Data) {
        guard isChunkedTransfer else { return }
        // Rationale: Maintain a small tail buffer to detect terminators across boundaries.
        let marker = "0\r\n\r\n".data(using: .utf8)!
        var combined = Data()
        combined.append(chunkedTail)
        combined.append(data)
        if combined.range(of: marker) != nil {
            finalChunkMarkerSeen = true
        }
        // Performance: Keep the last 32 bytes as tail for the next check.
        if combined.count > 32 {
            chunkedTail = Data(combined.suffix(32))
        } else {
            chunkedTail = combined
        }
    }

    private func isStreamingResponseComplete() -> Bool {
        guard headersComplete else { return false }
        if isChunkedTransfer {
            return finalChunkMarkerSeen
        }
        if let expectedContentLength {
            return responseBodyBytesReceived >= expectedContentLength
        }
        // Rationale: Without framing, completion relies on connection close.
        return false
    }

    private func parseHostPort(_ hostPort: String) -> (String, UInt16)? {
        if hostPort.hasPrefix("[") {
            guard let end = hostPort.firstIndex(of: "]") else { return nil }
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex) ..< end])
            let remainder = hostPort[hostPort.index(after: end)...]
            guard remainder.hasPrefix(":"), let port = UInt16(remainder.dropFirst()) else {
                return nil
            }
            return (host, port)
        }

        guard let lastColon = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[..<lastColon])
        let portString = hostPort[hostPort.index(after: lastColon)...]
        guard let port = UInt16(portString) else { return nil }
        return (host, port)
    }

    private func mitmAllowlistMatches(host: String) -> Bool {
        guard !mitmAllowlist.isEmpty else { return false }
        let lowerHost = host.lowercased()
        return mitmAllowlist.contains { pattern in
            let p = pattern.lowercased()
            // Rule: The "*" wildcard matches all hosts.
            if p == "*" { return true }
            // Rule: Patterns like "*.example.com" match the suffix or root host.
            if p.hasPrefix("*.") {
                let suffix = String(p.dropFirst(2))
                return lowerHost == suffix || lowerHost.hasSuffix("." + suffix)
            }
            return lowerHost == p || lowerHost.hasSuffix("." + p)
        }
    }

    /// Returns a human-readable bypass reason, or nil when MITM should proceed.
    private func mitmBypassReason(host: String) -> String? {
        guard mitmEnabled else { return "disabled" }

        if MITMAutoBypassCache.shared.shouldBypass(host: host) {
            let detail = MITMAutoBypassCache.shared.reason(host: host)
            return detail.map { "auto-bypass (\($0))" } ?? "auto-bypass (previous MITM failure)"
        }

        guard mitmAllowlistMatches(host: host) else { return "not allowlisted" }
        return nil
    }

    private func shouldMITM(host: String) -> Bool {
        mitmBypassReason(host: host) == nil
    }

    private func maybeRecordMITMAutoBypass(host: String, reason: String) {
        let r = reason.lowercased()

        // Rule: Do not auto-bypass when the likely cause is user/device trust configuration.
        if r.contains("ca_not_trusted") {
            return
        }

        let isPinningLike =
            r.contains("possible_pinning_or_strict_trust") ||
            r.contains("pinning requirements") ||
            r.contains("certificate pinning") ||
            r.contains("cert pinning") ||
            r.contains("pinned certificate")

        guard isPinningLike else { return }

        let normalized = if r.contains("pinning requirements") {
            "pinning requirements"
        } else if r.contains("possible_pinning_or_strict_trust") {
            "pinning/strict trust"
        } else if r.contains("certificate pinning") || r.contains("cert pinning") {
            "certificate pinning"
        } else if r.contains("pinned certificate") {
            "pinned certificate"
        } else {
            "pinning/strict trust"
        }

        MITMAutoBypassCache.shared.record(host: host, reason: normalized)
        ProxyLog.mitm.info("event=proxy.mitm_auto_bypass outcome=success host=\(host, privacy: .private(mask: .hash)) reason=\(normalized, privacy: .public)")
        let hostHash = LogRedaction.hash(host)
        eventLog?.append(type: "mitm_auto_bypass", msg: "\(hostHash) reason=\(normalized)")
    }
}

// MARK: - Helper Models

public struct ParsedHTTPRequest: Sendable {
    public let method: String
    public let url: String
    public let httpVersion: String?
    public let headers: [String: String]
    public let body: String?
    public let bodyData: Data
}

public struct CapturedRequest {
    public let id: UUID
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let body: String?
    public let bodyData: Data?
    public let startTime: Date
    public let wasRewritten: Bool
    public let isMocked: Bool
    public let isReplayed: Bool
    public let appliedScriptName: String?
    public let hitBreakpoint: Bool
    public let retryAttempts: Int
}

// MARK: - Connection Pool

/// Manages a pool of reusable upstream server connections.
public class ConnectionPool {
    public nonisolated(unsafe) static let shared = ConnectionPool()

    private var pool: [String: [PooledConnection]] = [:]
    private let queue = DispatchQueue(label: "com.trace.connectionpool", attributes: .concurrent)

    // Rule: Cap pooled connections per host.
    private let maxConnectionsPerHost = 6
    // Rule: Treat connections idle for more than 2 minutes as stale.
    private let maxIdleTime: TimeInterval = 120
    // Rule: Treat connections older than 10 minutes as stale.
    private let maxConnectionAge: TimeInterval = 600

    private var cleanupTimer: DispatchSourceTimer?

    private init() {
        startCleanupTimer()
    }

    deinit {
        cleanupTimer?.cancel()
    }

    /// Returns a connection from the pool or creates a new one.
    public func getConnection(host: String, port: UInt16, useTLS: Bool) -> NWConnection? {
        let key = "\(host):\(port)"

        if let connection = queue.sync(flags: .barrier, execute: { () -> PooledConnection? in
            guard var connections = pool[key], !connections.isEmpty else {
                return nil
            }

            for (index, pooled) in connections.enumerated().reversed() {
                if pooled.isHealthy {
                    let connection = connections.remove(at: index)
                    pool[key] = connections
                    ProxyLog.mitm.debug("event=proxy.pool_reuse outcome=success key=\(key, privacy: .private(mask: .hash))")
                    return connection
                }
            }

            return nil
        }) {
            connection.lastUsed = Date()
            return connection.connection
        }

        ProxyLog.mitm.debug("event=proxy.pool_create outcome=pending key=\(key, privacy: .private(mask: .hash))")
        return createNewConnection(host: host, port: port, useTLS: useTLS)
    }

    /// Returns a connection to the pool for reuse.
    public func returnConnection(_ connection: NWConnection, host: String, port: UInt16) {
        let key = "\(host):\(port)"

        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }

            guard connection.state == .ready else {
                ProxyLog.mitm.debug("event=proxy.pool_return_invalid outcome=skipped state=\(String(describing: connection.state), privacy: .public)")
                connection.cancel()
                return
            }

            var connections = self.pool[key] ?? []
            guard connections.count < self.maxConnectionsPerHost else {
                ProxyLog.mitm.debug("event=proxy.pool_full outcome=skipped key=\(key, privacy: .private(mask: .hash))")
                connection.cancel()
                return
            }

            let pooled = PooledConnection(connection: connection, host: host, port: port)
            connections.append(pooled)
            self.pool[key] = connections

            ProxyLog.mitm.debug("event=proxy.pool_return outcome=success key=\(key, privacy: .private(mask: .hash)) pool_size=\(connections.count)")
        }
    }

    /// Removes and closes a specific connection.
    public func removeConnection(_ connection: NWConnection, host: String, port: UInt16) {
        let key = "\(host):\(port)"

        queue.async(flags: .barrier) { [weak self] in
            guard var connections = self?.pool[key] else { return }

            connections.removeAll { $0.connection === connection }
            self?.pool[key] = connections

            connection.cancel()
            ProxyLog.mitm.debug("event=proxy.pool_remove outcome=success key=\(key, privacy: .private(mask: .hash))")
        }
    }

    /// Clears all pooled connections.
    public func clearAll() {
        queue.async(flags: .barrier) { [weak self] in
            for (_, connections) in self?.pool ?? [:] {
                connections.forEach { $0.connection.cancel() }
            }
            self?.pool.removeAll()
            ProxyLog.mitm.info("event=proxy.pool_clear outcome=success")
        }
    }

    // MARK: - Private Methods

    private func createNewConnection(host: String, port: UInt16, useTLS: Bool) -> NWConnection? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            ProxyLog.mitm.error("event=proxy.pool_invalid_port outcome=failure port=\(port)")
            return nil
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let parameters: NWParameters
        if useTLS {
            let tlsOptions = TLSHandler.createClientTLSOptions(for: host)
            parameters = NWParameters(tls: tlsOptions, tcp: .init())
        } else {
            parameters = .tcp
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .global())

        return connection
    }

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.cleanupStaleConnections()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func cleanupStaleConnections() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }

            let now = Date()
            var totalRemoved = 0

            for (key, connections) in self.pool {
                let (healthy, stale) = connections.reduce(
                    into: ([PooledConnection](), [PooledConnection]())
                ) { result, pooled in
                    if pooled.isStale(
                        now: now, maxIdleTime: self.maxIdleTime, maxAge: self.maxConnectionAge
                    ) {
                        result.1.append(pooled)
                    } else if pooled.isHealthy {
                        result.0.append(pooled)
                    } else {
                        result.1.append(pooled)
                    }
                }

                stale.forEach { $0.connection.cancel() }
                totalRemoved += stale.count

                if healthy.isEmpty {
                    self.pool.removeValue(forKey: key)
                } else {
                    self.pool[key] = healthy
                }
            }

            if totalRemoved > 0 {
                ProxyLog.mitm.debug("event=proxy.pool_cleanup outcome=success count=\(totalRemoved)")
            }
        }
    }
}

// MARK: - Pooled Connection

/// Represents a connection in the pool with metadata.
public class PooledConnection {
    public let connection: NWConnection
    public let host: String
    public let port: UInt16
    public let createdAt: Date
    public var lastUsed: Date

    public init(connection: NWConnection, host: String, port: UInt16) {
        self.connection = connection
        self.host = host
        self.port = port
        self.createdAt = Date()
        self.lastUsed = Date()
    }

    public var isHealthy: Bool {
        connection.state == .ready
    }

    public func isStale(now: Date, maxIdleTime: TimeInterval, maxAge: TimeInterval) -> Bool {
        let idleTime = now.timeIntervalSince(lastUsed)
        let age = now.timeIntervalSince(createdAt)

        return idleTime > maxIdleTime || age > maxAge
    }
}

// MARK: - Errors

public enum ProxyServerError: LocalizedError {
    case invalidPort(UInt16)

    public var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            "Invalid port number: \(port)"
        }
    }
}
