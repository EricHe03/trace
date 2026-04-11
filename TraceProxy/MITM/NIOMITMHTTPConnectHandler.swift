//
//  NIOMITMHTTPConnectHandler.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/20.
//

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS
import NIOTransportServices
import NIOWebSocket
import TraceCore
import TraceSecurity

final class NIOMITMHTTPConnectHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    static let decoderName = "nioHTTPDecoder"
    static let encoderName = "nioHTTPEncoder"
    static let handlerName = "nioConnectHandler"
    static let tlsName = "nioMITMTLS"
    static let tunneledDecoderName = "nioTunneledHTTPDecoder"
    static let tunneledEncoderName = "nioTunneledHTTPEncoder"
    static let tunneledHandlerName = "nioTunneledHTTPHandler"
    static let tunneledHTTP2CodecName = "nioTunneledHTTP2ToHTTP1Codec"
    static let tunneledHTTP2MetricsName = "nioTunneledHTTP2Metrics"
    static let tunneledHTTP2HandlerName = "nioTunneledHTTP2Handler"
    static let upstreamHTTPDecoderName = "nioUpstreamHTTPDecoder"
    static let upstreamHTTPEncoderName = "nioUpstreamHTTPEncoder"
    static let upstreamHTTPHandlerName = "nioUpstreamHTTPHandler"
    static let upstreamWSDecoderName = "nioUpstreamWSDecoder"
    static let upstreamWSEncoderName = "nioUpstreamWSEncoder"
    static let upstreamWSRelayName = "nioUpstreamWSRelay"
    static let clientWSDecoderName = "nioClientWSDecoder"
    static let clientWSEncoderName = "nioClientWSEncoder"
    static let clientWSRelayName = "nioClientWSRelay"
    static let tunnelPipelineVersion = "connect-relay-2026-02-20-v4"
    static let upstreamHTTPResponseDeadlineSeconds: Int64 = 600
    static let transparentTLSUpgradeTimeout: TimeAmount = .seconds(3)
    /// MITM ALPN protocols offered during the client-facing TLS handshake.
    static let mitmALPNProtocols: [String] = ["h2", "http/1.1"]

    enum State {
        case waitingForRequest
        case receivingHTTPRequest
        case forwardingHTTPRequest
        case connectingUpstream
        case tunnelEstablished
        case closed
    }

    enum IngressMode: Sendable {
        case proxy
        case tunneledHTTPS(host: String, port: UInt16)
    }

    struct OutboundRequestContext: Sendable {
        let requestSnapshot: NetworkRequest
        let methodToken: String
        let url: String
        let headers: [String: String]
        let body: Data
    }

    enum StreamingRequestKind {
        case none
        case webSocket
        case sse
        case grpc
    }

    let group: NIOTSEventLoopGroup
    weak var eventLog: NDJSONLogWriter?
    let throttler: PacketThrottler?
    let interceptor: (any InterceptionProviding)?
    let captureConfigProvider: () -> CaptureConfiguration
    let onRequestCaptured: ((NetworkRequest) -> Void)?
    let shouldMitmConnect: (String, UInt16) -> Bool
    let http2MITMEnabledProvider: () -> Bool
    let shouldFailOpenAfterMITMFailure: (String, UInt16, String, MITMFailoverContext) -> Bool
    let onMITMFailure: ((String, String) -> Void)?
    let ingressMode: IngressMode
    let upstreamHint: TransparentProxyMetadata.UpstreamHint?
    let usesHTTP2StreamSemantics: Bool

    let connectionID = UUID().uuidString
    var state: State = .waitingForRequest
    var upstreamChannel: Channel?
    var pendingRequestHead: HTTPRequestHead?
    var pendingRequestBody = ByteBuffer()
    var activeCapturedRequest: NetworkRequest?
    var queuedTerminalCapturedRequest: NetworkRequest?
    var connectTargetHost: String?
    var connectTargetPort: Int?
    var connectRequestStartTime: Date?
    var requestSentAt: Date?
    var responseHeadAt: Date?
    var didLogTunnelStatePassthrough = false
    var didEmitForwardingErrorResponse = false
    var shouldCloseAfterForwardingResponse = false
    var transparentTLSUpgradeWatchdog: Scheduled<Void>?
    var didSelectTransparentTLSProtocol = false

    init(
        group: NIOTSEventLoopGroup,
        eventLog: NDJSONLogWriter?,
        throttler: PacketThrottler?,
        interceptor: (any InterceptionProviding)?,
        captureConfigProvider: @escaping () -> CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?,
        shouldMitmConnect: @escaping (String, UInt16) -> Bool,
        http2MITMEnabledProvider: @escaping () -> Bool = { true },
        shouldFailOpenAfterMITMFailure: @escaping (String, UInt16, String, MITMFailoverContext) -> Bool,
        onMITMFailure: ((String, String) -> Void)?,
        ingressMode: IngressMode,
        upstreamHint: TransparentProxyMetadata.UpstreamHint?,
        usesHTTP2StreamSemantics: Bool = false
    ) {
        self.group = group
        self.eventLog = eventLog
        self.throttler = throttler
        self.interceptor = interceptor
        self.captureConfigProvider = captureConfigProvider
        self.onRequestCaptured = onRequestCaptured
        self.shouldMitmConnect = shouldMitmConnect
        self.http2MITMEnabledProvider = http2MITMEnabledProvider
        self.shouldFailOpenAfterMITMFailure = shouldFailOpenAfterMITMFailure
        self.onMITMFailure = onMITMFailure
        self.ingressMode = ingressMode
        self.upstreamHint = upstreamHint
        self.usesHTTP2StreamSemantics = usesHTTP2StreamSemantics
        switch ingressMode {
        case let .tunneledHTTPS(host, port):
            connectTargetHost = host
            connectTargetPort = Int(port)
        case .proxy:
            if let upstreamHint {
                connectTargetHost = upstreamHint.host
                connectTargetPort = Int(upstreamHint.port)
            }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let mode = switch ingressMode {
        case .proxy:
            "proxy"
        case .tunneledHTTPS:
            "tunneled_https"
        }
        logConnectStage(
            stage: "handler_added",
            outcome: "ready",
            detail: "version=\(Self.tunnelPipelineVersion),mode=\(mode)"
        )
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cancelTransparentTLSUpgradeWatchdog()
        finalizeActiveRequestAsCancellation(reason: "handler_removed")
        logConnectStage(
            stage: "handler_removed",
            outcome: "success",
            detail: "version=\(Self.tunnelPipelineVersion)"
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard state != .closed else { return }
        switch state {
        case .connectingUpstream, .tunnelEstablished:
            // During CONNECT->tunnel transitions this handler can still briefly sit in
            // the pipeline while raw bytes are already flowing. Do not force-decode
            // as HTTP parts here; pass through to downstream tunnel handlers.
            if !didLogTunnelStatePassthrough {
                didLogTunnelStatePassthrough = true
                logConnectStage(stage: "handler_tunnel_passthrough", outcome: "active")
            }
            context.fireChannelRead(data)
        case .closed:
            return
        case .waitingForRequest:
            let part = unwrapInboundIn(data)
            handleInitialRequestPart(part, context: context)
        case .receivingHTTPRequest:
            let part = unwrapInboundIn(data)
            handleHTTPRequestPart(part, context: context)
        case .forwardingHTTPRequest:
            let part = unwrapInboundIn(data)
            shouldCloseAfterForwardingResponse = true
            guard !didEmitForwardingErrorResponse else { return }
            didEmitForwardingErrorResponse = true
            if case .head = part {
                Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
            }
            let partToken = switch part {
            case let .head(head):
                "head(method=\(head.method.rawValue))"
            case .body:
                "body"
            case .end:
                "end"
            }
            logConnectStage(
                stage: "request_pipelining",
                outcome: "unsupported",
                detail: "action=emit_400_after_response,part=\(partToken)"
            )
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelTransparentTLSUpgradeWatchdog()
        finalizeActiveRequestAsCancellation(reason: "client_channel_inactive")
        logConnectStage(stage: "client_channel_inactive", outcome: "closed")
        upstreamChannel?.close(promise: nil)
        connectRequestStartTime = nil
        state = .closed
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        cancelTransparentTLSUpgradeWatchdog()
        if state == .closed {
            context.close(promise: nil)
            return
        }
        let failure = classifyClientHandlerFailure(error)
        if failure.shouldReport {
            ProxyLog.mitm.warning(
                "event=proxy.nio_connect_handler_error outcome=failure error=\(error.localizedDescription, privacy: .public) classified=\(failure.reason, privacy: .public)"
            )
            finalizeActiveRequestAsFailure(reason: failure.reason)
            logConnectStage(
                stage: "client_handler_error",
                outcome: "failure",
                detail: "\(error.localizedDescription) classified=\(failure.reason)"
            )
            reportMITMFailure(reason: failure.reason)
        } else {
            ProxyLog.mitm.info(
                "event=proxy.nio_connect_handler_error outcome=ignored error=\(error.localizedDescription, privacy: .public) classified=\(failure.reason, privacy: .public)"
            )
            finalizeActiveRequestAsCancellation(reason: failure.reason)
            logConnectStage(
                stage: "client_handler_error",
                outcome: "ignored",
                detail: "\(error.localizedDescription) classified=\(failure.reason)"
            )
        }
        upstreamChannel?.close(promise: nil)
        connectRequestStartTime = nil
        state = .closed
        context.close(promise: nil)
    }

    func handleInitialRequestPart(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        switch part {
        case let .head(head):
            if case let .tunneledHTTPS(host, port) = ingressMode {
                guard head.method != .CONNECT else {
                    sendResponse(status: .badRequest, body: "Nested CONNECT not supported", closeAfterSend: true, context: context)
                    Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
                    return
                }
                pendingRequestHead = head
                pendingRequestBody.clear()
                state = .receivingHTTPRequest
                eventLog?.append(
                    type: "proxy_nio_tunneled_request",
                    msg: "outcome=head_received mode=\(self.ingressModeLabel) id=\(self.connectionID) method=\(head.method.rawValue) host_hash=\(LogRedaction.hash(host)) port=\(port)"
                )
                ProxyLog.mitm.debug(
                    "event=proxy.nio_tunneled_http_request outcome=accepted host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public)"
                )
                return
            }

            guard head.method == .CONNECT else {
                pendingRequestHead = head
                pendingRequestBody.clear()
                state = .receivingHTTPRequest
                return
            }

            guard let (targetHost, targetPort) = Self.parseConnectTarget(head.uri) else {
                sendResponse(status: .badRequest, body: "Invalid CONNECT target", closeAfterSend: true, context: context)
                Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
                return
            }

            state = .connectingUpstream
            connectTargetHost = targetHost
            connectTargetPort = targetPort
            connectRequestStartTime = Date()
            ProxyLog.mitm.info(
                "event=proxy.nio_connect_request outcome=accepted host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public)"
            )
            eventLog?.append(type: "proxy_nio_connect", msg: "\(LogRedaction.hash(targetHost)):\(targetPort)")
            logConnectStage(stage: "connect_request", outcome: "accepted")
            logConnectStage(stage: "client_autoread", outcome: "disable_begin")
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { [weak self] result in
                if case let .failure(error) = result {
                    self?.logConnectStage(
                        stage: "client_autoread",
                        outcome: "disable_failure",
                        detail: error.localizedDescription
                    )
                }
            }

            if shouldMitmConnect(targetHost, UInt16(targetPort)) {
                if let bypassDetail = TLSHandler.preflightServerLeafTrust(for: targetHost) {
                    let failureReason = "client_rejected_mitm_or_pinning: \(bypassDetail)"
                    reportMITMFailure(host: targetHost, reason: failureReason)
                    let shouldFailOpen = shouldFailOpenAfterMITMFailure(
                        targetHost,
                        UInt16(targetPort),
                        failureReason,
                        .httpConnect
                    )
                    guard shouldFailOpen else {
                        logConnectStage(stage: "mitm_bypass_preflight", outcome: "blocked", detail: bypassDetail)
                        state = .closed
                        context.close(promise: nil)
                        return
                    }
                    ProxyLog.mitm.info(
                        "event=proxy.nio_connect_mitm_bypass outcome=success host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) reason=\(bypassDetail, privacy: .public)"
                    )
                    logConnectStage(stage: "mitm_bypass_preflight", outcome: "success", detail: bypassDetail)
                    Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
                    connectUpstream(
                        host: targetHost,
                        port: targetPort,
                        context: context,
                        connectMarkerNote: "CONNECT passthrough (\(bypassDetail))"
                    )
                    return
                }

                beginCONNECTMITM(host: targetHost, port: targetPort, context: context)
                return
            }

            logConnectStage(stage: "mitm_bypass_policy", outcome: "success", detail: "not_mitm")
            Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
            connectUpstream(
                host: targetHost,
                port: targetPort,
                context: context,
                connectMarkerNote: "CONNECT passthrough tunnel"
            )
        case .body, .end:
            return
        }
    }

    func handleHTTPRequestPart(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        switch part {
        case .head:
            sendResponse(status: .badRequest, body: "Unexpected HTTP request head", closeAfterSend: true, context: context)
            Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
        case let .body(buffer):
            var mutableBuffer = buffer
            pendingRequestBody.writeBuffer(&mutableBuffer)
        case .end:
            guard let requestHead = pendingRequestHead else {
                sendResponse(status: .badRequest, body: "Missing HTTP request head", closeAfterSend: true, context: context)
                Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
                return
            }

            let requestBody = pendingRequestBody
            pendingRequestHead = nil
            pendingRequestBody.clear()
            processHTTPRequest(head: requestHead, body: requestBody, context: context)
        }
    }

    func processHTTPRequest(head: HTTPRequestHead, body: ByteBuffer, context: ChannelHandlerContext) {
        guard let resolvedURL = resolveRequestURL(from: head) else {
            sendResponse(status: .badRequest, body: "Invalid request URL", closeAfterSend: true, context: context)
            Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
            return
        }

        Task { await ProxyNetworkMetrics.shared.recordHTTPRequestParsed() }
        eventLog?.append(
            type: "proxy_nio_tunneled_request",
            msg: "outcome=parsed mode=\(self.ingressModeLabel) id=\(self.connectionID) method=\(head.method.rawValue) url_hash=\(LogRedaction.hash(resolvedURL)) h2_stream=\(usesHTTP2StreamSemantics)"
        )

        let requestStart = Date()
        let flowID = UUID()
        let requestBodyData = byteBufferToData(body)
        let captureConfig = captureConfigProvider()
        let baseRequest = makeBaseNetworkRequest(
            flowID: flowID,
            requestURL: resolvedURL,
            methodToken: head.method.rawValue,
            requestVersion: head.version,
            requestHeaders: dictionary(from: head.headers),
            requestBodyData: requestBodyData,
            startTime: requestStart,
            captureConfig: captureConfig
        )
        activeCapturedRequest = baseRequest

        didEmitForwardingErrorResponse = false
        shouldCloseAfterForwardingResponse = false
        resetProxyPathTimingState()
        state = .forwardingHTTPRequest
        requestInterceptionFuture(
            RequestInterceptionContext(
                flowID: flowID,
                requestURL: resolvedURL,
                methodToken: head.method.rawValue,
                requestHeaders: dictionary(from: head.headers),
                requestBodyData: requestBodyData
            ),
            fallbackRequest: baseRequest,
            eventLoop: context.eventLoop
        ).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self, self.state == .forwardingHTTPRequest else { return }
                switch result {
                case let .success(interceptionResult):
                    self.handleInterceptionResult(
                        interceptionResult,
                        requestHead: head,
                        requestBodyData: requestBodyData,
                        fallbackRequest: baseRequest,
                        context: context
                    )
                case let .failure(error):
                    self.finalizeActiveRequestAsHTTPFailure(
                        status: .internalServerError,
                        reason: "request_interception_failed: \(error.localizedDescription)"
                    )
                    self.sendResponse(
                        status: .internalServerError,
                        body: "Interception failed: \(error.localizedDescription)",
                        closeAfterSend: true,
                        context: context
                    )
                }
            }
        }
    }

    func handleInterceptionResult(
        _ result: InterceptionResult,
        requestHead: HTTPRequestHead,
        requestBodyData: Data,
        fallbackRequest: NetworkRequest,
        context: ChannelHandlerContext
    ) {
        switch result {
        case .blocked:
            var blocked = fallbackRequest
            blocked.statusCode = 403
            blocked.statusMessage = "Blocked"
            blocked.wasBlocked = true
            blocked.responseHeaders = captureConfigProvider().captureHeaders
                ? [TraceHTTPHeader(key: "X-Trace-Note", value: "Blocked by rule")]
                : []
            blocked.responseBody = .empty
            annotateCaptureMetadata(&blocked)
            blocked.extractHTTPFields()
            NetworkThrottlingController.shared.applyMetadata(to: &blocked)
            finalizeCapturedDuration(for: &blocked)
            onRequestCaptured?(blocked)
            clearActiveCapturedRequest()
            Task {
                await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
            }
            sendResponse(status: .forbidden, body: nil, closeAfterSend: shouldCloseConnection(requestHead: requestHead, responseHeaders: HTTPHeaders()), context: context) { [weak self] in
                self?.clearActiveCapturedRequest()
                self?.state = self?.shouldCloseConnection(requestHead: requestHead, responseHeaders: HTTPHeaders()) == true ? .closed : .waitingForRequest
            }

        case let .failed(failure):
            switch failure {
            case .timeout:
                finalizeActiveRequestAsFailure(reason: "request_interception_timeout")
                context.eventLoop.scheduleTask(in: .milliseconds(500)) { [weak self] in
                    self?.state = .closed
                    context.close(promise: nil)
                }
            case .connectionReset, .dropConnection, .packetLoss:
                finalizeActiveRequestAsFailure(reason: "request_interception_connection_closed")
                state = .closed
                context.close(promise: nil)
            }

        case let .mocked(mockRequest):
            activeCapturedRequest = mockRequest
            deliverCapturedResponse(
                mockRequest,
                requestHead: requestHead,
                context: context,
                metricsAsParsedResponse: true
            )

        case let .modified(modifiedRequest):
            guard let outboundContext = makeOutboundRequestContext(
                from: modifiedRequest,
                fallbackBody: requestBodyData
            ) else {
                finalizeActiveRequestAsHTTPFailure(
                    status: .badRequest,
                    reason: "invalid_outbound_request"
                )
                sendResponse(status: .badRequest, body: "Invalid outbound request", closeAfterSend: true, context: context)
                Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
                return
            }
            activeCapturedRequest = outboundContext.requestSnapshot
            emitPendingTunneledSnapshotIfNeeded(outboundContext.requestSnapshot)
            forwardModifiedHTTPRequest(outboundContext, requestHead: requestHead, context: context)
        }
    }

    func emitPendingTunneledSnapshotIfNeeded(_ request: NetworkRequest) {
        guard case .tunneledHTTPS = ingressMode else { return }
        guard let onRequestCaptured else { return }

        var snapshot = request
        annotateCaptureMetadata(&snapshot)
        snapshot.extractHTTPFields()
        NetworkThrottlingController.shared.applyMetadata(to: &snapshot)
        onRequestCaptured(snapshot)
        var fields = [
            "outcome=pending_saved",
            "mode=\(self.ingressModeLabel)",
            "id=\(self.connectionID)",
            "request_id=\(snapshot.id.uuidString)",
            "method=\(snapshot.method.rawValue)",
            "url_hash=\(LogRedaction.hash(snapshot.url))",
            "h2_stream=\(usesHTTP2StreamSemantics)",
            "capture_path=\(snapshot.capturePath.rawValue)"
        ]
        if let captureFlowID = snapshot.captureFlowID {
            fields.append("capture_flow_id=\(captureFlowID)")
        }
        if let metadataVersion = snapshot.captureMetadataVersion {
            fields.append("capture_metadata_version=\(metadataVersion)")
        }
        eventLog?.append(
            type: "proxy_nio_tunneled_request",
            msg: fields.joined(separator: " ")
        )
    }

    func beginCONNECTMITM(host: String, port: Int, context: ChannelHandlerContext) {
        logConnectStage(stage: "mitm_prepare", outcome: "begin")
        do {
            let applicationProtocols = http2MITMEnabledProvider()
                ? Self.mitmALPNProtocols
                : ["http/1.1"]
            let tlsContext = try Self.makeServerTLSContext(
                for: host,
                applicationProtocols: applicationProtocols
            )
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { [weak self] _ in
                guard let self else { return }
                self.logConnectStage(stage: "connect_response", outcome: "writing", detail: "mitm")
                Task { await ProxyNetworkMetrics.shared.recordMITMIntercepted() }
                self.sendResponse(status: .ok, body: nil, closeAfterSend: false, context: context) { [weak self] in
                    guard let self else { return }
                    self.logConnectStage(stage: "connect_response", outcome: "flushed", detail: "mitm")
                    self.emitConnectMarker(
                        host: host,
                        port: port,
                        note: "CONNECT MITM established",
                        startTime: self.connectRequestStartTime
                    )
                    self.connectRequestStartTime = nil
                    self.installMITMDecryptionPipeline(
                        host: host,
                        port: port,
                        tlsContext: tlsContext,
                        context: context
                    )
                }
            }
        } catch {
            ProxyLog.mitm.warning(
                "event=proxy.nio_connect_mitm_prepare outcome=failure host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            logConnectStage(stage: "mitm_prepare", outcome: "failure", detail: error.localizedDescription)
            let failureReason = "mitm_setup_failed: \(error.localizedDescription)"
            reportMITMFailure(host: host, reason: failureReason)
            let shouldFailOpen = shouldFailOpenAfterMITMFailure(
                host,
                UInt16(port),
                failureReason,
                .httpConnect
            )
            guard shouldFailOpen else {
                state = .closed
                context.close(promise: nil)
                return
            }
            Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
            connectUpstream(
                host: host,
                port: port,
                context: context,
                connectMarkerNote: "CONNECT passthrough (mitm_setup_failed)"
            )
        }
    }

    func installMITMDecryptionPipeline(
        host: String,
        port: Int,
        tlsContext: NIOSSLContext,
        context: ChannelHandlerContext
    ) {
        logConnectStage(stage: "mitm_pipeline_install", outcome: "begin")
        let clientChannel = context.channel

        let tlsHandler: NIOSSLServerHandler
        do {
            tlsHandler = try NIOSSLServerHandler(context: tlsContext)
        } catch {
            ProxyLog.mitm.warning(
                "event=proxy.nio_connect_mitm_install outcome=failure stage=tls_handler host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            logConnectStage(stage: "mitm_pipeline_install", outcome: "failure", detail: "tls_handler:\(error.localizedDescription)")
            reportMITMFailure(host: host, reason: "mitm_tls_handler_failed: \(error.localizedDescription)")
            attemptMITMFallbackToPassthrough(
                host: host,
                port: port,
                context: context,
                detail: "tls_handler_failed"
            )
            return
        }

        removeCurrentHTTPPipelineHandlers(from: clientChannel)
            .flatMap {
                clientChannel.pipeline.addHandler(tlsHandler, name: Self.tlsName, position: .first)
            }
            .flatMap {
                clientChannel.configureHTTP2SecureUpgrade(
                    h2ChannelConfigurator: { [weak self] channel in
                        guard let self else {
                            return channel.eventLoop.makeSucceededVoidFuture()
                        }
                        return self.installTunneledHTTP2Pipeline(
                            on: channel,
                            host: host,
                            port: port
                        )
                    },
                    http1ChannelConfigurator: { [weak self] channel in
                        guard let self else {
                            return channel.eventLoop.makeSucceededVoidFuture()
                        }
                        return self.installTunneledHTTP1Pipeline(
                            on: channel,
                            host: host,
                            port: port
                        )
                    }
                )
            }
            .whenComplete { [weak self] result in
                switch result {
                case .success:
                    self?.logConnectStage(stage: "mitm_pipeline_install", outcome: "success")
                    self?.state = .tunnelEstablished
                    _ = clientChannel.setOption(ChannelOptions.autoRead, value: true)
                case let .failure(error):
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_connect_mitm_install outcome=failure stage=pipeline host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self?.logConnectStage(stage: "mitm_pipeline_install", outcome: "failure", detail: "pipeline:\(error.localizedDescription)")
                    self?.reportMITMFailure(host: host, reason: "mitm_pipeline_failed: \(error.localizedDescription)")
                    self?.attemptMITMFallbackToPassthrough(
                        host: host,
                        port: port,
                        context: context,
                        detail: "pipeline_failed"
                    )
                }
            }
    }
}
