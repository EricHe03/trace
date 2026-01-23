//
//  WebSocketMessage.swift
//  TraceCore
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Direction of a WebSocket message
public enum WebSocketDirection: String, Codable, CaseIterable {
    case sent
    case received

    public var displayName: String {
        switch self {
        case .sent: "Sent"
        case .received: "Received"
        }
    }

    public var symbol: String {
        switch self {
        case .sent: "↑"
        case .received: "↓"
        }
    }

    public var color: StatusColor {
        switch self {
        case .sent: .info
        case .received: .success
        }
    }
}

/// Type of WebSocket message frame
public enum WebSocketMessageType: String, Codable, CaseIterable, Equatable {
    case text
    case binary
    case ping
    case pong
    case close
    case continuation

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .binary: "Binary"
        case .ping: "Ping"
        case .pong: "Pong"
        case .close: "Close"
        case .continuation: "Continuation"
        }
    }

    public var opcode: UInt8 {
        switch self {
        case .continuation: 0x0
        case .text: 0x1
        case .binary: 0x2
        case .close: 0x8
        case .ping: 0x9
        case .pong: 0xA
        }
    }

    public init?(opcode: UInt8) {
        switch opcode {
        case 0x0: self = .continuation
        case 0x1: self = .text
        case 0x2: self = .binary
        case 0x8: self = .close
        case 0x9: self = .ping
        case 0xA: self = .pong
        default: return nil
        }
    }
}

/// Individual WebSocket message
public struct WebSocketMessage: Identifiable, Codable, Equatable {
    public let id: UUID
    public var direction: WebSocketDirection
    public var timestamp: Date
    public var payload: Data
    public var messageType: WebSocketMessageType
    public var isFinal: Bool
    public var isMasked: Bool
    public var payloadLength: Int

    public init(
        id: UUID = UUID(),
        direction: WebSocketDirection,
        timestamp: Date = Date(),
        payload: Data,
        messageType: WebSocketMessageType,
        isFinal: Bool = true,
        isMasked: Bool = false,
        payloadLength: Int? = nil
    ) {
        self.id = id
        self.direction = direction
        self.timestamp = timestamp
        self.payload = payload
        self.messageType = messageType
        self.isFinal = isFinal
        self.isMasked = isMasked
        self.payloadLength = payloadLength ?? payload.count
    }

    /// Get the message payload as a string (for text messages)
    public var textPayload: String? {
        guard messageType == .text else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    /// Get the message payload as hex string (for binary messages)
    public var hexPayload: String {
        payload.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Human-readable size
    public var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(payloadLength), countStyle: .file)
    }

    /// Preview of the payload for display
    public var preview: String {
        if messageType == .text, let text = textPayload {
            let maxLength = 100
            if text.count > maxLength {
                return String(text.prefix(maxLength)) + "..."
            }
            return text
        } else if messageType == .binary {
            let maxBytes = 20
            let bytes = payload.prefix(maxBytes)
            let hexString = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            return payload.count > maxBytes ? hexString + "..." : hexString
        } else if messageType == .ping || messageType == .pong {
            return "[\(messageType.displayName)]"
        } else if messageType == .close {
            return "[Close Frame]"
        }
        return "[Unknown]"
    }
}

// MARK: - Equatable conformance

public extension WebSocketMessage {
    static func == (lhs: WebSocketMessage, rhs: WebSocketMessage) -> Bool {
        lhs.id == rhs.id
    }
}
