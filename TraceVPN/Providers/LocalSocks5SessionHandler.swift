//
//  LocalSocks5SessionHandler.swift
//  TraceVPN
//

import Darwin
import Foundation
import NIOCore
import NIOTransportServices
import TraceCore

final class Socks5SessionHandler: ChannelDuplexHandler, @unchecked Sendable {
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
                "greeting"
            case .request:
                "request"
            case .connecting:
                "connecting"
            case .udpAssociating:
                "udp_associating"
            case .relaying:
                "relaying"
            case .udpAssociated:
                "udp_associated"
            case .closing:
                "closing"
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
                case .commandNotSupported:
                    sendReply(.commandNotSupported, context: context)
                    closeConnection(context: context)
                    return
                case .addressTypeNotSupported:
                    sendReply(.addressTypeNotSupported, context: context)
                    closeConnection(context: context)
                    return
                case .generalFailure:
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

    private func parseRequest() -> Socks5RequestParseResult {
        guard buffer.readableBytes >= 4 else {
            return .needMoreData
        }

        guard let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self),
              let commandRaw = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
              let atypRaw = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self)
        else {
            return .generalFailure
        }

        guard version == 0x05 else {
            return .generalFailure
        }

        guard Socks5Command(rawValue: commandRaw) != nil else {
            // RFC 1928 §6 REP 0x07: Command not supported.
            _ = buffer.readSlice(length: buffer.readableBytes)
            return .commandNotSupported
        }

        guard let atyp = Socks5AddressType(rawValue: atypRaw) else {
            // RFC 1928 §6 REP 0x08: Address type not supported.
            _ = buffer.readSlice(length: buffer.readableBytes)
            return .addressTypeNotSupported
        }

        let command = Socks5Command(rawValue: commandRaw)!

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

    static func ipv4Bytes(from host: String) -> [UInt8]? {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &addr.s_addr) { Array($0) }
    }

    static func ipv6Bytes(from host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &addr.__u6_addr.__u6_addr8) { Array($0) }
    }

    static func ipv6String(from bytes: [UInt8]) -> String? {
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
