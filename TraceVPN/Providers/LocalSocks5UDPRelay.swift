//
//  LocalSocks5UDPRelay.swift
//  TraceVPN
//

import Foundation
import NIOCore
import NIOTransportServices

final class Socks5UDPRelay: @unchecked Sendable {
    struct Endpoint: Sendable {
        let host: String
        let port: UInt16
        let addressType: Socks5AddressType
    }

    struct RemoteKey: Hashable {
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

    func activateClientChannel(_ channel: Channel) -> Bool {
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

    func handleClientChannelInactive(_ channel: Channel) {
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

    func handleClientDatagram(_ data: Data) {
        guard let datagram = parseUDPRequest(data) else {
            return
        }
        let key = RemoteKey(address: datagram.address, port: datagram.port)
        let state = remoteState(for: key, host: datagram.address.host, port: datagram.port)
        send(payload: datagram.payload, using: state)
    }

    func handleRemoteDatagram(_ payload: Data, from key: RemoteKey) {
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

    func handleRemoteChannelInactive(_ channel: Channel, key: RemoteKey) {
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
