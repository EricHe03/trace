//
//  StreamReplayEngine.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/03.
//

import Foundation
import NIOCore
import NIOWebSocket
import TraceCore

struct ReplayWebSocketFrame {
    let frame: WebSocketFrame
    let delayBeforeSend: TimeAmount
}

final class StreamReplayEngine: @unchecked Sendable {
    static let shared = StreamReplayEngine(storage: .shared)

    private let storage: AppGroupStorage
    private let queue = DispatchQueue(
        label: "com.trace.proxy.stream.replay.engine",
        qos: .utility
    )

    init(storage: AppGroupStorage) {
        self.storage = storage
    }

    func beginReplay(
        _ spec: StreamReplaySpec,
        eventLoop: EventLoop
    ) -> EventLoopFuture<UUID> {
        let promise = eventLoop.makePromise(of: UUID.self)
        queue.async {
            do {
                let replayID = try self.storage.startStreamReplay(spec)
                promise.succeed(replayID)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    func finishReplay(
        _ result: StreamReplayResult,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        queue.async {
            do {
                try self.storage.completeStreamReplay(result)
                promise.succeed(())
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    func loadReplayEvents(
        _ spec: StreamReplaySpec,
        eventLoop: EventLoop
    ) -> EventLoopFuture<[StreamEvent]> {
        let promise = eventLoop.makePromise(of: [StreamEvent].self)
        queue.async {
            do {
                var events = try self.storage.loadStreamEvents(sessionID: spec.sessionID)
                if !spec.eventIDs.isEmpty {
                    let wanted = Set(spec.eventIDs)
                    events.removeAll { !wanted.contains($0.id) }
                }
                events.sort { lhs, rhs in
                    if lhs.sequence == rhs.sequence {
                        return lhs.timestamp < rhs.timestamp
                    }
                    return lhs.sequence < rhs.sequence
                }
                promise.succeed(events)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    func loadReplayWebSocketFrames(
        _ spec: StreamReplaySpec,
        direction: StreamEventDirection,
        allocator: ByteBufferAllocator,
        maskKey: WebSocketMaskingKey?,
        eventLoop: EventLoop
    ) -> EventLoopFuture<[ReplayWebSocketFrame]> {
        loadReplayEvents(spec, eventLoop: eventLoop).map { events in
            var frames: [ReplayWebSocketFrame] = []
            frames.reserveCapacity(events.count)
            var previousTimestamp: Date?

            for event in events {
                guard event.direction == direction else { continue }
                guard let opcode = Self.opcode(for: event) else { continue }

                let payload = event.payload.binary
                    ?? event.payload.text?.data(using: .utf8)
                    ?? Data()

                let wantsPerMessageDeflate = event.metadata["permessage_deflate"] == "true"
                let canPerMessageDeflate = opcode == .text || opcode == .binary
                var useRSV1 = wantsPerMessageDeflate && canPerMessageDeflate
                var wirePayload = payload
                if useRSV1, let encoded = WebSocketPerMessageDeflateCodec.encode(payload) {
                    wirePayload = encoded
                } else {
                    useRSV1 = false
                }

                var buffer = allocator.buffer(capacity: wirePayload.count)
                if !wirePayload.isEmpty {
                    buffer.writeBytes(wirePayload)
                }

                let frame = WebSocketFrame(
                    fin: true,
                    rsv1: useRSV1,
                    rsv2: false,
                    rsv3: false,
                    opcode: opcode,
                    maskKey: maskKey,
                    data: buffer
                )
                let delay = Self.replayDelay(
                    current: event.timestamp,
                    previous: previousTimestamp,
                    mode: spec.timingMode
                )
                previousTimestamp = event.timestamp
                frames.append(ReplayWebSocketFrame(frame: frame, delayBeforeSend: delay))
            }

            return frames
        }
    }

    func loadReplaySSEPayload(
        _ spec: StreamReplaySpec,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Data> {
        loadReplayEvents(spec, eventLoop: eventLoop).map { events in
            let sseEvents = events.compactMap { event -> ServerSentEvent? in
                guard event.kind == .sseEvent || event.kind == .message else { return nil }
                let data = event.payload.text
                    ?? event.payload.binary.flatMap { String(data: $0, encoding: .utf8) }
                    ?? ""
                guard !data.isEmpty else { return nil }

                return ServerSentEvent(
                    id: event.id,
                    eventId: event.metadata["event_id"],
                    eventType: event.metadata["event_type"],
                    data: data,
                    retry: Int(event.metadata["retry"] ?? ""),
                    timestamp: event.timestamp
                )
            }
            let payload = SSEPayloadSerializer.serialize(events: sseEvents)
            return Data(payload.utf8)
        }
    }

    private static func opcode(for event: StreamEvent) -> WebSocketOpcode? {
        if let raw = event.metadata["message_type"], let type = WebSocketMessageType(rawValue: raw) {
            return opcode(for: type)
        }

        switch event.kind {
        case .ping:
            return .ping
        case .pong:
            return .pong
        case .close:
            return .connectionClose
        case .message:
            if event.payload.text != nil {
                return .text
            }
            return .binary
        default:
            return nil
        }
    }

    private static func opcode(for messageType: WebSocketMessageType) -> WebSocketOpcode {
        switch messageType {
        case .continuation:
            .continuation
        case .text:
            .text
        case .binary:
            .binary
        case .close:
            .connectionClose
        case .ping:
            .ping
        case .pong:
            .pong
        }
    }

    private static func replayDelay(
        current: Date,
        previous: Date?,
        mode: StreamReplayTimingMode
    ) -> TimeAmount {
        guard mode == .originalTiming else {
            return .nanoseconds(0)
        }
        guard let previous else {
            return .nanoseconds(0)
        }

        let delta = max(0, current.timeIntervalSince(previous))
        let clamped = min(delta, 30)
        return .nanoseconds(Int64(clamped * 1_000_000_000))
    }
}
