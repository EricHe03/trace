//
//  NIOMITMProxyEngine.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/14.
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
import Security
import TraceCore
import TraceSecurity

private struct NIOMITMUncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

enum TransparentMITMFailureKind: Sendable {
    case clientRejectedMITMOrPinning(detail: String?)
    case connectionClosedEarly(detail: String?)
    case upstreamTimeout(detail: String?)
    case upstreamConnectionClosed(detail: String?)
    case tlsUpstreamTrustFailed(detail: String?)
    case tlsUpstreamHostnameMismatch(detail: String?)
    case mitmSetupFailed(detail: String?)

    var normalizedToken: String {
        switch self {
        case .clientRejectedMITMOrPinning:
            "client_rejected_mitm_or_pinning"
        case .connectionClosedEarly:
            "connection_closed_early"
        case .upstreamTimeout:
            "upstream_timeout"
        case .upstreamConnectionClosed:
            "upstream_connection_closed"
        case .tlsUpstreamTrustFailed:
            "tls_upstream_trust_failed"
        case .tlsUpstreamHostnameMismatch:
            "tls_upstream_hostname_mismatch"
        case .mitmSetupFailed:
            "mitm_setup_failed"
        }
    }

    var detail: String? {
        switch self {
        case let .clientRejectedMITMOrPinning(detail),
             let .connectionClosedEarly(detail),
             let .upstreamTimeout(detail),
             let .upstreamConnectionClosed(detail),
             let .tlsUpstreamTrustFailed(detail),
             let .tlsUpstreamHostnameMismatch(detail),
             let .mitmSetupFailed(detail):
            detail
        }
    }

    var reasonString: String {
        guard let detail,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return normalizedToken
        }
        return "\(normalizedToken): \(detail)"
    }
}

enum MITMFailoverContext: String, Sendable {
    case transparentTLS = "tcp_transparent"
    case httpConnect = "http_connect"
}

/// NIO/NIOTS transport engine for MITM proxy listener lifecycle.
///
/// NIO is the sole transport backend for MITM server lifecycle.
final class NIOMITMProxyEngine: @unchecked Sendable {
    struct Endpoint: Sendable {
        let host: String
        let port: UInt16
    }

    private enum EngineError: LocalizedError {
        case eventLoopGroupUnavailable
        case listenerPortUnavailable

        var errorDescription: String? {
            switch self {
            case .eventLoopGroupUnavailable:
                "NIOTS event loop group unavailable for MITM proxy"
            case .listenerPortUnavailable:
                "NIO MITM listener did not report a local port"
            }
        }
    }

    private let lock = NSLock()
    private let port: UInt16
    private weak var eventLog: NDJSONLogWriter?
    private let throttler: PacketThrottler?
    private let interceptor: (any InterceptionProviding)?
    private let captureConfigProvider: () -> CaptureConfiguration
    private let onRequestCaptured: ((NetworkRequest) -> Void)?
    private let shouldMitmConnect: (String, UInt16) -> Bool
    private let isTransparentTLSEnabled: () -> Bool
    private let shouldFailOpenAfterMITMFailure: (String, UInt16, String, MITMFailoverContext) -> Bool
    private let onMITMFailure: ((String, String) -> Void)?

    private var listenerChannel: Channel?
    private var childChannels: [ObjectIdentifier: Channel] = [:]
    private var runtimeAcquired = false

    init(
        port: UInt16,
        eventLog: NDJSONLogWriter?,
        throttler: PacketThrottler? = nil,
        interceptor: (any InterceptionProviding)? = nil,
        captureConfigProvider: @escaping () -> CaptureConfiguration = { .default },
        onRequestCaptured: ((NetworkRequest) -> Void)? = nil,
        shouldMitmConnect: @escaping (String, UInt16) -> Bool = { _, _ in false },
        isTransparentTLSEnabled: @escaping () -> Bool = { false },
        shouldFailOpenAfterMITMFailure: @escaping (String, UInt16, String, MITMFailoverContext) -> Bool = { _, _, reason, context in
            switch context {
            case .transparentTLS:
                !reason.lowercased().contains("sni_invalid_or_missing")
            case .httpConnect:
                true
            }
        },
        onMITMFailure: ((String, String) -> Void)? = nil
    ) {
        self.port = port
        self.eventLog = eventLog
        self.throttler = throttler
        self.interceptor = interceptor
        self.captureConfigProvider = captureConfigProvider
        self.onRequestCaptured = onRequestCaptured
        self.shouldMitmConnect = shouldMitmConnect
        self.isTransparentTLSEnabled = isTransparentTLSEnabled
        self.shouldFailOpenAfterMITMFailure = shouldFailOpenAfterMITMFailure
        self.onMITMFailure = onMITMFailure
    }

    @discardableResult
    func start() throws -> Endpoint {
        lock.lock()
        if let listener = listenerChannel,
           let localAddress = listener.localAddress,
           let localPortRaw = localAddress.port,
           let localPort = UInt16(exactly: localPortRaw) {
            lock.unlock()
            return Endpoint(host: "127.0.0.1", port: localPort)
        }
        lock.unlock()

        let resources = NIORuntime.shared.acquire(for: .networkExtension)
        guard let group = resources.eventLoopGroup as? NIOTSEventLoopGroup else {
            try? NIORuntime.shared.release(for: .networkExtension)
            throw EngineError.eventLoopGroupUnavailable
        }

        let bootstrap = NIOTSListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }

                self.registerChild(channel)
                channel.closeFuture.whenComplete { [weak self, weak channel] _ in
                    guard let self, let channel else { return }
                    self.unregisterChild(channel)
                }

                let ingressHandler = NIOMITMInitialIngressHandler(
                    group: group,
                    eventLog: self.eventLog,
                    throttler: self.throttler,
                    interceptor: self.interceptor,
                    captureConfigProvider: self.captureConfigProvider,
                    onRequestCaptured: self.onRequestCaptured,
                    shouldMitmConnect: self.shouldMitmConnect,
                    shouldEnableTransparentTLS: self.isTransparentTLSEnabled,
                    shouldFailOpenAfterMITMFailure: self.shouldFailOpenAfterMITMFailure,
                    onMITMFailure: self.onMITMFailure
                )
                return channel.pipeline.addHandler(
                    ingressHandler,
                    name: NIOMITMInitialIngressHandler.handlerName
                )
            }

        let listener = try bootstrap.bind(host: "127.0.0.1", port: Int(port)).wait()
        guard let localAddress = listener.localAddress,
              let localPortRaw = localAddress.port,
              let localPort = UInt16(exactly: localPortRaw)
        else {
            _ = try? listener.close().wait()
            try? NIORuntime.shared.release(for: .networkExtension)
            throw EngineError.listenerPortUnavailable
        }

        lock.lock()
        listenerChannel = listener
        runtimeAcquired = true
        lock.unlock()

        ProxyLog.mitm.info(
            "event=proxy.nio_listener_ready outcome=success host=127.0.0.1 port=\(localPort, privacy: .public)"
        )
        eventLog?.append(type: "proxy_nio_listener", msg: "host=127.0.0.1 port=\(localPort)")
        return Endpoint(host: "127.0.0.1", port: localPort)
    }

    func stop() {
        let snapshot: (Channel?, [Channel], Bool)
        lock.lock()
        snapshot = (listenerChannel, Array(childChannels.values), runtimeAcquired)
        listenerChannel = nil
        childChannels.removeAll()
        runtimeAcquired = false
        lock.unlock()

        if let listener = snapshot.0 {
            listener.close(promise: nil)
        }
        for child in snapshot.1 {
            child.close(promise: nil)
        }

        if snapshot.2 {
            try? NIORuntime.shared.release(for: .networkExtension)
        }

        ProxyLog.mitm.info("event=proxy.nio_listener_stopped outcome=success")
    }

    func activeConnectionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return childChannels.count
    }

    private func registerChild(_ channel: Channel) {
        let key = ObjectIdentifier(channel)
        lock.lock()
        childChannels[key] = channel
        lock.unlock()
    }

    private func unregisterChild(_ channel: Channel) {
        let key = ObjectIdentifier(channel)
        lock.lock()
        childChannels.removeValue(forKey: key)
        lock.unlock()
    }
}

private final class NIOMITMInitialIngressHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    static let handlerName = "nioInitialIngressHandler"

    private enum State {
        case probing
        case installing
        case routed
        case closed
    }

    private enum TLSProbeState {
        case needMore
        case tlsClientHello
        case notTLS
    }

    private let group: NIOTSEventLoopGroup
    private weak var eventLog: NDJSONLogWriter?
    private let throttler: PacketThrottler?
    private let interceptor: (any InterceptionProviding)?
    private let captureConfigProvider: () -> CaptureConfiguration
    private let onRequestCaptured: ((NetworkRequest) -> Void)?
    private let shouldMitmConnect: (String, UInt16) -> Bool
    private let shouldEnableTransparentTLS: () -> Bool
    private let shouldFailOpenAfterMITMFailure: (String, UInt16, String, MITMFailoverContext) -> Bool
    private let onMITMFailure: ((String, String) -> Void)?
    private let flowID = UUID().uuidString

    private var state: State = .probing
    private var probeBuffer = ByteBuffer()
    private var upstreamHint: TransparentProxyMetadata.UpstreamHint?
    private var routeDecision = "undecided"
    private var fallbackApplied = false
    private var bypassReason = "none"
    private var sniHash = "unknown"
    private var upstreamHash = "unknown"
    private let maxTLSProbeBytes = 4096
    // Transparent MITM remains HTTP/1.1-only for stability; h2 negotiation here has
    // produced intermittent early-close failures under Dual MITM load.
    private static let transparentRelayALPNProtocols: [String] = ["http/1.1"]
    private static let transparentTLSHandshakeTimeout: TimeAmount = .seconds(5)
    private static let transparentTLSConnectTimeout: TimeAmount = .seconds(6)

    private enum TransparentMITMFailureStage {
        case generic
        case clientTLSHandshake
    }

    private enum TransparentMITMError: LocalizedError {
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

private extension NIOMITMInitialIngressHandler {
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

        let connectHandler = makeConnectHandler(ingressMode: .proxy)
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
                    DualMITMCircuitBreaker.shared.recordTCPClientHandshake(success: false)
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
            ingressMode: .tunneledHTTPS(host: host, port: UInt16(port))
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

        return Self.transparentRelayALPNProtocols.filter { candidate in
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

    private func classifyTransparentMITMFailure(
        _ error: Error,
        stage: TransparentMITMFailureStage = .generic
    ) -> TransparentMITMFailureKind {
        let lowercaseDetail = error.localizedDescription.lowercased()
        if stage == .clientTLSHandshake,
           lowercaseDetail.contains("niossl.niosslerror error 0") {
            return .clientRejectedMITMOrPinning(detail: "niossl_error_0")
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
        return .mitmSetupFailed(detail: error.localizedDescription)
    }

    private func transparentFailureToken(for failureKind: TransparentMITMFailureKind) -> String {
        let typedFailure = MITMFailureMapper.mapTransparentFailure(failureKind)
        return MITMFailureMapper.legacyToken(for: typedFailure)
    }

    private func transparentFailureLogReason(for failureKind: TransparentMITMFailureKind) -> String {
        let token = transparentFailureToken(for: failureKind)
        guard let detail = failureKind.detail,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return token
        }
        return "\(token): \(detail)"
    }

    func shouldRecordTCPHandshakeFailure(for failureKind: TransparentMITMFailureKind) -> Bool {
        switch failureKind {
        case .tlsUpstreamTrustFailed, .tlsUpstreamHostnameMismatch:
            // Certificate trust/hostname validation problems are host-specific and
            // should not globally degrade Dual MITM.
            false
        case .clientRejectedMITMOrPinning,
             .upstreamTimeout,
             .mitmSetupFailed:
            true
        case .connectionClosedEarly, .upstreamConnectionClosed:
            // Early close / unclean shutdown is common for speculative connections and
            // should not bias global breaker health.
            false
        }
    }

    func makeConnectHandler(ingressMode: NIOMITMHTTPConnectHandler.IngressMode) -> NIOMITMHTTPConnectHandler {
        NIOMITMHTTPConnectHandler(
            group: group,
            eventLog: eventLog,
            throttler: throttler,
            interceptor: interceptor,
            captureConfigProvider: captureConfigProvider,
            onRequestCaptured: onRequestCaptured,
            shouldMitmConnect: shouldMitmConnect,
            shouldFailOpenAfterMITMFailure: shouldFailOpenAfterMITMFailure,
            onMITMFailure: onMITMFailure,
            ingressMode: ingressMode
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

    private func tlsProbeState(for buffer: ByteBuffer) -> TLSProbeState {
        guard let firstByte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
            return .needMore
        }
        guard firstByte == 0x16 else {
            return .notTLS
        }
        guard buffer.readableBytes >= 6 else {
            return .needMore
        }

        guard let majorVersion = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
              let handshakeType = buffer.getInteger(at: buffer.readerIndex + 5, as: UInt8.self)
        else {
            return .needMore
        }
        guard majorVersion == 0x03, handshakeType == 0x01 else {
            return .notTLS
        }
        return .tlsClientHello
    }

    func parseTLSSNI(from buffer: ByteBuffer) -> String? {
        var copy = buffer
        let data = Data(copy.readableBytesView)
        return parseTLSSNI(from: data)
    }

    func parseTLSALPNProtocols(from buffer: ByteBuffer) -> [String] {
        var copy = buffer
        let data = Data(copy.readableBytesView)
        return parseTLSALPNProtocols(from: data)
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
    func parseTLSALPNProtocols(from data: Data) -> [String] {
        func u16(_ i: Int) -> Int? {
            guard i + 1 < data.count else { return nil }
            return (Int(data[i]) << 8) | Int(data[i + 1])
        }

        func u24(_ i: Int) -> Int? {
            guard i + 2 < data.count else { return nil }
            return (Int(data[i]) << 16) | (Int(data[i + 1]) << 8) | Int(data[i + 2])
        }

        guard data.count >= 5 else { return [] }
        guard data[0] == 0x16 else { return [] }
        guard data[1] == 0x03 else { return [] }
        guard let recordLen = u16(3) else { return [] }
        let recordEnd = 5 + recordLen
        guard recordEnd <= data.count else { return [] }

        let hsStart = 5
        guard data[hsStart] == 0x01 else { return [] }
        guard let hsLen = u24(hsStart + 1) else { return [] }
        let hsEnd = hsStart + 4 + hsLen
        guard hsEnd <= data.count else { return [] }

        var i = hsStart + 4
        i += 2 + 32
        guard i < hsEnd else { return [] }

        let sessionIDLen = Int(data[i]); i += 1
        i += sessionIDLen
        guard i + 2 <= hsEnd else { return [] }

        guard let cipherLen = u16(i) else { return [] }
        i += 2 + cipherLen
        guard i < hsEnd else { return [] }

        let compLen = Int(data[i]); i += 1
        i += compLen
        guard i + 2 <= hsEnd else { return [] }

        guard let extTotalLen = u16(i) else { return [] }
        i += 2
        let extEnd = i + extTotalLen
        guard extEnd <= hsEnd else { return [] }

        while i + 4 <= extEnd {
            guard let extType = u16(i), let extLen = u16(i + 2) else { return [] }
            i += 4
            let extDataEnd = i + extLen
            guard extDataEnd <= extEnd else { return [] }

            if extType == 0x0010 {
                guard i + 2 <= extDataEnd, let listLen = u16(i) else { return [] }
                var j = i + 2
                let listEnd = j + listLen
                guard listEnd <= extDataEnd else { return [] }

                var protocols: [String] = []
                var seen = Set<String>()
                while j < listEnd {
                    guard j < listEnd else { return protocols }
                    let protoLen = Int(data[j]); j += 1
                    guard j + protoLen <= listEnd else { return protocols }
                    let protoData = data.subdata(in: j ..< (j + protoLen))
                    if let proto = String(data: protoData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(),
                        !proto.isEmpty,
                        !seen.contains(proto) {
                        protocols.append(proto)
                        seen.insert(proto)
                    }
                    j += protoLen
                }
                return protocols
            }

            i = extDataEnd
        }

        return []
    }

    // swiftlint:disable:next cyclomatic_complexity
    func parseTLSSNI(from data: Data) -> String? {
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
        guard data[hsStart] == 0x01 else { return nil }
        guard let hsLen = u24(hsStart + 1) else { return nil }
        let hsEnd = hsStart + 4 + hsLen
        guard hsEnd <= data.count else { return nil }

        var i = hsStart + 4
        i += 2 + 32
        guard i < hsEnd else { return nil }

        let sessionIDLen = Int(data[i]); i += 1
        i += sessionIDLen
        guard i + 2 <= hsEnd else { return nil }

        guard let cipherLen = u16(i) else { return nil }
        i += 2 + cipherLen
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
}

private final class NIOMITMHTTPConnectHandler: ChannelInboundHandler, @unchecked Sendable {
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
    /// Keep MITM ALPN on HTTP/1.1 until tunneled HTTP/2 request stalls are fully resolved.
    static let mitmALPNProtocols: [String] = ["http/1.1"]

    private enum State {
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

    private struct OutboundRequestContext: Sendable {
        let requestSnapshot: NetworkRequest
        let methodToken: String
        let url: String
        let headers: [String: String]
        let body: Data
    }

    private enum StreamingRequestKind {
        case none
        case webSocket
        case sse
    }

    private let group: NIOTSEventLoopGroup
    private weak var eventLog: NDJSONLogWriter?
    private let throttler: PacketThrottler?
    private let interceptor: (any InterceptionProviding)?
    private let captureConfigProvider: () -> CaptureConfiguration
    private let onRequestCaptured: ((NetworkRequest) -> Void)?
    private let shouldMitmConnect: (String, UInt16) -> Bool
    private let shouldFailOpenAfterMITMFailure: (String, UInt16, String, MITMFailoverContext) -> Bool
    private let onMITMFailure: ((String, String) -> Void)?
    private let ingressMode: IngressMode
    private let usesHTTP2StreamSemantics: Bool

    private let connectionID = UUID().uuidString
    private var state: State = .waitingForRequest
    private var upstreamChannel: Channel?
    private var pendingRequestHead: HTTPRequestHead?
    private var pendingRequestBody = ByteBuffer()
    private var connectTargetHost: String?
    private var connectTargetPort: Int?
    private var connectRequestStartTime: Date?
    private var didLogTunnelStatePassthrough = false
    private var transparentTLSUpgradeWatchdog: Scheduled<Void>?
    private var didSelectTransparentTLSProtocol = false

    init(
        group: NIOTSEventLoopGroup,
        eventLog: NDJSONLogWriter?,
        throttler: PacketThrottler?,
        interceptor: (any InterceptionProviding)?,
        captureConfigProvider: @escaping () -> CaptureConfiguration,
        onRequestCaptured: ((NetworkRequest) -> Void)?,
        shouldMitmConnect: @escaping (String, UInt16) -> Bool,
        shouldFailOpenAfterMITMFailure: @escaping (String, UInt16, String, MITMFailoverContext) -> Bool,
        onMITMFailure: ((String, String) -> Void)?,
        ingressMode: IngressMode,
        usesHTTP2StreamSemantics: Bool = false
    ) {
        self.group = group
        self.eventLog = eventLog
        self.throttler = throttler
        self.interceptor = interceptor
        self.captureConfigProvider = captureConfigProvider
        self.onRequestCaptured = onRequestCaptured
        self.shouldMitmConnect = shouldMitmConnect
        self.shouldFailOpenAfterMITMFailure = shouldFailOpenAfterMITMFailure
        self.onMITMFailure = onMITMFailure
        self.ingressMode = ingressMode
        self.usesHTTP2StreamSemantics = usesHTTP2StreamSemantics
        if case let .tunneledHTTPS(host, port) = ingressMode {
            connectTargetHost = host
            connectTargetPort = Int(port)
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
            sendResponse(
                status: .badRequest,
                body: "HTTP request pipelining is not supported by the NIO engine yet",
                closeAfterSend: true,
                context: context
            )
            if case .head = part {
                Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelTransparentTLSUpgradeWatchdog()
        logConnectStage(stage: "client_channel_inactive", outcome: "closed")
        upstreamChannel?.close(promise: nil)
        connectRequestStartTime = nil
        state = .closed
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        cancelTransparentTLSUpgradeWatchdog()
        let failure = classifyClientHandlerFailure(error)
        ProxyLog.mitm.warning(
            "event=proxy.nio_connect_handler_error outcome=failure error=\(error.localizedDescription, privacy: .public) classified=\(failure.reason, privacy: .public)"
        )
        logConnectStage(
            stage: "client_handler_error",
            outcome: "failure",
            detail: "\(error.localizedDescription) classified=\(failure.reason)"
        )
        if failure.shouldReport {
            reportMITMFailure(reason: failure.reason)
        }
        upstreamChannel?.close(promise: nil)
        connectRequestStartTime = nil
        state = .closed
        context.close(promise: nil)
    }

    private func handleInitialRequestPart(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
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

    private func handleHTTPRequestPart(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
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

    private func processHTTPRequest(head: HTTPRequestHead, body: ByteBuffer, context: ChannelHandlerContext) {
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
            requestHeaders: dictionary(from: head.headers),
            requestBodyData: requestBodyData,
            startTime: requestStart,
            captureConfig: captureConfig
        )

        state = .forwardingHTTPRequest
        requestInterceptionFuture(
            flowID: flowID,
            requestURL: resolvedURL,
            methodToken: head.method.rawValue,
            requestHeaders: dictionary(from: head.headers),
            requestBodyData: requestBodyData,
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

    private func handleInterceptionResult(
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
            blocked.extractHTTPFields()
            NetworkThrottlingController.shared.applyMetadata(to: &blocked)
            finalizeCapturedDuration(for: &blocked)
            onRequestCaptured?(blocked)
            Task {
                await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
            }
            sendResponse(status: .forbidden, body: nil, closeAfterSend: shouldCloseConnection(requestHead: requestHead, responseHeaders: HTTPHeaders()), context: context) { [weak self] in
                self?.state = self?.shouldCloseConnection(requestHead: requestHead, responseHeaders: HTTPHeaders()) == true ? .closed : .waitingForRequest
            }

        case let .failed(failure):
            switch failure {
            case .timeout:
                context.eventLoop.scheduleTask(in: .milliseconds(500)) { [weak self] in
                    self?.state = .closed
                    context.close(promise: nil)
                }
            case .connectionReset, .dropConnection, .packetLoss:
                state = .closed
                context.close(promise: nil)
            }

        case let .mocked(mockRequest):
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
                sendResponse(status: .badRequest, body: "Invalid outbound request", closeAfterSend: true, context: context)
                Task { await ProxyNetworkMetrics.shared.recordHTTPParseFailure() }
                return
            }
            emitPendingTunneledSnapshotIfNeeded(outboundContext.requestSnapshot)
            forwardModifiedHTTPRequest(outboundContext, requestHead: requestHead, context: context)
        }
    }

    private func emitPendingTunneledSnapshotIfNeeded(_ request: NetworkRequest) {
        guard case .tunneledHTTPS = ingressMode else { return }
        guard let onRequestCaptured else { return }

        var snapshot = request
        snapshot.extractHTTPFields()
        NetworkThrottlingController.shared.applyMetadata(to: &snapshot)
        onRequestCaptured(snapshot)
        eventLog?.append(
            type: "proxy_nio_tunneled_request",
            msg: "outcome=pending_saved mode=\(self.ingressModeLabel) id=\(self.connectionID) request_id=\(snapshot.id.uuidString) method=\(snapshot.method.rawValue) url_hash=\(LogRedaction.hash(snapshot.url)) h2_stream=\(usesHTTP2StreamSemantics)"
        )
    }

    private func beginCONNECTMITM(host: String, port: Int, context: ChannelHandlerContext) {
        logConnectStage(stage: "mitm_prepare", outcome: "begin")
        do {
            let tlsContext = try Self.makeServerTLSContext(for: host)
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

    private func installMITMDecryptionPipeline(
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

    private func attemptMITMFallbackToPassthrough(
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

    fileprivate func installTransparentTLSPipeline(
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

    private func installTunneledHTTP1Pipeline(
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

    private func installTunneledHTTP2Pipeline(
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

    private func makeTunneledHTTPHandler(
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
            shouldFailOpenAfterMITMFailure: shouldFailOpenAfterMITMFailure,
            onMITMFailure: onMITMFailure,
            ingressMode: .tunneledHTTPS(host: host, port: UInt16(port)),
            usesHTTP2StreamSemantics: usesHTTP2StreamSemantics
        )
    }

    private func connectUpstream(
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

    private func forwardModifiedHTTPRequest(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard let httpClient = NIORuntime.shared.currentResources()?.httpClient else {
            sendResponse(status: .internalServerError, body: "NIO runtime unavailable", closeAfterSend: true, context: context)
            return
        }

        var outboundHeaders = makeHTTPHeaders(from: outboundContext.headers)
        let outboundBodyData = normalizeWireBody(
            outboundContext.body,
            headers: &outboundHeaders,
            compressionInfo: outboundContext.requestSnapshot.requestBody.getCompressionInfo(),
            direction: "request"
        )
        switch streamingRequestKind(requestHead: requestHead, headers: outboundHeaders) {
        case .webSocket:
            forwardWebSocketStream(
                outboundContext,
                requestHead: requestHead,
                outboundHeaders: outboundHeaders,
                context: context
            )
            return
        case .sse:
            forwardSSEStream(
                outboundContext,
                requestHead: requestHead,
                outboundHeaders: outboundHeaders,
                context: context
            )
            return
        case .none:
            break
        }

        let sanitizedHeaders = sanitizedRequestHeaders(from: outboundHeaders)
        let method = NIOHTTP1.HTTPMethod(rawValue: outboundContext.methodToken) ?? .RAW(value: outboundContext.methodToken)
        let outboundBodyBuffer = byteBuffer(from: outboundBodyData, allocator: context.channel.allocator)
        let outboundBody: HTTPClient.Body? = outboundBodyData.isEmpty ? nil : .byteBuffer(outboundBodyBuffer)

        let outboundRequest: HTTPClient.Request
        do {
            outboundRequest = try HTTPClient.Request(
                url: outboundContext.url,
                method: method,
                headers: sanitizedHeaders,
                body: outboundBody
            )
        } catch {
            sendResponse(status: .badRequest, body: "Invalid outbound request", closeAfterSend: true, context: context)
            return
        }

        throttle(
            direction: .upload,
            bytes: outboundBodyData.count,
            context: context
        ) { [weak self] in
            guard let self else { return }
            self.responsePipelineFuture(for: outboundContext.url, eventLoop: context.eventLoop)
                .and(self.blockQUICEnabledFuture(eventLoop: context.eventLoop))
                .whenComplete { [weak self] planResult in
                    context.eventLoop.execute {
                        guard let self, self.state == .forwardingHTTPRequest else { return }

                        let responsePipeline: ResponsePipeline
                        let blockQUIC: Bool
                        switch planResult {
                        case let .success(plan):
                            responsePipeline = plan.0
                            blockQUIC = plan.1
                        case let .failure(error):
                            responsePipeline = .bufferAndIntercept
                            blockQUIC = true
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_response_pipeline outcome=failure url=\(outboundContext.url, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public)"
                            )
                        }

                        self.logConnectStage(
                            stage: "response_pipeline",
                            outcome: "selected",
                            detail: responsePipeline == .streamAndCapture ? "stream_and_capture" : "buffer_and_intercept"
                        )

                        let upstreamDeadline = NIODeadline.now() + .seconds(Self.upstreamHTTPResponseDeadlineSeconds)
                        self.logConnectStage(
                            stage: "http_upstream",
                            outcome: "start",
                            detail: "deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds)"
                        )
                        if responsePipeline == .streamAndCapture {
                            self.forwardStreamingUpstreamResponse(
                                httpClient: httpClient,
                                request: outboundRequest,
                                outboundContext: outboundContext,
                                requestHead: requestHead,
                                context: context,
                                blockQUIC: blockQUIC,
                                upstreamDeadline: upstreamDeadline,
                                metricsAsParsedResponse: true
                            )
                            return
                        }
                        httpClient.execute(request: outboundRequest, deadline: upstreamDeadline).whenComplete { [weak self] result in
                            context.eventLoop.execute {
                                guard let self, self.state == .forwardingHTTPRequest else { return }
                                switch result {
                                case let .success(response):
                                    var forwardedHeaders = response.headers
                                    if blockQUIC, outboundContext.url.lowercased().hasPrefix("https://") {
                                        forwardedHeaders.remove(name: "Alt-Svc")
                                        forwardedHeaders.add(name: "Alt-Svc", value: "clear")
                                    }
                                    self.logConnectStage(
                                        stage: "http_upstream",
                                        outcome: "response",
                                        detail: "version=\(response.version.major).\(response.version.minor),status=\(response.status.code)"
                                    )

                                    let responseHeadersTrace = self.traceHeaders(from: forwardedHeaders)
                                    let responseBodyData = self.byteBufferToData(response.body ?? ByteBuffer())
                                    let captureConfig = self.captureConfigProvider()
                                    var captured = outboundContext.requestSnapshot
                                    captured.protocolVersion = self.httpProtocolVersion(from: response.version)
                                    captured.statusCode = Int(response.status.code)
                                    captured.statusMessage = response.status.reasonPhrase
                                    captured.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                                    let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                                    let responseContentEncoding = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                                    captured.responseBody = self.bodyStorage(
                                        from: responseBodyData,
                                        charset: responseCharset,
                                        contentEncoding: responseContentEncoding,
                                        captureConfig: captureConfig
                                    )
                                    captured.extractHTTPFields()
                                    NetworkThrottlingController.shared.applyMetadata(to: &captured)

                                    self.responseInterceptionFuture(
                                        fallbackRequest: captured,
                                        statusCode: Int(response.status.code),
                                        statusMessage: response.status.reasonPhrase,
                                        responseHeaders: responseHeadersTrace,
                                        responseBodyData: responseBodyData,
                                        eventLoop: context.eventLoop
                                    ).whenComplete { [weak self] interceptResult in
                                        context.eventLoop.execute {
                                            guard let self, self.state == .forwardingHTTPRequest else { return }
                                            switch interceptResult {
                                            case let .success(interceptedRequest):
                                                self.deliverCapturedResponse(
                                                    interceptedRequest,
                                                    requestHead: requestHead,
                                                    context: context,
                                                    metricsAsParsedResponse: true
                                                )
                                            case .failure:
                                                self.deliverCapturedResponse(
                                                    captured,
                                                    requestHead: requestHead,
                                                    context: context,
                                                    metricsAsParsedResponse: true
                                                )
                                            }
                                        }
                                    }
                                case let .failure(error):
                                    let classifiedFailure = self.classifyMITMFailure(error)
                                    self.reportMITMFailure(reason: classifiedFailure)
                                    self.logConnectStage(stage: "http_upstream", outcome: "failure", detail: error.localizedDescription)
                                    let targetHost = URL(string: outboundContext.url)?.host ?? "unknown"
                                    ProxyLog.mitm.warning(
                                        "event=proxy.nio_http_upstream outcome=failure method=\(outboundContext.methodToken, privacy: .public) host=\(targetHost, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public) classified=\(classifiedFailure, privacy: .public) deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds, privacy: .public)"
                                    )
                                    self.eventLog?.append(
                                        type: "proxy_nio_http_upstream_failure",
                                        msg: "method=\(outboundContext.methodToken) host_hash=\(LogRedaction.hash(targetHost)) error=\(error.localizedDescription) classified=\(classifiedFailure) deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds)"
                                    )
                                    self.sendResponse(
                                        status: .badGateway,
                                        body: "Upstream HTTP request failed",
                                        closeAfterSend: true,
                                        context: context
                                    )
                                }
                            }
                        }
                    }
                }
        }
    }

    private func streamingRequestKind(requestHead: HTTPRequestHead, headers: HTTPHeaders) -> StreamingRequestKind {
        guard requestHead.version.major == 1 else {
            return .none
        }
        if isWebSocketUpgrade(headers: headers) {
            return .webSocket
        }
        if isSSERequest(headers: headers) {
            return .sse
        }
        return .none
    }

    private func forwardSSEStream(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        guard let targetURL = URL(string: outboundContext.url),
              let targetHost = targetURL.host
        else {
            sendResponse(status: .badRequest, body: "Invalid SSE request target", closeAfterSend: true, context: context)
            return
        }

        let targetPort = targetURL.port ?? ((targetURL.scheme?.lowercased() == "https") ? 443 : 80)
        var requestHeaders = sanitizedStreamingRequestHeaders(from: outboundHeaders)
        requestHeaders.remove(name: "Accept-Encoding")
        requestHeaders.replaceOrAdd(name: "Accept-Encoding", value: "identity")
        let requestBuffer = makeRawStreamingRequestBuffer(
            url: targetURL,
            method: outboundContext.methodToken,
            headers: requestHeaders,
            body: outboundContext.body,
            allocator: context.channel.allocator
        )
        let sseCapture = NIOMITMSSECaptureState(baseRequest: outboundContext.requestSnapshot)
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)

        let bootstrap = NIOTSConnectionBootstrap(group: group)
        bootstrap.connect(host: targetHost, port: targetPort).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self, self.state == .forwardingHTTPRequest else {
                    if case let .success(upstream) = result {
                        upstream.close(promise: nil)
                    }
                    return
                }

                switch result {
                case let .success(upstream):
                    self.upstreamChannel = upstream
                    var closeAfterSend = false
                    var responseHeadSeen = false

                    let onPart: @Sendable (HTTPClientResponsePart) -> Void = { [weak self, weak upstream] part in
                        let context = sendableContext.value
                        guard let self, let upstream else { return }
                        context.eventLoop.execute {
                            guard self.state == .forwardingHTTPRequest else { return }
                            switch part {
                            case let .head(head):
                                responseHeadSeen = true
                                closeAfterSend = self.shouldCloseConnection(requestHead: requestHead, responseHeaders: head.headers)
                                sseCapture.beginResponse(
                                    head: head,
                                    captureConfig: self.captureConfigProvider()
                                )
                                var forwardedHead = head
                                forwardedHead.headers.remove(name: "Proxy-Connection")
                                context.write(self.wrapOutboundOut(.head(forwardedHead)), promise: nil)
                            case let .body(buffer):
                                let chunkData = self.byteBufferToData(buffer)
                                sseCapture.consume(
                                    bodyChunk: chunkData,
                                    captureConfig: self.captureConfigProvider(),
                                    onRequestCaptured: self.onRequestCaptured
                                )
                                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                            case let .end(trailers):
                                sseCapture.finish(
                                    succeeded: true,
                                    captureConfig: self.captureConfigProvider(),
                                    onRequestCaptured: self.onRequestCaptured
                                )
                                let promise = context.eventLoop.makePromise(of: Void.self)
                                promise.futureResult.whenComplete { _ in
                                    self.upstreamChannel = nil
                                    upstream.close(promise: nil)
                                    self.state = closeAfterSend ? .closed : .waitingForRequest
                                    if closeAfterSend {
                                        context.close(promise: nil)
                                    }
                                }
                                context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
                            }
                        }
                    }

                    let onError: @Sendable (Error) -> Void = { [weak self] error in
                        let context = sendableContext.value
                        context.eventLoop.execute {
                            guard let self, self.state == .forwardingHTTPRequest else { return }
                            self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_sse_upstream_error outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                            sseCapture.finish(
                                succeeded: false,
                                captureConfig: self.captureConfigProvider(),
                                onRequestCaptured: self.onRequestCaptured
                            )
                            self.sendResponse(
                                status: .badGateway,
                                body: "Upstream SSE request failed",
                                closeAfterSend: true,
                                context: context
                            )
                            self.state = .closed
                            self.upstreamChannel = nil
                        }
                    }

                    let onInactive: @Sendable () -> Void = { [weak self] in
                        let context = sendableContext.value
                        context.eventLoop.execute {
                            guard let self, self.state == .forwardingHTTPRequest else { return }
                            sseCapture.finish(
                                succeeded: responseHeadSeen,
                                captureConfig: self.captureConfigProvider(),
                                onRequestCaptured: self.onRequestCaptured
                            )
                            self.state = .closed
                            context.close(promise: nil)
                        }
                    }

                    self.installStreamingUpstreamHTTPPipeline(
                        on: upstream,
                        onResponsePart: onPart,
                        onError: onError,
                        onInactive: onInactive
                    ).flatMap {
                        self.writeAndFlush(requestBuffer, to: upstream)
                    }.whenComplete { [weak self] pipelineResult in
                        guard let self else { return }
                        if case let .failure(error) = pipelineResult {
                            self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_sse_setup outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                            sseCapture.finish(
                                succeeded: false,
                                captureConfig: self.captureConfigProvider(),
                                onRequestCaptured: self.onRequestCaptured
                            )
                            self.sendResponse(
                                status: .badGateway,
                                body: "Failed to establish SSE upstream",
                                closeAfterSend: true,
                                context: context
                            )
                            self.state = .closed
                            self.upstreamChannel = nil
                            upstream.close(promise: nil)
                        }
                    }
                case let .failure(error):
                    self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_sse_connect outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.sendResponse(
                        status: .badGateway,
                        body: "Failed to establish SSE upstream",
                        closeAfterSend: true,
                        context: context
                    )
                }
            }
        }
    }

    private func forwardWebSocketStream(
        _ outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        outboundHeaders: HTTPHeaders,
        context: ChannelHandlerContext
    ) {
        guard let targetURL = URL(string: outboundContext.url),
              let targetHost = targetURL.host
        else {
            sendResponse(status: .badRequest, body: "Invalid WebSocket request target", closeAfterSend: true, context: context)
            return
        }

        let targetPort = targetURL.port ?? ((targetURL.scheme?.lowercased() == "https") ? 443 : 80)
        let requestHeaders = sanitizedStreamingRequestHeaders(from: outboundHeaders)
        let requestBuffer = makeRawStreamingRequestBuffer(
            url: targetURL,
            method: outboundContext.methodToken,
            headers: requestHeaders,
            body: outboundContext.body,
            allocator: context.channel.allocator
        )
        let wsCapture = NIOMITMWebSocketCaptureState(
            url: normalizedWebSocketURL(from: outboundContext.url),
            requestHeaders: traceHeaders(from: requestHeaders)
        )
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)

        let bootstrap = NIOTSConnectionBootstrap(group: group)
        bootstrap.connect(host: targetHost, port: targetPort).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self, self.state == .forwardingHTTPRequest else {
                    if case let .success(upstream) = result {
                        upstream.close(promise: nil)
                    }
                    return
                }

                switch result {
                case let .success(upstream):
                    self.upstreamChannel = upstream
                    var responseHead: HTTPResponseHead?
                    var responseBody = context.channel.allocator.buffer(capacity: 0)
                    var closeAfterSend = false

                    let onPart: @Sendable (HTTPClientResponsePart) -> Void = { [weak self, weak upstream] part in
                        let context = sendableContext.value
                        guard let self, let upstream else { return }
                        context.eventLoop.execute {
                            guard self.state == .forwardingHTTPRequest else { return }
                            switch part {
                            case let .head(head):
                                responseHead = head
                                closeAfterSend = self.shouldCloseConnection(
                                    requestHead: requestHead,
                                    responseHeaders: head.headers
                                )
                                var forwardedHead = head
                                forwardedHead.headers.remove(name: "Proxy-Connection")
                                context.write(self.wrapOutboundOut(.head(forwardedHead)), promise: nil)
                            case let .body(buffer):
                                guard responseHead?.status != .switchingProtocols else { return }
                                var mutable = buffer
                                responseBody.writeBuffer(&mutable)
                                context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                            case let .end(trailers):
                                guard let head = responseHead else {
                                    self.sendResponse(
                                        status: .badGateway,
                                        body: "Invalid WebSocket upstream response",
                                        closeAfterSend: true,
                                        context: context
                                    )
                                    self.state = .closed
                                    self.upstreamChannel = nil
                                    upstream.close(promise: nil)
                                    wsCapture.markFailed()
                                    return
                                }

                                let isUpgrade = head.status == .switchingProtocols &&
                                    self.isWebSocketUpgrade(headers: head.headers)
                                if isUpgrade {
                                    wsCapture.markOpen(
                                        responseHeaders: self.captureConfigProvider().captureHeaders
                                            ? self.traceHeaders(from: head.headers)
                                            : []
                                    )
                                    let promise = context.eventLoop.makePromise(of: Void.self)
                                    promise.futureResult.whenComplete { [weak self] _ in
                                        guard let self else { return }
                                        self.installWebSocketRelay(
                                            clientContext: context,
                                            upstream: upstream,
                                            captureState: wsCapture
                                        )
                                    }
                                    context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
                                    return
                                }

                                let responseBodyData = self.byteBufferToData(responseBody)
                                let captureConfig = self.captureConfigProvider()
                                let responseHeadersTrace = self.traceHeaders(from: head.headers)
                                var captured = outboundContext.requestSnapshot
                                captured.protocolVersion = self.httpProtocolVersion(from: head.version)
                                captured.statusCode = Int(head.status.code)
                                captured.statusMessage = head.status.reasonPhrase
                                captured.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                                let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                                let responseContentEncoding = responseHeadersTrace.first(where: { $0.key.lowercased() == "content-encoding" })?.value
                                captured.responseBody = self.bodyStorage(
                                    from: responseBodyData,
                                    charset: responseCharset,
                                    contentEncoding: responseContentEncoding,
                                    captureConfig: captureConfig
                                )
                                captured.extractHTTPFields()
                                NetworkThrottlingController.shared.applyMetadata(to: &captured)
                                self.finalizeCapturedDuration(for: &captured)
                                self.onRequestCaptured?(captured)

                                let promise = context.eventLoop.makePromise(of: Void.self)
                                promise.futureResult.whenComplete { _ in
                                    self.upstreamChannel = nil
                                    upstream.close(promise: nil)
                                    self.state = closeAfterSend ? .closed : .waitingForRequest
                                    if closeAfterSend {
                                        context.close(promise: nil)
                                    }
                                }
                                context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
                            }
                        }
                    }

                    let onError: @Sendable (Error) -> Void = { [weak self] error in
                        let context = sendableContext.value
                        context.eventLoop.execute {
                            guard let self, self.state == .forwardingHTTPRequest else { return }
                            self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_ws_upstream_error outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                            wsCapture.markFailed()
                            self.sendResponse(
                                status: .badGateway,
                                body: "Upstream WebSocket request failed",
                                closeAfterSend: true,
                                context: context
                            )
                            self.state = .closed
                            self.upstreamChannel = nil
                        }
                    }

                    let onInactive: @Sendable () -> Void = { [weak self] in
                        let context = sendableContext.value
                        context.eventLoop.execute {
                            guard let self, self.state == .forwardingHTTPRequest else { return }
                            wsCapture.markClosed(code: nil, reason: nil)
                            self.state = .closed
                            context.close(promise: nil)
                        }
                    }

                    self.installStreamingUpstreamHTTPPipeline(
                        on: upstream,
                        onResponsePart: onPart,
                        onError: onError,
                        onInactive: onInactive
                    ).flatMap {
                        self.writeAndFlush(requestBuffer, to: upstream)
                    }.whenComplete { [weak self] pipelineResult in
                        guard let self else { return }
                        if case let .failure(error) = pipelineResult {
                            self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                            ProxyLog.mitm.warning(
                                "event=proxy.nio_ws_setup outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                            wsCapture.markFailed()
                            self.sendResponse(
                                status: .badGateway,
                                body: "Failed to establish WebSocket upstream",
                                closeAfterSend: true,
                                context: context
                            )
                            self.state = .closed
                            self.upstreamChannel = nil
                            upstream.close(promise: nil)
                        }
                    }
                case let .failure(error):
                    self.reportMITMFailure(reason: self.classifyMITMFailure(error))
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_ws_connect outcome=failure host=\(targetHost, privacy: .private(mask: .hash)) port=\(targetPort, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.sendResponse(
                        status: .badGateway,
                        body: "Failed to establish WebSocket upstream",
                        closeAfterSend: true,
                        context: context
                    )
                }
            }
        }
    }

    private func installStreamingUpstreamHTTPPipeline(
        on upstream: Channel,
        onResponsePart: @escaping @Sendable (HTTPClientResponsePart) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onInactive: @escaping @Sendable () -> Void
    ) -> EventLoopFuture<Void> {
        upstream.pipeline
            .addHandler(
                ByteToMessageHandler(
                    HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)
                ),
                name: Self.upstreamHTTPDecoderName
            )
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

    private func installWebSocketRelay(
        clientContext: ChannelHandlerContext,
        upstream: Channel,
        captureState: NIOMITMWebSocketCaptureState
    ) {
        let clientChannel = clientContext.channel
        removeHandlerIfPresent(name: Self.upstreamHTTPHandlerName, from: upstream)
            .flatMap {
                self.removeHandlerIfPresent(name: Self.upstreamHTTPDecoderName, from: upstream)
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
                        captureState: captureState
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
                        captureState: captureState
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
                    self?.state = .tunnelEstablished
                case let .failure(error):
                    captureState.markFailed()
                    ProxyLog.mitm.warning(
                        "event=proxy.nio_ws_relay_install outcome=failure error=\(error.localizedDescription, privacy: .public)"
                    )
                    self?.state = .closed
                    upstream.close(promise: nil)
                    clientChannel.close(promise: nil)
                }
            }
    }

    private func removeHandlerIfPresent(name: String, from channel: Channel) -> EventLoopFuture<Void> {
        channel.pipeline
            .removeHandler(name: name)
            .flatMapError { _ in
                channel.eventLoop.makeSucceededVoidFuture()
            }
    }

    private func removeCurrentHTTPPipelineHandlers(from channel: Channel) -> EventLoopFuture<Void> {
        removeCurrentHTTPPipelineHandlersIfPresent(from: channel)
    }

    private func removeCurrentHTTPPipelineHandlersIfPresent(from channel: Channel) -> EventLoopFuture<Void> {
        var future = channel.eventLoop.makeSucceededVoidFuture()
        for name in currentHTTPPipelineHandlerNames() {
            future = future.flatMap {
                self.removeHandlerIfPresent(name: name, from: channel)
            }
        }
        return future
    }

    private func currentHTTPPipelineHandlerNames() -> [String] {
        switch ingressMode {
        case .proxy:
            [Self.handlerName, Self.decoderName, Self.encoderName]
        case .tunneledHTTPS:
            [Self.tunneledHandlerName, Self.tunneledDecoderName, Self.tunneledEncoderName]
        }
    }

    private func currentHTTPPipelinePresenceSummary(on channel: Channel) -> EventLoopFuture<String> {
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

    private func makeRawStreamingRequestBuffer(
        url: URL,
        method: String,
        headers: HTTPHeaders,
        body: Data,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        var requestHeaders = headers
        requestHeaders.remove(name: "Proxy-Connection")

        if requestHeaders.first(name: "Host") == nil, let host = url.host {
            let scheme = (url.scheme ?? "http").lowercased()
            let defaultPort = scheme == "https" ? 443 : 80
            let hostValue: String = if let port = url.port, port != defaultPort {
                "\(host):\(port)"
            } else {
                host
            }
            requestHeaders.add(name: "Host", value: hostValue)
        }

        if !body.isEmpty,
           requestHeaders.first(name: "Content-Length") == nil,
           requestHeaders.first(name: "Transfer-Encoding") == nil {
            requestHeaders.add(name: "Content-Length", value: "\(body.count)")
        }

        var path = url.path
        if path.isEmpty {
            path = "/"
        }
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }

        var buffer = allocator.buffer(capacity: 512 + body.count)
        buffer.writeString("\(method) \(path) HTTP/1.1\r\n")
        for header in requestHeaders {
            buffer.writeString("\(header.name): \(header.value)\r\n")
        }
        buffer.writeString("\r\n")
        if !body.isEmpty {
            buffer.writeBytes(body)
        }
        return buffer
    }

    private func writeAndFlush(_ buffer: ByteBuffer, to channel: Channel) -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(buffer, promise: promise)
        return promise.futureResult
    }

    private func deliverCapturedResponse(
        _ request: NetworkRequest,
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext,
        metricsAsParsedResponse: Bool
    ) {
        let responseStatusCode = request.statusCode ?? 200
        let responseStatus = HTTPResponseStatus(
            statusCode: responseStatusCode,
            reasonPhrase: request.statusMessage ?? HTTPResponseStatus(statusCode: responseStatusCode).reasonPhrase
        )
        var responseHeaders = makeHTTPHeaders(from: request.responseHeaders)
        var responseBodyData = request.responseBody.getData()
            ?? request.responseBody.getString()?.data(using: .utf8)
            ?? Data()
        responseBodyData = normalizeWireBody(
            responseBodyData,
            headers: &responseHeaders,
            compressionInfo: request.responseBody.getCompressionInfo(),
            direction: "response"
        )
        let closeAfterSend = shouldCloseConnection(requestHead: requestHead, responseHeaders: responseHeaders)
        let sanitizedHeaders = sanitizedResponseHeaders(
            from: responseHeaders,
            bodyBytes: responseBodyData.count,
            closeAfterSend: closeAfterSend
        )
        let responseBodyBuffer = byteBuffer(from: responseBodyData, allocator: context.channel.allocator)

        throttle(direction: .download, bytes: responseBodyData.count, context: context) { [weak self] in
            guard let self else { return }
            self.sendHTTPResponse(
                status: responseStatus,
                headers: sanitizedHeaders,
                body: responseBodyBuffer,
                closeAfterSend: closeAfterSend,
                context: context
            ) { [weak self] in
                guard let self else { return }
                var finalized = request
                self.finalizeCapturedDuration(for: &finalized)
                self.onRequestCaptured?(finalized)
                if metricsAsParsedResponse {
                    Task {
                        await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                        await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
                    }
                }
                self.state = closeAfterSend ? .closed : .waitingForRequest
            }
        }
    }

    private func deliverRawUpstreamResponse(
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        bodyData: Data,
        capturedRequest: NetworkRequest,
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext,
        metricsAsParsedResponse: Bool
    ) {
        let closeAfterSend = shouldCloseConnection(requestHead: requestHead, responseHeaders: headers)
        let sanitizedHeaders = sanitizedResponseHeaders(
            from: headers,
            bodyBytes: bodyData.count,
            closeAfterSend: closeAfterSend
        )
        let responseBodyBuffer = byteBuffer(from: bodyData, allocator: context.channel.allocator)

        throttle(direction: .download, bytes: bodyData.count, context: context) { [weak self] in
            guard let self else { return }
            self.sendHTTPResponse(
                status: status,
                headers: sanitizedHeaders,
                body: responseBodyBuffer,
                closeAfterSend: closeAfterSend,
                context: context
            ) { [weak self] in
                guard let self else { return }
                var finalized = capturedRequest
                self.finalizeCapturedDuration(for: &finalized)
                self.onRequestCaptured?(finalized)
                if metricsAsParsedResponse {
                    Task {
                        await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                        await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
                    }
                }
                self.state = closeAfterSend ? .closed : .waitingForRequest
            }
        }
    }

    private func forwardStreamingUpstreamResponse(
        httpClient: HTTPClient,
        request: HTTPClient.Request,
        outboundContext: OutboundRequestContext,
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext,
        blockQUIC: Bool,
        upstreamDeadline: NIODeadline,
        metricsAsParsedResponse: Bool
    ) {
        let captureConfig = captureConfigProvider()
        let maxCapturedBodyBytes = captureConfig.captureBody ? max(0, captureConfig.maxBodySize) : 0
        var capturedBodyData = Data()
        var receivedBodyBytes = 0
        var didTruncateCapturedBody = false
        var declaredResponseBodyBytes: Int?
        var capturedRequest = outboundContext.requestSnapshot
        var responseHead: HTTPResponseHead?
        var responseHeadersTrace: [TraceHTTPHeader] = []
        var closeAfterSend = false
        var responseHeadSent = false
        var terminalStateReached = false
        let targetHost = URL(string: outboundContext.url)?.host ?? "unknown"
        let sendableContext = NIOMITMUncheckedSendableBox(value: context)

        let onHead: @Sendable (HTTPResponseHead) -> EventLoopFuture<Void> = { [weak self] head in
            let context = sendableContext.value
            guard let self else {
                return context.eventLoop.makeSucceededVoidFuture()
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.eventLoop.execute {
                guard self.state == .forwardingHTTPRequest, !terminalStateReached else {
                    promise.succeed(())
                    return
                }

                responseHead = head
                responseHeadSent = true
                declaredResponseBodyBytes = self.contentLength(from: head.headers)
                capturedRequest.protocolVersion = self.httpProtocolVersion(from: head.version)
                self.logConnectStage(
                    stage: "http_upstream",
                    outcome: "response",
                    detail: "version=\(head.version.major).\(head.version.minor),status=\(head.status.code)"
                )

                var forwardedHeaders = head.headers
                if blockQUIC, outboundContext.url.lowercased().hasPrefix("https://") {
                    forwardedHeaders.remove(name: "Alt-Svc")
                    forwardedHeaders.add(name: "Alt-Svc", value: "clear")
                }
                closeAfterSend = self.shouldCloseConnection(requestHead: requestHead, responseHeaders: forwardedHeaders)
                responseHeadersTrace = self.traceHeaders(from: forwardedHeaders)

                if head.status.code >= 400 {
                    self.logConnectStage(
                        stage: "response_emit",
                        outcome: "error",
                        detail: "status=\(head.status.code),close=\(closeAfterSend),h2_stream=\(self.usesHTTP2StreamSemantics)"
                    )
                    self.eventLog?.append(
                        type: "proxy_nio_error_response",
                        msg: "mode=\(self.ingressModeLabel) id=\(self.connectionID) status=\(head.status.code) close=\(closeAfterSend) h2_stream=\(self.usesHTTP2StreamSemantics)"
                    )
                }

                let responseHead = HTTPResponseHead(
                    version: .http1_1,
                    status: head.status,
                    headers: self.streamingResponseHeaders(from: forwardedHeaders, closeAfterSend: closeAfterSend)
                )
                context.writeAndFlush(self.wrapOutboundOut(.head(responseHead)), promise: promise)
            }
            return promise.futureResult
        }

        let onBodyPart: @Sendable (ByteBuffer) -> EventLoopFuture<Void> = { [weak self] buffer in
            let context = sendableContext.value
            guard let self else {
                return context.eventLoop.makeSucceededVoidFuture()
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.eventLoop.execute {
                guard self.state == .forwardingHTTPRequest, !terminalStateReached else {
                    promise.succeed(())
                    return
                }

                let chunkBytes = buffer.readableBytes
                if chunkBytes > 0 {
                    receivedBodyBytes += chunkBytes
                }

                if maxCapturedBodyBytes > 0, chunkBytes > 0 {
                    let remaining = maxCapturedBodyBytes - capturedBodyData.count
                    if remaining > 0 {
                        let chunkData = self.byteBufferToData(buffer)
                        if chunkData.count <= remaining {
                            capturedBodyData.append(chunkData)
                        } else {
                            capturedBodyData.append(chunkData.prefix(remaining))
                            didTruncateCapturedBody = true
                        }
                    } else {
                        didTruncateCapturedBody = true
                    }
                }

                let writeChunk = {
                    context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
                }
                if buffer.readableBytes > 0 {
                    self.throttle(
                        direction: .download,
                        bytes: buffer.readableBytes,
                        context: context,
                        operation: writeChunk
                    )
                } else {
                    writeChunk()
                }
            }
            return promise.futureResult
        }

        let onFinish: @Sendable () throws -> Void = { [weak self] in
            let context = sendableContext.value
            guard let self else { return }
            context.eventLoop.execute {
                guard self.state == .forwardingHTTPRequest, !terminalStateReached else { return }
                terminalStateReached = true

                let finalStatus = responseHead?.status ?? .ok
                capturedRequest.statusCode = Int(finalStatus.code)
                capturedRequest.statusMessage = finalStatus.reasonPhrase
                capturedRequest.responseHeaders = captureConfig.captureHeaders ? responseHeadersTrace : []
                let responseCharset = BodyStorage.extractCharset(from: responseHeadersTrace)
                let observedResponseBodyBytes = max(receivedBodyBytes, capturedBodyData.count)
                let resolvedResponseBodyBytes = self.resolvedResponseBodyBytes(
                    declaredContentLength: declaredResponseBodyBytes,
                    observedBodyBytes: observedResponseBodyBytes
                )
                if didTruncateCapturedBody {
                    let totalSize = max(capturedBodyData.count, resolvedResponseBodyBytes)
                    capturedRequest.responseBody = self.truncatedBodyStorage(
                        fromCapturedData: capturedBodyData,
                        totalSize: totalSize,
                        charset: responseCharset,
                        contentEncoding: nil,
                        decodeCompressedContent: false
                    )
                } else {
                    capturedRequest.responseBody = self.bodyStorage(
                        from: capturedBodyData,
                        charset: responseCharset,
                        contentEncoding: nil,
                        captureConfig: captureConfig,
                        decodeCompressedContent: false
                    )
                }
                NetworkThrottlingController.shared.applyMetadata(to: &capturedRequest)

                let endPromise = context.eventLoop.makePromise(of: Void.self)
                endPromise.futureResult.whenComplete { _ in
                    var finalized = capturedRequest
                    self.finalizeCapturedDuration(for: &finalized)
                    self.onRequestCaptured?(finalized)
                    if metricsAsParsedResponse {
                        Task {
                            await ProxyNetworkMetrics.shared.recordHTTPResponseParsed()
                            await ProxyNetworkMetrics.shared.recordHTTPTransactionCompleted()
                        }
                    }
                    self.state = closeAfterSend ? .closed : .waitingForRequest
                    if closeAfterSend {
                        context.close(promise: nil)
                    }
                }
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: endPromise)
            }
        }

        let onError: @Sendable (Error) -> Void = { [weak self] error in
            let context = sendableContext.value
            guard let self else { return }
            context.eventLoop.execute {
                guard self.state == .forwardingHTTPRequest, !terminalStateReached else { return }
                terminalStateReached = true

                let classifiedFailure = self.classifyMITMFailure(error)
                self.reportMITMFailure(reason: classifiedFailure)
                self.logConnectStage(stage: "http_upstream", outcome: "failure", detail: error.localizedDescription)
                ProxyLog.mitm.warning(
                    "event=proxy.nio_http_upstream outcome=failure method=\(outboundContext.methodToken, privacy: .public) host=\(targetHost, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .public) classified=\(classifiedFailure, privacy: .public) deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds, privacy: .public)"
                )
                self.eventLog?.append(
                    type: "proxy_nio_http_upstream_failure",
                    msg: "method=\(outboundContext.methodToken) host_hash=\(LogRedaction.hash(targetHost)) error=\(error.localizedDescription) classified=\(classifiedFailure) deadline_seconds=\(Self.upstreamHTTPResponseDeadlineSeconds)"
                )

                if responseHeadSent {
                    self.state = .closed
                    context.close(promise: nil)
                } else {
                    self.sendResponse(
                        status: .badGateway,
                        body: "Upstream HTTP request failed",
                        closeAfterSend: true,
                        context: context
                    )
                    self.state = .closed
                }
            }
        }

        let delegate = NIOMITMHTTPStreamingResponseDelegate(
            onHead: onHead,
            onBodyPart: onBodyPart,
            onFinish: onFinish,
            onError: onError
        )
        let task = httpClient.execute(request: request, delegate: delegate, deadline: upstreamDeadline)
        task.futureResult.whenFailure { error in
            onError(error)
        }
    }

    private func installTunnel(
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

    private func sendResponse(
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

    private func sendHTTPResponse(
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        body: ByteBuffer,
        closeAfterSend: Bool,
        context: ChannelHandlerContext,
        onFlushed: (() -> Void)? = nil
    ) {
        var responseHeaders = headers
        if usesHTTP2StreamSemantics {
            // HTTP/2 forbids connection-specific headers.
            responseHeaders.remove(name: "Connection")
            responseHeaders.remove(name: "Proxy-Connection")
            responseHeaders.remove(name: "Keep-Alive")
            responseHeaders.remove(name: "Transfer-Encoding")
            responseHeaders.remove(name: "Upgrade")
        } else if responseHeaders.first(name: "Connection") == nil {
            responseHeaders.add(name: "Connection", value: closeAfterSend ? "close" : "keep-alive")
        } else if closeAfterSend {
            responseHeaders.replaceOrAdd(name: "Connection", value: "close")
        }

        if status.code >= 400 {
            logConnectStage(
                stage: "response_emit",
                outcome: "error",
                detail: "status=\(status.code),close=\(closeAfterSend),h2_stream=\(usesHTTP2StreamSemantics)"
            )
            eventLog?.append(
                type: "proxy_nio_error_response",
                msg: "mode=\(ingressModeLabel) id=\(connectionID) status=\(status.code) close=\(closeAfterSend) h2_stream=\(usesHTTP2StreamSemantics)"
            )
        }

        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: responseHeaders)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        if body.readableBytes > 0 {
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        }

        let flushPromise = context.eventLoop.makePromise(of: Void.self)
        flushPromise.futureResult.whenComplete { _ in
            onFlushed?()
            if closeAfterSend {
                context.close(promise: nil)
            }
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: flushPromise)
    }

    private func resolveRequestURL(from head: HTTPRequestHead) -> String? {
        if case let .tunneledHTTPS(host, port) = ingressMode {
            let uri = head.uri
            if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
                return uri
            }

            let hostHeader = head.headers.first(name: "Host")
            let authority: String = if let hostHeader, !hostHeader.isEmpty {
                hostHeader
            } else if port == 443 {
                host
            } else {
                "\(host):\(port)"
            }
            let path = uri.hasPrefix("/") ? uri : "/\(uri)"
            return "https://\(authority)\(path)"
        }

        let uri = head.uri
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return uri
        }

        guard let host = head.headers.first(name: "Host"), !host.isEmpty else {
            return nil
        }
        let path = uri.hasPrefix("/") ? uri : "/\(uri)"
        return "http://\(host)\(path)"
    }

    private func sanitizedRequestHeaders(from headers: HTTPHeaders) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Connection")
        sanitized.remove(name: "Keep-Alive")
        sanitized.remove(name: "TE")
        sanitized.remove(name: "Trailer")
        sanitized.remove(name: "Transfer-Encoding")
        sanitized.remove(name: "Content-Length")
        return sanitized
    }

    private func sanitizedStreamingRequestHeaders(from headers: HTTPHeaders) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Proxy-Authorization")
        sanitized.remove(name: "Host")
        sanitized.remove(name: "Content-Length")
        sanitized.remove(name: "Transfer-Encoding")
        return sanitized
    }

    private func isWebSocketUpgrade(headers: HTTPHeaders) -> Bool {
        headerContainsToken("Connection", token: "upgrade", in: headers) &&
            headers[canonicalForm: "Upgrade"].contains(where: { $0.lowercased().contains("websocket") })
    }

    private func isSSERequest(headers: HTTPHeaders) -> Bool {
        headers[canonicalForm: "Accept"].contains {
            $0
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains("text/event-stream")
        }
    }

    private func normalizedWebSocketURL(from url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        guard let scheme = components.scheme?.lowercased() else { return url }
        switch scheme {
        case "http":
            components.scheme = "ws"
            return components.string ?? url
        case "https":
            components.scheme = "wss"
            return components.string ?? url
        default:
            return url
        }
    }

    private func normalizeWireBody(
        _ body: Data,
        headers: inout HTTPHeaders,
        compressionInfo: CompressionInfo?,
        direction: String
    ) -> Data {
        guard !body.isEmpty else { return body }
        guard let compressionInfo, compressionInfo.decompressionSuccess else { return body }
        guard let contentEncoding = headers.first(name: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !contentEncoding.isEmpty,
            contentEncoding.lowercased() != "identity"
        else {
            return body
        }

        let encodings = contentEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }

        guard !encodings.isEmpty else {
            headers.remove(name: "Content-Encoding")
            return body
        }

        var encodedBody = body
        for encoding in encodings {
            guard let compressed = CompressionHelper.compress(data: encodedBody, algorithm: encoding) else {
                headers.remove(name: "Content-Encoding")
                logConnectStage(
                    stage: "body_encoding_normalize",
                    outcome: "fallback_identity",
                    detail: "\(direction),encoding=\(contentEncoding),failed=\(encoding)"
                )
                eventLog?.append(
                    type: "proxy_nio_body_encoding_normalize",
                    msg: "mode=\(ingressModeLabel) id=\(connectionID) direction=\(direction) action=strip content_encoding=\(contentEncoding) failed=\(encoding)"
                )
                return body
            }
            encodedBody = compressed
        }

        logConnectStage(
            stage: "body_encoding_normalize",
            outcome: "recompressed",
            detail: "\(direction),encoding=\(contentEncoding),bytes=\(body.count)->\(encodedBody.count)"
        )
        eventLog?.append(
            type: "proxy_nio_body_encoding_normalize",
            msg: "mode=\(ingressModeLabel) id=\(connectionID) direction=\(direction) action=recompress content_encoding=\(contentEncoding) bytes_in=\(body.count) bytes_out=\(encodedBody.count)"
        )
        return encodedBody
    }

    private func streamingResponseHeaders(
        from headers: HTTPHeaders,
        closeAfterSend: Bool
    ) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")

        if usesHTTP2StreamSemantics {
            sanitized.remove(name: "Connection")
            sanitized.remove(name: "Keep-Alive")
            sanitized.remove(name: "Transfer-Encoding")
            sanitized.remove(name: "Upgrade")
        } else if sanitized.first(name: "Connection") == nil {
            sanitized.add(name: "Connection", value: closeAfterSend ? "close" : "keep-alive")
        } else if closeAfterSend {
            sanitized.replaceOrAdd(name: "Connection", value: "close")
        }

        return sanitized
    }

    private func sanitizedResponseHeaders(
        from headers: HTTPHeaders,
        bodyBytes: Int,
        closeAfterSend: Bool
    ) -> HTTPHeaders {
        var sanitized = headers
        sanitized.remove(name: "Proxy-Connection")
        sanitized.remove(name: "Connection")
        sanitized.remove(name: "Keep-Alive")
        sanitized.remove(name: "Trailer")
        sanitized.remove(name: "Transfer-Encoding")
        sanitized.replaceOrAdd(name: "Content-Length", value: "\(bodyBytes)")
        if !usesHTTP2StreamSemantics {
            sanitized.replaceOrAdd(name: "Connection", value: closeAfterSend ? "close" : "keep-alive")
        }
        return sanitized
    }

    private func shouldCloseConnection(requestHead: HTTPRequestHead, responseHeaders: HTTPHeaders) -> Bool {
        if headerContainsToken("Connection", token: "close", in: requestHead.headers) {
            return true
        }
        if headerContainsToken("Connection", token: "close", in: responseHeaders) {
            return true
        }

        if requestHead.version.major == 1, requestHead.version.minor == 0 {
            return !headerContainsToken("Connection", token: "keep-alive", in: requestHead.headers)
        }

        return false
    }

    private func httpProtocolVersion(from version: HTTPVersion) -> HTTPProtocolVersion {
        switch version.major {
        case 1:
            version.minor == 0 ? .http10 : .http11
        case 2:
            .http2
        case 3:
            .http3
        default:
            .http11
        }
    }

    private func requestInterceptionFuture(
        flowID: UUID,
        requestURL: String,
        methodToken: String,
        requestHeaders: [String: String],
        requestBodyData: Data,
        fallbackRequest: NetworkRequest,
        eventLoop: EventLoop
    ) -> EventLoopFuture<InterceptionResult> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(.modified(fallbackRequest))
        }

        let promise = eventLoop.makePromise(of: InterceptionResult.self)
        promise.completeWithTask { [fallbackRequest] in
            let result = await interceptor.interceptRequest(
                flowId: flowID,
                url: requestURL,
                method: methodToken,
                headers: requestHeaders,
                body: requestBodyData.isEmpty ? nil : requestBodyData
            )

            switch result {
            case let .modified(request):
                var patched = request
                if patched.protocolVersion == nil || patched.protocolVersion == .http11 {
                    patched.protocolVersion = fallbackRequest.protocolVersion
                }
                return .modified(patched)
            case let .mocked(request):
                var patched = request
                if patched.protocolVersion == nil || patched.protocolVersion == .http11 {
                    patched.protocolVersion = fallbackRequest.protocolVersion
                }
                return .mocked(patched)
            case .blocked, .failed:
                return result
            }
        }
        return promise.futureResult
    }

    private func responseInterceptionFuture(
        fallbackRequest: NetworkRequest,
        statusCode: Int,
        statusMessage: String,
        responseHeaders: [TraceHTTPHeader],
        responseBodyData: Data,
        eventLoop: EventLoop
    ) -> EventLoopFuture<NetworkRequest> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(fallbackRequest)
        }

        let promise = eventLoop.makePromise(of: NetworkRequest.self)
        promise.completeWithTask {
            await interceptor.interceptResponse(
                request: fallbackRequest,
                statusCode: statusCode,
                statusMessage: statusMessage,
                headers: responseHeaders,
                body: responseBodyData.isEmpty ? nil : responseBodyData
            )
        }
        return promise.futureResult
    }

    private func responsePipelineFuture(for requestURL: String, eventLoop: EventLoop) -> EventLoopFuture<ResponsePipeline> {
        guard let interceptor else {
            return eventLoop.makeSucceededFuture(.bufferAndIntercept)
        }

        let promise = eventLoop.makePromise(of: ResponsePipeline.self)
        promise.completeWithTask {
            await interceptor.responsePipeline(for: requestURL)
        }
        return promise.futureResult
    }

    private func blockQUICEnabledFuture(eventLoop: EventLoop) -> EventLoopFuture<Bool> {
        let promise = eventLoop.makePromise(of: Bool.self)
        promise.completeWithTask {
            await HardeningConfig.shared.blockQUIC
        }
        return promise.futureResult
    }

    private func makeOutboundRequestContext(from request: NetworkRequest, fallbackBody: Data) -> OutboundRequestContext? {
        let methodToken = request.requestMethodRaw ?? request.method.rawValue
        let requestHeaders = dictionary(from: request.requestHeaders)
        let requestBodyData = request.requestBody.getData()
            ?? request.requestBody.getString()?.data(using: .utf8)
            ?? fallbackBody
        guard URL(string: request.url) != nil else {
            return nil
        }

        return OutboundRequestContext(
            requestSnapshot: request,
            methodToken: methodToken,
            url: request.url,
            headers: requestHeaders,
            body: requestBodyData
        )
    }

    private func makeBaseNetworkRequest(
        flowID: UUID,
        requestURL: String,
        methodToken: String,
        requestHeaders: [String: String],
        requestBodyData: Data,
        startTime: Date,
        captureConfig: CaptureConfiguration
    ) -> NetworkRequest {
        let uppercasedMethod = methodToken.uppercased()
        let mappedMethod = HTTPMethod(rawValue: uppercasedMethod) ?? .get
        let methodRaw = HTTPMethod(rawValue: uppercasedMethod) == nil ? methodToken : nil
        let traceHeaders = captureConfig.captureHeaders ? traceHeaders(from: requestHeaders) : []
        let requestCharset = BodyStorage.extractCharset(from: requestHeaders)
        let requestContentEncoding = requestHeaders.first(where: { $0.key.lowercased() == "content-encoding" })?.value
        let requestBody = bodyStorage(
            from: requestBodyData,
            charset: requestCharset,
            contentEncoding: requestContentEncoding,
            captureConfig: captureConfig
        )

        return NetworkRequest(
            id: flowID,
            url: requestURL,
            method: mappedMethod,
            requestMethodRaw: methodRaw,
            statusCode: nil,
            statusMessage: nil,
            timestamp: startTime,
            duration: 0,
            requestHeaders: traceHeaders,
            responseHeaders: [],
            requestBody: requestBody,
            responseBody: .empty,
            protocolVersion: usesHTTP2StreamSemantics ? .http2 : nil
        )
    }

    private func bodyStorage(
        from data: Data,
        charset: String?,
        contentEncoding: String?,
        captureConfig: CaptureConfiguration,
        decodeCompressedContent: Bool = true
    ) -> BodyStorage {
        guard captureConfig.captureBody, captureConfig.maxBodySize > 0, !data.isEmpty else { return .empty }
        return BodyStorage.from(
            data: data,
            charset: charset,
            maxSize: max(0, captureConfig.maxBodySize),
            contentEncoding: contentEncoding,
            decodeCompressedContent: decodeCompressedContent
        )
    }

    private func contentLength(from headers: HTTPHeaders) -> Int? {
        guard let rawValue = headers.first(name: "Content-Length") else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentLength = Int(trimmed), contentLength >= 0 else { return nil }
        return contentLength
    }

    private func resolvedResponseBodyBytes(
        declaredContentLength: Int?,
        observedBodyBytes: Int
    ) -> Int {
        if let declaredContentLength, declaredContentLength >= 0 {
            return max(declaredContentLength, observedBodyBytes)
        }
        return observedBodyBytes
    }

    private func truncatedBodyStorage(
        fromCapturedData capturedData: Data,
        totalSize: Int,
        charset: String?,
        contentEncoding: String?,
        decodeCompressedContent: Bool
    ) -> BodyStorage {
        guard !capturedData.isEmpty else { return .empty }

        let capturedStorage = BodyStorage.from(
            data: capturedData,
            charset: charset,
            maxSize: Int.max,
            contentEncoding: contentEncoding,
            decodeCompressedContent: decodeCompressedContent
        )

        switch capturedStorage {
        case let .inline(data, capturedCharset, compressionInfo):
            return .truncated(
                data,
                totalSize: max(totalSize, data.count),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .file(url, capturedCharset, compressionInfo):
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? capturedData.count
            return .truncatedFile(
                url,
                totalSize: max(totalSize, fileSize),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .truncated(data, _, capturedCharset, compressionInfo):
            return .truncated(
                data,
                totalSize: max(totalSize, data.count),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case let .truncatedFile(url, _, capturedCharset, compressionInfo):
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? capturedData.count
            return .truncatedFile(
                url,
                totalSize: max(totalSize, fileSize),
                charset: capturedCharset ?? charset,
                compressionInfo: compressionInfo
            )
        case .empty:
            return .empty
        }
    }

    private func finalizeCapturedDuration(for request: inout NetworkRequest) {
        let elapsed = Date().timeIntervalSince(request.timestamp)
        guard elapsed.isFinite else { return }
        request.duration = max(request.duration, max(0, elapsed))
    }

    private func throttle(
        direction: PacketThrottler.Direction,
        bytes: Int,
        context: ChannelHandlerContext,
        operation: @escaping () -> Void
    ) {
        guard let throttler, bytes > 0 else {
            operation()
            return
        }
        let markerBytes = min(max(bytes, 1), 64 * 1024)
        let marker = Data(repeating: 0, count: markerBytes)
        throttler.process(packet: marker, direction: direction) {
            context.eventLoop.execute {
                operation()
            }
        }
    }

    private func mitmHost() -> String? {
        if let connectTargetHost, !connectTargetHost.isEmpty {
            return connectTargetHost
        }
        switch ingressMode {
        case .proxy:
            return nil
        case let .tunneledHTTPS(host, _):
            return host
        }
    }

    private var ingressModeLabel: String {
        switch ingressMode {
        case .proxy:
            "proxy"
        case .tunneledHTTPS:
            "tunneled_https"
        }
    }

    private func logConnectStage(stage: String, outcome: String, detail: String? = nil) {
        guard let host = connectTargetHost, let port = connectTargetPort else { return }
        let hostHash = LogRedaction.hash(host)
        let stateLabel = String(describing: state)
        let detailText = detail.flatMap { $0.isEmpty ? nil : $0 }

        if let detailText {
            ProxyLog.mitm.debug(
                "event=proxy.nio_connect_stage stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public) mode=\(self.ingressModeLabel, privacy: .public) id=\(self.connectionID, privacy: .public) host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) state=\(stateLabel, privacy: .public) detail=\(detailText, privacy: .public)"
            )
            eventLog?.append(
                type: "proxy_nio_connect_stage",
                msg: "stage=\(stage) outcome=\(outcome) mode=\(self.ingressModeLabel) id=\(self.connectionID) host_hash=\(hostHash) port=\(port) state=\(stateLabel) detail=\(detailText)"
            )
            return
        }

        ProxyLog.mitm.debug(
            "event=proxy.nio_connect_stage stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public) mode=\(self.ingressModeLabel, privacy: .public) id=\(self.connectionID, privacy: .public) host=\(host, privacy: .private(mask: .hash)) port=\(port, privacy: .public) state=\(stateLabel, privacy: .public)"
        )
        eventLog?.append(
            type: "proxy_nio_connect_stage",
            msg: "stage=\(stage) outcome=\(outcome) mode=\(self.ingressModeLabel) id=\(self.connectionID) host_hash=\(hostHash) port=\(port) state=\(stateLabel)"
        )
    }

    private func reportMITMFailure(host: String, reason: String) {
        onMITMFailure?(host, reason)
    }

    private func reportMITMFailure(reason: String) {
        guard let host = mitmHost() else {
            ProxyLog.mitm.debug(
                "event=proxy.mitm_failure_unattributed outcome=ignored mode=\(self.ingressModeLabel, privacy: .public) id=\(self.connectionID, privacy: .public) reason=\(reason, privacy: .public)"
            )
            eventLog?.append(
                type: "mitm_failure_unattributed",
                msg: "mode=\(self.ingressModeLabel) id=\(self.connectionID) reason=\(reason)"
            )
            return
        }
        onMITMFailure?(host, reason)
    }

    private func scheduleTransparentTLSUpgradeWatchdog(on channel: Channel) {
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

    private func markTransparentTLSProtocolSelected() {
        didSelectTransparentTLSProtocol = true
        cancelTransparentTLSUpgradeWatchdog()
    }

    private func cancelTransparentTLSUpgradeWatchdog() {
        transparentTLSUpgradeWatchdog?.cancel()
        transparentTLSUpgradeWatchdog = nil
    }

    private func classifyMITMFailure(_ error: Error) -> String {
        if let classified = classifyTypedMITMFailure(error) {
            return classified
        }

        if let classified = classifyNSErrorMITMFailure(error as NSError) {
            return classified
        }

        if let underlying = underlyingError(from: error),
           let classified = classifyTypedMITMFailure(underlying) {
            return classified
        }

        if let underlying = underlyingError(from: error),
           let classified = classifyNSErrorMITMFailure(underlying as NSError) {
            return classified
        }

        let detail = error.localizedDescription.lowercased()
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return "upstream_timeout"
            case NSURLErrorCancelled:
                return "upstream_cancelled"
            default:
                break
            }
        }

        if detail.contains("timed out") || detail.contains("timeout") || detail.contains("deadline") {
            return "upstream_timeout"
        }
        if detail.contains("cancelled") || detail.contains("canceled") {
            return "upstream_cancelled"
        }
        if detail.contains("httpparsererror") {
            return "mitm_non_http_protocol"
        }
        if detail.contains("httpclienterror error 1") {
            return "possible_pinning_or_strict_trust: \(error.localizedDescription)"
        }
        if detail.contains("connection reset") ||
            detail.contains("connection closed") ||
            detail.contains("remote closed") ||
            detail.contains("channelerror error 5") ||
            detail.contains("nwerror error 54") ||
            detail.contains("streamclosed") {
            return "upstream_connection_closed"
        }
        if detail.contains("hostname") && detail.contains("mismatch") {
            return "tls_upstream_hostname_mismatch"
        }
        if detail.contains("failedtovalidatehostname") {
            return "tls_upstream_hostname_mismatch"
        }
        if detail.contains("certificate") ||
            detail.contains("trust") ||
            detail.contains("x509") ||
            detail.contains("unabletovalidatecertificate") {
            return "tls_upstream_trust_failed"
        }
        if detail.contains("tls") && detail.contains("handshake") {
            return "tls_upstream_handshake_failed"
        }
        return "upstream_transport_error: \(error.localizedDescription)"
    }

    private func classifyClientHandlerFailure(_ error: Error) -> (reason: String, shouldReport: Bool) {
        let classifiedFailure = classifyMITMFailure(error)
        guard classifiedFailure == "upstream_connection_closed",
              isTLSUncleanShutdown(error)
        else {
            return (classifiedFailure, true)
        }
        // Client channels frequently close TLS without close_notify during retries/preconnects.
        // Do not treat that as an upstream MITM failure (it would incorrectly trigger auto-bypass).
        return ("client_connection_closed", false)
    }

    private func isTLSUncleanShutdown(_ error: Error) -> Bool {
        if let sslError = error as? NIOSSLError,
           sslError == .uncleanShutdown {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "NIOSSL.NIOSSLError",
           nsError.code == 12 {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTLSUncleanShutdown(underlying)
        }
        return false
    }

    private func classifyNSErrorMITMFailure(_ nsError: NSError) -> String? {
        if nsError.domain == "NIOSSL.NIOSSLError" {
            switch nsError.code {
            case 12:
                // `uncleanShutdown`: common for servers that close TLS without close_notify.
                return "upstream_connection_closed"
            case 7:
                return "tls_upstream_hostname_mismatch"
            case 8, 9:
                return "tls_upstream_trust_failed"
            default:
                return nil
            }
        }

        return nil
    }

    private func classifyTypedMITMFailure(_ error: Error) -> String? {
        if let sslError = error as? NIOSSLError {
            switch sslError {
            case .uncleanShutdown:
                return "upstream_connection_closed"
            case .noCertificateToValidate, .unableToValidateCertificate:
                return "tls_upstream_trust_failed"
            case .cannotMatchULabel:
                return "tls_upstream_hostname_mismatch"
            case let .handshakeFailed(sslDetail), let .shutdownFailed(sslDetail):
                if let classified = classifyTLSStackDescription(String(describing: sslDetail).lowercased()) {
                    return classified
                }
                return "tls_upstream_handshake_failed"
            default:
                break
            }
        }

        if let sslExtraError = error as? NIOSSLExtraError {
            if sslExtraError == .failedToValidateHostname ||
                sslExtraError == .serverHostnameImpossibleToMatch ||
                sslExtraError == .cannotUseIPAddressInSNI ||
                sslExtraError == .invalidSNIHostname {
                return "tls_upstream_hostname_mismatch"
            }
        }

        if let httpClientError = error as? HTTPClientError {
            if httpClientError == .readTimeout ||
                httpClientError == .writeTimeout ||
                httpClientError == .connectTimeout ||
                httpClientError == .tlsHandshakeTimeout ||
                httpClientError == .socksHandshakeTimeout ||
                httpClientError == .httpProxyHandshakeTimeout ||
                httpClientError == .deadlineExceeded ||
                httpClientError == .getConnectionFromPoolTimeout {
                return "upstream_timeout"
            }

            if httpClientError == .cancelled || httpClientError == .requestStreamCancelled {
                return "upstream_cancelled"
            }

            if httpClientError == .remoteConnectionClosed || httpClientError == .uncleanShutdown {
                return "upstream_connection_closed"
            }
        }

        return nil
    }

    private func classifyTLSStackDescription(_ detail: String) -> String? {
        if detail.contains("hostname") && detail.contains("mismatch") {
            return "tls_upstream_hostname_mismatch"
        }
        if detail.contains("x509") ||
            detail.contains("certificate") ||
            detail.contains("verify") ||
            detail.contains("trust") {
            return "tls_upstream_trust_failed"
        }
        return nil
    }

    private func underlyingError(from error: Error) -> Error? {
        let nsError = error as NSError
        return nsError.userInfo[NSUnderlyingErrorKey] as? Error
    }

    private func emitConnectMarker(host: String, port: Int, note: String, startTime: Date? = nil) {
        guard let onRequestCaptured else { return }

        let markerTimestamp = startTime ?? Date()
        let elapsed = max(0, Date().timeIntervalSince(markerTimestamp))
        let connectURL = "https://\(host):\(port)"
        var marker = NetworkRequest(
            id: UUID(),
            url: connectURL,
            method: .connect,
            statusCode: 200,
            statusMessage: "CONNECT established",
            timestamp: markerTimestamp,
            duration: elapsed,
            requestHeaders: [TraceHTTPHeader(key: "Host", value: "\(host):\(port)")],
            responseHeaders: [TraceHTTPHeader(key: "X-Trace-Note", value: note)],
            requestBody: .empty,
            responseBody: .empty
        )
        marker.extractHTTPFields()
        NetworkThrottlingController.shared.applyMetadata(to: &marker)
        onRequestCaptured(marker)
    }

    private func headerContainsToken(_ headerName: String, token: String, in headers: HTTPHeaders) -> Bool {
        headers[canonicalForm: headerName].contains { value in
            value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(token.lowercased())
        }
    }

    private func dictionary(from headers: HTTPHeaders) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            result[header.name] = header.value
        }
        return result
    }

    private func dictionary(from headers: [TraceHTTPHeader]) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            result[header.key] = header.value
        }
        return result
    }

    private func traceHeaders(from headers: HTTPHeaders) -> [TraceHTTPHeader] {
        headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) }
    }

    private func traceHeaders(from headers: [String: String]) -> [TraceHTTPHeader] {
        headers.map { TraceHTTPHeader(key: $0.key, value: $0.value) }
    }

    private func makeHTTPHeaders(from headers: [String: String]) -> HTTPHeaders {
        var result = HTTPHeaders()
        for (key, value) in headers {
            result.add(name: key, value: value)
        }
        return result
    }

    private func makeHTTPHeaders(from headers: [TraceHTTPHeader]) -> HTTPHeaders {
        var result = HTTPHeaders()
        for header in headers {
            result.add(name: header.key, value: header.value)
        }
        return result
    }

    private func byteBuffer(from data: Data, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    private func byteBufferToData(_ buffer: ByteBuffer) -> Data {
        var mutableBuffer = buffer
        return mutableBuffer.readData(length: mutableBuffer.readableBytes) ?? Data()
    }

    private enum TLSContextError: LocalizedError {
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

    private nonisolated(unsafe) static let tlsContextCacheLock = NSLock()
    private nonisolated(unsafe) static var tlsContextCache: [String: NIOSSLContext] = [:]

    fileprivate static func makeServerTLSContext(
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

    private static func parseConnectTarget(_ uri: String) -> (host: String, port: Int)? {
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

private final class NIOMITMHTTPClientResponseRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let onPart: @Sendable (HTTPClientResponsePart) -> Void
    private let onError: @Sendable (Error) -> Void
    private let onInactive: @Sendable () -> Void

    init(
        onPart: @escaping @Sendable (HTTPClientResponsePart) -> Void,
        onError: @escaping @Sendable (Error) -> Void,
        onInactive: @escaping @Sendable () -> Void
    ) {
        self.onPart = onPart
        self.onError = onError
        self.onInactive = onInactive
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        onPart(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        onInactive()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private final class NIOMITMHTTPStreamingResponseDelegate: HTTPClientResponseDelegate, @unchecked Sendable {
    typealias Response = Void

    private let onHead: @Sendable (HTTPResponseHead) -> EventLoopFuture<Void>
    private let onBodyPart: @Sendable (ByteBuffer) -> EventLoopFuture<Void>
    private let onFinish: @Sendable () throws -> Void
    private let onError: @Sendable (Error) -> Void

    init(
        onHead: @escaping @Sendable (HTTPResponseHead) -> EventLoopFuture<Void>,
        onBodyPart: @escaping @Sendable (ByteBuffer) -> EventLoopFuture<Void>,
        onFinish: @escaping @Sendable () throws -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.onHead = onHead
        self.onBodyPart = onBodyPart
        self.onFinish = onFinish
        self.onError = onError
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        onHead(head).hop(to: task.eventLoop)
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        onBodyPart(buffer).hop(to: task.eventLoop)
    }

    func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
        onError(error)
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        try onFinish()
    }
}

private final class NIOMITMSSECaptureState: @unchecked Sendable {
    private static let persistenceQueue = DispatchQueue(
        label: "com.trace.proxy.nio.sse.capture.persist",
        qos: .utility
    )

    private let lock = NSLock()
    private let baseRequest: NetworkRequest
    private var responseStatusCode: Int?
    private var responseStatusMessage: String?
    private var responseHeaders: [TraceHTTPHeader] = []
    private var connection: SSEConnection?
    private var parser = SSEParser()
    private var utf8Remainder = Data()
    private var publishThrottle = SSECapturePublishThrottle()
    private var finished = false

    private let maxEvents = 1000
    private let maxTotalBytes = 10 * 1024 * 1024

    init(baseRequest: NetworkRequest) {
        self.baseRequest = baseRequest
    }

    func beginResponse(head: HTTPResponseHead, captureConfig: CaptureConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        responseStatusCode = Int(head.status.code)
        responseStatusMessage = head.status.reasonPhrase
        responseHeaders = captureConfig.captureHeaders
            ? head.headers.map { TraceHTTPHeader(key: $0.name, value: $0.value) }
            : []

        if connection == nil {
            connection = SSEConnection(
                id: UUID(),
                url: baseRequest.url,
                startTime: Date(),
                status: .streaming,
                requestHeaders: captureConfig.captureHeaders ? baseRequest.requestHeaders : [],
                responseHeaders: responseHeaders
            )
            if let snapshot = connection {
                persist(snapshot)
            }
        } else {
            connection?.responseHeaders = responseHeaders
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
        if snapshot.events.count >= maxEvents || snapshot.totalBytesReceived >= maxTotalBytes {
            if !snapshot.isTruncated {
                snapshot.isTruncated = true
                connection = snapshot
                persist(snapshot)
                emitRequestSnapshotLocked(
                    connection: snapshot,
                    captureConfig: captureConfig,
                    onRequestCaptured: onRequestCaptured
                )
            }
            return
        }

        guard let decoded = decodeUTF8ChunkLocked(bodyChunk), !decoded.isEmpty else {
            connection = snapshot
            return
        }

        let events = parser.parse(decoded)
        if !events.isEmpty {
            for event in events {
                snapshot.addEvent(event)
            }
            connection = snapshot
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
            id: UUID(),
            url: baseRequest.url,
            startTime: Date(),
            status: .streaming,
            requestHeaders: captureConfig.captureHeaders ? baseRequest.requestHeaders : [],
            responseHeaders: responseHeaders
        )
        snapshot.status = succeeded ? .closed : .failed
        snapshot.endTime = Date()
        connection = snapshot
        persist(snapshot)
        emitRequestSnapshotLocked(
            connection: snapshot,
            captureConfig: captureConfig,
            onRequestCaptured: onRequestCaptured
        )
    }

    private func decodeUTF8ChunkLocked(_ data: Data) -> String? {
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

    private func emitRequestSnapshotLocked(
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

    private func persist(_ snapshot: SSEConnection) {
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
}

private final class NIOMITMWebSocketCaptureState: @unchecked Sendable {
    private static let persistenceQueue = DispatchQueue(
        label: "com.trace.proxy.nio.websocket.capture.persist",
        qos: .utility
    )

    private let lock = NSLock()
    private var connection: WebSocketConnection
    private var finalized = false

    private var sentContinuationType: WebSocketMessageType?
    private var sentContinuationPayload = Data()
    private var receivedContinuationType: WebSocketMessageType?
    private var receivedContinuationPayload = Data()

    private let maxContinuationPayloadBytes = 5 * 1024 * 1024

    init(url: String, requestHeaders: [TraceHTTPHeader]) {
        connection = WebSocketConnection(
            id: UUID(),
            url: url,
            startTime: Date(),
            status: .connecting,
            requestHeaders: requestHeaders
        )
        persist(connection)
    }

    func markOpen(responseHeaders: [TraceHTTPHeader]) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        connection.status = .open
        connection.responseHeaders = responseHeaders
        persist(connection)
    }

    func recordFrame(_ frame: WebSocketFrame, direction: WebSocketDirection) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        guard let frameType = websocketMessageType(for: frame.opcode) else { return }

        var continuationType = continuationType(for: direction)
        var continuationPayload = continuationPayload(for: direction)
        let payload = payloadData(from: frame)

        switch frameType {
        case .continuation:
            guard let activeType = continuationType else { return }
            let candidateSize = continuationPayload.count + payload.count
            guard candidateSize <= maxContinuationPayloadBytes else {
                continuationType = nil
                continuationPayload.removeAll(keepingCapacity: false)
                setContinuation(type: continuationType, payload: continuationPayload, for: direction)
                return
            }
            continuationPayload.append(payload)
            if frame.fin {
                appendMessage(
                    type: activeType,
                    payload: continuationPayload,
                    isFinal: true,
                    isMasked: frame.maskKey != nil,
                    direction: direction
                )
                continuationType = nil
                continuationPayload.removeAll(keepingCapacity: false)
            }
        case .text, .binary:
            if frame.fin {
                appendMessage(
                    type: frameType,
                    payload: payload,
                    isFinal: true,
                    isMasked: frame.maskKey != nil,
                    direction: direction
                )
            } else {
                guard payload.count <= maxContinuationPayloadBytes else {
                    continuationType = nil
                    continuationPayload.removeAll(keepingCapacity: false)
                    setContinuation(type: continuationType, payload: continuationPayload, for: direction)
                    return
                }
                continuationType = frameType
                continuationPayload = payload
            }
        case .ping, .pong, .close:
            appendMessage(
                type: frameType,
                payload: payload,
                isFinal: frame.fin,
                isMasked: frame.maskKey != nil,
                direction: direction
            )
            if frameType == .close {
                connection.status = .closing
                connection.closeCode = extractCloseCode(from: payload)
                connection.closeReason = extractCloseReason(from: payload)
            }
        }

        setContinuation(type: continuationType, payload: continuationPayload, for: direction)
        persist(connection)
    }

    func markClosed(code: Int?, reason: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        connection.status = .closed
        connection.endTime = Date()
        if let code {
            connection.closeCode = code
        }
        if let reason {
            connection.closeReason = reason
        }
        persist(connection)
    }

    func markFailed() {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        connection.status = .failed
        connection.endTime = Date()
        persist(connection)
    }

    private func appendMessage(
        type: WebSocketMessageType,
        payload: Data,
        isFinal: Bool,
        isMasked: Bool,
        direction: WebSocketDirection
    ) {
        connection.addMessage(
            WebSocketMessage(
                direction: direction,
                timestamp: Date(),
                payload: payload,
                messageType: type,
                isFinal: isFinal,
                isMasked: isMasked,
                payloadLength: payload.count
            )
        )
    }

    private func continuationType(for direction: WebSocketDirection) -> WebSocketMessageType? {
        switch direction {
        case .sent:
            sentContinuationType
        case .received:
            receivedContinuationType
        }
    }

    private func continuationPayload(for direction: WebSocketDirection) -> Data {
        switch direction {
        case .sent:
            sentContinuationPayload
        case .received:
            receivedContinuationPayload
        }
    }

    private func setContinuation(type: WebSocketMessageType?, payload: Data, for direction: WebSocketDirection) {
        switch direction {
        case .sent:
            sentContinuationType = type
            sentContinuationPayload = payload
        case .received:
            receivedContinuationType = type
            receivedContinuationPayload = payload
        }
    }

    private func payloadData(from frame: WebSocketFrame) -> Data {
        var payloadBuffer = frame.unmaskedData
        return payloadBuffer.readData(length: payloadBuffer.readableBytes) ?? Data()
    }

    private func websocketMessageType(for opcode: WebSocketOpcode) -> WebSocketMessageType? {
        switch opcode {
        case .continuation:
            .continuation
        case .text:
            .text
        case .binary:
            .binary
        case .ping:
            .ping
        case .pong:
            .pong
        case .connectionClose:
            .close
        default:
            nil
        }
    }

    private func extractCloseCode(from payload: Data) -> Int? {
        guard payload.count >= 2 else { return nil }
        return Int(payload[0]) << 8 | Int(payload[1])
    }

    private func extractCloseReason(from payload: Data) -> String? {
        guard payload.count > 2 else { return nil }
        return String(data: payload.subdata(in: 2 ..< payload.count), encoding: .utf8)
    }

    private func persist(_ snapshot: WebSocketConnection) {
        Self.persistenceQueue.async {
            do {
                try AppGroupStorage.shared.saveWebSocketConnection(snapshot)
            } catch {
                ProxyLog.mitm.warning(
                    "event=proxy.nio_ws_capture_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

private final class NIOMITMWebSocketRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    private weak var peerChannel: Channel?
    private let direction: WebSocketDirection
    private let captureState: NIOMITMWebSocketCaptureState

    init(
        peerChannel: Channel,
        direction: WebSocketDirection,
        captureState: NIOMITMWebSocketCaptureState
    ) {
        self.peerChannel = peerChannel
        self.direction = direction
        self.captureState = captureState
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        captureState.recordFrame(frame, direction: direction)
        guard let peerChannel, peerChannel.isActive else {
            context.close(promise: nil)
            return
        }
        peerChannel.writeAndFlush(frame, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        captureState.markClosed(code: nil, reason: nil)
        peerChannel?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        captureState.markFailed()
        peerChannel?.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class NIOMITMHTTP2MetricsHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        Task { await ProxyNetworkMetrics.shared.recordHTTP2FrameParsed() }
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Task { await ProxyNetworkMetrics.shared.recordHTTP2ProtocolError() }
        context.fireErrorCaught(error)
    }
}

private final class NIOMITMTLSHandshakeObserver: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var handshakePromise: EventLoopPromise<String?>?

    init(handshakePromise: EventLoopPromise<String?>) {
        self.handshakePromise = handshakePromise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case let TLSUserEvent.handshakeCompleted(negotiatedProtocol: negotiatedProtocol) = event {
            handshakePromise?.succeed(negotiatedProtocol)
            handshakePromise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        handshakePromise?.fail(ChannelError.inputClosed)
        handshakePromise = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        handshakePromise?.fail(error)
        handshakePromise = nil
        context.fireErrorCaught(error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        handshakePromise = nil
    }
}

private final class NIOMITMRawRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let linkID = UUID().uuidString
    private weak var peerChannel: Channel?

    init(peerChannel: Channel) {
        self.peerChannel = peerChannel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        guard let peerChannel, peerChannel.isActive else {
            context.close(promise: nil)
            return
        }
        peerChannel.writeAndFlush(inbound, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        ProxyLog.mitm.debug(
            "event=proxy.nio_raw_relay_inactive outcome=closing_peer id=\(self.linkID, privacy: .public)"
        )
        peerChannel?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ProxyLog.mitm.warning(
            "event=proxy.nio_raw_relay_error outcome=failure id=\(self.linkID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
        peerChannel?.close(promise: nil)
        context.close(promise: nil)
    }
}
