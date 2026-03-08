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

struct NIOMITMUncheckedSendableBox<Value>: @unchecked Sendable {
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
    private let http2MITMEnabledProvider: () -> Bool
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
        http2MITMEnabledProvider: @escaping () -> Bool = { true },
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
        self.http2MITMEnabledProvider = http2MITMEnabledProvider
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
                    http2MITMEnabledProvider: self.http2MITMEnabledProvider,
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
