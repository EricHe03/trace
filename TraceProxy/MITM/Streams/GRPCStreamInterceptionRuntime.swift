//
//  GRPCStreamInterceptionRuntime.swift
//  TraceProxy
//
//  Per-stream interception runtime for gRPC length-prefixed message frames.
//  Mirrors the SSEInterceptionRuntime pattern exactly.
//

import Foundation
import NIOCore
import TraceCore

final class GRPCStreamInterceptionRuntime: @unchecked Sendable {
    private struct InterceptionContext {
        let runtime: StreamSessionRuntime
        let streamEvent: StreamEvent
        let rawFrame: Data          // Original 5-byte header + payload (for .forward)
        let payload: Data           // Just the protobuf payload (for .modify)
        let isCompressed: Bool
        let eventRecorder: @Sendable (StreamEvent) -> Void
    }

    private let frameBuffer = GRPCFrameBuffer()
    private let lock = NSLock()

    // MARK: - Main Entry Point

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

        let extracted = frameBuffer.append(chunk)

        // If there are no complete data frames and no trailer, forward the raw chunk unchanged.
        guard !extracted.dataFrames.isEmpty || !extracted.trailerFrames.isEmpty else {
            return eventLoop.makeSucceededFuture(chunk)
        }

        // Handle any gRPC-Web trailer embedded in the body (updates session metadata).
        for trailerFrame in extracted.trailerFrames {
            handleTrailerPayload(trailerFrame.payload, runtime: runtime)
        }

        guard !extracted.dataFrames.isEmpty else {
            // Trailer-only chunks must still be forwarded verbatim to the client.
            return eventLoop.makeSucceededFuture(rawOutput(from: extracted))
        }

        // Chain futures for each complete frame.
        var chain = eventLoop.makeSucceededFuture((output: Data(), changed: false))

        for frame in extracted.dataFrames {
            chain = chain.flatMap { state in
                let streamEvent = runtime.makeEvent(
                    direction: .received,
                    kind: .message,
                    payload: .binary(frame.payload, contentType: "application/grpc")
                )

                return decisionProvider(runtime.snapshot(), streamEvent, eventLoop)
                    .flatMap { decision in
                        self.applyDecision(
                            decision,
                            context: InterceptionContext(
                                runtime: runtime,
                                streamEvent: streamEvent,
                                rawFrame: frame.rawFrame,
                                payload: frame.payload,
                                isCompressed: frame.isCompressed,
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
                var output = state.output
                self.appendTrailerFrames(from: extracted, to: &output)
                return output
            }
            // Nothing modified — re-assemble and forward original frame bytes.
            return self.rawOutput(from: extracted)
        }
    }

    // MARK: - Decision Application

    private func applyDecision(
        _ decision: StreamInterceptionDecision,
        context: InterceptionContext,
        state: (output: Data, changed: Bool),
        replayEngine: StreamReplayEngine,
        eventLoop: EventLoop
    ) -> EventLoopFuture<(output: Data, changed: Bool)> {
        switch decision {
        case .forward:
            context.eventRecorder(context.streamEvent)
            var output = state.output
            output.append(context.rawFrame)
            return eventLoop.makeSucceededFuture((output, state.changed))

        case let .modify(mutation):
            let newPayload = mutation.payload?.binary ?? context.payload
            var recordedEvent = context.streamEvent
            recordedEvent.payload = .binary(newPayload, contentType: mutation.payload?.contentType ?? "application/grpc")
            recordedEvent.wasModified = true
            recordedEvent.metadata = context.streamEvent.metadata.merging(mutation.metadata) { _, new in new }
            context.eventRecorder(recordedEvent)
            var output = state.output
            output.append(makeGRPCFrame(payload: newPayload, compressed: context.isCompressed))
            return eventLoop.makeSucceededFuture((output, true))

        case .block, .drop:
            var recordedEvent = context.streamEvent
            recordedEvent.wasBlocked = true
            context.eventRecorder(recordedEvent)
            return eventLoop.makeSucceededFuture((state.output, true))

        case let .inject(mutations):
            context.eventRecorder(context.streamEvent)
            var output = state.output
            output.append(context.rawFrame)
            for mutation in mutations {
                let injectedPayload = mutation.payload?.binary ?? Data()
                let injectedEvent = context.runtime.makeEvent(
                    direction: .received,
                    kind: .message,
                    payload: .binary(injectedPayload, contentType: mutation.payload?.contentType ?? "application/grpc"),
                    wasModified: true,
                    metadata: ["injected": "true"].merging(mutation.metadata) { _, new in new }
                )
                context.eventRecorder(injectedEvent)
                output.append(makeGRPCFrame(payload: injectedPayload, compressed: false))
            }
            return eventLoop.makeSucceededFuture((output, true))

        case let .replay(spec):
            context.eventRecorder(context.streamEvent)
            return replayEngine.beginReplay(spec, eventLoop: eventLoop)
                .flatMap { replayID in
                    replayEngine.loadReplayEvents(spec, eventLoop: eventLoop)
                        .flatMap { replayEvents in
                            var replayedCount = 0
                            var output = state.output
                            output.append(context.rawFrame)
                            for replayEvent in replayEvents {
                                let replayPayload = replayEvent.payload.binary ?? Data()
                                let recordedEvent = context.runtime.makeEvent(
                                    direction: replayEvent.direction,
                                    kind: .replay,
                                    payload: .binary(replayPayload, contentType: "application/grpc"),
                                    wasModified: true,
                                    metadata: ["replay": "true"]
                                )
                                context.eventRecorder(recordedEvent)
                                output.append(self.makeGRPCFrame(payload: replayPayload, compressed: false))
                                replayedCount += 1
                            }
                            return replayEngine.finishReplay(
                                StreamReplayResult(
                                    replayID: replayID,
                                    sessionID: spec.sessionID,
                                    succeeded: true,
                                    replayedEvents: replayedCount,
                                    startedAt: spec.startedAt,
                                    endedAt: Date()
                                ),
                                eventLoop: eventLoop
                            ).map { (output, true) }
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
                                var output = state.output
                                output.append(context.rawFrame)
                                return (output, true)
                            }
                        }
                }
        }
    }

    // MARK: - Helpers

    private func handleTrailerPayload(_ trailerData: Data, runtime: StreamSessionRuntime) {
        // Parse gRPC-Web trailer frame payload as HTTP header lines.
        guard let text = String(data: trailerData, encoding: .ascii) ?? String(data: trailerData, encoding: .utf8) else { return }
        var metadata: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex ..< colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            metadata["grpc_\(key.replacingOccurrences(of: "-", with: "_"))"] = value
        }
        if !metadata.isEmpty {
            runtime.mergeMetadata(metadata)
        }
    }

    private func rawOutput(from extracted: GRPCCompleteFrames) -> Data {
        var output = Data()
        for frame in extracted.dataFrames {
            output.append(frame.rawFrame)
        }
        appendTrailerFrames(from: extracted, to: &output)
        return output
    }

    private func appendTrailerFrames(from extracted: GRPCCompleteFrames, to output: inout Data) {
        for trailerFrame in extracted.trailerFrames {
            output.append(trailerFrame.rawFrame)
        }
    }

    /// Reconstruct a gRPC frame from its payload.
    private func makeGRPCFrame(payload: Data, compressed: Bool) -> Data {
        var frame = Data(count: 5 + payload.count)
        frame[0] = compressed ? 1 : 0
        let len = UInt32(payload.count)
        frame[1] = UInt8((len >> 24) & 0xFF)
        frame[2] = UInt8((len >> 16) & 0xFF)
        frame[3] = UInt8((len >> 8) & 0xFF)
        frame[4] = UInt8(len & 0xFF)
        frame.replaceSubrange(5..., with: payload)
        return frame
    }
}
