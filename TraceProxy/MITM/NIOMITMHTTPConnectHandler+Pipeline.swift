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

        return channel.configureHTTP2Pipeline(mode: .server) { [weak self] streamChannel in
            guard let self else {
                return streamChannel.eventLoop.makeSucceededVoidFuture()
            }

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
                        self.makeTunneledHTTPHandler(
                            host: host,
                            port: port,
                            usesHTTP2StreamSemantics: true
                        ),
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
        captureState: NIOMITMWebSocketCaptureState,
        streamRuntime: StreamSessionRuntime? = nil,
        perMessageDeflateEnabled: Bool = false
    ) {
        let clientChannel = clientContext.channel
        let decisionProvider: (@Sendable (StreamSession, StreamEvent, EventLoop) -> EventLoopFuture<StreamInterceptionDecision>)? = if streamRuntime == nil {
            nil
        } else {
            { [weak self] session, event, eventLoop in
                guard let self else {
                    return eventLoop.makeSucceededFuture(.forward)
                }
                return self.streamEventInterceptionFuture(session: session, event: event, eventLoop: eventLoop)
            }
        }
        let closeNotifier: (@Sendable (StreamSessionStatus, String?, EventLoop) -> Void)? = if let streamRuntime {
            { [weak self] status, reason, eventLoop in
                self?.completeStreamRuntime(
                    streamRuntime,
                    status: status,
                    reason: reason,
                    eventLoop: eventLoop
                )
            }
        } else {
            nil
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
                        captureState: captureState,
                        streamRuntime: streamRuntime,
                        interceptDecisionProvider: decisionProvider,
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
                        captureState: captureState,
                        streamRuntime: streamRuntime,
                        interceptDecisionProvider: decisionProvider,
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
                        "event=proxy.nio_ws_relay_install outcome=success ws_id=\(captureState.connectionID.uuidString, privacy: .public)"
                    )
                    self?.eventLog?.append(
                        type: "proxy_nio_ws_relay_install",
                        msg: "outcome=success mode=\(self?.ingressModeLabel ?? "unknown") id=\(self?.connectionID ?? "unknown") ws_id=\(captureState.connectionID.uuidString)"
                    )
                    self?.state = .tunnelEstablished
                case let .failure(error):
                    captureState.markFailed()
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_ws_relay_install outcome=failure ws_id=\(captureState.connectionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self?.eventLog?.append(
                        type: "proxy_nio_ws_relay_install",
                        msg: "outcome=failure mode=\(self?.ingressModeLabel ?? "unknown") id=\(self?.connectionID ?? "unknown") ws_id=\(captureState.connectionID.uuidString) error=\(error.localizedDescription)"
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

    nonisolated(unsafe) static let tlsContextCacheLock = NSLock()
    nonisolated(unsafe) static var tlsContextCache: [String: NIOSSLContext] = [:]

    static func makeServerTLSContext(
        for host: String,
        applicationProtocols: [String]? = nil
    ) throws -> NIOSSLContext {
        let normalizedHost = host.lowercased()
        guard !normalizedHost.isEmpty else {
            throw TLSContextError.unsupportedHost
        }
        let normalizedProtocols = (applicationProtocols ?? mitmALPNProtocols).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let protocolCacheComponent = normalizedProtocols.joined(separator: "|")
        let key = "\(normalizedHost)|\(protocolCacheComponent)"

        tlsContextCacheLock.lock()
        if let cached = tlsContextCache[key] {
            tlsContextCacheLock.unlock()
            return cached
        }
        tlsContextCacheLock.unlock()

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

        tlsContextCacheLock.lock()
        tlsContextCache[key] = context
        tlsContextCacheLock.unlock()
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
