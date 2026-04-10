//
//  NIOMITMHTTPConnectHandler+Pipeline.swift
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

final class NIOMITMTunneledHTTP2StreamHandlerFactory: @unchecked Sendable {
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
    let upstreamHint: TransparentProxyMetadata.UpstreamHint?
    let host: String
    let port: Int

    init(
        group: NIOTSEventLoopGroup,
        eventLog: NDJSONLogWriter?,
        throttler: PacketThrottler?,
        interceptor: (any InterceptionProviding)?,
        captureConfigProvider: @escaping () -> CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?,
        shouldMitmConnect: @escaping (String, UInt16) -> Bool,
        http2MITMEnabledProvider: @escaping () -> Bool,
        shouldFailOpenAfterMITMFailure: @escaping (String, UInt16, String, MITMFailoverContext) -> Bool,
        onMITMFailure: ((String, String) -> Void)?,
        upstreamHint: TransparentProxyMetadata.UpstreamHint?,
        host: String,
        port: Int
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
        self.upstreamHint = upstreamHint
        self.host = host
        self.port = port
    }

    func makeHandler() -> NIOMITMHTTPConnectHandler {
        NIOMITMHTTPConnectHandler(
            group: group,
            eventLog: eventLog,
            throttler: throttler,
            interceptor: interceptor,
            captureConfigProvider: captureConfigProvider,
            onRequestCaptured: onRequestCaptured,
            shouldMitmConnect: shouldMitmConnect,
            http2MITMEnabledProvider: http2MITMEnabledProvider,
            shouldFailOpenAfterMITMFailure: shouldFailOpenAfterMITMFailure,
            onMITMFailure: onMITMFailure,
            ingressMode: .tunneledHTTPS(host: host, port: UInt16(port)),
            upstreamHint: upstreamHint,
            usesHTTP2StreamSemantics: true
        )
    }
}

extension NIOMITMHTTPConnectHandler {
    func attemptMITMFallbackToPassthrough(
        host: String,
        port: Int,
        context: ChannelHandlerContext,
        detail: String
    ) {
        guard context.channel.isActive else {
            logConnectStage(stage: "mitm_fallback", outcome: "skipped", detail: "\(detail),client_inactive")
            state = .closed
            return
        }

        let failureReason = "mitm_setup_failed:\(detail)"
        guard shouldFailOpenAfterMITMFailure(
            host,
            UInt16(port),
            failureReason,
            .httpConnect
        ) else {
            logConnectStage(stage: "mitm_fallback", outcome: "blocked", detail: detail)
            state = .closed
            context.close(promise: nil)
            return
        }

        state = .connectingUpstream
        logConnectStage(stage: "mitm_fallback", outcome: "begin", detail: detail)
        connectUpstream(
            host: host,
            port: port,
            context: context,
            sendConnectResponse: false
        )
    }

    func installTransparentTLSPipeline(
        on channel: Channel,
        host: String,
        port: Int,
        tlsContext: NIOSSLContext
    ) -> EventLoopFuture<Void> {
        let tlsHandler: NIOSSLServerHandler
        do {
            tlsHandler = try NIOSSLServerHandler(context: tlsContext)
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }

        return channel.pipeline
            .addHandler(tlsHandler, name: Self.tlsName, position: .first)
            .flatMap {
                self.logConnectStage(
                    stage: "transparent_tls_upgrade",
                    outcome: "begin",
                    detail: "alpn=\(Self.mitmALPNProtocols.joined(separator: "|"))"
                )
                self.scheduleTransparentTLSUpgradeWatchdog(on: channel)
                return channel.configureHTTP2SecureUpgrade(
                    // Important: transparent mode creates this handler outside the pipeline first.
                    // Retain strongly through ALPN selection so tunneled HTTP handlers are installed.
                    h2ChannelConfigurator: { channel in
                        self.markTransparentTLSProtocolSelected()
                        self.logConnectStage(stage: "transparent_tls_upgrade", outcome: "h2")
                        return self.installTunneledHTTP2Pipeline(
                            on: channel,
                            host: host,
                            port: port
                        )
                    },
                    http1ChannelConfigurator: { channel in
                        self.markTransparentTLSProtocolSelected()
                        self.logConnectStage(stage: "transparent_tls_upgrade", outcome: "http1.1")
                        return self.installTunneledHTTP1Pipeline(
                            on: channel,
                            host: host,
                            port: port
                        )
                    }
                )
            }
            .flatMapError { error in
                self.cancelTransparentTLSUpgradeWatchdog()
                return channel.eventLoop.makeFailedFuture(error)
            }
    }

    func installTunneledHTTP1Pipeline(
        on channel: Channel,
        host: String,
        port: Int
    ) -> EventLoopFuture<Void> {
        logConnectStage(stage: "mitm_protocol_select", outcome: "success", detail: "http1.1")
        ProxyLog.mitm.debug(
            "event=proxy.nio_connect_mitm_protocol outcome=selected protocol=http1.1 host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public)"
        )
        return channel.pipeline
            .addHandler(
                ByteToMessageHandler(
                    // Tunneled HTTP/1 requests should not forward raw leftovers
                    // to typed HTTP handlers, which can trigger NIOAny type traps.
                    HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)
                ),
                name: Self.tunneledDecoderName
            )
            .flatMap {
                channel.pipeline.addHandler(
                    HTTPResponseEncoder(),
                    name: Self.tunneledEncoderName
                )
            }
            .flatMap {
                channel.pipeline.addHandler(
                    self.makeTunneledHTTPHandler(host: host, port: port),
                    name: Self.tunneledHandlerName
                )
            }
    }

    func installTunneledHTTP2Pipeline(
        on channel: Channel,
        host: String,
        port: Int
    ) -> EventLoopFuture<Void> {
        logConnectStage(stage: "mitm_protocol_select", outcome: "success", detail: "h2")
        ProxyLog.mitm.info(
            "event=proxy.nio_connect_mitm_protocol outcome=selected protocol=h2 host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public)"
        )

        // Important: transparent dual-MITM installs HTTP/2 using a temporary setup handler.
        // Stream channels can be created long after setup completes, so they must not depend
        // on that temporary handler still being alive.
        let streamHandlerFactory = makeTunneledHTTP2StreamHandlerFactory(host: host, port: port)

        return channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
            Task { await ProxyNetworkMetrics.shared.recordHTTP2StreamCreated() }
            streamChannel.closeFuture.whenComplete { _ in
                Task { await ProxyNetworkMetrics.shared.recordHTTP2StreamClosed() }
            }

            return streamChannel.pipeline
                .addHandler(
                    HTTP2FramePayloadToHTTP1ServerCodec(),
                    name: Self.tunneledHTTP2CodecName
                )
                .flatMap {
                    streamChannel.pipeline.addHandler(
                        NIOMITMHTTP2MetricsHandler(),
                        name: Self.tunneledHTTP2MetricsName
                    )
                }
                .flatMap {
                    streamChannel.pipeline.addHandler(
                        streamHandlerFactory.makeHandler(),
                        name: Self.tunneledHTTP2HandlerName
                    )
                }
        }.map { _ in () }
    }

    func makeTunneledHTTPHandler(
        host: String,
        port: Int,
        usesHTTP2StreamSemantics: Bool = false
    ) -> NIOMITMHTTPConnectHandler {
        NIOMITMHTTPConnectHandler(
            group: group,
            eventLog: eventLog,
            throttler: throttler,
            interceptor: interceptor,
            captureConfigProvider: captureConfigProvider,
            onRequestCaptured: onRequestCaptured,
            shouldMitmConnect: shouldMitmConnect,
            http2MITMEnabledProvider: http2MITMEnabledProvider,
            shouldFailOpenAfterMITMFailure: shouldFailOpenAfterMITMFailure,
            onMITMFailure: onMITMFailure,
            ingressMode: .tunneledHTTPS(host: host, port: UInt16(port)),
            upstreamHint: upstreamHint,
            usesHTTP2StreamSemantics: usesHTTP2StreamSemantics
        )
    }

    func makeTunneledHTTP2StreamHandlerFactory(
        host: String,
        port: Int
    ) -> NIOMITMTunneledHTTP2StreamHandlerFactory {
        NIOMITMTunneledHTTP2StreamHandlerFactory(
            group: group,
            eventLog: eventLog,
            throttler: throttler,
            interceptor: interceptor,
            captureConfigProvider: captureConfigProvider,
            onRequestCaptured: onRequestCaptured,
            shouldMitmConnect: shouldMitmConnect,
            http2MITMEnabledProvider: http2MITMEnabledProvider,
            shouldFailOpenAfterMITMFailure: shouldFailOpenAfterMITMFailure,
            onMITMFailure: onMITMFailure,
            upstreamHint: upstreamHint,
            host: host,
            port: port
        )
    }

    func connectUpstream(
        host: String,
        port: Int,
        context: ChannelHandlerContext,
        sendConnectResponse: Bool = true,
        connectMarkerNote: String? = nil
    ) {
        logConnectStage(stage: "upstream_connect", outcome: "begin")
        let bootstrap = NIOTSConnectionBootstrap(group: group)
        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self else { return }
                guard self.state == .connectingUpstream else {
                    if case let .success(channel) = result {
                        channel.close(promise: nil)
                    }
                    return
                }

                switch result {
                case let .success(upstream):
                    self.logConnectStage(stage: "upstream_connect", outcome: "success")
                    self.upstreamChannel = upstream
                    if sendConnectResponse {
                        self.logConnectStage(stage: "connect_response", outcome: "writing", detail: "passthrough")
                        self.sendResponse(status: .ok, body: nil, closeAfterSend: false, context: context) { [weak self] in
                            guard let self else { return }
                            self.logConnectStage(stage: "connect_response", outcome: "flushed", detail: "passthrough")
                            if let connectMarkerNote {
                                self.emitConnectMarker(
                                    host: host,
                                    port: port,
                                    note: connectMarkerNote,
                                    startTime: self.connectRequestStartTime
                                )
                            }
                            self.connectRequestStartTime = nil
                            self.installTunnel(
                                clientContext: context,
                                upstream: upstream,
                                restoreAutoRead: true
                            )
                        }
                    } else {
                        self.connectRequestStartTime = nil
                        self.installTunnel(
                            clientContext: context,
                            upstream: upstream,
                            restoreAutoRead: true
                        )
                    }
                case let .failure(error):
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_upstream_connect outcome=failure host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.logConnectStage(stage: "upstream_connect", outcome: "failure", detail: error.localizedDescription)
                    self.connectRequestStartTime = nil
                    if sendConnectResponse {
                        self.sendResponse(status: .badGateway, body: "Failed to connect upstream", closeAfterSend: true, context: context)
                    } else {
                        self.state = .closed
                        context.close(promise: nil)
                    }
                }
            }
        }
    }

    func installStreamingUpstreamHTTPPipeline(
        on upstream: Channel,
        onResponsePart: @escaping @Sendable (HTTPClientResponsePart) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onInactive: @escaping @Sendable () -> Void
    ) -> EventLoopFuture<Void> {
        let ensureRequestEncoder = upstream.pipeline
            .containsHandler(type: HTTPRequestEncoder.self)
            .map { _ in () }
            .flatMapError { _ in
                upstream.pipeline.addHandler(
                    HTTPRequestEncoder(),
                    name: Self.upstreamHTTPEncoderName
                )
            }

        return ensureRequestEncoder
            .flatMap {
                upstream.pipeline.addHandler(
                    ByteToMessageHandler(
                        HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)
                    ),
                    name: Self.upstreamHTTPDecoderName
                )
            }
            .flatMap {
                upstream.pipeline.addHandler(
                    NIOMITMHTTPClientResponseRelayHandler(
                        onPart: onResponsePart,
                        onError: onError,
                        onInactive: onInactive
                    ),
                    name: Self.upstreamHTTPHandlerName
                )
            }
    }

    func installWebSocketRelay(
        clientContext: ChannelHandlerContext,
        upstream: Channel,
        streamRuntime: StreamSessionRuntime,
        perMessageDeflateEnabled: Bool = false
    ) {
        let clientChannel = clientContext.channel
        let decisionProvider: @Sendable (StreamSession, StreamEvent, EventLoop) -> EventLoopFuture<StreamInterceptionDecision> = { [weak self] session, event, eventLoop in
            guard let self else {
                return eventLoop.makeSucceededFuture(.forward)
            }
            return self.streamEventInterceptionFuture(session: session, event: event, eventLoop: eventLoop)
        }
        let eventRecorder: @Sendable (StreamEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.persistStreamEvent(event, runtime: streamRuntime)
        }
        let closeNotifier: @Sendable (StreamSessionStatus, String?, EventLoop) -> Void = { [weak self] status, reason, eventLoop in
            self?.completeStreamRuntime(
                streamRuntime,
                status: status,
                reason: reason,
                eventLoop: eventLoop
            )
        }
        removeHandlerIfPresent(name: Self.upstreamHTTPHandlerName, from: upstream)
            .flatMap {
                self.removeHandlerIfPresent(name: Self.upstreamHTTPDecoderName, from: upstream)
            }
            .flatMap {
                self.removeHandlerIfPresent(name: Self.upstreamHTTPEncoderName, from: upstream)
            }
            .flatMap {
                self.removeCurrentHTTPPipelineHandlers(from: clientChannel)
            }
            .flatMap {
                upstream.pipeline.addHandler(
                    ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1 << 20)),
                    name: Self.upstreamWSDecoderName
                )
            }
            .flatMap {
                upstream.pipeline.addHandler(
                    NIOMITMWebSocketRelayHandler(
                        peerChannel: clientChannel,
                        direction: .received,
                        streamRuntime: streamRuntime,
                        interceptDecisionProvider: decisionProvider,
                        streamEventRecorder: eventRecorder,
                        closeNotifier: closeNotifier,
                        perMessageDeflateEnabled: perMessageDeflateEnabled
                    ),
                    name: Self.upstreamWSRelayName
                )
            }
            .flatMap {
                upstream.pipeline.addHandler(WebSocketFrameEncoder(), name: Self.upstreamWSEncoderName)
            }
            .flatMap {
                clientChannel.pipeline.addHandler(
                    ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1 << 20)),
                    name: Self.clientWSDecoderName
                )
            }
            .flatMap {
                clientChannel.pipeline.addHandler(
                    NIOMITMWebSocketRelayHandler(
                        peerChannel: upstream,
                        direction: .sent,
                        streamRuntime: streamRuntime,
                        interceptDecisionProvider: decisionProvider,
                        streamEventRecorder: eventRecorder,
                        closeNotifier: closeNotifier,
                        perMessageDeflateEnabled: perMessageDeflateEnabled
                    ),
                    name: Self.clientWSRelayName
                )
            }
            .flatMap {
                clientChannel.pipeline.addHandler(WebSocketFrameEncoder(), name: Self.clientWSEncoderName)
            }
            .whenComplete { [weak self] result in
                switch result {
                case .success:
                    ProxyLog.mitm.info(
                        "event=proxy.nio_ws_relay_install outcome=success session_id=\(streamRuntime.snapshot().id.uuidString, privacy: .public)"
                    )
                    self?.eventLog?.append(
                        type: "proxy_nio_ws_relay_install",
                        msg: "outcome=success mode=\(self?.ingressModeLabel ?? "unknown") id=\(self?.connectionID ?? "unknown") session_id=\(streamRuntime.snapshot().id.uuidString)"
                    )
                    self?.state = .tunnelEstablished
                case let .failure(error):
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_ws_relay_install outcome=failure session_id=\(streamRuntime.snapshot().id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self?.eventLog?.append(
                        type: "proxy_nio_ws_relay_install",
                        msg: "outcome=failure mode=\(self?.ingressModeLabel ?? "unknown") id=\(self?.connectionID ?? "unknown") session_id=\(streamRuntime.snapshot().id.uuidString) error=\(error.localizedDescription)"
                    )
                    self?.completeStreamRuntime(
                        streamRuntime,
                        status: .failed,
                        reason: error.localizedDescription,
                        eventLoop: clientChannel.eventLoop
                    )
                    self?.state = .closed
                    upstream.close(promise: nil)
                    clientChannel.close(promise: nil)
                }
            }
    }

    func removeHandlerIfPresent(name: String, from channel: Channel) -> EventLoopFuture<Void> {
        channel.pipeline
            .removeHandler(name: name)
            .flatMapError { _ in
                channel.eventLoop.makeSucceededVoidFuture()
            }
    }

    func removeCurrentHTTPPipelineHandlers(from channel: Channel) -> EventLoopFuture<Void> {
        removeCurrentHTTPPipelineHandlersIfPresent(from: channel)
    }

    func removeCurrentHTTPPipelineHandlersIfPresent(from channel: Channel) -> EventLoopFuture<Void> {
        var future = channel.eventLoop.makeSucceededVoidFuture()
        for name in currentHTTPPipelineHandlerNames() {
            future = future.flatMap {
                self.removeHandlerIfPresent(name: name, from: channel)
            }
        }
        return future
    }

    func currentHTTPPipelineHandlerNames() -> [String] {
        switch ingressMode {
        case .proxy:
            [Self.handlerName, Self.decoderName, Self.encoderName]
        case .tunneledHTTPS:
            [Self.tunneledHandlerName, Self.tunneledDecoderName, Self.tunneledEncoderName]
        }
    }

    func currentHTTPPipelinePresenceSummary(on channel: Channel) -> EventLoopFuture<String> {
        let checks = currentHTTPPipelineHandlerNames().map { name in
            channel.pipeline.context(name: name)
                .map { _ in "\(name)=present" }
                .flatMapError { _ in
                    channel.eventLoop.makeSucceededFuture("\(name)=missing")
                }
        }
        return EventLoopFuture.whenAllSucceed(checks, on: channel.eventLoop)
            .map { $0.joined(separator: ",") }
    }

    func installTunnel(
        clientContext: ChannelHandlerContext,
        upstream: Channel,
        restoreAutoRead: Bool = false
    ) {
        logConnectStage(stage: "relay_install", outcome: "begin")
        let clientChannel = clientContext.channel

        let prepareFuture = currentHTTPPipelinePresenceSummary(on: clientChannel)
            .map { [weak self] summary in
                self?.logConnectStage(
                    stage: "relay_prepare",
                    outcome: "pipeline_before",
                    detail: summary
                )
            }
            .flatMap { [weak self] _ -> EventLoopFuture<Void> in
                guard let self else {
                    return clientChannel.eventLoop.makeSucceededVoidFuture()
                }
                return self.removeCurrentHTTPPipelineHandlersIfPresent(from: clientChannel)
            }
            .flatMap { [weak self] in
                guard let self else {
                    return clientChannel.eventLoop.makeSucceededVoidFuture()
                }
                return self.currentHTTPPipelinePresenceSummary(on: clientChannel)
                    .map { summary in
                        self.logConnectStage(
                            stage: "relay_prepare",
                            outcome: "pipeline_after",
                            detail: summary
                        )
                    }
            }

        prepareFuture
            .flatMap {
                upstream.pipeline.addHandler(NIOMITMRawRelayHandler(peerChannel: clientChannel))
            }
            .flatMap {
                clientChannel.pipeline.addHandler(NIOMITMRawRelayHandler(peerChannel: upstream))
            }
            .whenComplete { [weak self] result in
                switch result {
                case .success:
                    self?.logConnectStage(stage: "relay_install", outcome: "success")
                    self?.state = .tunnelEstablished
                    if restoreAutoRead {
                        _ = clientChannel.setOption(ChannelOptions.autoRead, value: true)
                    }
                case let .failure(error):
                    ProxyLog.mitm.warning("event=proxy.nio_tunnel_install outcome=failure error=\(error.localizedDescription, privacy: .public)")
                    self?.logConnectStage(stage: "relay_install", outcome: "failure", detail: error.localizedDescription)
                    self?.state = .closed
                    upstream.close(promise: nil)
                    clientChannel.close(promise: nil)
                }
            }
    }

    func sendResponse(
        status: HTTPResponseStatus,
        body: String?,
        closeAfterSend: Bool,
        context: ChannelHandlerContext,
        onFlushed: (() -> Void)? = nil
    ) {
        var bodyBuffer = context.channel.allocator.buffer(capacity: body?.utf8.count ?? 0)
        if let body {
            bodyBuffer.writeString(body)
        }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(bodyBuffer.readableBytes)")
        sendHTTPResponse(
            status: status,
            headers: headers,
            body: bodyBuffer,
            closeAfterSend: closeAfterSend,
            context: context,
            onFlushed: onFlushed
        )
    }

    func scheduleTransparentTLSUpgradeWatchdog(on channel: Channel) {
        cancelTransparentTLSUpgradeWatchdog()
        didSelectTransparentTLSProtocol = false
        transparentTLSUpgradeWatchdog = channel.eventLoop.scheduleTask(in: Self.transparentTLSUpgradeTimeout) { [weak self, weak channel] in
            guard let self else { return }
            guard !self.didSelectTransparentTLSProtocol else { return }
            guard self.state == .waitingForRequest else { return }
            self.logConnectStage(
                stage: "transparent_tls_upgrade",
                outcome: "timeout",
                detail: "alpn_not_selected"
            )
            self.reportMITMFailure(reason: "mitm_non_http_protocol: transparent_tls_upgrade_timeout")
            if let channel, channel.isActive {
                channel.close(promise: nil)
            }
        }
    }

    func markTransparentTLSProtocolSelected() {
        didSelectTransparentTLSProtocol = true
        cancelTransparentTLSUpgradeWatchdog()
    }

    func cancelTransparentTLSUpgradeWatchdog() {
        transparentTLSUpgradeWatchdog?.cancel()
        transparentTLSUpgradeWatchdog = nil
    }

    enum TLSContextError: LocalizedError {
        case invalidPrivateKey
        case invalidLeafCertificate
        case invalidRootCertificate
        case unsupportedHost
        case privateKeyExportFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPrivateKey:
                "Unable to parse generated private key for NIO TLS"
            case .invalidLeafCertificate:
                "Unable to parse generated leaf certificate for NIO TLS"
            case .invalidRootCertificate:
                "Unable to parse root CA certificate for NIO TLS"
            case .unsupportedHost:
                "CONNECT target host is empty"
            case let .privateKeyExportFailed(detail):
                "Failed to export private key: \(detail)"
            }
        }
    }

    struct CachedTLSContextEntry {
        let context: NIOSSLContext
        let expiresAt: Date
        var lastAccessAt: Date
    }

    nonisolated(unsafe) static let tlsContextCacheLock = NSLock()
    nonisolated(unsafe) static var tlsContextCache: [String: CachedTLSContextEntry] = [:]
    nonisolated(unsafe) static let tlsContextCacheTTL: TimeInterval = TLSHandler.certificateLifetime
    nonisolated(unsafe) static let tlsContextCacheMaxEntries = 128
    nonisolated(unsafe) static let runtimeCacheInvalidatorRegistration: Void = {
        CertificateManager.registerRuntimeCacheInvalidator {
            NIOMITMHTTPConnectHandler.clearCachedTLSContexts()
        }
    }()

    private static func ensureRuntimeCacheInvalidatorRegistration() {
        _ = runtimeCacheInvalidatorRegistration
    }

    static func clearCachedTLSContexts() {
        ensureRuntimeCacheInvalidatorRegistration()
        tlsContextCacheLock.lock()
        tlsContextCache.removeAll()
        tlsContextCacheLock.unlock()
    }

    static func cachedTLSContextCountForTesting() -> Int {
        ensureRuntimeCacheInvalidatorRegistration()
        tlsContextCacheLock.lock()
        defer { tlsContextCacheLock.unlock() }
        return tlsContextCache.count
    }

    static func cacheServerTLSContextForTesting(
        _ context: NIOSSLContext,
        host: String,
        applicationProtocols: [String]? = nil,
        now: Date = Date()
    ) {
        ensureRuntimeCacheInvalidatorRegistration()
        let key = tlsContextCacheKey(for: host, applicationProtocols: applicationProtocols)
        cacheServerTLSContext(context, forKey: key, now: now)
    }

    static func cachedServerTLSContextForTesting(
        host: String,
        applicationProtocols: [String]? = nil,
        now: Date = Date()
    ) -> NIOSSLContext? {
        ensureRuntimeCacheInvalidatorRegistration()
        let key = tlsContextCacheKey(for: host, applicationProtocols: applicationProtocols)
        return cachedServerTLSContext(forKey: key, now: now)
    }

    private static func tlsContextCacheKey(
        for host: String,
        applicationProtocols: [String]? = nil
    ) -> String {
        let normalizedHost = host.lowercased()
        let normalizedProtocols = (applicationProtocols ?? mitmALPNProtocols).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let protocolCacheComponent = normalizedProtocols.joined(separator: "|")
        return "\(normalizedHost)|\(protocolCacheComponent)"
    }

    private static func cachedServerTLSContext(forKey key: String, now: Date) -> NIOSSLContext? {
        tlsContextCacheLock.lock()
        defer { tlsContextCacheLock.unlock() }

        pruneExpiredTLSContextsLocked(now: now)
        guard var entry = tlsContextCache[key] else { return nil }
        entry.lastAccessAt = now
        tlsContextCache[key] = entry
        return entry.context
    }

    private static func cacheServerTLSContext(
        _ context: NIOSSLContext,
        forKey key: String,
        now: Date
    ) {
        tlsContextCacheLock.lock()
        defer { tlsContextCacheLock.unlock() }

        pruneExpiredTLSContextsLocked(now: now)
        tlsContextCache[key] = CachedTLSContextEntry(
            context: context,
            expiresAt: now.addingTimeInterval(tlsContextCacheTTL),
            lastAccessAt: now
        )
        trimTLSContextCacheIfNeededLocked()
    }

    private static func pruneExpiredTLSContextsLocked(now: Date) {
        tlsContextCache = tlsContextCache.filter { _, entry in
            entry.expiresAt > now
        }
    }

    private static func trimTLSContextCacheIfNeededLocked() {
        guard tlsContextCache.count > tlsContextCacheMaxEntries else { return }
        let overflow = tlsContextCache.count - tlsContextCacheMaxEntries
        let keysToRemove = tlsContextCache
            .sorted { lhs, rhs in
                lhs.value.lastAccessAt < rhs.value.lastAccessAt
            }
            .prefix(overflow)
            .map(\.key)
        for key in keysToRemove {
            tlsContextCache.removeValue(forKey: key)
        }
    }

    static func makeServerTLSContext(
        for host: String,
        applicationProtocols: [String]? = nil
    ) throws -> NIOSSLContext {
        ensureRuntimeCacheInvalidatorRegistration()
        let normalizedHost = host.lowercased()
        guard !normalizedHost.isEmpty else {
            throw TLSContextError.unsupportedHost
        }
        let normalizedProtocols = (applicationProtocols ?? mitmALPNProtocols).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = tlsContextCacheKey(for: normalizedHost, applicationProtocols: normalizedProtocols)
        let now = Date()

        if let cached = cachedServerTLSContext(forKey: key, now: now) {
            return cached
        }

        let (leafCertificate, leafPrivateKey) = try CertificateManager.shared.generateCertificateForDomain(normalizedHost)
        let leafData = SecCertificateCopyData(leafCertificate) as Data

        var exportError: Unmanaged<CFError>?
        guard let privateKeyData = SecKeyCopyExternalRepresentation(leafPrivateKey, &exportError) as Data? else {
            let detail = exportError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw TLSContextError.privateKeyExportFailed(detail)
        }

        let leafNIOSSL = try NIOSSLCertificate(bytes: [UInt8](leafData), format: .der)
        let privateKeyNIOSSL = try NIOSSLPrivateKey(bytes: [UInt8](privateKeyData), format: .der)

        var certificateChain: [NIOSSLCertificateSource] = [.certificate(leafNIOSSL)]
        if let (rootCertificate, _) = try? CertificateManager.shared.getRootCA() {
            let rootData = SecCertificateCopyData(rootCertificate) as Data
            let rootNIOSSL = try NIOSSLCertificate(bytes: [UInt8](rootData), format: .der)
            certificateChain.append(.certificate(rootNIOSSL))
        }

        var tlsConfiguration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain,
            privateKey: .privateKey(privateKeyNIOSSL)
        )
        tlsConfiguration.applicationProtocols = normalizedProtocols

        let context = try NIOSSLContext(configuration: tlsConfiguration)
        cacheServerTLSContext(context, forKey: key, now: now)
        return context
    }

    static func parseConnectTarget(_ uri: String) -> (host: String, port: Int)? {
        if uri.hasPrefix("["),
           let closeBracket = uri.firstIndex(of: "]"),
           closeBracket < uri.endIndex {
            let hostStart = uri.index(after: uri.startIndex)
            let host = String(uri[hostStart ..< closeBracket])
            let portStart = uri.index(after: closeBracket)
            guard portStart < uri.endIndex, uri[portStart] == ":" else { return nil }
            let numericStart = uri.index(after: portStart)
            guard numericStart < uri.endIndex,
                  let port = Int(uri[numericStart...]),
                  (1 ... 65535).contains(port)
            else { return nil }
            return (host: host, port: port)
        }

        guard let colon = uri.lastIndex(of: ":") else { return nil }
        let hostPart = String(uri[..<colon])
        let portPart = String(uri[uri.index(after: colon)...])
        guard !hostPart.isEmpty,
              let port = Int(portPart),
              (1 ... 65535).contains(port)
        else {
            return nil
        }
        return (host: hostPart, port: port)
    }
}
