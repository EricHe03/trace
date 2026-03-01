//
//  NIOMITMRelayHandlers.swift
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
import NIOWebSocket
import TraceCore

final class NIOMITMHTTPClientResponseRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    let onPart: @Sendable (HTTPClientResponsePart) -> Void
    let onError: @Sendable (Error) -> Void
    let onInactive: @Sendable () -> Void

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

final class NIOMITMHTTPStreamingResponseDelegate: HTTPClientResponseDelegate, @unchecked Sendable {
    typealias Response = Void

    let onHead: @Sendable (HTTPResponseHead) -> EventLoopFuture<Void>
    let onBodyPart: @Sendable (ByteBuffer) -> EventLoopFuture<Void>
    let onFinish: @Sendable () throws -> Void
    let onError: @Sendable (Error) -> Void

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

final class NIOMITMWebSocketRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    weak var peerChannel: Channel?
    let direction: WebSocketDirection
    let captureState: NIOMITMWebSocketCaptureState

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

final class NIOMITMHTTP2MetricsHandler: ChannelInboundHandler, @unchecked Sendable {
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

final class NIOMITMTLSHandshakeObserver: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    var handshakePromise: EventLoopPromise<String?>?

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

final class NIOMITMRawRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let linkID = UUID().uuidString
    weak var peerChannel: Channel?

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
