//
//  WebSocketHandler.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation
import Network
import TraceCore

/// Manages WebSocket connections and frame proxying.
///
/// Discussion: Detects WebSocket upgrades, parses frames, and relays messages bidirectionally.
public class WebSocketHandler {
    private let clientConnection: NWConnection
    private var serverConnection: NWConnection?

    private let url: String
    private let connectionID: UUID
    private var connection: WebSocketConnection

    private let persistenceQueue = DispatchQueue(label: "com.trace.websocket.handler.persist", qos: .utility)
    private var clientFrameBuffer = Data()
    private var serverFrameBuffer = Data()
    private var onConnectionUpdate: ((WebSocketConnection) -> Void)?
    private var clientContinuationType: WebSocketMessageType?
    private var serverContinuationType: WebSocketMessageType?
    private var clientContinuationPayload = Data()
    private var serverContinuationPayload = Data()
    private let stateQueue = DispatchQueue(label: "com.trace.websocket.handler.state", qos: .utility)
    private let stateQueueKey = DispatchSpecificKey<Void>()
    private let parseWarningThrottle = LogThrottle()
    private var closeRequested = false
    private var closeWorkItem: DispatchWorkItem?

    private let maxControlPayloadLength = 125
    private let maxContinuationPayloadBytes = 5 * 1024 * 1024
    private let closeDelaySeconds: TimeInterval = 0.2

    /// Initializes a WebSocket handler for a proxied connection.
    public init(
        clientConnection: NWConnection,
        serverConnection: NWConnection?,
        url: String,
        requestHeaders: [TraceHTTPHeader],
        responseHeaders: [TraceHTTPHeader]
    ) {
        self.clientConnection = clientConnection
        self.serverConnection = serverConnection
        self.url = Self.normalizedWebSocketURL(from: url)
        self.connectionID = UUID()

        self.connection = WebSocketConnection(
            id: connectionID,
            url: self.url,
            startTime: Date(),
            status: .open,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders
        )

        stateQueue.setSpecific(key: stateQueueKey, value: ())
    }

    // MARK: - Connection Management

    /// Starts the WebSocket handler and begins bidirectional proxying.
    /// - Parameters:
    ///   - onUpdate: Callback invoked whenever the captured connection is updated.
    ///   - initialClientData: Bytes already forwarded by the caller that must be parsed to preserve
    ///     frame boundaries on the client side.
    ///   - initialServerData: Bytes already forwarded by the caller that must be parsed to preserve
    ///     frame boundaries on the server side.
    public func start(
        onUpdate: @escaping (WebSocketConnection) -> Void,
        initialClientData: Data = Data(),
        initialServerData: Data = Data()
    ) {
        withState {
            self.onConnectionUpdate = onUpdate
            self.saveConnectionLocked()

            if !initialClientData.isEmpty {
                self.parseWebSocketFrame(initialClientData, direction: .sent)
            }
            if !initialServerData.isEmpty {
                self.parseWebSocketFrame(initialServerData, direction: .received)
            }
        }

        readFromClient()
        readFromServer()

        NetworkLog.webSocket.info("event=websocket.connection_open outcome=success url=\(self.url, privacy: .private(mask: .hash))")
    }

    /// Closes the WebSocket connection and persists the final snapshot.
    public func close(code: Int? = nil, reason: String? = nil) {
        var shouldClose = true
        withState {
            if self.connection.status == .closed || self.connection.status == .failed {
                shouldClose = false
            }
        }
        if !shouldClose { return }

        finalizeConnection(status: .closed, code: code, reason: reason)

        clientConnection.cancel()
        serverConnection?.cancel()

        NetworkLog.webSocket.info("event=websocket.connection_close outcome=success url=\(self.url, privacy: .private(mask: .hash))")
    }

    // MARK: - Client <-> Server Proxying

    private func readFromClient() {
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NetworkLog.webSocket.error("event=websocket.client_error outcome=failure error=\(error, privacy: .public)")
                self.failAndClose()
                return
            }

            if let data, !data.isEmpty {
                self.withState {
                    self.parseWebSocketFrame(data, direction: .sent)
                }

                // Rule: Forward bytes immediately to keep the proxy transparent.
                self.serverConnection?.send(content: data, completion: .contentProcessed { sendError in
                    if let sendError {
                        NetworkLog.webSocket.error("event=websocket.server_send outcome=failure error=\(sendError, privacy: .public)")
                        self.failAndClose()
                    }
                })
            }

            if !isComplete {
                self.readFromClient()
            } else {
                self.close()
            }
        }
    }

    private func readFromServer() {
        serverConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                NetworkLog.webSocket.error("event=websocket.server_error outcome=failure error=\(error, privacy: .public)")
                self.failAndClose()
                return
            }

            if let data, !data.isEmpty {
                self.withState {
                    self.parseWebSocketFrame(data, direction: .received)
                }

                // Rule: Forward bytes immediately to keep the proxy transparent.
                self.clientConnection.send(content: data, completion: .contentProcessed { sendError in
                    if let sendError {
                        NetworkLog.webSocket.error("event=websocket.client_send outcome=failure error=\(sendError, privacy: .public)")
                        self.failAndClose()
                    }
                })
            }

            if !isComplete {
                self.readFromServer()
            } else {
                self.close()
            }
        }
    }

    // MARK: - WebSocket Frame Parsing

    private func parseWebSocketFrame(_ data: Data, direction: WebSocketDirection) {
        switch direction {
        case .sent:
            clientFrameBuffer.append(data)
            while true {
                guard let result = extractFrame(from: &clientFrameBuffer) else { return }
                switch result {
                case let .frame(frame):
                    handleParsedFrame(frame, direction: direction)
                case .skipped:
                    continue
                }
            }
        case .received:
            serverFrameBuffer.append(data)
            while true {
                guard let result = extractFrame(from: &serverFrameBuffer) else { return }
                switch result {
                case let .frame(frame):
                    handleParsedFrame(frame, direction: direction)
                case .skipped:
                    continue
                }
            }
        }
    }

    private enum FrameParseResult {
        case frame(WebSocketFrame)
        case skipped
    }

    private func extractFrame(from buffer: inout Data) -> FrameParseResult? {
        guard buffer.count >= 2 else { return nil }

        // Rule: Use startIndex when parsing Data because indices are not stable after mutation.
        let start = buffer.startIndex

        let byte1 = buffer[start]
        let isFinal = (byte1 & 0x80) != 0
        let opcode = byte1 & 0x0F

        let messageType = WebSocketMessageType(opcode: opcode)
        let isUnknownOpcode = messageType == nil

        let byte2 = buffer[start + 1]
        let isMasked = (byte2 & 0x80) != 0
        var payloadLength = UInt64(byte2 & 0x7F)

        var cursor = start + 2

        if payloadLength == 126 {
            guard cursor + 2 <= buffer.endIndex else { return nil }
            payloadLength = UInt64(buffer[cursor]) << 8 | UInt64(buffer[cursor + 1])
            cursor += 2
        } else if payloadLength == 127 {
            guard cursor + 8 <= buffer.endIndex else { return nil }
            payloadLength =
                (UInt64(buffer[cursor]) << 56) | (UInt64(buffer[cursor + 1]) << 48)
                    | (UInt64(buffer[cursor + 2]) << 40) | (UInt64(buffer[cursor + 3]) << 32)
                    | (UInt64(buffer[cursor + 4]) << 24) | (UInt64(buffer[cursor + 5]) << 16)
                    | (UInt64(buffer[cursor + 6]) << 8) | UInt64(buffer[cursor + 7])
            cursor += 8
        }

        var maskingKey: [UInt8]?
        if isMasked {
            guard cursor + 4 <= buffer.endIndex else { return nil }
            maskingKey = Array(buffer[cursor ..< cursor + 4])
            cursor += 4
        }

        guard payloadLength <= UInt64(Int.max) else {
            if parseWarningThrottle.shouldLog(key: "websocket.frame_parse.payload_too_large.\(connectionID)", minInterval: 5) {
                NetworkLog.webSocket.warning("event=websocket.frame_parse outcome=failure error=payload_too_large")
            }
            buffer.removeAll()
            return .skipped
        }

        let payloadLengthInt = Int(payloadLength)
        guard cursor + payloadLengthInt <= buffer.endIndex else { return nil }

        var payload = Data(buffer[cursor ..< cursor + payloadLengthInt])
        cursor += payloadLengthInt

        if let key = maskingKey {
            for i in 0 ..< payload.count {
                payload[i] ^= key[i % 4]
            }
        }

        buffer.removeFirst(buffer.distance(from: start, to: cursor))

        if isUnknownOpcode {
            if parseWarningThrottle.shouldLog(key: "websocket.frame_parse.unknown_opcode.\(connectionID)", minInterval: 5) {
                NetworkLog.webSocket.warning("event=websocket.frame_parse outcome=failure error=unknown_opcode opcode=\(opcode, privacy: .public)")
            }
            return .skipped
        }

        guard let resolvedType = messageType else {
            return .skipped
        }

        if resolvedType == .ping || resolvedType == .pong || resolvedType == .close {
            if !isFinal {
                if parseWarningThrottle.shouldLog(key: "websocket.frame_parse.control_fragmented.\(connectionID)", minInterval: 5) {
                    NetworkLog.webSocket.warning("event=websocket.frame_parse outcome=failure error=control_fragmented opcode=\(opcode, privacy: .public)")
                }
                return .skipped
            }
            if payloadLengthInt > maxControlPayloadLength {
                if parseWarningThrottle.shouldLog(key: "websocket.frame_parse.control_too_large.\(connectionID)", minInterval: 5) {
                    NetworkLog.webSocket.warning("event=websocket.frame_parse outcome=failure error=control_too_large size=\(payloadLengthInt, privacy: .public)")
                }
                return .skipped
            }
        }

        return .frame(WebSocketFrame(
            isFinal: isFinal,
            type: resolvedType,
            isMasked: isMasked,
            payloadLength: payloadLengthInt,
            payload: payload
        ))
    }

    private func continuationState(
        for direction: WebSocketDirection
    ) -> (type: WebSocketMessageType?, payload: Data) {
        switch direction {
        case .sent:
            (clientContinuationType, clientContinuationPayload)
        case .received:
            (serverContinuationType, serverContinuationPayload)
        }
    }

    private func setContinuationState(
        for direction: WebSocketDirection,
        type: WebSocketMessageType?,
        payload: Data
    ) {
        switch direction {
        case .sent:
            clientContinuationType = type
            clientContinuationPayload = payload
        case .received:
            serverContinuationType = type
            serverContinuationPayload = payload
        }
    }

    private func handleParsedFrame(_ frame: WebSocketFrame, direction: WebSocketDirection) {
        var (continuationType, continuationPayload) = continuationState(for: direction)

        switch frame.type {
        case .continuation:
            guard let activeContinuationType = continuationType else {
                if parseWarningThrottle.shouldLog(key: "websocket.frame_parse.unexpected_continuation.\(connectionID)", minInterval: 5) {
                    NetworkLog.webSocket.warning("event=websocket.frame_parse outcome=failure error=unexpected_continuation")
                }
                return
            }

            if continuationPayload.count + frame.payload.count > maxContinuationPayloadBytes {
                if parseWarningThrottle.shouldLog(key: "websocket.frame_parse.continuation_overflow.\(connectionID)", minInterval: 5) {
                    NetworkLog.webSocket.warning("event=websocket.frame_parse outcome=failure error=continuation_overflow size=\(continuationPayload.count + frame.payload.count, privacy: .public)")
                }
                continuationType = nil
                continuationPayload.removeAll()
                break
            }

            continuationPayload.append(frame.payload)
            if frame.isFinal {
                emitMessage(
                    type: activeContinuationType,
                    payload: continuationPayload,
                    isFinal: true,
                    isMasked: frame.isMasked,
                    direction: direction
                )
                continuationType = nil
                continuationPayload.removeAll()
            }

        case .text, .binary:
            if frame.isFinal {
                emitMessage(
                    type: frame.type,
                    payload: frame.payload,
                    isFinal: true,
                    isMasked: frame.isMasked,
                    direction: direction
                )
            } else {
                if frame.payload.count > maxContinuationPayloadBytes {
                    if parseWarningThrottle.shouldLog(key: "websocket.frame_parse.continuation_overflow.\(connectionID)", minInterval: 5) {
                        NetworkLog.webSocket.warning("event=websocket.frame_parse outcome=failure error=continuation_overflow size=\(frame.payload.count, privacy: .public)")
                    }
                    continuationType = nil
                    continuationPayload.removeAll()
                    break
                }
                continuationType = frame.type
                continuationPayload = frame.payload
            }

        case .ping, .pong, .close:
            emitMessage(
                type: frame.type,
                payload: frame.payload,
                isFinal: frame.isFinal,
                isMasked: frame.isMasked,
                direction: direction
            )

            if frame.type == .close {
                let closeCode = extractCloseCode(from: frame.payload)
                let closeReason = extractCloseReason(from: frame.payload)
                scheduleClose(code: closeCode, reason: closeReason)
            }
        }

        setContinuationState(for: direction, type: continuationType, payload: continuationPayload)
    }

    private func emitMessage(
        type: WebSocketMessageType,
        payload: Data,
        isFinal: Bool,
        isMasked: Bool,
        direction: WebSocketDirection
    ) {
        let message = WebSocketMessage(
            direction: direction,
            timestamp: Date(),
            payload: payload,
            messageType: type,
            isFinal: isFinal,
            isMasked: isMasked,
            payloadLength: payload.count
        )
        connection.addMessage(message)
        saveConnectionLocked()
    }

    private func extractCloseCode(from payload: Data) -> Int? {
        guard payload.count >= 2 else { return nil }
        return Int(payload[0]) << 8 | Int(payload[1])
    }

    private func extractCloseReason(from payload: Data) -> String? {
        guard payload.count > 2 else { return nil }
        let reasonData = payload.subdata(in: 2 ..< payload.count)
        return String(data: reasonData, encoding: .utf8)
    }

    // MARK: - Storage

    private func saveConnectionLocked() {
        let snapshot = connection
        onConnectionUpdate?(snapshot)

        persistenceQueue.async {
            do {
                try AppGroupStorage.shared.saveWebSocketConnection(snapshot)
            } catch {
                NetworkLog.webSocket.error("event=websocket.storage_save outcome=failure error=\(error, privacy: .public)")
            }
        }
    }

    private func failAndClose() {
        finalizeConnection(status: .failed, code: nil, reason: nil)
        clientConnection.cancel()
        serverConnection?.cancel()
    }

    private func finalizeConnection(status: WebSocketConnectionStatus, code: Int?, reason: String?) {
        withState {
            switch status {
            case .closed:
                self.connection.close(code: code, reason: reason)
            case .failed:
                self.connection.status = .failed
                self.connection.endTime = Date()
                self.connection.closeCode = code
                self.connection.closeReason = reason
            default:
                break
            }

            self.saveConnectionLocked()
            self.onConnectionUpdate = nil
            self.closeWorkItem?.cancel()
            self.closeWorkItem = nil
        }
    }

    private func scheduleClose(code: Int?, reason: String?) {
        withState {
            if self.closeRequested { return }
            self.closeRequested = true
            self.connection.status = .closing
            self.connection.closeCode = code
            self.connection.closeReason = reason
            self.saveConnectionLocked()

            let work = DispatchWorkItem { [weak self] in
                self?.close(code: code, reason: reason)
            }
            self.closeWorkItem?.cancel()
            self.closeWorkItem = work
            self.stateQueue.asyncAfter(deadline: .now() + self.closeDelaySeconds, execute: work)
        }
    }

    private func withState(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            work()
        } else {
            stateQueue.sync(execute: work)
        }
    }

    private static func normalizedWebSocketURL(from url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        guard let scheme = components.scheme?.lowercased() else { return url }
        switch scheme {
        case "http":
            components.scheme = "ws"
            return components.string ?? url
        case "https":
            components.scheme = "wss"
            return components.string ?? url
        default:
            return url
        }
    }

    #if DEBUG
    /// Test-only hook to parse frames without starting network reads.
    func testProcess(_ data: Data, direction: WebSocketDirection) {
        withState {
            self.parseWebSocketFrame(data, direction: direction)
        }
    }

    /// Test-only hook to inspect the current connection snapshot.
    func testConnectionSnapshot() -> WebSocketConnection {
        var snapshot: WebSocketConnection?
        withState {
            snapshot = self.connection
        }
        return snapshot ?? self.connection
    }
    #endif
}

// MARK: - WebSocket Frame Structure

/// Represents a parsed WebSocket frame.
public struct WebSocketFrame {
    public let isFinal: Bool
    public let type: WebSocketMessageType
    public let isMasked: Bool
    public let payloadLength: Int
    public let payload: Data
}
