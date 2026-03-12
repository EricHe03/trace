//
//  NIOMITMInitialIngressHandler.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/20.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOTransportServices
import TraceCore
import TraceSecurity

final class NIOMITMInitialIngressHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    static let handlerName = "nioInitialIngressHandler"

    enum State {
        case probing
        case installing
        case routed
        case closed
    }

    enum TLSProbeState {
        case needMore
        case tlsClientHello
        case notTLS
    }

    let group: NIOTSEventLoopGroup
    weak var eventLog: NDJSONLogWriter?
    let throttler: PacketThrottler?
    let interceptor: (any InterceptionProviding)?
    let captureConfigProvider: () -> CaptureConfiguration
    let onRequestCaptured: ((NetworkRequest) -> Void)?
    let shouldMitmConnect: (String, UInt16) -> Bool
    let shouldEnableTransparentTLS: () -> Bool
    let http2MITMEnabledProvider: () -> Bool
    let shouldFailOpenAfterMITMFailure: (String, UInt16, String, MITMFailoverContext) -> Bool
    let onMITMFailure: ((String, String) -> Void)?
    let flowID = UUID().uuidString

    var state: State = .probing
    var probeBuffer = ByteBuffer()
    var upstreamHint: TransparentProxyMetadata.UpstreamHint?
    var routeDecision = "undecided"
    var fallbackApplied = false
    var bypassReason = "none"
    var sniHash = "unknown"
    var upstreamHash = "unknown"
    let maxTLSProbeBytes = 4096
    /// Transparent MITM ALPN protocols offered during the upstream TLS handshake.
    static let transparentRelayALPNProtocols: [String] = ["h2", "http/1.1"]
    static let transparentTLSHandshakeTimeout: TimeAmount = .seconds(5)
    static let transparentTLSConnectTimeout: TimeAmount = .seconds(6)

    enum TransparentMITMFailureStage {
        case generic
        case clientTLSHandshake
    }

    enum TransparentMITMError: LocalizedError {
        case handshakeTimeout(String)

        var errorDescription: String? {
            switch self {
            case let .handshakeTimeout(role):
                "Transparent TLS \(role) handshake timed out"
            }
        }
    }

    init(
        group: NIOTSEventLoopGroup,
        eventLog: NDJSONLogWriter?,
        throttler: PacketThrottler?,
        interceptor: (any InterceptionProviding)?,
        captureConfigProvider: @escaping () -> CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?,
        shouldMitmConnect: @escaping (String, UInt16) -> Bool,
        shouldEnableTransparentTLS: @escaping () -> Bool,
        http2MITMEnabledProvider: @escaping () -> Bool,
        shouldFailOpenAfterMITMFailure: @escaping (String, UInt16, String, MITMFailoverContext) -> Bool,
        onMITMFailure: ((String, String) -> Void)?
    ) {
        self.group = group
        self.eventLog = eventLog
        self.throttler = throttler
        self.interceptor = interceptor
        self.captureConfigProvider = captureConfigProvider
        self.onRequestCaptured = onRequestCaptured
        self.shouldMitmConnect = shouldMitmConnect
        self.shouldEnableTransparentTLS = shouldEnableTransparentTLS
        self.http2MITMEnabledProvider = http2MITMEnabledProvider
        self.shouldFailOpenAfterMITMFailure = shouldFailOpenAfterMITMFailure
        self.onMITMFailure = onMITMFailure
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch state {
        case .closed:
            return
        case .routed:
            context.fireChannelRead(data)
        case .probing, .installing:
            var inbound = unwrapInboundIn(data)
            probeBuffer.writeBuffer(&inbound)
            evaluateRouting(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state = .closed
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state = .closed
        context.close(promise: nil)
    }
}

extension NIOMITMInitialIngressHandler {
    func evaluateRouting(context: ChannelHandlerContext) {
        guard state == .probing else { return }

        switch consumeUpstreamHintIfPresent() {
        case .absent:
            break
        case .needMore:
            return
        case let .invalid(reason):
            appendTransparentTLSEvent("stage=upstream_hint outcome=invalid reason=\(reason)")
            state = .closed
            context.close(promise: nil)
            return
        case let .value(hint, consumedBytes):
            upstreamHint = hint
            probeBuffer.moveReaderIndex(forwardBy: consumedBytes)
            appendTransparentTLSEvent(
                "stage=upstream_hint outcome=applied host_hash=\(LogRedaction.hash(hint.host)) port=\(hint.port) address_type=\(hint.addressTypeRaw)"
            )
            if probeBuffer.readableBytes == 0 {
                return
            }
        }

        switch tlsProbeState(for: probeBuffer) {
        case .needMore:
            return
        case .notTLS:
            installHTTPProxyPipeline(context: context)
        case .tlsClientHello:
            routeTransparentTLS(context: context)
        }
    }

    func installHTTPProxyPipeline(context: ChannelHandlerContext) {
        guard state == .probing else { return }
        state = .installing

        let connectHandler = makeConnectHandler(
            ingressMode: .proxy,
            upstreamHint: upstreamHint
        )
        context.channel.pipeline
            .addHandler(
                ByteToMessageHandler(
                    // Avoid forwarding non-HTTP leftovers as IOData into handlers
                    // that only accept HTTPServerRequestPart.
                    HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)
                ),
                name: NIOMITMHTTPConnectHandler.decoderName
            )
            .flatMap {
                context.channel.pipeline.addHandler(
                    HTTPResponseEncoder(),
                    name: NIOMITMHTTPConnectHandler.encoderName
                )
            }
            .flatMap {
                context.channel.pipeline.addHandler(
                    connectHandler,
                    name: NIOMITMHTTPConnectHandler.handlerName
                )
            }
            .map {
                self.state = .routed
                self.forwardBufferedInbound(context: context)
            }
            .flatMap {
                context.channel.pipeline.removeHandler(self)
            }
            .whenComplete { result in
                if case let .failure(error) = result {
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_ingress_route outcome=failure mode=http error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.state = .closed
                    context.close(promise: nil)
                }
            }
    }

    func routeTransparentTLS(context: ChannelHandlerContext) {
        guard state == .probing else { return }

        guard shouldEnableTransparentTLS() else {
            routeDecision = "close"
            fallbackApplied = false
            bypassReason = "mode_off"
            ProxyLog.mitm.warning("event=proxy.nio_transparent_tls outcome=disabled action=close")
            appendTransparentTLSEvent("outcome=disabled reason=mode_off")
            state = .closed
            context.close(promise: nil)
            return
        }

        let hintedUpstreamHost = upstreamHint.flatMap { normalizeUpstreamConnectHost($0.host) }
        let hintedUpstreamPort = upstreamHint?.port ?? 443

        guard let parsedHost = parseTLSSNI(from: probeBuffer),
              let host = normalizeSNIHost(parsedHost) else {
            if let hintedUpstreamHost {
                let hintedHostHash = LogRedaction.hash(hintedUpstreamHost)
                let failureReason = "sni_invalid_or_missing_upstream_hint"
                onMITMFailure?(hintedUpstreamHost, failureReason)
                let shouldFailOpen = shouldFailOpenAfterMITMFailure(
                    hintedUpstreamHost,
                    hintedUpstreamPort,
                    failureReason,
                    .transparentTLS
                )
                routeDecision = shouldFailOpen ? "passthrough" : "block"
                fallbackApplied = shouldFailOpen
                bypassReason = shouldFailOpen ? failureReason : "strict_fail_closed"
                sniHash = hintedHostHash
                upstreamHash = hintedHostHash
                if shouldFailOpen {
                    appendTransparentTLSEvent(
                        "outcome=passthrough host_hash=\(hintedHostHash) port=\(hintedUpstreamPort) reason=\(failureReason)"
                    )
                    Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
                    installTransparentPassthrough(host: hintedUpstreamHost, port: Int(hintedUpstreamPort), context: context)
                } else {
                    appendTransparentTLSEvent(
                        "outcome=blocked host_hash=\(hintedHostHash) port=\(hintedUpstreamPort) reason=\(failureReason)"
                    )
                    state = .closed
                    context.close(promise: nil)
                }
                return
            }
            if probeBuffer.readableBytes < maxTLSProbeBytes {
                return
            }
            ProxyLog.mitm.warning("event=proxy.nio_transparent_tls outcome=failure reason=sni_invalid_or_missing")
            appendTransparentTLSEvent("outcome=failure reason=sni_invalid_or_missing")
            state = .closed
            context.close(promise: nil)
            return
        }

        let upstreamHost = hintedUpstreamHost ?? host
        let upstreamPort = hintedUpstreamPort
        let hostHash = LogRedaction.hash(host)
        let upstreamHostHash = LogRedaction.hash(upstreamHost)
        sniHash = hostHash
        upstreamHash = upstreamHostHash
        let clientALPNOffer = parseTLSALPNProtocols(from: probeBuffer)
        let clientALPNOfferLabel = clientALPNOffer.isEmpty ? "none" : clientALPNOffer.joined(separator: "|")
        appendTransparentTLSEvent(
            "stage=sni_detected host_hash=\(hostHash) port=\(upstreamPort) client_alpn_offer=\(clientALPNOfferLabel) upstream_hash=\(upstreamHostHash)"
        )

        if shouldMitmConnect(host, upstreamPort) {
            routeDecision = "mitm"
            fallbackApplied = false
            bypassReason = "none"
            if let bypassDetail = TLSHandler.preflightServerLeafTrust(for: host) {
                let failureReason = "client_rejected_mitm_or_pinning: \(bypassDetail)"
                onMITMFailure?(host, failureReason)
                if host.caseInsensitiveCompare(upstreamHost) != .orderedSame {
                    onMITMFailure?(upstreamHost, failureReason)
                }
                let shouldFailOpen = shouldFailOpenAfterMITMFailure(
                    host,
                    upstreamPort,
                    failureReason,
                    .transparentTLS
                )
                routeDecision = shouldFailOpen ? "passthrough" : "block"
                fallbackApplied = shouldFailOpen
                bypassReason = shouldFailOpen ? "possible_pinning_or_strict_trust" : "strict_fail_closed"
                if shouldFailOpen {
                    ProxyLog.mitm.info(
                        "event=proxy.nio_transparent_tls outcome=passthrough host=\(host, privacy: .private(mask: .hash)) reason=\(bypassDetail, privacy: .public)"
                    )
                    appendTransparentTLSEvent(
                        "outcome=passthrough host_hash=\(hostHash) port=\(upstreamPort) reason=\(bypassDetail) upstream_hash=\(upstreamHostHash)"
                    )
                    Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
                    installTransparentPassthrough(host: upstreamHost, port: Int(upstreamPort), context: context)
                } else {
                    appendTransparentTLSEvent(
                        "outcome=blocked host_hash=\(hostHash) port=\(upstreamPort) reason=strict_fail_closed upstream_hash=\(upstreamHostHash)"
                    )
                    state = .closed
                    context.close(promise: nil)
                }
                return
            }

            installTransparentMITM(
                sniHost: host,
                upstreamConnectHost: upstreamHost,
                upstreamConnectPort: Int(upstreamPort),
                clientALPNOffer: clientALPNOffer,
                context: context
            )
            return
        }

        routeDecision = "passthrough"
        fallbackApplied = false
        bypassReason = "policy"
        appendTransparentTLSEvent(
            "outcome=passthrough host_hash=\(hostHash) port=\(upstreamPort) reason=policy upstream_hash=\(upstreamHostHash)"
        )
        Task { await ProxyNetworkMetrics.shared.recordMITMBypassed() }
        installTransparentPassthrough(host: upstreamHost, port: Int(upstreamPort), context: context)
    }

    func installTransparentMITM(
        sniHost: String,
        upstreamConnectHost: String,
        upstreamConnectPort: Int,
        clientALPNOffer: [String],
        context: ChannelHandlerContext
    ) {
        guard state == .probing else { return }
        state = .installing

        let hostHash = LogRedaction.hash(sniHost)
        let upstreamHash = LogRedaction.hash(upstreamConnectHost)
        sniHash = hostHash
        self.upstreamHash = upstreamHash
        let upstreamALPNCandidates = preferredUpstreamALPNCandidates(fromClientOffer: clientALPNOffer)
        let upstreamALPNCandidatesLabel = upstreamALPNCandidates.isEmpty ? "none" : upstreamALPNCandidates.joined(separator: "|")
        appendTransparentTLSEvent(
            "stage=mitm_prepare host_hash=\(hostHash) port=\(upstreamConnectPort) mode=decoded_http_capture alpn_candidates=\(upstreamALPNCandidatesLabel) upstream_hash=\(upstreamHash)"
        )

        appendTransparentTLSEvent(
            "stage=mitm_connect outcome=begin host_hash=\(hostHash) port=\(upstreamConnectPort) upstream_hash=\(upstreamHash)"
        )
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(Self.transparentTLSConnectTimeout)
        bootstrap.connect(host: upstreamConnectHost, port: upstreamConnectPort).whenComplete { result in
            context.eventLoop.execute {
                guard self.state == .installing else {
                    if case let .success(channel) = result {
                        channel.close(promise: nil)
                    }
                    return
                }

                switch result {
                case let .success(upstream):
                    self.appendTransparentTLSEvent(
                        "stage=mitm_connect outcome=success host_hash=\(hostHash) port=\(upstreamConnectPort) upstream_hash=\(upstreamHash)"
                    )
                    self.installUpstreamTLS(
                        on: upstream,
                        host: sniHost,
                        applicationProtocols: upstreamALPNCandidates
                    )
                    .flatMap { negotiatedUpstreamALPN in
                        self.installTransparentMITMRelay(
                            host: sniHost,
                            upstreamConnectHost: upstreamConnectHost,
                            port: upstreamConnectPort,
                            hostHash: hostHash,
                            negotiatedUpstreamALPN: negotiatedUpstreamALPN,
                            clientOfferedALPN: clientALPNOffer,
                            upstream: upstream,
                            context: context
                        )
                    }
                    .whenComplete { relayResult in
                        if case let .failure(error) = relayResult {
                            let failureKind = self.classifyTransparentMITMFailure(error)
                            if self.shouldRecordTCPHandshakeFailure(for: failureKind) {
                                DualMITMCircuitBreaker.shared.recordTCPClientHandshake(success: false)
                            }
                            let failureToken = self.transparentFailureToken(for: failureKind)
                            let classifiedFailure = self.transparentFailureLogReason(for: failureKind)
                            self.onMITMFailure?(sniHost, failureToken)
                            if sniHost.caseInsensitiveCompare(upstreamConnectHost) != .orderedSame {
                                self.onMITMFailure?(upstreamConnectHost, failureToken)
                            }
                            self.appendTransparentTLSEvent(
                                "outcome=mitm_failed host_hash=\(hostHash) port=\(upstreamConnectPort) reason=\(error.localizedDescription) classified=\(classifiedFailure) upstream_hash=\(upstreamHash)"
                            )
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_transparent_tls outcome=failure host=\(sniHost, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public) classified=\(classifiedFailure, privacy: .public)"
                            )

                            // Channel-close races are common during speculative browser
                            // preconnects; keep the failure local instead of mutating
                            // this channel into passthrough after partial TLS setup.
                            if self.state == .installing,
                               self.shouldFailOpenAfterMITMFailure(
                                   sniHost,
                                   UInt16(upstreamConnectPort),
                                   failureToken,
                                   .transparentTLS
                               ) {
                                upstream.close(promise: nil)
                                self.state = .probing
                                self.routeDecision = "passthrough"
                                self.fallbackApplied = true
                                self.bypassReason = failureToken
                                self.installTransparentPassthrough(
                                    host: upstreamConnectHost,
                                    port: upstreamConnectPort,
                                    context: context
                                )
                                return
                            }

                            self.state = .closed
                            upstream.close(promise: nil)
                            context.close(promise: nil)
                        }
                    }
                case let .failure(error):
                    let failureKind = self.classifyTransparentMITMFailure(error)
                    if self.shouldRecordTCPHandshakeFailure(for: failureKind) {
                        DualMITMCircuitBreaker.shared.recordTCPClientHandshake(success: false)
                    }
                    let failureToken = self.transparentFailureToken(for: failureKind)
                    let classifiedFailure = self.transparentFailureLogReason(for: failureKind)
                    self.onMITMFailure?(sniHost, failureToken)
                    if sniHost.caseInsensitiveCompare(upstreamConnectHost) != .orderedSame {
                        self.onMITMFailure?(upstreamConnectHost, failureToken)
                    }
                    self.appendTransparentTLSEvent(
                        "stage=mitm_connect outcome=failure host_hash=\(hostHash) port=\(upstreamConnectPort) reason=\(error.localizedDescription) classified=\(classifiedFailure) upstream_hash=\(upstreamHash)"
                    )
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_transparent_tls outcome=failure host=\(sniHost, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public) classified=\(classifiedFailure, privacy: .public)"
                    )
                    if self.state == .installing,
                       self.shouldFailOpenAfterMITMFailure(
                           sniHost,
                           UInt16(upstreamConnectPort),
                           failureToken,
                           .transparentTLS
                       ) {
                        self.state = .probing
                        self.routeDecision = "passthrough"
                        self.fallbackApplied = true
                        self.bypassReason = failureToken
                        self.installTransparentPassthrough(
                            host: upstreamConnectHost,
                            port: upstreamConnectPort,
                            context: context
                        )
                    } else {
                        self.state = .closed
                        context.close(promise: nil)
                    }
                }
            }
        }
    }

    func installTransparentPassthrough(host: String, port: Int, context: ChannelHandlerContext) {
        guard state == .probing || state == .installing else { return }
        state = .installing

        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(Self.transparentTLSConnectTimeout)
        bootstrap.connect(host: host, port: port).whenComplete { result in
            context.eventLoop.execute {
                guard self.state == .installing else {
                    if case let .success(channel) = result {
                        channel.close(promise: nil)
                    }
                    return
                }

                switch result {
                case let .success(upstream):
                    let hostHash = LogRedaction.hash(host)
                    upstream.pipeline.addHandler(NIOMITMRawRelayHandler(peerChannel: context.channel))
                        .flatMap {
                            context.channel.pipeline.addHandler(NIOMITMRawRelayHandler(peerChannel: upstream))
                        }
                        .map {
                            self.appendTransparentTLSEvent(
                                "outcome=passthrough_established host_hash=\(hostHash) port=\(port)"
                            )
                            self.state = .routed
                            self.writeBufferedInbound(to: upstream)
                            context.channel.pipeline.removeHandler(self).whenFailure { removeError in
                                self.appendTransparentTLSEvent(
                                    "stage=passthrough_ingress_remove outcome=ignored_failure host_hash=\(hostHash) port=\(port) reason=\(removeError.localizedDescription)"
                                )
                                ProxyLog.mitm.debug(
                                    "event=proxy.nio_transparent_passthrough_remove outcome=ignored_failure host=\(host, privacy: .private(mask: .hash)) error=\(removeError.localizedDescription, privacy: .public)"
                                )
                            }
                        }
                        .whenComplete { pipelineResult in
                            if case let .failure(error) = pipelineResult {
                                self.appendTransparentTLSEvent(
                                    "outcome=passthrough_failed host_hash=\(hostHash) port=\(port) reason=\(error.localizedDescription)"
                                )
                                ProxyLog.mitm.warning(
                                    "event=proxy.nio_transparent_passthrough outcome=failure host=\(host, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public)"
                                )
                                self.state = .closed
                                upstream.close(promise: nil)
                                context.close(promise: nil)
                            }
                        }
                case let .failure(error):
                    let hostHash = LogRedaction.hash(host)
                    self.appendTransparentTLSEvent(
                        "outcome=passthrough_connect_failed host_hash=\(hostHash) port=\(port) reason=\(error.localizedDescription)"
                    )
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_transparent_passthrough outcome=failure host=\(host, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.state = .closed
                    context.close(promise: nil)
                }
            }
        }
    }

    func installUpstreamTLS(
        on upstream: Channel,
        host: String,
        applicationProtocols: [String]
    ) -> EventLoopFuture<String?> {
        let handshakePromise = upstream.eventLoop.makePromise(of: String?.self)
        let timeoutTask = upstream.eventLoop.scheduleTask(in: Self.transparentTLSHandshakeTimeout) {
            handshakePromise.fail(TransparentMITMError.handshakeTimeout("upstream"))
        }
        handshakePromise.futureResult.whenComplete { _ in
            timeoutTask.cancel()
        }

        do {
            let upstreamTLSContext = try makeUpstreamTLSContext(applicationProtocols: applicationProtocols)
            let upstreamTLSHandler = try NIOSSLClientHandler(context: upstreamTLSContext, serverHostname: host)
            let observer = NIOMITMTLSHandshakeObserver(handshakePromise: handshakePromise)
            return upstream.pipeline
                .addHandler(upstreamTLSHandler, name: "nioTransparentUpstreamTLS", position: .first)
                .flatMap {
                    upstream.pipeline.addHandler(observer, name: "nioTransparentUpstreamTLSObserver")
                }
                .flatMap {
                    handshakePromise.futureResult
                }
        } catch {
            timeoutTask.cancel()
            return upstream.eventLoop.makeFailedFuture(error)
        }
    }

    func installTransparentMITMRelay(
        host: String,
        upstreamConnectHost: String,
        port: Int,
        hostHash: String,
        negotiatedUpstreamALPN: String?,
        clientOfferedALPN: [String],
        upstream: Channel,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        let upstreamALPNLabel = negotiatedUpstreamALPN ?? "none"
        let mirroredClientALPN = mirroredClientALPNList(
            from: negotiatedUpstreamALPN,
            clientOfferedALPN: clientOfferedALPN
        )
        appendTransparentTLSEvent(
            "stage=mitm_upstream_tls outcome=ready host_hash=\(hostHash) port=\(port) upstream_alpn=\(upstreamALPNLabel) mirrored_client_alpn=\(mirroredClientALPN.joined(separator: "|"))"
        )

        let clientTLSContext: NIOSSLContext
        do {
            clientTLSContext = try NIOMITMHTTPConnectHandler.makeServerTLSContext(
                for: host,
                applicationProtocols: mirroredClientALPN
            )
        } catch {
            return context.eventLoop.makeFailedFuture(error)
        }

        let clientHandshakePromise = context.eventLoop.makePromise(of: String?.self)
        var clientHandshakeTimeoutTask: Scheduled<Void>?
        clientHandshakePromise.futureResult.whenComplete { _ in
            clientHandshakeTimeoutTask?.cancel()
        }
        let clientObserver = NIOMITMTLSHandshakeObserver(handshakePromise: clientHandshakePromise)

        clientHandshakePromise.futureResult.whenComplete { result in
            context.eventLoop.execute {
                switch result {
                case let .success(clientALPN):
                    DualMITMCircuitBreaker.shared.recordTCPClientHandshake(success: true)
                    let clientALPNLabel = clientALPN ?? "none"
                    self.appendTransparentTLSEvent(
                        "stage=mitm_client_tls outcome=ready host_hash=\(hostHash) port=\(port) client_alpn=\(clientALPNLabel) upstream_alpn=\(upstreamALPNLabel)"
                    )
                    guard let upstreamALPN = negotiatedUpstreamALPN,
                          let clientALPN,
                          clientALPN != upstreamALPN
                    else {
                        self.appendTransparentTLSEvent(
                            "outcome=mitm_established host_hash=\(hostHash) port=\(port) mode=decoded_http_capture upstream_alpn=\(upstreamALPNLabel)"
                        )
                        _ = Task { await ProxyNetworkMetrics.shared.recordMITMIntercepted() }
                        return
                    }
                    self.appendTransparentTLSEvent(
                        "outcome=mitm_alpn_mismatch host_hash=\(hostHash) port=\(port) upstream_alpn=\(upstreamALPN) client_alpn=\(clientALPN)"
                    )
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_transparent_tls outcome=failure host=\(host, privacy: .private(mask: .hash)) reason=alpn_mismatch upstream=\(upstreamALPN, privacy: .public) client=\(clientALPN, privacy: .public)"
                    )
                    self.state = .closed
                    upstream.close(promise: nil)
                    context.close(promise: nil)
                case let .failure(error):
                    let failureKind = self.classifyTransparentMITMFailure(
                        error,
                        stage: .clientTLSHandshake
                    )
                    let failureToken = self.transparentFailureToken(for: failureKind)
                    let classifiedFailure = self.transparentFailureLogReason(for: failureKind)
                    if self.shouldRecordTCPHandshakeFailure(for: failureKind) {
                        DualMITMCircuitBreaker.shared.recordTCPClientHandshake(success: false)
                    }
                    self.onMITMFailure?(host, failureToken)
                    if host.caseInsensitiveCompare(upstreamConnectHost) != .orderedSame {
                        self.onMITMFailure?(upstreamConnectHost, failureToken)
                    }
                    self.bypassReason = failureToken
                    self.appendTransparentTLSEvent(
                        "stage=mitm_client_tls outcome=failure host_hash=\(hostHash) port=\(port) reason=\(error.localizedDescription) classified=\(classifiedFailure)"
                    )
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_transparent_tls outcome=failure host=\(host, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public) classified=\(classifiedFailure, privacy: .public)"
                    )
                    self.state = .closed
                    upstream.close(promise: nil)
                    context.close(promise: nil)
                }
            }
        }

        let tunneledHandler = makeConnectHandler(
            ingressMode: .tunneledHTTPS(host: host, port: UInt16(port)),
            upstreamHint: upstreamHint
        )

        return context.channel.pipeline
            .addHandler(clientObserver, name: "nioTransparentClientTLSObserver")
            .flatMap {
                tunneledHandler.installTransparentTLSPipeline(
                    on: context.channel,
                    host: host,
                    port: port,
                    tlsContext: clientTLSContext
                )
            }
            .map {
                clientHandshakeTimeoutTask = context.eventLoop.scheduleTask(in: Self.transparentTLSHandshakeTimeout) {
                    clientHandshakePromise.fail(TransparentMITMError.handshakeTimeout("client"))
                }
                self.state = .routed
                // Replay from pipeline head so TLS handlers receive the buffered ClientHello.
                context.eventLoop.execute {
                    self.replayBufferedInbound(on: context.channel)
                }
                context.channel.pipeline.removeHandler(self).whenFailure { removeError in
                    self.appendTransparentTLSEvent(
                        "stage=mitm_ingress_remove outcome=ignored_failure host_hash=\(hostHash) port=\(port) reason=\(removeError.localizedDescription)"
                    )
                    ProxyLog.mitm.debug(
                        "event=proxy.nio_transparent_tls_remove outcome=ignored_failure host=\(host, privacy: .private(mask: .hash)) error=\(removeError.localizedDescription, privacy: .public)"
                    )
                }
            }
    }

    func makeUpstreamTLSContext(applicationProtocols: [String]) throws -> NIOSSLContext {
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.applicationProtocols = applicationProtocols
        if RuntimeEnvironment.isRunningUnitTests {
            // Unit tests use ephemeral local TLS endpoints that are not installed in the system trust store.
            tlsConfiguration.certificateVerification = .none
        }
        return try NIOSSLContext(configuration: tlsConfiguration)
    }

    func preferredUpstreamALPNCandidates(fromClientOffer clientALPNOffer: [String]) -> [String] {
        let normalizedOffer = clientALPNOffer
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !normalizedOffer.isEmpty else {
            // Client did not advertise ALPN; keep upstream ALPN disabled to avoid
            // selecting a protocol the client did not negotiate.
            return []
        }

        let relayProtocols = http2MITMEnabledProvider()
            ? Self.transparentRelayALPNProtocols
            : ["http/1.1"]
        return relayProtocols.filter { candidate in
            normalizedOffer.contains(candidate.lowercased())
        }
    }

    func mirroredClientALPNList(from negotiatedUpstreamALPN: String?, clientOfferedALPN: [String]) -> [String] {
        guard let negotiated = negotiatedUpstreamALPN?.trimmingCharacters(in: .whitespacesAndNewlines),
              !negotiated.isEmpty
        else {
            // Upstream negotiated no ALPN, so keep downstream ALPN disabled too.
            return []
        }
        let normalizedOffer = clientOfferedALPN
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard normalizedOffer.isEmpty || normalizedOffer.contains(negotiated.lowercased()) else {
            // Defensive: if upstream selected a protocol the client did not advertise,
            // avoid forcing an unsupported ALPN on the client handshake.
            return []
        }
        return [negotiated]
    }

    func classifyTransparentMITMFailure(
        _ error: Error,
        stage: TransparentMITMFailureStage = .generic
    ) -> TransparentMITMFailureKind {
        let detail = transparentMITMFailureDetail(error)
        let lowercaseDetail = detail.lowercased()
        if stage == .clientTLSHandshake {
            if let clientTLSAlert = classifyClientTLSAlertDetail(from: lowercaseDetail) {
                return .clientRejectedMITMOrPinning(detail: clientTLSAlert)
            }
            if lowercaseDetail.contains("niossl.niosslerror error 0") {
                return .clientRejectedMITMOrPinning(detail: "niossl_error_0")
            }
        }

        if let transparentError = error as? TransparentMITMError {
            switch transparentError {
            case let .handshakeTimeout(role):
                if role == "client" {
                    return .connectionClosedEarly(detail: "transparent_tls_client_handshake_timeout")
                }
                return .mitmSetupFailed(detail: "transparent_tls_\(role)_handshake_timeout")
            }
        }

        if let channelError = error as? ChannelError {
            if case .connectTimeout = channelError {
                return .upstreamTimeout(detail: nil)
            }
            return .connectionClosedEarly(detail: nil)
        }

        if let sslError = error as? NIOSSLError {
            switch sslError {
            case .uncleanShutdown:
                return .upstreamConnectionClosed(detail: nil)
            case .noCertificateToValidate, .unableToValidateCertificate:
                return .tlsUpstreamTrustFailed(detail: nil)
            case .cannotMatchULabel:
                return .tlsUpstreamHostnameMismatch(detail: nil)
            default:
                break
            }
        }

        if let sslExtraError = error as? NIOSSLExtraError {
            if sslExtraError == .failedToValidateHostname ||
                sslExtraError == .serverHostnameImpossibleToMatch ||
                sslExtraError == .cannotUseIPAddressInSNI ||
                sslExtraError == .invalidSNIHostname {
                return .tlsUpstreamHostnameMismatch(detail: nil)
            }
        }

        if lowercaseDetail.contains("connect timeout") || lowercaseDetail.contains("connection timed out") {
            return .upstreamTimeout(detail: nil)
        }
        if lowercaseDetail.contains("connection reset by peer") ||
            lowercaseDetail.contains("channelerror") ||
            lowercaseDetail.contains("input closed") ||
            lowercaseDetail.contains("closed channel") {
            return .connectionClosedEarly(detail: nil)
        }
        if lowercaseDetail.contains("certificate") || lowercaseDetail.contains("trust") || lowercaseDetail.contains("x509") {
            return .tlsUpstreamTrustFailed(detail: nil)
        }
        if lowercaseDetail.contains("hostname") && lowercaseDetail.contains("mismatch") {
            return .tlsUpstreamHostnameMismatch(detail: nil)
        }
        if lowercaseDetail.contains("timed out") || lowercaseDetail.contains("timeout") {
            return .upstreamTimeout(detail: nil)
        }
        return .mitmSetupFailed(detail: detail)
    }

    private func transparentMITMFailureDetail(_ error: Error) -> String {
        var segments = [error.localizedDescription, String(describing: error)]
        var current = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        var depth = 0

        while let current, depth < 4 {
            segments.append(current.localizedDescription)
            segments.append(String(describing: current))
            current = (current as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }

        return segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private func classifyClientTLSAlertDetail(from detail: String) -> String? {
        let alertMappings = [
            ("certificate_unknown", "peer_tls_alert_certificate_unknown"),
            ("unknown_ca", "peer_tls_alert_unknown_ca"),
            ("bad_certificate", "peer_tls_alert_bad_certificate"),
            ("unsupported_certificate", "peer_tls_alert_unsupported_certificate"),
            ("certificate_expired", "peer_tls_alert_certificate_expired"),
            ("certificate_revoked", "peer_tls_alert_certificate_revoked"),
            ("access_denied", "peer_tls_alert_access_denied")
        ]

        for (needle, token) in alertMappings where detail.contains(needle) {
            return token
        }

        if detail.contains("certificate unknown") {
            return "peer_tls_alert_certificate_unknown"
        }
        if detail.contains("unknown ca") {
            return "peer_tls_alert_unknown_ca"
        }
        if detail.contains("bad certificate") {
            return "peer_tls_alert_bad_certificate"
        }

        return nil
    }

    func transparentFailureToken(for failureKind: TransparentMITMFailureKind) -> String {
        let typedFailure = MITMFailureMapper.mapTransparentFailure(failureKind)
        return MITMFailureMapper.legacyToken(for: typedFailure)
    }

    func transparentFailureLogReason(for failureKind: TransparentMITMFailureKind) -> String {
        let token = transparentFailureToken(for: failureKind)
        guard let detail = failureKind.detail,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return token
        }
        return "\(token): \(detail)"
    }

    func shouldRecordTCPHandshakeFailure(for failureKind: TransparentMITMFailureKind) -> Bool {
        failureKind.shouldAffectGlobalCircuitBreaker
    }

    func makeConnectHandler(
        ingressMode: NIOMITMHTTPConnectHandler.IngressMode,
        upstreamHint: TransparentProxyMetadata.UpstreamHint?
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
            ingressMode: ingressMode,
            upstreamHint: upstreamHint
        )
    }

    func forwardBufferedInbound(context: ChannelHandlerContext) {
        var buffered = probeBuffer
        probeBuffer.clear()
        guard buffered.readableBytes > 0 else { return }
        context.fireChannelRead(wrapInboundOut(buffered))
        context.fireChannelReadComplete()
    }

    func replayBufferedInbound(on channel: Channel) {
        var buffered = probeBuffer
        probeBuffer.clear()
        guard buffered.readableBytes > 0 else { return }
        channel.pipeline.fireChannelRead(NIOAny(buffered))
        channel.pipeline.fireChannelReadComplete()
    }

    func writeBufferedInbound(to channel: Channel) {
        var buffered = probeBuffer
        probeBuffer.clear()
        guard buffered.readableBytes > 0 else { return }
        channel.writeAndFlush(buffered, promise: nil)
    }

    func appendTransparentTLSEvent(_ message: String) {
        let policy = captureConfigProvider().dualMITMPolicy.rawValue
        let prefix =
            "flow_id=\(flowID) sni_hash=\(sniHash) upstream_hash=\(upstreamHash) " +
            "route_decision=\(routeDecision) fallback_applied=\(fallbackApplied) " +
            "bypass_reason=\(bypassReason) policy=\(policy)"
        eventLog?.append(type: "proxy_nio_transparent_tls", msg: "\(prefix) \(message)")
    }

    func consumeUpstreamHintIfPresent() -> TransparentProxyMetadata.DecodeResult {
        guard upstreamHint == nil else {
            return .absent
        }
        return TransparentProxyMetadata.decodeUpstreamHintPrefix(from: probeBuffer)
    }

    func normalizeUpstreamConnectHost(_ rawHost: String) -> String? {
        var normalized = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("["),
           normalized.hasSuffix("]"),
           normalized.count > 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        guard !normalized.isEmpty else { return nil }
        guard !normalized.contains(where: \.isWhitespace) else { return nil }
        guard normalized.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return !(value < 0x20 || value == 0x7F)
        }) else {
            return nil
        }
        return normalized.lowercased()
    }

    func normalizeSNIHost(_ rawHost: String) -> String? {
        var normalized = rawHost
        if let nullIndex = normalized.firstIndex(of: "\0") {
            normalized = String(normalized[..<nullIndex])
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("["),
           normalized.hasSuffix("]"),
           normalized.count > 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        if normalized.hasSuffix("."),
           normalized.count > 1 {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else { return nil }
        guard !normalized.contains(where: \.isWhitespace) else { return nil }
        guard normalized.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return !(value < 0x20 || value == 0x7F)
        }) else {
            return nil
        }
        let lowercased = normalized.lowercased()
        guard !lowercased.hasPrefix("."),
              !lowercased.hasSuffix("."),
              !lowercased.contains("..")
        else {
            return nil
        }
        guard lowercased.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            let isDigit = value >= 0x30 && value <= 0x39
            let isLowerAlpha = value >= 0x61 && value <= 0x7A
            return isDigit || isLowerAlpha || value == 0x2D || value == 0x2E
        }) else {
            return nil
        }
        let labels = lowercased.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return nil }
            guard label.first != "-", label.last != "-" else { return nil }
        }
        return lowercased
    }

    // swiftlint:disable:next cyclomatic_complexity
}
