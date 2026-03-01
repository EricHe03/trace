//
//  LocalSocks5RelayHandlers.swift
//  TraceVPN
//

import Foundation
import NIOCore

final class Socks5RemoteRelayHandler: ChannelInboundHandler, @unchecked Sendable {
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

final class Socks5UDPClientInboundHandler: ChannelInboundHandler, @unchecked Sendable {
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

final class Socks5UDPRemoteInboundHandler: ChannelInboundHandler, @unchecked Sendable {
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
