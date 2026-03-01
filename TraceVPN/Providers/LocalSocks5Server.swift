//
//  LocalSocks5Server.swift
//  TraceVPN
//
//  Created by Justin on 2026/02/06.
//

import Darwin
import Foundation
import NIOCore
import NIOTransportServices
import TraceCore

/// Embedded SOCKS5 server used by full-tunnel mode when no external server is configured.
final class LocalSocks5Server: @unchecked Sendable {
    struct Endpoint: Sendable {
        let host: String
        let port: UInt16
    }

    struct TCPConnectRoutingPolicy: Sendable {
        enum RouteDecision: Sendable, Equatable {
            case mitm
            case direct(reason: String)
        }

        struct RouteDecisionEvaluation: Sendable, Equatable {
            let effectiveDecision: RouteDecision
            let legacyDecision: RouteDecision
            let policyDecision: RouteDecision?
            let shadowEnabled: Bool
            let policyEnforced: Bool

            var hasShadowMismatch: Bool {
                guard shadowEnabled, let policyDecision else { return false }
                return legacyDecision != policyDecision
            }
        }

        let enabled: Bool
        let interceptPorts: Set<UInt16>
        let mitmProxyHost: String
        let mitmProxyPort: UInt16
        let failOpen: Bool
        let dualMITMPolicy: DualMITMPolicy
        let policyEngine: DualMITMPolicyEngine?
        let shouldBypassHost: @Sendable (String) -> Bool
        let bypassReasonForHost: @Sendable (String) -> String?

        init(
            enabled: Bool,
            interceptPorts: Set<UInt16>,
            mitmProxyHost: String,
            mitmProxyPort: UInt16,
            failOpen: Bool,
            dualMITMPolicy: DualMITMPolicy = .adaptiveFailOpen,
            policyEngine: DualMITMPolicyEngine? = nil,
            shouldBypassHost: @escaping @Sendable (String) -> Bool = { _ in false },
            bypassReasonForHost: @escaping @Sendable (String) -> String? = { _ in nil }
        ) {
            self.enabled = enabled
            self.interceptPorts = interceptPorts
            self.mitmProxyHost = mitmProxyHost
            self.mitmProxyPort = mitmProxyPort
            self.failOpen = failOpen
            self.dualMITMPolicy = dualMITMPolicy
            self.policyEngine = policyEngine
            self.shouldBypassHost = shouldBypassHost
            self.bypassReasonForHost = bypassReasonForHost
        }

        static let disabled = TCPConnectRoutingPolicy(
            enabled: false,
            interceptPorts: [],
            mitmProxyHost: "",
            mitmProxyPort: 0,
            failOpen: true,
            dualMITMPolicy: .adaptiveFailOpen,
            policyEngine: nil,
            shouldBypassHost: { _ in false },
            bypassReasonForHost: { _ in nil }
        )

        func routeDecision(destinationHost: String, destinationPort: UInt16) -> RouteDecision {
            evaluateRouteDecision(
                destinationHost: destinationHost,
                destinationPort: destinationPort
            ).effectiveDecision
        }

        func evaluateRouteDecision(destinationHost: String, destinationPort: UInt16) -> RouteDecisionEvaluation {
            let legacyDecision = legacyRouteDecision(
                destinationHost: destinationHost,
                destinationPort: destinationPort
            )

            guard let policyEngine else {
                return RouteDecisionEvaluation(
                    effectiveDecision: legacyDecision,
                    legacyDecision: legacyDecision,
                    policyDecision: nil,
                    shadowEnabled: false,
                    policyEnforced: false
                )
            }

            let policyPlan = policyEngine.planNewTCPTransparentFlow(
                destinationHost: destinationHost,
                destinationPort: destinationPort
            )
            let policyDecision = routeDecision(from: policyPlan.decision)
            let effectiveDecision = policyPlan.enforceTCPRouting ? policyDecision : legacyDecision

            return RouteDecisionEvaluation(
                effectiveDecision: effectiveDecision,
                legacyDecision: legacyDecision,
                policyDecision: policyDecision,
                shadowEnabled: policyPlan.shadowEnabled,
                policyEnforced: policyPlan.enforceTCPRouting
            )
        }

        private func routeDecision(from decision: DualMITMTCPRouteDecision) -> RouteDecision {
            switch decision {
            case .mitm:
                .mitm
            case let .direct(reason):
                .direct(reason: reason)
            }
        }

        private func legacyRouteDecision(destinationHost: String, destinationPort: UInt16) -> RouteDecision {
            guard enabled, mitmProxyPort > 0 else {
                return .direct(reason: "policy_disabled")
            }
            guard interceptPorts.contains(destinationPort) else {
                return .direct(reason: "port_not_intercepted")
            }

            if dualMITMPolicy == .adaptiveFailOpen,
               DualMITMCircuitBreaker.shared.shouldForceTCPDirect(port: destinationPort) {
                return .direct(reason: "dual_mitm_circuit_breaker")
            }

            var normalizedDestination = destinationHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedDestination.first == "[", normalizedDestination.last == "]" {
                normalizedDestination = String(normalizedDestination.dropFirst().dropLast())
            }
            let normalizedProxyHost = mitmProxyHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedDestination.isEmpty else {
                return .direct(reason: "destination_host_missing")
            }
            guard !normalizedProxyHost.isEmpty else {
                return .direct(reason: "proxy_host_missing")
            }

            if normalizedDestination == normalizedProxyHost, destinationPort == mitmProxyPort {
                return .direct(reason: "proxy_endpoint")
            }

            if shouldBypassHost(normalizedDestination) {
                let normalizedReason = bypassReasonForHost(normalizedDestination)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if let normalizedReason,
                   normalizedReason.hasPrefix("quic ") || normalizedReason.hasPrefix("quic_") {
                    return .mitm
                }
                let bypassReason = normalizedReason?.replacingOccurrences(of: " ", with: "_")
                if let bypassReason, !bypassReason.isEmpty {
                    return .direct(reason: "auto_bypass_\(bypassReason)")
                }
                return .direct(reason: "auto_bypass")
            }

            return .mitm
        }

        func shouldRouteToMITM(destinationHost: String, destinationPort: UInt16) -> Bool {
            switch routeDecision(destinationHost: destinationHost, destinationPort: destinationPort) {
            case .mitm:
                true
            case .direct:
                false
            }
        }
    }

    private enum ServerError: LocalizedError {
        case listenerPortUnavailable
        case listenerBindFailed
        case eventLoopGroupUnavailable

        var errorDescription: String? {
            switch self {
            case .listenerPortUnavailable:
                "Local SOCKS5 listener did not report a port"
            case .listenerBindFailed:
                "Local SOCKS5 listener failed to bind"
            case .eventLoopGroupUnavailable:
                "NIOTS event loop group unavailable"
            }
        }
    }

    private let lock = NSLock()
    private let lifecycleQueue = DispatchQueue(label: "com.trace.vpn.local_socks5.lifecycle")
    private let lifecycleQueueKey = DispatchSpecificKey<Void>()
    private let bindHost: String
    private let tcpConnectRoutingPolicy: TCPConnectRoutingPolicy
    private let eventLogHandler: (@Sendable (String, String) -> Void)?

    private var endpoint: Endpoint?
    private var listenerChannel: Channel?
    private var childChannels: [ObjectIdentifier: Channel] = [:]
    private var runtimeAcquired = false

    init(
        bindHost: String = "127.0.0.1",
        tcpConnectRoutingPolicy: TCPConnectRoutingPolicy = .disabled,
        eventLogHandler: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.bindHost = bindHost
        self.tcpConnectRoutingPolicy = tcpConnectRoutingPolicy
        self.eventLogHandler = eventLogHandler
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: ())
    }

    func start(preferredPort: UInt16) throws -> Endpoint {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            return try startOnLifecycleQueue(preferredPort: preferredPort)
        }
        return try lifecycleQueue.sync {
            try startOnLifecycleQueue(preferredPort: preferredPort)
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            stopOnLifecycleQueue()
            return
        }
        lifecycleQueue.sync {
            stopOnLifecycleQueue()
        }
    }

    private func startOnLifecycleQueue(preferredPort: UInt16) throws -> Endpoint {
        lock.lock()
        if let endpoint {
            lock.unlock()
            return endpoint
        }
        lock.unlock()

        let resources = NIORuntime.shared.acquire(for: .networkExtension)
        guard let group = resources.eventLoopGroup as? NIOTSEventLoopGroup else {
            try? NIORuntime.shared.release(for: .networkExtension)
            throw ServerError.eventLoopGroupUnavailable
        }

        do {
            let resolved = try bindListener(using: group, preferredPort: preferredPort)
            lock.lock()
            self.listenerChannel = resolved.channel
            self.endpoint = resolved.endpoint
            self.runtimeAcquired = true
            lock.unlock()

            eventLogHandler?(
                "local_socks5_server",
                "outcome=success host=\(resolved.endpoint.host) port=\(resolved.endpoint.port)"
            )
            return resolved.endpoint
        } catch {
            try? NIORuntime.shared.release(for: .networkExtension)
            throw error
        }
    }

    private func stopOnLifecycleQueue() {
        let snapshot: (Channel?, [Channel], Bool)
        lock.lock()
        snapshot = (
            listenerChannel,
            Array(childChannels.values),
            runtimeAcquired
        )
        listenerChannel = nil
        childChannels.removeAll()
        endpoint = nil
        runtimeAcquired = false
        lock.unlock()

        if let listener = snapshot.0 {
            if listener.eventLoop.inEventLoop {
                listener.close(promise: nil)
            } else {
                _ = try? listener.close().wait()
            }
        }

        for child in snapshot.1 {
            if child.eventLoop.inEventLoop {
                child.close(promise: nil)
            } else {
                _ = try? child.close().wait()
            }
        }

        if snapshot.2 {
            try? NIORuntime.shared.release(for: .networkExtension)
        }

        eventLogHandler?("local_socks5_server", "outcome=stopped")
    }

    private func bindListener(using group: NIOTSEventLoopGroup, preferredPort: UInt16) throws -> (channel: Channel, endpoint: Endpoint) {
        do {
            let preferred = preferredPort > 0 ? preferredPort : nil
            return try bindListener(using: group, port: preferred)
        } catch {
            guard preferredPort > 0 else {
                throw error
            }
            let fallback = try bindListener(using: group, port: nil)
            eventLogHandler?(
                "local_socks5_server",
                "outcome=success fallback=ephemeral requested_port=\(preferredPort) host=\(fallback.endpoint.host) port=\(fallback.endpoint.port)"
            )
            return fallback
        }
    }

    private func bindListener(using group: NIOTSEventLoopGroup, port: UInt16?) throws -> (channel: Channel, endpoint: Endpoint) {
        let bootstrap = NIOTSListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                self.registerChild(channel)

                let handler = Socks5SessionHandler(
                    group: group,
                    tcpConnectRoutingPolicy: self.tcpConnectRoutingPolicy,
                    eventLogHandler: self.eventLogHandler
                ) { [weak self, weak channel] in
                    guard let self, let channel else { return }
                    self.unregisterChild(channel)
                }

                channel.closeFuture.whenComplete { [weak self, weak channel] _ in
                    guard let self, let channel else { return }
                    self.unregisterChild(channel)
                }
                return channel.pipeline.addHandler(handler)
            }

        let channel: Channel = if let port {
            try bootstrap.bind(host: bindHost, port: Int(port)).wait()
        } else {
            try bootstrap.bind(host: bindHost, port: 0).wait()
        }

        guard let localAddress = channel.localAddress,
              let localPortRaw = localAddress.port,
              let localPort = UInt16(exactly: localPortRaw)
        else {
            _ = try? channel.close().wait()
            throw ServerError.listenerPortUnavailable
        }

        let endpoint = Endpoint(host: bindHost, port: localPort)
        return (channel: channel, endpoint: endpoint)
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
