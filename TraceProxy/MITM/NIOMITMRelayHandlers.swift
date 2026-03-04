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

final class NIOMITMHTTPClientResponseRelayHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
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

    private enum WebSocketProtocolValidationFailure {
        case protocolError(String)
        case invalidUTF8(String)
    }

    private struct FragmentAccumulator {
        var messageType: WebSocketMessageType
        var initialFrame: WebSocketFrame
        var frames: [WebSocketFrame]
        var wirePayload: Data
        var compressed: Bool
    }

    weak var peerChannel: Channel?
    let direction: WebSocketDirection
    let captureState: NIOMITMWebSocketCaptureState
    let streamRuntime: StreamSessionRuntime?
    let interceptDecisionProvider: (@Sendable (StreamSession, StreamEvent, EventLoop) -> EventLoopFuture<StreamInterceptionDecision>)?
    let closeNotifier: (@Sendable (StreamSessionStatus, String?, EventLoop) -> Void)?
    let replayEngine: StreamReplayEngine
    let perMessageDeflateEnabled: Bool
    let maxFragmentedPayloadBytes = 8 * 1024 * 1024
    var relayChain: EventLoopFuture<Void>?
    private var fragmentedAccumulator: FragmentAccumulator?

    init(
        peerChannel: Channel,
        direction: WebSocketDirection,
        captureState: NIOMITMWebSocketCaptureState,
        streamRuntime: StreamSessionRuntime? = nil,
        interceptDecisionProvider: (@Sendable (StreamSession, StreamEvent, EventLoop) -> EventLoopFuture<StreamInterceptionDecision>)? = nil,
        closeNotifier: (@Sendable (StreamSessionStatus, String?, EventLoop) -> Void)? = nil,
        replayEngine: StreamReplayEngine = .shared,
        perMessageDeflateEnabled: Bool = false
    ) {
        self.peerChannel = peerChannel
        self.direction = direction
        self.captureState = captureState
        self.streamRuntime = streamRuntime
        self.interceptDecisionProvider = interceptDecisionProvider
        self.closeNotifier = closeNotifier
        self.replayEngine = replayEngine
        self.perMessageDeflateEnabled = perMessageDeflateEnabled
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard let streamRuntime, let interceptDecisionProvider else {
            captureState.recordFrame(frame, direction: direction)
            forward(frame, context: context)
            return
        }

        let sequenceStart = relayChain ?? context.eventLoop.makeSucceededVoidFuture()
        relayChain = sequenceStart.flatMap { [weak self] in
            guard let self else {
                return context.eventLoop.makeSucceededVoidFuture()
            }
            return self.processFrameWithInterception(
                frame,
                runtime: streamRuntime,
                decisionProvider: interceptDecisionProvider,
                context: context
            )
        }
        relayChain?.whenFailure { [weak self] _ in
            self?.captureState.markFailed()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        captureState.markClosed(code: nil, reason: nil)
        closeNotifier?(.closed, nil, context.eventLoop)
        peerChannel?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        captureState.markFailed()
        closeNotifier?(.failed, error.localizedDescription, context.eventLoop)
        peerChannel?.close(promise: nil)
        context.close(promise: nil)
    }

    private func processFrameWithInterception(
        _ frame: WebSocketFrame,
        runtime: StreamSessionRuntime,
        decisionProvider: @escaping @Sendable (StreamSession, StreamEvent, EventLoop) -> EventLoopFuture<StreamInterceptionDecision>,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        if fragmentedAccumulator != nil {
            return processFrameWhileFragmenting(
                frame,
                runtime: runtime,
                decisionProvider: decisionProvider,
                context: context
            )
        }

        guard let messageType = websocketMessageType(for: frame.opcode) else {
            captureState.recordFrame(frame, direction: direction)
            forward(frame, context: context)
            return context.eventLoop.makeSucceededVoidFuture()
        }

        if let failure = validateProtocolFrame(
            frame: frame,
            messageType: messageType,
            hasActiveFragments: false
        ) {
            return handleValidationFailure(
                failure,
                frame: frame,
                messageType: messageType,
                payload: payloadData(from: frame),
                context: context
            )
        }

        if messageType == .text || messageType == .binary, !frame.fin {
            let wirePayload = payloadData(from: frame)
            guard wirePayload.count <= maxFragmentedPayloadBytes else {
                closeOnProtocolError(
                    maskKey: direction == .sent ? frame.maskKey : nil,
                    reason: "fragment_payload_too_large",
                    context: context
                )
                return context.eventLoop.makeSucceededVoidFuture()
            }
            fragmentedAccumulator = FragmentAccumulator(
                messageType: messageType,
                initialFrame: frame,
                frames: [frame],
                wirePayload: wirePayload,
                compressed: perMessageDeflateEnabled && frame.rsv1
            )
            return context.eventLoop.makeSucceededVoidFuture()
        }

        return processInterceptableFrame(
            frame,
            runtime: runtime,
            decisionProvider: decisionProvider,
            context: context
        )
    }

    private func processFrameWhileFragmenting(
        _ frame: WebSocketFrame,
        runtime: StreamSessionRuntime,
        decisionProvider: @escaping @Sendable (StreamSession, StreamEvent, EventLoop) -> EventLoopFuture<StreamInterceptionDecision>,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        guard var accumulator = fragmentedAccumulator else {
            return context.eventLoop.makeSucceededVoidFuture()
        }

        guard let messageType = websocketMessageType(for: frame.opcode) else {
            captureState.recordFrame(frame, direction: direction)
            forward(frame, context: context)
            return context.eventLoop.makeSucceededVoidFuture()
        }

        if let failure = validateProtocolFrame(
            frame: frame,
            messageType: messageType,
            hasActiveFragments: true
        ) {
            return handleValidationFailure(
                failure,
                frame: frame,
                messageType: messageType,
                payload: payloadData(from: frame),
                context: context
            )
        }

        if isControlMessageType(messageType) {
            return processInterceptableFrame(
                frame,
                runtime: runtime,
                decisionProvider: decisionProvider,
                context: context
            )
        }

        guard messageType == .continuation else {
            fragmentedAccumulator = nil
            closeOnProtocolError(
                maskKey: direction == .sent ? accumulator.initialFrame.maskKey : nil,
                reason: "unexpected_fragment_opcode",
                context: context
            )
            return context.eventLoop.makeSucceededVoidFuture()
        }

        let chunk = payloadData(from: frame)
        if accumulator.wirePayload.count + chunk.count > maxFragmentedPayloadBytes {
            fragmentedAccumulator = nil
            closeOnProtocolError(
                maskKey: direction == .sent ? accumulator.initialFrame.maskKey : nil,
                reason: "fragment_payload_too_large",
                context: context
            )
            return context.eventLoop.makeSucceededVoidFuture()
        }

        accumulator.frames.append(frame)
        accumulator.wirePayload.append(chunk)
        fragmentedAccumulator = frame.fin ? nil : accumulator
        guard frame.fin else {
            return context.eventLoop.makeSucceededVoidFuture()
        }

        let decodedPayload = decodePayloadIfNeeded(
            accumulator.wirePayload,
            compressed: accumulator.compressed,
            type: accumulator.messageType
        )
        let textPayload = accumulator.messageType == .text ? String(data: decodedPayload, encoding: .utf8) : nil
        if accumulator.messageType == .text, textPayload == nil {
            captureState.recordMessage(
                type: .text,
                payload: accumulator.wirePayload,
                isFinal: true,
                isMasked: accumulator.initialFrame.maskKey != nil,
                direction: direction,
                wasModified: false,
                wasBlocked: true,
                metadata: ["error": "invalid_utf8_fragmented"]
            )
            closeOnInvalidUTF8(frame: accumulator.initialFrame, context: context)
            return context.eventLoop.makeSucceededVoidFuture()
        }

        let streamDirection: StreamEventDirection = direction == .sent ? .sent : .received
        let streamEvent = runtime.makeEvent(
            direction: streamDirection,
            kind: streamEventKind(for: accumulator.messageType),
            payload: StreamEventPayload(
                text: textPayload,
                binary: decodedPayload,
                contentType: accumulator.messageType == .text ? "text/plain; charset=utf-8" : "application/octet-stream",
                encoding: accumulator.messageType == .text ? "utf-8" : nil
            ),
            metadata: [
                "message_type": accumulator.messageType.rawValue,
                "is_final": "true",
                "is_masked": accumulator.initialFrame.maskKey != nil ? "true" : "false",
                "payload_length": String(decodedPayload.count),
                "permessage_deflate": accumulator.compressed ? "true" : "false",
                "is_fragmented": "true",
                "fragment_count": String(accumulator.frames.count)
            ]
        )

        return decisionProvider(runtime.snapshot(), streamEvent, context.eventLoop)
            .flatMap { [weak self] decision in
                guard let self else {
                    return context.eventLoop.makeSucceededVoidFuture()
                }
                return self.applyDecisionToFragmentedMessage(
                    decision,
                    accumulator: accumulator,
                    decodedPayload: decodedPayload,
                    streamEvent: streamEvent,
                    context: context
                )
            }
    }

    private func processInterceptableFrame(
        _ frame: WebSocketFrame,
        runtime: StreamSessionRuntime,
        decisionProvider: @escaping @Sendable (StreamSession, StreamEvent, EventLoop) -> EventLoopFuture<StreamInterceptionDecision>,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        guard let messageType = websocketMessageType(for: frame.opcode) else {
            captureState.recordFrame(frame, direction: direction)
            forward(frame, context: context)
            return context.eventLoop.makeSucceededVoidFuture()
        }

        let rawPayload = payloadData(from: frame)
        if let failure = validateProtocolFrame(
            frame: frame,
            messageType: messageType,
            hasActiveFragments: fragmentedAccumulator != nil,
            payload: rawPayload
        ) {
            return handleValidationFailure(
                failure,
                frame: frame,
                messageType: messageType,
                payload: rawPayload,
                context: context
            )
        }
        let decodedPayload = decodePayloadIfNeeded(rawPayload, frame: frame, type: messageType)
        let textPayload = messageType == .text ? String(data: decodedPayload, encoding: .utf8) : nil
        if messageType == .text, textPayload == nil {
            captureState.recordMessage(
                type: .text,
                payload: rawPayload,
                isFinal: frame.fin,
                isMasked: frame.maskKey != nil,
                direction: direction,
                wasModified: false,
                wasBlocked: true,
                metadata: ["error": "invalid_utf8"]
            )
            closeOnInvalidUTF8(frame: frame, context: context)
            return context.eventLoop.makeSucceededVoidFuture()
        }

        let streamDirection: StreamEventDirection = direction == .sent ? .sent : .received
        let streamEvent = runtime.makeEvent(
            direction: streamDirection,
            kind: streamEventKind(for: messageType),
            payload: StreamEventPayload(
                text: textPayload,
                binary: decodedPayload,
                contentType: messageType == .text ? "text/plain; charset=utf-8" : "application/octet-stream",
                encoding: messageType == .text ? "utf-8" : nil
            ),
            metadata: [
                "message_type": messageType.rawValue,
                "is_final": frame.fin ? "true" : "false",
                "is_masked": frame.maskKey != nil ? "true" : "false",
                "payload_length": String(decodedPayload.count),
                "permessage_deflate": frame.rsv1 ? "true" : "false"
            ]
        )

        return decisionProvider(runtime.snapshot(), streamEvent, context.eventLoop)
            .flatMap { [weak self] decision in
                guard let self else {
                    return context.eventLoop.makeSucceededVoidFuture()
                }
                return self.applyDecision(
                    decision,
                    originalFrame: frame,
                    messageType: messageType,
                    decodedPayload: decodedPayload,
                    streamEvent: streamEvent,
                    context: context
                )
            }
    }

    private func applyDecision(
        _ decision: StreamInterceptionDecision,
        originalFrame: WebSocketFrame,
        messageType: WebSocketMessageType,
        decodedPayload: Data,
        streamEvent: StreamEvent,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        switch decision {
        case .forward:
            captureState.recordFrame(originalFrame, direction: direction)
            forward(originalFrame, context: context)
            return context.eventLoop.makeSucceededVoidFuture()

        case let .modify(mutation):
            let modifiedPayload = mutation.payload?.binary
                ?? mutation.payload?.text?.data(using: .utf8)
                ?? decodedPayload
            let wirePayload = encodePayloadIfNeeded(
                modifiedPayload,
                originalFrame: originalFrame,
                messageType: messageType
            ) ?? payloadData(from: originalFrame)
            let modifiedFrame = makeFrame(
                basedOn: originalFrame,
                payload: wirePayload,
                messageType: messageType,
                preserveCompressionFlag: originalFrame.rsv1 && perMessageDeflateEnabled
            )
            captureState.recordMessage(
                type: messageType,
                payload: modifiedPayload,
                isFinal: modifiedFrame.fin,
                isMasked: modifiedFrame.maskKey != nil,
                direction: direction,
                wasModified: true,
                wasBlocked: false,
                metadata: mutation.metadata
            )
            forward(modifiedFrame, context: context)
            return context.eventLoop.makeSucceededVoidFuture()

        case .block, .drop:
            captureState.recordMessage(
                type: messageType,
                payload: decodedPayload,
                isFinal: originalFrame.fin,
                isMasked: originalFrame.maskKey != nil,
                direction: direction,
                wasModified: false,
                wasBlocked: true
            )
            return context.eventLoop.makeSucceededVoidFuture()

        case let .inject(mutations):
            captureState.recordFrame(originalFrame, direction: direction)
            let baseFuture = forwardFuture(originalFrame, context: context)
            return mutations.reduce(baseFuture) { partial, mutation in
                partial.flatMap {
                    let injectedType: WebSocketMessageType = mutation.payload?.text != nil ? .text : .binary
                    let injectedPayload = mutation.payload?.binary
                        ?? mutation.payload?.text?.data(using: .utf8)
                        ?? Data()
                    let wirePayload = self.encodePayloadIfNeeded(
                        injectedPayload,
                        originalFrame: originalFrame,
                        messageType: injectedType
                    ) ?? injectedPayload
                    let injectedFrame = self.makeFrame(
                        basedOn: originalFrame,
                        payload: wirePayload,
                        messageType: injectedType,
                        preserveCompressionFlag: originalFrame.rsv1 && self.perMessageDeflateEnabled
                    )
                    self.captureState.recordMessage(
                        type: injectedType,
                        payload: injectedPayload,
                        isFinal: true,
                        isMasked: injectedFrame.maskKey != nil,
                        direction: self.direction,
                        wasModified: true,
                        wasBlocked: false,
                        metadata: mutation.metadata.merging(["injected": "true"]) { _, new in new }
                    )
                    return self.forwardFuture(injectedFrame, context: context)
                }
            }

        case let .replay(spec):
            captureState.recordFrame(originalFrame, direction: direction)
            let baseFuture = forwardFuture(originalFrame, context: context)
            let maskKey = direction == .sent ? originalFrame.maskKey : nil
            return applyReplayDecision(
                spec: spec,
                streamDirection: streamEvent.direction,
                baseFuture: baseFuture,
                maskKey: maskKey,
                context: context
            )
        }
    }

    private func applyDecisionToFragmentedMessage(
        _ decision: StreamInterceptionDecision,
        accumulator: FragmentAccumulator,
        decodedPayload: Data,
        streamEvent: StreamEvent,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        switch decision {
        case .forward:
            return forwardOriginalFramesFuture(accumulator.frames, context: context)

        case let .modify(mutation):
            let modifiedPayload = mutation.payload?.binary
                ?? mutation.payload?.text?.data(using: .utf8)
                ?? decodedPayload
            let wirePayload = encodePayloadIfNeeded(
                modifiedPayload,
                compressed: accumulator.compressed,
                messageType: accumulator.messageType
            ) ?? accumulator.wirePayload
            let modifiedFrame = makeFrame(
                basedOn: accumulator.initialFrame,
                payload: wirePayload,
                messageType: accumulator.messageType,
                preserveCompressionFlag: accumulator.compressed
            )
            captureState.recordMessage(
                type: accumulator.messageType,
                payload: modifiedPayload,
                isFinal: true,
                isMasked: modifiedFrame.maskKey != nil,
                direction: direction,
                wasModified: true,
                wasBlocked: false,
                metadata: mutation.metadata.merging([
                    "is_fragmented": "true",
                    "fragment_count": String(accumulator.frames.count)
                ]) { _, new in new }
            )
            return forwardFuture(modifiedFrame, context: context)

        case .block, .drop:
            captureState.recordMessage(
                type: accumulator.messageType,
                payload: decodedPayload,
                isFinal: true,
                isMasked: accumulator.initialFrame.maskKey != nil,
                direction: direction,
                wasModified: false,
                wasBlocked: true,
                metadata: [
                    "is_fragmented": "true",
                    "fragment_count": String(accumulator.frames.count)
                ]
            )
            return context.eventLoop.makeSucceededVoidFuture()

        case let .inject(mutations):
            let baseFuture = forwardOriginalFramesFuture(accumulator.frames, context: context)
            return mutations.reduce(baseFuture) { partial, mutation in
                partial.flatMap {
                    let injectedType: WebSocketMessageType = mutation.payload?.text != nil ? .text : .binary
                    let injectedPayload = mutation.payload?.binary
                        ?? mutation.payload?.text?.data(using: .utf8)
                        ?? Data()
                    let wirePayload = self.encodePayloadIfNeeded(
                        injectedPayload,
                        compressed: false,
                        messageType: injectedType
                    ) ?? injectedPayload
                    let injectedFrame = self.makeFrame(
                        basedOn: accumulator.initialFrame,
                        payload: wirePayload,
                        messageType: injectedType,
                        preserveCompressionFlag: false
                    )
                    self.captureState.recordMessage(
                        type: injectedType,
                        payload: injectedPayload,
                        isFinal: true,
                        isMasked: injectedFrame.maskKey != nil,
                        direction: self.direction,
                        wasModified: true,
                        wasBlocked: false,
                        metadata: mutation.metadata.merging([
                            "injected": "true",
                            "is_fragmented": "true"
                        ]) { _, new in new }
                    )
                    return self.forwardFuture(injectedFrame, context: context)
                }
            }

        case let .replay(spec):
            let baseFuture = forwardOriginalFramesFuture(accumulator.frames, context: context)
            let maskKey = direction == .sent ? accumulator.initialFrame.maskKey : nil
            return applyReplayDecision(
                spec: spec,
                streamDirection: streamEvent.direction,
                baseFuture: baseFuture,
                maskKey: maskKey,
                context: context
            )
        }
    }

    private func forwardOriginalFramesFuture(
        _ frames: [WebSocketFrame],
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        frames.reduce(context.eventLoop.makeSucceededVoidFuture()) { partial, frame in
            partial.flatMap {
                self.captureState.recordFrame(frame, direction: self.direction)
                return self.forwardFuture(frame, context: context)
            }
        }
    }

    private func applyReplayDecision(
        spec: StreamReplaySpec,
        streamDirection: StreamEventDirection,
        baseFuture: EventLoopFuture<Void>,
        maskKey: WebSocketMaskingKey?,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        replayEngine.beginReplay(spec, eventLoop: context.eventLoop)
            .flatMap { replayID in
                self.replayEngine.loadReplayWebSocketFrames(
                    spec,
                    direction: streamDirection,
                    allocator: context.channel.allocator,
                    maskKey: maskKey,
                    eventLoop: context.eventLoop
                ).flatMap { replayFrames in
                    replayFrames.reduce(baseFuture) { partial, replayFrame in
                        partial.flatMap {
                            self.forwardReplayFrame(replayFrame, context: context)
                        }
                    }.flatMap {
                        self.replayEngine.finishReplay(
                            StreamReplayResult(
                                replayID: replayID,
                                sessionID: spec.sessionID,
                                succeeded: true,
                                replayedEvents: replayFrames.count,
                                startedAt: spec.startedAt,
                                endedAt: Date()
                            ),
                            eventLoop: context.eventLoop
                        )
                    }.flatMapError { error in
                        self.replayEngine.finishReplay(
                            StreamReplayResult(
                                replayID: replayID,
                                sessionID: spec.sessionID,
                                succeeded: false,
                                replayedEvents: 0,
                                startedAt: spec.startedAt,
                                endedAt: Date(),
                                errorMessage: error.localizedDescription
                            ),
                            eventLoop: context.eventLoop
                        ).flatMap { context.eventLoop.makeFailedFuture(error) }
                    }
                }
            }
    }

    private func forwardReplayFrame(
        _ replayFrame: ReplayWebSocketFrame,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        let send: () -> EventLoopFuture<Void> = {
            self.captureState.recordFrame(replayFrame.frame, direction: self.direction)
            return self.forwardFuture(replayFrame.frame, context: context)
        }

        if replayFrame.delayBeforeSend.nanoseconds <= 0 {
            return send()
        }

        return context.eventLoop
            .scheduleTask(in: replayFrame.delayBeforeSend) {}
            .futureResult
            .flatMap { send() }
    }

    private func forward(_ frame: WebSocketFrame, context: ChannelHandlerContext) {
        _ = forwardFuture(frame, context: context)
    }

    private func forwardFuture(_ frame: WebSocketFrame, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        guard let peerChannel, peerChannel.isActive else {
            context.close(promise: nil)
            return context.eventLoop.makeSucceededVoidFuture()
        }
        let promise = peerChannel.eventLoop.makePromise(of: Void.self)
        peerChannel.writeAndFlush(frame, promise: promise)
        return promise.futureResult.hop(to: context.eventLoop)
    }

    private func payloadData(from frame: WebSocketFrame) -> Data {
        var unmasked = frame.unmaskedData
        return unmasked.readData(length: unmasked.readableBytes) ?? Data()
    }

    private func decodePayloadIfNeeded(_ payload: Data, frame: WebSocketFrame, type: WebSocketMessageType) -> Data {
        decodePayloadIfNeeded(
            payload,
            compressed: perMessageDeflateEnabled && frame.rsv1,
            type: type
        )
    }

    private func decodePayloadIfNeeded(
        _ payload: Data,
        compressed: Bool,
        type: WebSocketMessageType
    ) -> Data {
        guard compressed, type == .text || type == .binary else {
            return payload
        }
        return WebSocketPerMessageDeflateCodec.decode(payload) ?? payload
    }

    private func encodePayloadIfNeeded(
        _ payload: Data,
        originalFrame: WebSocketFrame,
        messageType: WebSocketMessageType
    ) -> Data? {
        encodePayloadIfNeeded(
            payload,
            compressed: perMessageDeflateEnabled && originalFrame.rsv1,
            messageType: messageType
        )
    }

    private func encodePayloadIfNeeded(
        _ payload: Data,
        compressed: Bool,
        messageType: WebSocketMessageType
    ) -> Data? {
        guard compressed, messageType == .text || messageType == .binary else {
            return payload
        }
        return WebSocketPerMessageDeflateCodec.encode(payload)
    }

    private func makeFrame(
        basedOn originalFrame: WebSocketFrame,
        payload: Data,
        messageType: WebSocketMessageType,
        preserveCompressionFlag: Bool
    ) -> WebSocketFrame {
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        if !payload.isEmpty {
            buffer.writeBytes(payload)
        }
        return WebSocketFrame(
            fin: true,
            rsv1: preserveCompressionFlag,
            rsv2: false,
            rsv3: false,
            opcode: websocketOpcode(for: messageType),
            maskKey: originalFrame.maskKey,
            data: buffer
        )
    }

    private func streamEventKind(for messageType: WebSocketMessageType) -> StreamEventKind {
        switch messageType {
        case .ping:
            .ping
        case .pong:
            .pong
        case .close:
            .close
        case .text, .binary, .continuation:
            .message
        }
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

    private func websocketOpcode(for messageType: WebSocketMessageType) -> WebSocketOpcode {
        switch messageType {
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
        case .close:
            .connectionClose
        }
    }

    private func isControlMessageType(_ type: WebSocketMessageType) -> Bool {
        switch type {
        case .ping, .pong, .close:
            true
        case .text, .binary, .continuation:
            false
        }
    }

    private func validateProtocolFrame(
        frame: WebSocketFrame,
        messageType: WebSocketMessageType,
        hasActiveFragments: Bool,
        payload: Data? = nil
    ) -> WebSocketProtocolValidationFailure? {
        if frame.rsv2 || frame.rsv3 {
            return .protocolError("unexpected_rsv_bits")
        }

        if messageType == .continuation, !hasActiveFragments {
            return .protocolError("unexpected_continuation_frame")
        }

        if messageType == .continuation, frame.rsv1 {
            return .protocolError("continuation_frame_rsv1_set")
        }

        if isControlMessageType(messageType), frame.rsv1 {
            return .protocolError("control_frame_rsv1_set")
        }

        if messageType == .text || messageType == .binary,
           frame.rsv1,
           !perMessageDeflateEnabled {
            return .protocolError("unexpected_rsv1_without_extension")
        }

        guard isControlMessageType(messageType) else {
            return nil
        }

        if !frame.fin {
            return .protocolError("fragmented_control_frame")
        }

        let framePayload = payload ?? payloadData(from: frame)
        if framePayload.count > 125 {
            return .protocolError("control_frame_too_large")
        }

        guard messageType == .close else {
            return nil
        }

        if framePayload.count == 1 {
            return .protocolError("invalid_close_payload_length")
        }

        if framePayload.count >= 2 {
            let code = (UInt16(framePayload[0]) << 8) | UInt16(framePayload[1])
            if !isValidCloseCode(code) {
                return .protocolError("invalid_close_code")
            }
            if framePayload.count > 2,
               String(data: framePayload.subdata(in: 2 ..< framePayload.count), encoding: .utf8) == nil {
                return .invalidUTF8("invalid_close_reason_utf8")
            }
        }

        return nil
    }

    private func handleValidationFailure(
        _ failure: WebSocketProtocolValidationFailure,
        frame: WebSocketFrame,
        messageType: WebSocketMessageType,
        payload: Data,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        switch failure {
        case let .protocolError(reason):
            closeOnProtocolError(
                maskKey: direction == .sent ? frame.maskKey : nil,
                reason: reason,
                context: context
            )
        case let .invalidUTF8(reason):
            captureState.recordMessage(
                type: messageType,
                payload: payload,
                isFinal: frame.fin,
                isMasked: frame.maskKey != nil,
                direction: direction,
                wasModified: false,
                wasBlocked: true,
                metadata: ["error": reason]
            )
            closeOnInvalidUTF8(frame: frame, context: context)
        }

        return context.eventLoop.makeSucceededVoidFuture()
    }

    private func isValidCloseCode(_ code: UInt16) -> Bool {
        switch code {
        case 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014:
            true
        case 3000 ... 4999:
            true
        default:
            false
        }
    }

    private func closeOnInvalidUTF8(frame: WebSocketFrame, context: ChannelHandlerContext) {
        var payload = context.channel.allocator.buffer(capacity: 2)
        payload.writeInteger(UInt16(1007).bigEndian)
        let closeFrame = WebSocketFrame(
            fin: true,
            opcode: .connectionClose,
            maskKey: direction == .sent ? frame.maskKey : nil,
            data: payload
        )
        forward(closeFrame, context: context)
        closeNotifier?(.failed, "invalid_utf8", context.eventLoop)
    }

    private func closeOnProtocolError(
        maskKey: WebSocketMaskingKey?,
        reason: String,
        context: ChannelHandlerContext
    ) {
        var payload = context.channel.allocator.buffer(capacity: 2)
        payload.writeInteger(UInt16(1002).bigEndian)
        let closeFrame = WebSocketFrame(
            fin: true,
            opcode: .connectionClose,
            maskKey: maskKey,
            data: payload
        )
        captureState.recordMessage(
            type: .close,
            payload: Data([0x03, 0xEA]),
            isFinal: true,
            isMasked: maskKey != nil,
            direction: direction,
            wasModified: false,
            wasBlocked: true,
            metadata: ["error": reason]
        )
        forward(closeFrame, context: context)
        closeNotifier?(.failed, reason, context.eventLoop)
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
