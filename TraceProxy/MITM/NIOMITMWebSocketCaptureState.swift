//
//  NIOMITMWebSocketCaptureState.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/20.
//
import Foundation
import NIOCore
import NIOWebSocket
import TraceCore

final class NIOMITMWebSocketCaptureState: @unchecked Sendable {
    static let persistenceQueue = DispatchQueue(
        label: "com.trace.proxy.nio.websocket.capture.persist",
        qos: .utility
    )

    let lock = NSLock()
    var connection: WebSocketConnection
    var finalized = false
    var streamSequence: Int64 = 0

    var sentContinuationType: WebSocketMessageType?
    var sentContinuationPayload = Data()
    var receivedContinuationType: WebSocketMessageType?
    var receivedContinuationPayload = Data()

    let maxContinuationPayloadBytes = 5 * 1024 * 1024

    init(url: String, requestHeaders: [TraceHTTPHeader], sessionID: UUID? = nil) {
        connection = WebSocketConnection(
            id: sessionID ?? UUID(),
            url: url,
            startTime: Date(),
            status: .connecting,
            requestHeaders: requestHeaders
        )
        persist(connection)
        persistStreamSession(
            StreamSession(
                id: connection.id,
                protocolType: .websocket,
                url: connection.url,
                startTime: connection.startTime,
                endTime: connection.endTime,
                status: .connecting,
                requestHeaders: connection.requestHeaders,
                responseHeaders: connection.responseHeaders,
                metadata: [:],
                eventCount: 0,
                bytesIn: 0,
                bytesOut: 0
            )
        )
    }

    func markOpen(responseHeaders: [TraceHTTPHeader]) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        connection.status = .open
        connection.responseHeaders = responseHeaders
        persist(connection)
        persistStreamSession(currentStreamSession(status: .open))
    }

    func recordFrame(_ frame: WebSocketFrame, direction: WebSocketDirection) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        guard let frameType = websocketMessageType(for: frame.opcode) else { return }

        var continuationType = continuationType(for: direction)
        var continuationPayload = continuationPayload(for: direction)
        let payload = payloadData(from: frame)

        switch frameType {
        case .continuation:
            guard let activeType = continuationType else { return }
            let candidateSize = continuationPayload.count + payload.count
            guard candidateSize <= maxContinuationPayloadBytes else {
                continuationType = nil
                continuationPayload.removeAll(keepingCapacity: false)
                setContinuation(type: continuationType, payload: continuationPayload, for: direction)
                return
            }
            continuationPayload.append(payload)
            if frame.fin {
                appendMessage(
                    type: activeType,
                    payload: continuationPayload,
                    isFinal: true,
                    isMasked: frame.maskKey != nil,
                    direction: direction,
                    wasModified: false,
                    wasBlocked: false
                )
                continuationType = nil
                continuationPayload.removeAll(keepingCapacity: false)
            }
        case .text, .binary:
            if frame.fin {
                appendMessage(
                    type: frameType,
                    payload: payload,
                    isFinal: true,
                    isMasked: frame.maskKey != nil,
                    direction: direction,
                    wasModified: false,
                    wasBlocked: false
                )
            } else {
                guard payload.count <= maxContinuationPayloadBytes else {
                    continuationType = nil
                    continuationPayload.removeAll(keepingCapacity: false)
                    setContinuation(type: continuationType, payload: continuationPayload, for: direction)
                    return
                }
                continuationType = frameType
                continuationPayload = payload
            }
        case .ping, .pong, .close:
            appendMessage(
                type: frameType,
                payload: payload,
                isFinal: frame.fin,
                isMasked: frame.maskKey != nil,
                direction: direction,
                wasModified: false,
                wasBlocked: false
            )
            if frameType == .close {
                connection.status = .closing
                connection.closeCode = extractCloseCode(from: payload)
                connection.closeReason = extractCloseReason(from: payload)
            }
        }

        setContinuation(type: continuationType, payload: continuationPayload, for: direction)
        persist(connection)
        persistStreamSession(currentStreamSession(status: streamStatus(for: connection.status)))
    }

    func recordMessage(
        type: WebSocketMessageType,
        payload: Data,
        isFinal: Bool,
        isMasked: Bool,
        direction: WebSocketDirection,
        wasModified: Bool,
        wasBlocked: Bool,
        metadata: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }

        appendMessage(
            type: type,
            payload: payload,
            isFinal: isFinal,
            isMasked: isMasked,
            direction: direction,
            wasModified: wasModified,
            wasBlocked: wasBlocked,
            additionalMetadata: metadata
        )

        if type == .close {
            connection.status = .closing
            connection.closeCode = extractCloseCode(from: payload)
            connection.closeReason = extractCloseReason(from: payload)
        }

        persist(connection)
        persistStreamSession(currentStreamSession(status: streamStatus(for: connection.status)))
    }

    func markClosed(code: Int?, reason: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        connection.status = .closed
        connection.endTime = Date()
        if let code {
            connection.closeCode = code
        }
        if let reason {
            connection.closeReason = reason
        }
        persist(connection)
        persistStreamSession(currentStreamSession(status: .closed))
    }

    func markFailed() {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        connection.status = .failed
        connection.endTime = Date()
        persist(connection)
        persistStreamSession(currentStreamSession(status: .failed))
    }

    func appendMessage(
        type: WebSocketMessageType,
        payload: Data,
        isFinal: Bool,
        isMasked: Bool,
        direction: WebSocketDirection,
        wasModified: Bool = false,
        wasBlocked: Bool = false,
        additionalMetadata: [String: String] = [:]
    ) {
        connection.addMessage(
            WebSocketMessage(
                direction: direction,
                timestamp: Date(),
                payload: payload,
                messageType: type,
                isFinal: isFinal,
                isMasked: isMasked,
                payloadLength: payload.count
            )
        )
        streamSequence += 1
        let payloadText = type == .text ? String(data: payload, encoding: .utf8) : nil
        let streamEvent = StreamEvent(
            sessionID: connection.id,
            sequence: streamSequence,
            direction: direction == .sent ? .sent : .received,
            kind: streamEventKind(for: type),
            payload: StreamEventPayload(
                text: payloadText,
                binary: payload,
                contentType: type == .text ? "text/plain; charset=utf-8" : "application/octet-stream",
                encoding: type == .text ? "utf-8" : nil
            ),
            wasModified: wasModified,
            wasBlocked: wasBlocked,
            metadata: [
                "message_type": type.rawValue,
                "is_final": isFinal ? "true" : "false",
                "is_masked": isMasked ? "true" : "false",
                "payload_length": String(payload.count)
            ].merging(additionalMetadata) { _, new in new }
        )
        persistStreamEvent(streamEvent)
    }

    func continuationType(for direction: WebSocketDirection) -> WebSocketMessageType? {
        switch direction {
        case .sent:
            sentContinuationType
        case .received:
            receivedContinuationType
        }
    }

    func continuationPayload(for direction: WebSocketDirection) -> Data {
        switch direction {
        case .sent:
            sentContinuationPayload
        case .received:
            receivedContinuationPayload
        }
    }

    func setContinuation(type: WebSocketMessageType?, payload: Data, for direction: WebSocketDirection) {
        switch direction {
        case .sent:
            sentContinuationType = type
            sentContinuationPayload = payload
        case .received:
            receivedContinuationType = type
            receivedContinuationPayload = payload
        }
    }

    func payloadData(from frame: WebSocketFrame) -> Data {
        var payloadBuffer = frame.unmaskedData
        return payloadBuffer.readData(length: payloadBuffer.readableBytes) ?? Data()
    }

    func websocketMessageType(for opcode: WebSocketOpcode) -> WebSocketMessageType? {
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

    func extractCloseCode(from payload: Data) -> Int? {
        guard payload.count >= 2 else { return nil }
        return Int(payload[0]) << 8 | Int(payload[1])
    }

    func extractCloseReason(from payload: Data) -> String? {
        guard payload.count > 2 else { return nil }
        return String(data: payload.subdata(in: 2 ..< payload.count), encoding: .utf8)
    }

    func persist(_ snapshot: WebSocketConnection) {
        Self.persistenceQueue.async {
            do {
                try AppGroupStorage.shared.saveWebSocketConnection(snapshot)
            } catch {
                ProxyLog.mitm.warning(
                    "event=proxy.nio_ws_capture_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func persistStreamSession(_ session: StreamSession) {
        Self.persistenceQueue.async {
            do {
                try AppGroupStorage.shared.upsertStreamSession(session)
            } catch {
                ProxyLog.mitm.warning(
                    "event=proxy.nio_ws_stream_session_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func persistStreamEvent(_ event: StreamEvent) {
        Self.persistenceQueue.async {
            do {
                try AppGroupStorage.shared.appendStreamEvent(event)
            } catch {
                ProxyLog.mitm.warning(
                    "event=proxy.nio_ws_stream_event_persist outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func currentStreamSession(status: StreamSessionStatus) -> StreamSession {
        let bytesIn = connection.messages
            .filter { $0.direction == .received }
            .reduce(into: 0) { $0 += $1.payloadLength }
        let bytesOut = connection.messages
            .filter { $0.direction == .sent }
            .reduce(into: 0) { $0 += $1.payloadLength }

        var metadata: [String: String] = [:]
        if let closeCode = connection.closeCode {
            metadata["close_code"] = String(closeCode)
        }
        if let closeReason = connection.closeReason {
            metadata["close_reason"] = closeReason
        }

        return StreamSession(
            id: connection.id,
            protocolType: .websocket,
            url: connection.url,
            startTime: connection.startTime,
            endTime: connection.endTime,
            status: status,
            requestHeaders: connection.requestHeaders,
            responseHeaders: connection.responseHeaders,
            metadata: metadata,
            eventCount: connection.messages.count,
            bytesIn: bytesIn,
            bytesOut: bytesOut
        )
    }

    func streamStatus(for status: WebSocketConnectionStatus) -> StreamSessionStatus {
        switch status {
        case .connecting:
            .connecting
        case .open:
            .open
        case .closing:
            .closing
        case .closed:
            .closed
        case .failed:
            .failed
        }
    }

    func streamEventKind(for messageType: WebSocketMessageType) -> StreamEventKind {
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
}
