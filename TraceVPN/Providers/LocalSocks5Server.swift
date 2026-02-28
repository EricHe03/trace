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

private enum Socks5ServerConnectionError: LocalizedError {
    case closed
    case commandNotSupported
    case addressTypeNotSupported
    case connectFailed

    var errorDescription: String? {
        switch self {
        case .closed:
            "Connection closed"
        case .commandNotSupported:
            "SOCKS5 command not supported"
        case .addressTypeNotSupported:
            "SOCKS5 address type not supported"
        case .connectFailed:
            "Failed to connect upstream target"
        }
    }
}

private enum Socks5Command: UInt8 {
    case connect = 0x01
    case udpAssociate = 0x03
}

private enum Socks5Reply: UInt8 {
    case succeeded = 0x00
    case generalFailure = 0x01
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08
}

private enum Socks5AddressType: UInt8, Sendable {
    case ipv4 = 0x01
    case domain = 0x03
    case ipv6 = 0x04
}

private struct Socks5Address: Hashable, Sendable {
    let type: Socks5AddressType
    let host: String
}

private struct Socks5Request {
    let command: Socks5Command
    let address: Socks5Address
    let port: UInt16
}

private enum ParseResult<T> {
    case needMoreData
    case invalid
    case value(T)
}

private final class Socks5SessionHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case greeting
        case request
        case connecting
        case udpAssociating
        case relaying
        case udpAssociated
        case closing

        var logToken: String {
            switch self {
            case .greeting:
                return "greeting"
            case .request:
                return "request"
            case .connecting:
                return "connecting"
            case .udpAssociating:
                return "udp_associating"
            case .relaying:
                return "relaying"
            case .udpAssociated:
                return "udp_associated"
            case .closing:
                return "closing"
            }
        }
    }

    private enum UDPAssociateSetupResult {
        case success(relay: Socks5UDPRelay, endpoint: Socks5UDPRelay.Endpoint)
        case failure
    }

    /// Avoid blocking the channel's event loop while creating the UDP relay socket.
    private static let udpAssociateSetupQueue = DispatchQueue(
        label: "com.trace.vpn.local_socks5.udp_associate_setup",
        qos: .userInitiated
    )

    private let group: NIOTSEventLoopGroup
    private let tcpConnectRoutingPolicy: LocalSocks5Server.TCPConnectRoutingPolicy
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private let onSessionClosed: @Sendable () -> Void

    private static let dotBackoffTTL: TimeInterval = 60
    private static let dotBackoffLock = NSLock()
    private nonisolated(unsafe) static var dotBackoffByEndpoint: [String: Date] = [:]
    private static let directBackoffTTL: TimeInterval = 10
    private static let directBackoffLock = NSLock()
    private nonisolated(unsafe) static var directBackoffByEndpoint: [String: Date] = [:]
    private static let flowIDLock = NSLock()
    private nonisolated(unsafe) static var nextFlowID: UInt64 = 1

    private let sessionID = UUID().uuidString
    private let flowID = Socks5SessionHandler.allocateFlowID()
    private var state: State = .greeting
    private var didLogFailure = false
    private var buffer = ByteBuffer()
    private var remoteChannel: Channel?
    private var udpRelay: Socks5UDPRelay?

    private enum DirectConnectControlError: LocalizedError {
        case directBackoffActive
        case dotBackoffActive

        var errorDescription: String? {
            switch self {
            case .directBackoffActive:
                "Direct endpoint is in failure backoff window"
            case .dotBackoffActive:
                "DoT endpoint is in failure backoff window"
            }
        }
    }

    init(
        group: NIOTSEventLoopGroup,
        tcpConnectRoutingPolicy: LocalSocks5Server.TCPConnectRoutingPolicy,
        eventLogHandler: (@Sendable (String, String) -> Void)?,
        onSessionClosed: @Sendable @escaping () -> Void
    ) {
        self.group = group
        self.tcpConnectRoutingPolicy = tcpConnectRoutingPolicy
        self.eventLogHandler = eventLogHandler
        self.onSessionClosed = onSessionClosed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)

        switch state {
        case .relaying:
            guard let remoteChannel, remoteChannel.isActive else {
                closeConnection(context: context)
                return
            }
            remoteChannel.writeAndFlush(inbound, promise: nil)
        case .udpAssociated, .udpAssociating:
            // Keep the TCP control channel open; ignore additional payload.
            return
        case .closing:
            return
        case .greeting, .request, .connecting:
            buffer.writeBuffer(&inbound)
            processBufferedData(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state = .closing
        remoteChannel?.close(promise: nil)
        remoteChannel = nil
        udpRelay?.stop()
        udpRelay = nil
        onSessionClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logSessionFailureIfNeeded(error)
        closeConnection(context: context)
    }

    private func logSessionFailureIfNeeded(_ error: Error) {
        guard !didLogFailure else { return }
        guard state != .closing else { return }
        didLogFailure = true
        let expectedClosure = isExpectedSessionClosure(error)
        let outcome = expectedClosure ? "closed" : "failure"
        let classification = expectedClosure ? "channel_closed" : "unexpected_error"
        eventLogHandler?(
            "local_socks5_session",
            "outcome=\(outcome) session=\(sessionID) state=\(state.logToken) classification=\(classification) error=\(error.localizedDescription)"
        )
    }

    private func isExpectedSessionClosure(_ error: Error) -> Bool {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .alreadyClosed, .ioOnClosedChannel:
                return true
            default:
                break
            }

            let detail = String(describing: channelError).lowercased()
            if detail.contains("channelerror 0") || detail.contains("channelerror 5") {
                return true
            }
        }

        let nsError = error as NSError
        let nsDomain = nsError.domain.lowercased()
        if nsDomain.contains("niocore.channelerror"),
           nsError.code == 0 || nsError.code == 5 {
            return true
        }

        let detail = "\(String(describing: error).lowercased()) \(error.localizedDescription.lowercased())"
        if detail.contains("channelerror"),
           detail.contains("error 0") || detail.contains("error 5") {
            return true
        }

        return false
    }

    private func processBufferedData(context: ChannelHandlerContext) {
        while true {
            switch state {
            case .greeting:
                switch parseGreeting() {
                case .needMoreData:
                    return
                case .invalid:
                    closeConnection(context: context)
                    return
                case let .value(supportsNoAuth):
                    let method: UInt8 = supportsNoAuth ? 0x00 : 0xFF
                    writeBytes([0x05, method], context: context)
                    guard supportsNoAuth else {
                        closeConnection(context: context)
                        return
                    }
                    state = .request
                }
            case .request:
                switch parseRequest() {
                case .needMoreData:
                    return
                case .invalid:
                    sendReply(.generalFailure, context: context)
                    closeConnection(context: context)
                    return
                case let .value(request):
                    switch request.command {
                    case .connect:
                        state = .connecting
                        connectToUpstream(request: request, context: context)
                        return
                    case .udpAssociate:
                        handleUDPAssociate(request: request, context: context)
                        return
                    }
                }
            case .connecting, .udpAssociating, .relaying, .udpAssociated, .closing:
                return
            }
        }
    }

    private func connectToUpstream(request: Socks5Request, context: ChannelHandlerContext) {
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .channelInitializer { [weak context] channel in
                guard let context else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return channel.pipeline.addHandler(Socks5RemoteRelayHandler(clientChannel: context.channel))
            }

        let destinationHost = request.address.host
        let destinationPort = request.port
        let destinationHash = LogRedaction.hash(destinationHost)
        let routeEvaluation = tcpConnectRoutingPolicy.evaluateRouteDecision(
            destinationHost: destinationHost,
            destinationPort: destinationPort
        )
        let routeDecision = routeEvaluation.effectiveDecision
        maybeLogPolicyShadowMismatch(
            evaluation: routeEvaluation,
            destinationHash: destinationHash,
            destinationPort: destinationPort
        )

        switch routeDecision {
        case .mitm:
            let mitmHost = tcpConnectRoutingPolicy.mitmProxyHost
            let mitmPort = tcpConnectRoutingPolicy.mitmProxyPort
            eventLogHandler?(
                "local_socks5_connect_route",
                "session=\(sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=mitm route_decision=mitm fallback_applied=false bypass_reason=none policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) proxy_port=\(mitmPort)"
            )
            connect(
                host: mitmHost,
                port: mitmPort,
                using: bootstrap,
                context: context
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(remoteChannel):
                    self.completeMITMConnectSuccess(
                        remoteChannel,
                        destinationAddress: request.address,
                        destinationPort: destinationPort,
                        destinationHash: destinationHash,
                        context: context
                    )
                case let .failure(error):
                    self.eventLogHandler?(
                        "local_socks5_connect_route",
                        "session=\(self.sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=mitm route_decision=mitm fallback_applied=true bypass_reason=mitm_connect_failed policy=\(self.tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) outcome=failure error=\(error.localizedDescription)"
                    )
                    self.attemptDirectFallback(
                        destinationHost: destinationHost,
                        destinationPort: destinationPort,
                        destinationHash: destinationHash,
                        context: context
                    )
                }
            }
        case let .direct(reason):
            eventLogHandler?(
                "local_socks5_connect_route",
                "session=\(sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=direct route_decision=direct fallback_applied=false bypass_reason=\(reason) policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue)"
            )
            attemptDirectConnect(
                host: destinationHost,
                port: destinationPort,
                destinationHash: destinationHash,
                fallbackApplied: false,
                bypassReason: reason,
                context: context
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(remoteChannel):
                    self.completeConnectSuccess(remoteChannel, context: context)
                case let .failure(error):
                    self.eventLogHandler?(
                        "local_socks5_connect_route",
                        "session=\(self.sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=direct route_decision=direct fallback_applied=false bypass_reason=\(reason) policy=\(self.tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) outcome=failure error=\(error.localizedDescription)"
                    )
                    self.completeConnectFailure(context: context)
                }
            }
        }
    }

    private func maybeLogPolicyShadowMismatch(
        evaluation: LocalSocks5Server.TCPConnectRoutingPolicy.RouteDecisionEvaluation,
        destinationHash: String,
        destinationPort: UInt16
    ) {
        guard evaluation.hasShadowMismatch else { return }
        guard let policyDecision = evaluation.policyDecision else { return }

        let legacyRoute = routeDecisionValue(evaluation.legacyDecision)
        let legacyReason = routeBypassReason(evaluation.legacyDecision)
        let policyRoute = routeDecisionValue(policyDecision)
        let policyReason = routeBypassReason(policyDecision)
        let effectiveRoute = routeDecisionValue(evaluation.effectiveDecision)
        let effectiveReason = routeBypassReason(evaluation.effectiveDecision)
        eventLogHandler?(
            "dual_mitm_policy_shadow",
            "session=\(sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) legacy_route=\(legacyRoute) legacy_reason=\(legacyReason) policy_route=\(policyRoute) policy_reason=\(policyReason) effective_route=\(effectiveRoute) effective_reason=\(effectiveReason) mismatch=true enforced=\(evaluation.policyEnforced)"
        )
    }

    private func routeDecisionValue(_ decision: LocalSocks5Server.TCPConnectRoutingPolicy.RouteDecision) -> String {
        switch decision {
        case .mitm:
            "mitm"
        case .direct:
            "direct"
        }
    }

    private func routeBypassReason(_ decision: LocalSocks5Server.TCPConnectRoutingPolicy.RouteDecision) -> String {
        switch decision {
        case .mitm:
            return "none"
        case let .direct(reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "none" : trimmed
        }
    }

    private func connect(
        host: String,
        port: UInt16,
        using bootstrap: NIOTSConnectionBootstrap,
        context: ChannelHandlerContext,
        completion: @escaping (Result<Channel, Error>) -> Void
    ) {
        bootstrap.connect(host: host, port: Int(port)).whenComplete { result in
            context.eventLoop.execute {
                completion(result)
            }
        }
    }

    private func makeDirectBootstrap(context: ChannelHandlerContext) -> NIOTSConnectionBootstrap {
        NIOTSConnectionBootstrap(group: group)
            .channelInitializer { [weak context] channel in
                guard let context else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return channel.pipeline.addHandler(Socks5RemoteRelayHandler(clientChannel: context.channel))
            }
    }

    private func attemptDirectConnect(
        host: String,
        port: UInt16,
        destinationHash: String,
        fallbackApplied: Bool,
        bypassReason: String,
        context: ChannelHandlerContext,
        completion: @escaping (Result<Channel, Error>) -> Void
    ) {
        if Self.isDirectBackoffActive(host: host, port: port) {
            eventLogHandler?(
                "local_socks5_connect_route",
                "session=\(sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(port) route=direct route_decision=direct fallback_applied=\(fallbackApplied) bypass_reason=\(bypassReason) policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) outcome=skipped reason=direct_backoff_active"
            )
            completion(.failure(DirectConnectControlError.directBackoffActive))
            return
        }

        if Self.isDoTBackoffActive(host: host, port: port) {
            eventLogHandler?(
                "local_socks5_connect_route",
                "session=\(sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(port) route=direct route_decision=direct fallback_applied=\(fallbackApplied) bypass_reason=\(bypassReason) policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) outcome=skipped reason=dot_backoff_active"
            )
            completion(.failure(DirectConnectControlError.dotBackoffActive))
            return
        }

        let directBootstrap = makeDirectBootstrap(context: context)
        connect(host: host, port: port, using: directBootstrap, context: context) { [weak self] firstResult in
            guard let self else { return }

            switch firstResult {
            case .success:
                completion(firstResult)

            case let .failure(firstError):
                guard self.shouldRetryDirectConnect(error: firstError, port: port) else {
                    self.maybeRecordDoTBackoff(
                        host: host,
                        port: port,
                        destinationHash: destinationHash,
                        fallbackApplied: fallbackApplied,
                        bypassReason: bypassReason,
                        error: firstError
                    )
                    self.maybeRecordDirectBackoff(
                        host: host,
                        port: port,
                        destinationHash: destinationHash,
                        fallbackApplied: fallbackApplied,
                        bypassReason: bypassReason,
                        error: firstError
                    )
                    completion(firstResult)
                    return
                }

                let delayMilliseconds = Int64(Int.random(in: 100 ... 250))
                self.eventLogHandler?(
                    "local_socks5_connect_route",
                    "session=\(self.sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(port) route=direct route_decision=direct fallback_applied=\(fallbackApplied) bypass_reason=\(bypassReason) policy=\(self.tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) outcome=retry_scheduled attempt=2 delay_ms=\(delayMilliseconds)"
                )
                context.eventLoop.scheduleTask(in: .milliseconds(delayMilliseconds)) { [weak self] in
                    guard let self else { return }
                    let retryBootstrap = self.makeDirectBootstrap(context: context)
                    self.connect(host: host, port: port, using: retryBootstrap, context: context) { retryResult in
                        if case let .failure(retryError) = retryResult {
                            self.maybeRecordDoTBackoff(
                                host: host,
                                port: port,
                                destinationHash: destinationHash,
                                fallbackApplied: fallbackApplied,
                                bypassReason: bypassReason,
                                error: retryError
                            )
                            self.maybeRecordDirectBackoff(
                                host: host,
                                port: port,
                                destinationHash: destinationHash,
                                fallbackApplied: fallbackApplied,
                                bypassReason: bypassReason,
                                error: retryError
                            )
                        }
                        completion(retryResult)
                    }
                }
            }
        }
    }

    private func shouldRetryDirectConnect(error: Error, port: UInt16) -> Bool {
        guard port == 443 || port == 853 else { return false }

        if let channelError = error as? ChannelError {
            let channelDetail = String(describing: channelError).lowercased()
            if channelDetail.contains("ioonclosedchannel") ||
                channelDetail.contains("alreadyclosed") ||
                channelDetail.contains("channelerror 0") ||
                channelDetail.contains("channelerror 5") {
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain.lowercased().contains("niocore.channelerror"),
           nsError.code == 0 || nsError.code == 5 {
            return true
        }
        if nsError.code == 54 {
            return true
        }

        let detail = String(describing: error).lowercased()
        let localizedDetail = error.localizedDescription.lowercased()
        let combinedDetail = "\(detail) \(localizedDetail)"
        if combinedDetail.contains("channelerror") &&
            (
                combinedDetail.contains("error 0") ||
                    combinedDetail.contains("error 5") ||
                    combinedDetail.contains("channelerror 0") ||
                    combinedDetail.contains("channelerror 5") ||
                    combinedDetail.contains(": 0") ||
                    combinedDetail.contains(": 5")
            ) {
            return true
        }
        if combinedDetail.contains("nwerror") && combinedDetail.contains("54") {
            return true
        }
        return false
    }

    private func shouldApplyDirectBackoff(
        port: UInt16,
        bypassReason: String,
        error: Error
    ) -> Bool {
        guard port == 443 else { return false }
        if shouldRetryDirectConnect(error: error, port: port) {
            return true
        }

        let normalizedBypassReason = bypassReason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedBypassReason.contains("connection_closed_early") {
            return true
        }

        let combinedDetail = "\(String(describing: error).lowercased()) \(error.localizedDescription.lowercased())"
        return combinedDetail.contains("channelerror")
    }

    private func maybeRecordDoTBackoff(
        host: String,
        port: UInt16,
        destinationHash: String,
        fallbackApplied: Bool,
        bypassReason: String,
        error: Error
    ) {
        guard port == 853 else { return }
        let expiresAt = Self.recordDoTBackoff(host: host, port: port)
        let backoffMilliseconds = max(0, Int(expiresAt.timeIntervalSinceNow * 1000))
        eventLogHandler?(
            "local_socks5_connect_route",
            "session=\(sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(port) route=direct route_decision=direct fallback_applied=\(fallbackApplied) bypass_reason=\(bypassReason) policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) outcome=backoff_set ttl_ms=\(backoffMilliseconds) error=\(error.localizedDescription)"
        )
    }

    private func maybeRecordDirectBackoff(
        host: String,
        port: UInt16,
        destinationHash: String,
        fallbackApplied: Bool,
        bypassReason: String,
        error: Error
    ) {
        guard shouldApplyDirectBackoff(port: port, bypassReason: bypassReason, error: error) else { return }

        let expiresAt = Self.recordDirectBackoff(host: host, port: port)
        let backoffMilliseconds = max(0, Int(expiresAt.timeIntervalSinceNow * 1000))
        eventLogHandler?(
            "local_socks5_connect_route",
            "session=\(sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(port) route=direct route_decision=direct fallback_applied=\(fallbackApplied) bypass_reason=\(bypassReason) policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) outcome=backoff_set reason=direct_endpoint_backoff ttl_ms=\(backoffMilliseconds) error=\(error.localizedDescription)"
        )
    }

    private static func normalizedEndpointHost(_ host: String) -> String {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.first == "[", normalized.last == "]" {
            normalized = String(normalized.dropFirst().dropLast())
        }
        return normalized
    }

    private static func dotEndpointKey(host: String, port: UInt16) -> String {
        "\(normalizedEndpointHost(host)):\(port)"
    }

    private static func directEndpointKey(host: String, port: UInt16) -> String {
        "\(normalizedEndpointHost(host)):\(port)"
    }

    private static func allocateFlowID() -> UInt64 {
        flowIDLock.lock()
        defer { flowIDLock.unlock() }
        let allocated = nextFlowID
        nextFlowID &+= 1
        if nextFlowID == 0 {
            nextFlowID = 1
        }
        return allocated
    }

    private static func isDoTBackoffActive(host: String, port: UInt16, now: Date = Date()) -> Bool {
        guard port == 853 else { return false }
        let key = dotEndpointKey(host: host, port: port)

        dotBackoffLock.lock()
        defer { dotBackoffLock.unlock() }
        pruneDoTBackoffLocked(now: now)
        guard let expiresAt = dotBackoffByEndpoint[key] else { return false }
        return expiresAt > now
    }

    private static func isDirectBackoffActive(host: String, port: UInt16, now: Date = Date()) -> Bool {
        guard port == 443 else { return false }
        let key = directEndpointKey(host: host, port: port)

        directBackoffLock.lock()
        defer { directBackoffLock.unlock() }
        pruneDirectBackoffLocked(now: now)
        guard let expiresAt = directBackoffByEndpoint[key] else { return false }
        return expiresAt > now
    }

    @discardableResult
    private static func recordDoTBackoff(host: String, port: UInt16, now: Date = Date()) -> Date {
        let key = dotEndpointKey(host: host, port: port)
        let expiresAt = now.addingTimeInterval(dotBackoffTTL)
        dotBackoffLock.lock()
        defer { dotBackoffLock.unlock() }
        pruneDoTBackoffLocked(now: now)
        dotBackoffByEndpoint[key] = expiresAt
        return expiresAt
    }

    @discardableResult
    private static func recordDirectBackoff(host: String, port: UInt16, now: Date = Date()) -> Date {
        let key = directEndpointKey(host: host, port: port)
        let expiresAt = now.addingTimeInterval(directBackoffTTL)
        directBackoffLock.lock()
        defer { directBackoffLock.unlock() }
        pruneDirectBackoffLocked(now: now)
        directBackoffByEndpoint[key] = expiresAt
        return expiresAt
    }

    private static func pruneDoTBackoffLocked(now: Date) {
        guard !dotBackoffByEndpoint.isEmpty else { return }
        dotBackoffByEndpoint = dotBackoffByEndpoint.filter { _, expiresAt in
            expiresAt > now
        }
    }

    private static func pruneDirectBackoffLocked(now: Date) {
        guard !directBackoffByEndpoint.isEmpty else { return }
        directBackoffByEndpoint = directBackoffByEndpoint.filter { _, expiresAt in
            expiresAt > now
        }
    }

    private func completeMITMConnectSuccess(
        _ remoteChannel: Channel,
        destinationAddress: Socks5Address,
        destinationPort: UInt16,
        destinationHash: String,
        context: ChannelHandlerContext
    ) {
        let policyModeRaw: UInt8 = tcpConnectRoutingPolicy.dualMITMPolicy == .strictMITM ? 1 : 0
        guard let metadataBytes = TransparentProxyMetadata.encodeUpstreamHintV2(
            host: destinationAddress.host,
            port: destinationPort,
            addressTypeRaw: destinationAddress.type.rawValue,
            flowID: flowID,
            policyModeRaw: policyModeRaw
        ) else {
            eventLogHandler?(
                "local_socks5_connect_route",
                "session=\(sessionID) flow_id=\(flowID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=mitm route_decision=mitm fallback_applied=false bypass_reason=none policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) metadata=encode_skipped"
            )
            completeConnectSuccess(remoteChannel, context: context)
            return
        }

        var metadataBuffer = remoteChannel.allocator.buffer(capacity: metadataBytes.count)
        metadataBuffer.writeBytes(metadataBytes)
        remoteChannel.writeAndFlush(metadataBuffer).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self else {
                    remoteChannel.close(promise: nil)
                    return
                }

                switch result {
                case .success:
                    self.eventLogHandler?(
                        "local_socks5_connect_route",
                        "session=\(self.sessionID) flow_id=\(self.flowID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=mitm route_decision=mitm fallback_applied=false bypass_reason=none policy=\(self.tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) metadata=sent bytes=\(metadataBytes.count) metadata_version=2"
                    )
                    self.completeConnectSuccess(remoteChannel, context: context)

                case let .failure(error):
                    self.eventLogHandler?(
                        "local_socks5_connect_route",
                        "session=\(self.sessionID) flow_id=\(self.flowID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=mitm route_decision=mitm fallback_applied=true bypass_reason=mitm_metadata_send_failed policy=\(self.tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) metadata=send_failed error=\(error.localizedDescription)"
                    )
                    remoteChannel.close(promise: nil)
                    self.attemptDirectFallback(
                        destinationHost: destinationAddress.host,
                        destinationPort: destinationPort,
                        destinationHash: destinationHash,
                        context: context,
                        fallbackDetail: "mitm_metadata_send_failed"
                    )
                }
            }
        }
    }

    private func attemptDirectFallback(
        destinationHost: String,
        destinationPort: UInt16,
        destinationHash: String,
        context: ChannelHandlerContext,
        fallbackDetail: String? = nil
    ) {
        guard tcpConnectRoutingPolicy.failOpen else {
            completeConnectFailure(context: context)
            return
        }

        let fallbackSuffix = if let fallbackDetail,
                                !fallbackDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            " detail=\(fallbackDetail)"
        } else {
            ""
        }
        eventLogHandler?(
            "local_socks5_connect_route",
            "session=\(sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=direct route_decision=direct fallback_applied=true bypass_reason=\(fallbackDetail ?? "mitm_connect_failed") policy=\(tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) fallback=enabled\(fallbackSuffix)"
        )

        attemptDirectConnect(
            host: destinationHost,
            port: destinationPort,
            destinationHash: destinationHash,
            fallbackApplied: true,
            bypassReason: fallbackDetail ?? "mitm_connect_failed",
            context: context
        ) { [weak self] directResult in
            guard let self else { return }
            switch directResult {
            case let .success(remoteChannel):
                self.completeConnectSuccess(remoteChannel, context: context)
            case let .failure(directError):
                self.eventLogHandler?(
                    "local_socks5_connect_route",
                    "session=\(self.sessionID) destination_hash=\(destinationHash) sni_hash=\(destinationHash) upstream_hash=\(destinationHash) destination_port=\(destinationPort) route=direct route_decision=direct fallback_applied=true bypass_reason=\(fallbackDetail ?? "mitm_connect_failed") policy=\(self.tcpConnectRoutingPolicy.dualMITMPolicy.rawValue) outcome=failure error=\(directError.localizedDescription)"
                )
                self.completeConnectFailure(context: context)
            }
        }
    }

    private func completeConnectSuccess(_ remoteChannel: Channel, context: ChannelHandlerContext) {
        guard state == .connecting else {
            remoteChannel.close(promise: nil)
            return
        }

        self.remoteChannel = remoteChannel
        self.state = .relaying
        self.sendReply(.succeeded, context: context)

        if self.buffer.readableBytes > 0, let remaining = self.buffer.readSlice(length: self.buffer.readableBytes) {
            remoteChannel.writeAndFlush(remaining, promise: nil)
        }
    }

    private func completeConnectFailure(context: ChannelHandlerContext) {
        guard state == .connecting else { return }
        sendReply(.generalFailure, context: context)
        closeConnection(context: context)
    }

    private func handleUDPAssociate(request: Socks5Request, context: ChannelHandlerContext) {
        guard state == .request else { return }
        state = .udpAssociating
        let preferredType: Socks5AddressType = request.address.type == .ipv6 ? .ipv6 : .ipv4
        Self.udpAssociateSetupQueue.async { [weak self, weak context] in
            guard let self, let context else { return }
            let result = self.makeUDPAssociateRelay(preferredType: preferredType)
            context.eventLoop.execute {
                guard self.state == .udpAssociating else {
                    if case let .success(relay, _) = result {
                        relay.stop()
                    }
                    return
                }

                switch result {
                case let .success(relay, endpoint):
                    self.udpRelay = relay
                    self.state = .udpAssociated
                    self.sendReply(
                        .succeeded,
                        bindAddress: Socks5Address(type: endpoint.addressType, host: endpoint.host),
                        bindPort: endpoint.port,
                        context: context
                    )
                case .failure:
                    self.sendReply(.generalFailure, context: context)
                    self.closeConnection(context: context)
                }
            }
        }
    }

    private func makeUDPAssociateRelay(preferredType: Socks5AddressType) -> UDPAssociateSetupResult {
        do {
            let relay = Socks5UDPRelay(
                group: group,
                bindAddressType: preferredType,
                eventLogHandler: eventLogHandler
            )
            let endpoint = try relay.start()
            return .success(relay: relay, endpoint: endpoint)
        } catch {
            guard preferredType == .ipv6 else {
                eventLogHandler?(
                    "local_socks5_udp_relay",
                    "outcome=failure addr_type=\(preferredType.rawValue) reason=start_failed"
                )
                return .failure
            }

            do {
                let relay = Socks5UDPRelay(
                    group: group,
                    bindAddressType: .ipv4,
                    eventLogHandler: eventLogHandler
                )
                let endpoint = try relay.start()
                eventLogHandler?(
                    "local_socks5_udp_relay",
                    "outcome=success fallback=ipv4_from_ipv6_request"
                )
                return .success(relay: relay, endpoint: endpoint)
            } catch {
                eventLogHandler?(
                    "local_socks5_udp_relay",
                    "outcome=failure addr_type=\(preferredType.rawValue) fallback=ipv4_failed"
                )
                return .failure
            }
        }
    }

    private func parseGreeting() -> ParseResult<Bool> {
        guard buffer.readableBytes >= 2 else {
            return .needMoreData
        }

        guard let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self),
              let methodsCount = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self)
        else {
            return .invalid
        }

        guard version == 0x05 else {
            return .invalid
        }

        let totalLength = 2 + Int(methodsCount)
        guard buffer.readableBytes >= totalLength else {
            return .needMoreData
        }

        _ = buffer.readInteger(as: UInt8.self)
        _ = buffer.readInteger(as: UInt8.self)
        guard let methods = buffer.readBytes(length: Int(methodsCount)) else {
            return .invalid
        }

        return .value(methods.contains(0x00))
    }

    private func parseRequest() -> ParseResult<Socks5Request> {
        guard buffer.readableBytes >= 4 else {
            return .needMoreData
        }

        guard let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self),
              let commandRaw = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
              let atypRaw = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self)
        else {
            return .invalid
        }

        guard version == 0x05 else {
            return .invalid
        }

        guard let command = Socks5Command(rawValue: commandRaw) else {
            return .invalid
        }

        guard let atyp = Socks5AddressType(rawValue: atypRaw) else {
            return .invalid
        }

        let checkpoint = buffer

        _ = buffer.readInteger(as: UInt8.self) // version
        _ = buffer.readInteger(as: UInt8.self) // command
        _ = buffer.readInteger(as: UInt8.self) // reserved
        _ = buffer.readInteger(as: UInt8.self) // atyp

        guard let address = readAddress(type: atyp) else {
            buffer = checkpoint
            return .needMoreData
        }

        guard let portHigh = buffer.readInteger(as: UInt8.self),
              let portLow = buffer.readInteger(as: UInt8.self)
        else {
            buffer = checkpoint
            return .needMoreData
        }

        let port = UInt16(portHigh) << 8 | UInt16(portLow)
        return .value(Socks5Request(command: command, address: address, port: port))
    }

    private func readAddress(type: Socks5AddressType) -> Socks5Address? {
        switch type {
        case .ipv4:
            guard let bytes = buffer.readBytes(length: 4) else { return nil }
            let host = bytes.map(String.init).joined(separator: ".")
            return Socks5Address(type: .ipv4, host: host)
        case .domain:
            guard let length = buffer.readInteger(as: UInt8.self) else { return nil }
            guard let bytes = buffer.readBytes(length: Int(length)),
                  let host = String(bytes: bytes, encoding: .utf8)
            else {
                return nil
            }
            return Socks5Address(type: .domain, host: host)
        case .ipv6:
            guard let bytes = buffer.readBytes(length: 16) else { return nil }
            guard let host = Self.ipv6String(from: bytes) else { return nil }
            return Socks5Address(type: .ipv6, host: host)
        }
    }

    private func sendReply(
        _ reply: Socks5Reply,
        bindAddress: Socks5Address = Socks5Address(type: .ipv4, host: "0.0.0.0"),
        bindPort: UInt16 = 0,
        context: ChannelHandlerContext
    ) {
        guard let addressBytes = encodeAddress(bindAddress) else {
            writeBytes([0x05, Socks5Reply.generalFailure.rawValue, 0x00, Socks5AddressType.ipv4.rawValue, 0, 0, 0, 0, 0, 0], context: context)
            return
        }

        var bytes: [UInt8] = [0x05, reply.rawValue, 0x00, bindAddress.type.rawValue]
        bytes.append(contentsOf: addressBytes)
        bytes.append(UInt8((bindPort >> 8) & 0xFF))
        bytes.append(UInt8(bindPort & 0xFF))
        writeBytes(bytes, context: context)
    }

    private func encodeAddress(_ address: Socks5Address) -> [UInt8]? {
        switch address.type {
        case .ipv4:
            return Self.ipv4Bytes(from: address.host)
        case .domain:
            guard let data = address.host.data(using: .utf8), data.count <= 255 else {
                return nil
            }
            return [UInt8(data.count)] + Array(data)
        case .ipv6:
            return Self.ipv6Bytes(from: address.host)
        }
    }

    private func writeBytes(_ bytes: [UInt8], context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func closeConnection(context: ChannelHandlerContext) {
        state = .closing
        remoteChannel?.close(promise: nil)
        remoteChannel = nil
        udpRelay?.stop()
        udpRelay = nil
        context.close(promise: nil)
    }

    fileprivate static func ipv4Bytes(from host: String) -> [UInt8]? {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &addr.s_addr) { Array($0) }
    }

    fileprivate static func ipv6Bytes(from host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &addr.__u6_addr.__u6_addr8) { Array($0) }
    }

    fileprivate static func ipv6String(from bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr.__u6_addr.__u6_addr8) { destination in
            destination.copyBytes(from: bytes)
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &output, socklen_t(output.count)) != nil else {
            return nil
        }
        return String(cString: output)
    }
}

private final class Socks5RemoteRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var clientChannel: Channel?

    init(clientChannel: Channel) {
        self.clientChannel = clientChannel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inbound = unwrapInboundIn(data)
        guard let clientChannel, clientChannel.isActive else {
            context.close(promise: nil)
            return
        }
        clientChannel.writeAndFlush(inbound, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        clientChannel?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        clientChannel?.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class Socks5UDPRelay: @unchecked Sendable {
    struct Endpoint: Sendable {
        let host: String
        let port: UInt16
        let addressType: Socks5AddressType
    }

    fileprivate struct RemoteKey: Hashable {
        let address: Socks5Address
        let port: UInt16
    }

    private struct Datagram {
        let address: Socks5Address
        let port: UInt16
        let payload: Data
    }

    private enum RelayError: LocalizedError {
        case listenerPortUnavailable
        case startupFailed
    }

    private final class RemoteState: @unchecked Sendable {
        let key: RemoteKey
        let host: String
        let port: UInt16
        var channel: Channel?
        var isReady = false
        var pendingPayloads: [Data] = []

        init(key: RemoteKey, host: String, port: UInt16) {
            self.key = key
            self.host = host
            self.port = port
        }
    }

    private let lock = NSLock()
    private let group: NIOTSEventLoopGroup
    private let bindAddressType: Socks5AddressType
    private let bindHost: String
    private let eventLogHandler: (@Sendable (String, String) -> Void)?

    private var listenerChannel: Channel?
    private var clientChannel: Channel?
    private var clientKey: String?
    private var remoteStates: [RemoteKey: RemoteState] = [:]

    init(
        group: NIOTSEventLoopGroup,
        bindAddressType: Socks5AddressType,
        eventLogHandler: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.group = group
        self.bindAddressType = bindAddressType
        self.bindHost = bindAddressType == .ipv6 ? "::1" : "127.0.0.1"
        self.eventLogHandler = eventLogHandler
    }

    func start() throws -> Endpoint {
        let bootstrap = NIOTSDatagramListenerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return channel.pipeline.addHandler(Socks5UDPClientInboundHandler(owner: self))
            }

        let channel: Channel
        do {
            channel = try bootstrap.bind(host: bindHost, port: 0).wait()
        } catch {
            throw RelayError.startupFailed
        }

        guard let localAddress = channel.localAddress,
              let localPortRaw = localAddress.port,
              let localPort = UInt16(exactly: localPortRaw)
        else {
            _ = try? channel.close().wait()
            throw RelayError.listenerPortUnavailable
        }

        lock.lock()
        listenerChannel = channel
        lock.unlock()

        let endpoint = Endpoint(host: bindHost, port: localPort, addressType: bindAddressType)
        eventLogHandler?("local_socks5_udp_relay", "outcome=ready port=\(endpoint.port)")
        return endpoint
    }

    func stop() {
        let channelsToClose: [Channel]
        lock.lock()
        var channels: [Channel] = []
        if let listenerChannel {
            channels.append(listenerChannel)
        }
        if let clientChannel {
            channels.append(clientChannel)
        }
        channels.append(contentsOf: remoteStates.values.compactMap(\.channel))

        listenerChannel = nil
        clientChannel = nil
        clientKey = nil
        remoteStates.removeAll()
        channelsToClose = channels
        lock.unlock()

        for channel in channelsToClose {
            channel.close(promise: nil)
        }
    }

    fileprivate func activateClientChannel(_ channel: Channel) -> Bool {
        guard let key = endpointKey(channel.remoteAddress) else {
            return false
        }
        var previousChannel: Channel?
        var accepted = false
        lock.lock()
        if let existingKey = clientKey, existingKey != key {
            accepted = false
        } else {
            accepted = true
            previousChannel = clientChannel
            clientChannel = channel
            clientKey = key
        }
        lock.unlock()

        if let previousChannel, !Self.sameChannel(previousChannel, channel) {
            previousChannel.close(promise: nil)
        }
        return accepted
    }

    fileprivate func handleClientChannelInactive(_ channel: Channel) {
        let channelsToClose: [Channel]
        lock.lock()
        guard Self.sameChannel(clientChannel, channel) else {
            lock.unlock()
            return
        }
        clientChannel = nil
        clientKey = nil
        channelsToClose = remoteStates.values.compactMap(\.channel)
        remoteStates.removeAll()
        lock.unlock()

        for remote in channelsToClose {
            remote.close(promise: nil)
        }
    }

    fileprivate func handleClientDatagram(_ data: Data) {
        guard let datagram = parseUDPRequest(data) else {
            return
        }
        let key = RemoteKey(address: datagram.address, port: datagram.port)
        let state = remoteState(for: key, host: datagram.address.host, port: datagram.port)
        send(payload: datagram.payload, using: state)
    }

    fileprivate func handleRemoteDatagram(_ payload: Data, from key: RemoteKey) {
        guard let frame = buildUDPResponse(address: key.address, port: key.port, payload: payload) else {
            return
        }
        var destination: Channel?
        lock.lock()
        if let clientChannel, clientChannel.isActive {
            destination = clientChannel
        }
        lock.unlock()

        guard let destination else {
            return
        }
        write(payload: frame, to: destination)
    }

    fileprivate func handleRemoteChannelInactive(_ channel: Channel, key: RemoteKey) {
        lock.lock()
        if let state = remoteStates[key],
           let current = state.channel,
           Self.sameChannel(current, channel) {
            remoteStates.removeValue(forKey: key)
        }
        lock.unlock()
    }

    private func remoteState(for key: RemoteKey, host: String, port: UInt16) -> RemoteState {
        let state: RemoteState
        let shouldConnect: Bool

        lock.lock()
        if let existing = remoteStates[key] {
            state = existing
            shouldConnect = false
        } else {
            let created = RemoteState(key: key, host: host, port: port)
            remoteStates[key] = created
            state = created
            shouldConnect = true
        }
        lock.unlock()

        if shouldConnect {
            connectRemote(state)
        }

        return state
    }

    private func connectRemote(_ state: RemoteState) {
        let bootstrap = NIOTSDatagramConnectionBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return channel.pipeline.addHandler(Socks5UDPRemoteInboundHandler(owner: self, key: state.key))
            }

        bootstrap.connect(host: state.host, port: Int(state.port)).whenComplete { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .success(channel):
                var pending: [Data] = []
                var shouldClose = false
                self.lock.lock()
                if let current = self.remoteStates[state.key], current === state {
                    current.channel = channel
                    current.isReady = true
                    pending = current.pendingPayloads
                    current.pendingPayloads.removeAll(keepingCapacity: true)
                } else {
                    shouldClose = true
                }
                self.lock.unlock()

                if shouldClose {
                    channel.close(promise: nil)
                    return
                }

                channel.closeFuture.whenComplete { [weak self, weak channel] _ in
                    guard let self, let channel else { return }
                    self.handleRemoteChannelInactive(channel, key: state.key)
                }

                for payload in pending {
                    self.write(payload: payload, to: channel)
                }
            case let .failure(error):
                self.lock.lock()
                if let current = self.remoteStates[state.key], current === state {
                    self.remoteStates.removeValue(forKey: state.key)
                }
                self.lock.unlock()

                self.eventLogHandler?(
                    "local_socks5_udp_relay",
                    "outcome=remote_connect_failure host=\(state.host) port=\(state.port) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func send(payload: Data, using state: RemoteState) {
        var channel: Channel?
        lock.lock()
        if state.isReady, let readyChannel = state.channel, readyChannel.isActive {
            channel = readyChannel
        } else {
            state.pendingPayloads.append(payload)
        }
        lock.unlock()

        guard let channel else {
            return
        }
        write(payload: payload, to: channel)
    }

    private func write(payload: Data, to channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        channel.writeAndFlush(buffer, promise: nil)
    }

    private func parseUDPRequest(_ data: Data) -> Datagram? {
        guard data.count >= 4 else { return nil }
        guard data[0] == 0, data[1] == 0 else { return nil }
        guard data[2] == 0 else { return nil } // Fragmentation is not supported.

        var offset = 3
        guard let atyp = Socks5AddressType(rawValue: data[offset]) else { return nil }
        offset += 1

        let host: String
        switch atyp {
        case .ipv4:
            guard data.count >= offset + 4 else { return nil }
            host = data[offset ..< offset + 4].map(String.init).joined(separator: ".")
            offset += 4
        case .domain:
            guard data.count > offset else { return nil }
            let length = Int(data[offset])
            offset += 1
            guard data.count >= offset + length,
                  let decoded = String(data: Data(data[offset ..< offset + length]), encoding: .utf8)
            else {
                return nil
            }
            host = decoded
            offset += length
        case .ipv6:
            guard data.count >= offset + 16 else { return nil }
            let raw = Array(data[offset ..< offset + 16])
            guard let decoded = Socks5SessionHandler.ipv6String(from: raw) else { return nil }
            host = decoded
            offset += 16
        }

        guard data.count >= offset + 2 else { return nil }
        let port = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2

        let payload = Data(data[offset...])
        let address = Socks5Address(type: atyp, host: host)
        return Datagram(address: address, port: port, payload: payload)
    }

    private func buildUDPResponse(address: Socks5Address, port: UInt16, payload: Data) -> Data? {
        guard let encodedAddress = encodeAddress(address) else { return nil }
        var frame = Data([0x00, 0x00, 0x00, address.type.rawValue])
        frame.append(contentsOf: encodedAddress)
        frame.append(UInt8((port >> 8) & 0xFF))
        frame.append(UInt8(port & 0xFF))
        frame.append(payload)
        return frame
    }

    private func encodeAddress(_ address: Socks5Address) -> Data? {
        switch address.type {
        case .ipv4:
            guard let bytes = Socks5SessionHandler.ipv4Bytes(from: address.host) else { return nil }
            return Data(bytes)
        case .domain:
            guard let data = address.host.data(using: .utf8), data.count <= 255 else { return nil }
            var encoded = Data([UInt8(data.count)])
            encoded.append(data)
            return encoded
        case .ipv6:
            guard let bytes = Socks5SessionHandler.ipv6Bytes(from: address.host) else { return nil }
            return Data(bytes)
        }
    }

    private func endpointKey(_ address: SocketAddress?) -> String? {
        guard let address else { return nil }
        return address.description
    }

    private static func sameChannel(_ lhs: Channel?, _ rhs: Channel?) -> Bool {
        guard let lhs, let rhs else { return false }
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

private final class Socks5UDPClientInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var owner: Socks5UDPRelay?

    init(owner: Socks5UDPRelay) {
        self.owner = owner
    }

    func channelActive(context: ChannelHandlerContext) {
        guard let owner, owner.activateClientChannel(context.channel) else {
            context.close(promise: nil)
            return
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }
        owner?.handleClientDatagram(Data(bytes))
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.handleClientChannelInactive(context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class Socks5UDPRemoteInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var owner: Socks5UDPRelay?
    private let key: Socks5UDPRelay.RemoteKey

    init(owner: Socks5UDPRelay, key: Socks5UDPRelay.RemoteKey) {
        self.owner = owner
        self.key = key
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }
        owner?.handleRemoteDatagram(Data(bytes), from: key)
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.handleRemoteChannelInactive(context.channel, key: key)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
