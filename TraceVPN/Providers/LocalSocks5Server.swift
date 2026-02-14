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
    private let bindHost: String
    private let eventLogHandler: (@Sendable (String, String) -> Void)?

    private var endpoint: Endpoint?
    private var listenerChannel: Channel?
    private var childChannels: [ObjectIdentifier: Channel] = [:]
    private var runtimeAcquired = false

    init(bindHost: String = "127.0.0.1", eventLogHandler: (@Sendable (String, String) -> Void)? = nil) {
        self.bindHost = bindHost
        self.eventLogHandler = eventLogHandler
    }

    func start(preferredPort: UInt16) throws -> Endpoint {
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

    func stop() {
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
                    eventLogHandler: self.eventLogHandler,
                    onSessionClosed: { [weak self, weak channel] in
                        guard let self, let channel else { return }
                        self.unregisterChild(channel)
                    }
                )

                channel.closeFuture.whenComplete { [weak self, weak channel] _ in
                    guard let self, let channel else { return }
                    self.unregisterChild(channel)
                }
                return channel.pipeline.addHandler(handler)
            }

        let channel: Channel
        if let port {
            channel = try bootstrap.bind(host: bindHost, port: Int(port)).wait()
        } else {
            channel = try bootstrap.bind(host: bindHost, port: 0).wait()
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
        case relaying
        case udpAssociated
        case closing
    }

    private let group: NIOTSEventLoopGroup
    private let eventLogHandler: (@Sendable (String, String) -> Void)?
    private let onSessionClosed: @Sendable () -> Void

    private let sessionID = UUID().uuidString
    private var state: State = .greeting
    private var buffer = ByteBuffer()
    private var remoteChannel: Channel?
    private var udpRelay: Socks5UDPRelay?

    init(
        group: NIOTSEventLoopGroup,
        eventLogHandler: (@Sendable (String, String) -> Void)?,
        onSessionClosed: @Sendable @escaping () -> Void
    ) {
        self.group = group
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
        case .udpAssociated:
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
        eventLogHandler?(
            "local_socks5_session",
            "outcome=failure session=\(sessionID) error=\(error.localizedDescription)"
        )
        closeConnection(context: context)
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
                case .value(let supportsNoAuth):
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
            case .connecting, .relaying, .udpAssociated, .closing:
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

        bootstrap.connect(host: request.address.host, port: Int(request.port)).whenComplete { [weak self] result in
            context.eventLoop.execute {
                guard let self else { return }
                guard self.state == .connecting else { return }

                switch result {
                case let .success(remoteChannel):
                    self.remoteChannel = remoteChannel
                    self.state = .relaying
                    self.sendReply(.succeeded, context: context)

                    if self.buffer.readableBytes > 0, let remaining = self.buffer.readSlice(length: self.buffer.readableBytes) {
                        remoteChannel.writeAndFlush(remaining, promise: nil)
                    }
                case .failure:
                    self.sendReply(.generalFailure, context: context)
                    self.closeConnection(context: context)
                }
            }
        }
    }

    private func handleUDPAssociate(request: Socks5Request, context: ChannelHandlerContext) {
        let preferredType: Socks5AddressType = request.address.type == .ipv6 ? .ipv6 : .ipv4
        let relay: Socks5UDPRelay
        let endpoint: Socks5UDPRelay.Endpoint

        do {
            let candidate = Socks5UDPRelay(
                group: group,
                bindAddressType: preferredType,
                eventLogHandler: eventLogHandler
            )
            endpoint = try candidate.start()
            relay = candidate
        } catch {
            guard preferredType == .ipv6 else {
                sendReply(.generalFailure, context: context)
                closeConnection(context: context)
                return
            }

            do {
                let fallback = Socks5UDPRelay(
                    group: group,
                    bindAddressType: .ipv4,
                    eventLogHandler: eventLogHandler
                )
                endpoint = try fallback.start()
                relay = fallback
            } catch {
                sendReply(.generalFailure, context: context)
                closeConnection(context: context)
                return
            }
        }

        udpRelay = relay
        state = .udpAssociated

        sendReply(
            .succeeded,
            bindAddress: Socks5Address(type: endpoint.addressType, host: endpoint.host),
            bindPort: endpoint.port,
            context: context
        )
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
           Self.sameChannel(current, channel)
        {
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
