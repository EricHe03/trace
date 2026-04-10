//
//  SSEInterceptionRuntime.swift
//  TraceProxy
//
//  Created by Justin on 2026/03/03.
//

import Foundation
import NIOCore
import TraceCore

final class SSEInterceptionRuntime: @unchecked Sendable {
    private struct InterceptionContext {
        let runtime: StreamSessionRuntime
        let streamEvent: StreamEvent
        let baseEvent: ServerSentEvent
        let eventRecorder: @Sendable (StreamEvent) -> Void
    }

    private let lock = NSLock()
    private var parser = SSEParser()
    private var utf8Remainder = Data()

    func interceptChunk(
        _ chunk: Data,
        runtime: StreamSessionRuntime,
        decisionProvider: @escaping @Sendable (StreamSession, StreamEvent, EventLoop) -> EventLoopFuture<StreamInterceptionDecision>,
        eventRecorder: @escaping @Sendable (StreamEvent) -> Void,
        replayEngine: StreamReplayEngine,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Data> {
        guard !chunk.isEmpty else {
            return eventLoop.makeSucceededFuture(chunk)
        }

        let decodedResult = decodeUTF8Chunk(chunk)
        let decoded = decodedResult.decoded
        let forwardBytes = decodedResult.forwardBytes
        guard let decoded, !decoded.isEmpty else {
            return eventLoop.makeSucceededFuture(forwardBytes)
        }

        let parsed = parseEventsAndRemainder(decoded)
        let events = parsed.events
        guard !events.isEmpty else {
            return eventLoop.makeSucceededFuture(forwardBytes)
        }

        var chain = eventLoop.makeSucceededFuture((payload: "", changed: false))

        for event in events {
            chain = chain.flatMap { state in
                let streamEvent = runtime.makeEvent(
                    direction: .received,
                    kind: .sseEvent,
                    payload: .text(event.data, contentType: "text/event-stream; charset=utf-8"),
                    metadata: [
                        "event_id": event.eventId ?? "",
                        "event_type": event.eventType ?? "",
                        "retry": event.retry.map(String.init) ?? ""
                    ]
                )

                return decisionProvider(runtime.snapshot(), streamEvent, eventLoop)
                    .flatMap { decision in
                        self.applyDecision(
                            decision,
                            context: InterceptionContext(
                                runtime: runtime,
                                streamEvent: streamEvent,
                                baseEvent: event,
                                eventRecorder: eventRecorder
                            ),
                            state: state,
                            replayEngine: replayEngine,
                            eventLoop: eventLoop
                        )
                    }
            }
        }

        return chain.map { state in
            if state.changed {
                var output = Data(state.payload.utf8)
                if !parsed.remainder.isEmpty {
                    output.append(Data(parsed.remainder.utf8))
                }
                return output
            }
            return forwardBytes
        }
    }

    private func applyDecision(
        _ decision: StreamInterceptionDecision,
        context: InterceptionContext,
        state: (payload: String, changed: Bool),
        replayEngine: StreamReplayEngine,
        eventLoop: EventLoop
    ) -> EventLoopFuture<(payload: String, changed: Bool)> {
        switch decision {
        case .forward:
            context.eventRecorder(context.streamEvent)
            let payload = state.payload + SSEPayloadSerializer.serialize(events: [context.baseEvent])
            return eventLoop.makeSucceededFuture((payload, state.changed))

        case let .modify(mutation):
            var patched = context.baseEvent
            if let text = mutation.payload?.text {
                patched.data = text
            } else if let binary = mutation.payload?.binary,
                      let decoded = String(data: binary, encoding: .utf8) {
                patched.data = decoded
            }
            if let eventID = mutation.metadata["event_id"], !eventID.isEmpty {
                patched.eventId = eventID
            }
            if let eventType = mutation.metadata["event_type"], !eventType.isEmpty {
                patched.eventType = eventType
            }
            if let retry = mutation.metadata["retry"], let parsed = Int(retry) {
                patched.retry = parsed
            }
            var recordedEvent = context.streamEvent
            recordedEvent.payload = .text(
                patched.data,
                contentType: mutation.payload?.contentType ?? context.streamEvent.payload.contentType
            )
            recordedEvent.wasModified = true
            recordedEvent.metadata = context.streamEvent.metadata.merging(mutation.metadata) { _, new in new }
            recordedEvent.metadata["event_id"] = patched.eventId ?? ""
            recordedEvent.metadata["event_type"] = patched.eventType ?? ""
            recordedEvent.metadata["retry"] = patched.retry.map(String.init) ?? ""
            context.eventRecorder(recordedEvent)
            let payload = state.payload + SSEPayloadSerializer.serialize(events: [patched])
            return eventLoop.makeSucceededFuture((payload, true))

        case .block, .drop:
            var recordedEvent = context.streamEvent
            recordedEvent.wasBlocked = true
            context.eventRecorder(recordedEvent)
            return eventLoop.makeSucceededFuture((state.payload, true))

        case let .inject(mutations):
            context.eventRecorder(context.streamEvent)
            var serialized = state.payload + SSEPayloadSerializer.serialize(events: [context.baseEvent])
            for mutation in mutations {
                let data = mutation.payload?.text
                    ?? mutation.payload?.binary.flatMap { String(data: $0, encoding: .utf8) }
                    ?? ""
                let injectedEvent = ServerSentEvent(
                    eventId: mutation.metadata["event_id"],
                    eventType: mutation.metadata["event_type"] ?? "injected",
                    data: data,
                    retry: mutation.metadata["retry"].flatMap(Int.init)
                )
                let recordedEvent = context.runtime.makeEvent(
                    direction: .received,
                    kind: .sseEvent,
                    payload: .text(
                        injectedEvent.data,
                        contentType: mutation.payload?.contentType ?? "text/event-stream; charset=utf-8"
                    ),
                    wasModified: true,
                    metadata: [
                        "event_id": injectedEvent.eventId ?? "",
                        "event_type": injectedEvent.eventType ?? "",
                        "retry": injectedEvent.retry.map(String.init) ?? "",
                        "injected": "true"
                    ].merging(mutation.metadata) { _, new in new }
                )
                context.eventRecorder(recordedEvent)
                serialized += SSEPayloadSerializer.serialize(events: [injectedEvent])
            }
            return eventLoop.makeSucceededFuture((serialized, true))

        case let .replay(spec):
            context.eventRecorder(context.streamEvent)
            return replayEngine.beginReplay(spec, eventLoop: eventLoop)
                .flatMap { replayID in
                    replayEngine.loadReplaySSEPayload(spec, eventLoop: eventLoop)
                        .flatMap { payloadData in
                            let replayPayload = String(data: payloadData, encoding: .utf8) ?? ""
                            let replayedEvents = if replayPayload.isEmpty {
                                0
                            } else {
                                replayPayload
                                    .components(separatedBy: "\n\n")
                                    .count { !$0.isEmpty }
                            }
                            return replayEngine.finishReplay(
                                StreamReplayResult(
                                    replayID: replayID,
                                    sessionID: spec.sessionID,
                                    succeeded: true,
                                    replayedEvents: replayedEvents,
                                    startedAt: spec.startedAt,
                                    endedAt: Date()
                                ),
                                eventLoop: eventLoop
                            ).map {
                                let parser = SSEParser()
                                let replayEvents = parser.parse(replayPayload)
                                for replayEvent in replayEvents {
                                    let recordedEvent = context.runtime.makeEvent(
                                        direction: .received,
                                        kind: .sseEvent,
                                        payload: .text(
                                            replayEvent.data,
                                            contentType: "text/event-stream; charset=utf-8"
                                        ),
                                        wasModified: true,
                                        metadata: [
                                            "event_id": replayEvent.eventId ?? "",
                                            "event_type": replayEvent.eventType ?? "",
                                            "retry": replayEvent.retry.map(String.init) ?? "",
                                            "replay": "true"
                                        ]
                                    )
                                    context.eventRecorder(recordedEvent)
                                }
                                let serialized = state.payload
                                    + SSEPayloadSerializer.serialize(events: [context.baseEvent])
                                    + replayPayload
                                return (serialized, true)
                            }
                        }
                        .flatMapError { error in
                            replayEngine.finishReplay(
                                StreamReplayResult(
                                    replayID: replayID,
                                    sessionID: spec.sessionID,
                                    succeeded: false,
                                    replayedEvents: 0,
                                    startedAt: spec.startedAt,
                                    endedAt: Date(),
                                    errorMessage: error.localizedDescription
                                ),
                                eventLoop: eventLoop
                            ).map {
                                let serialized = state.payload + SSEPayloadSerializer.serialize(events: [context.baseEvent])
                                return (serialized, true)
                            }
                        }
                }
        }
    }

    private func decodeUTF8Chunk(_ chunk: Data) -> (decoded: String?, forwardBytes: Data) {
        lock.lock()
        defer { lock.unlock() }

        let combined = utf8Remainder + chunk
        if let decoded = String(data: combined, encoding: .utf8) {
            utf8Remainder.removeAll(keepingCapacity: false)
            return (decoded, combined)
        }

        var splitIndex = combined.count
        var decodedString: String?
        let maxTail = min(3, combined.count)
        for drop in 1 ... maxTail {
            let endIndex = combined.count - drop
            guard endIndex > 0 else { break }
            if let candidate = String(data: combined.subdata(in: 0 ..< endIndex), encoding: .utf8) {
                decodedString = candidate
                splitIndex = endIndex
                break
            }
        }

        guard let decodedString else {
            parser.reset()
            utf8Remainder.removeAll(keepingCapacity: false)
            return (nil, combined)
        }

        let forwardBytes = combined.subdata(in: 0 ..< splitIndex)
        utf8Remainder = combined.subdata(in: splitIndex ..< combined.count)
        return (decodedString, forwardBytes)
    }

    private func parseEventsAndRemainder(_ text: String) -> (events: [ServerSentEvent], remainder: String) {
        lock.lock()
        defer { lock.unlock() }
        let events = parser.parse(text)
        return (events, parser.bufferedRawRemainder)
    }
}
