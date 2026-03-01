//
//  NIOMITMWebSocketCaptureState.swift
//  TraceProxy
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

    var sentContinuationType: WebSocketMessageType?
    var sentContinuationPayload = Data()
    var receivedContinuationType: WebSocketMessageType?
    var receivedContinuationPayload = Data()

    let maxContinuationPayloadBytes = 5 * 1024 * 1024

    init(url: String, requestHeaders: [TraceHTTPHeader]) {
        connection = WebSocketConnection(
            id: UUID(),
            url: url,
            startTime: Date(),
            status: .connecting,
            requestHeaders: requestHeaders
        )
        persist(connection)
    }

    func markOpen(responseHeaders: [TraceHTTPHeader]) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        connection.status = .open
        connection.responseHeaders = responseHeaders
        persist(connection)
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
                    direction: direction
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
                    direction: direction
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
                direction: direction
            )
            if frameType == .close {
                connection.status = .closing
                connection.closeCode = extractCloseCode(from: payload)
                connection.closeReason = extractCloseReason(from: payload)
            }
        }

        setContinuation(type: continuationType, payload: continuationPayload, for: direction)
        persist(connection)
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
    }

    func markFailed() {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        finalized = true
        connection.status = .failed
        connection.endTime = Date()
        persist(connection)
    }

    func appendMessage(
        type: WebSocketMessageType,
        payload: Data,
        isFinal: Bool,
        isMasked: Bool,
        direction: WebSocketDirection
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
}
