//
//  HTTP2Frame.swift
//  TraceNetworking
//
//  Created by Justin on 2026/01/10.
//

import Foundation

/// Defines HTTP/2 frame types.
public enum HTTP2FrameType: UInt8, Sendable {
    case data = 0x0
    case headers = 0x1
    case priority = 0x2
    case rstStream = 0x3
    case settings = 0x4
    case pushPromise = 0x5
    case ping = 0x6
    case goaway = 0x7
    case windowUpdate = 0x8
    case continuation = 0x9

    /// Returns a human-readable description.
    public var description: String {
        switch self {
        case .data: "DATA"
        case .headers: "HEADERS"
        case .priority: "PRIORITY"
        case .rstStream: "RST_STREAM"
        case .settings: "SETTINGS"
        case .pushPromise: "PUSH_PROMISE"
        case .ping: "PING"
        case .goaway: "GOAWAY"
        case .windowUpdate: "WINDOW_UPDATE"
        case .continuation: "CONTINUATION"
        }
    }
}

/// Defines HTTP/2 frame flags.
public struct HTTP2FrameFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let endStream = HTTP2FrameFlags(rawValue: 0x1) // DATA, HEADERS
    public static let endHeaders = HTTP2FrameFlags(rawValue: 0x4) // HEADERS, PUSH_PROMISE, CONTINUATION
    public static let padded = HTTP2FrameFlags(rawValue: 0x8) // DATA, HEADERS, PUSH_PROMISE
    public static let priority = HTTP2FrameFlags(rawValue: 0x20) // HEADERS

    public static let ack = HTTP2FrameFlags(rawValue: 0x1) // SETTINGS, PING

    /// Returns a list of flag names for display.
    public func toStringArray() -> [String] {
        var flags: [String] = []
        if contains(.endStream) { flags.append("END_STREAM") }
        if contains(.endHeaders) { flags.append("END_HEADERS") }
        if contains(.padded) { flags.append("PADDED") }
        if contains(.priority) { flags.append("PRIORITY") }
        return flags
    }
}

/// Defines HTTP/2 error codes.
public enum HTTP2ErrorCode: UInt32, Sendable {
    case noError = 0x0
    case protocolError = 0x1
    case internalError = 0x2
    case flowControlError = 0x3
    case settingsTimeout = 0x4
    case streamClosed = 0x5
    case frameSizeError = 0x6
    case refusedStream = 0x7
    case cancel = 0x8
    case compressionError = 0x9
    case connectError = 0xA
    case enhanceYourCalm = 0xB
    case inadequateSecurity = 0xC
    case http11Required = 0xD
}

/// Defines HTTP/2 settings identifiers.
public enum HTTP2SettingIdentifier: UInt16, Sendable {
    case headerTableSize = 0x1
    case enablePush = 0x2
    case maxConcurrentStreams = 0x3
    case initialWindowSize = 0x4
    case maxFrameSize = 0x5
    case maxHeaderListSize = 0x6
}

/// Represents an HTTP/2 frame header.
public struct HTTP2FrameHeader: Sendable {
    public let length: UInt32 // 24 bits
    public let type: UInt8
    public let flags: UInt8
    public let streamId: UInt32 // 31 bits (1 bit reserved)

    public init(length: UInt32, type: UInt8, flags: UInt8, streamId: UInt32) {
        self.length = length
        self.type = type
        self.flags = flags
        self.streamId = streamId
    }

    public var frameType: HTTP2FrameType? {
        HTTP2FrameType(rawValue: type)
    }

    public var frameFlags: HTTP2FrameFlags {
        HTTP2FrameFlags(rawValue: flags)
    }

    /// Parses a frame header from data.
    public static func parse(from data: Data) -> HTTP2FrameHeader? {
        guard data.count >= 9 else { return nil }

        // Rule: Use startIndex when parsing Data because indices are not stable after mutation.
        let start = data.startIndex

        let length = UInt32(data[start]) << 16 | UInt32(data[start + 1]) << 8 | UInt32(data[start + 2])

        let type = data[start + 3]

        let flags = data[start + 4]

        let streamId =
            (UInt32(data[start + 5]) & 0x7F) << 24
                | UInt32(data[start + 6]) << 16
                | UInt32(data[start + 7]) << 8
                | UInt32(data[start + 8])

        return HTTP2FrameHeader(length: length, type: type, flags: flags, streamId: streamId)
    }

    /// Serializes the frame header to data.
    public func serialize() -> Data {
        var data = Data(capacity: 9)

        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))

        data.append(type)

        data.append(flags)

        data.append(UInt8((streamId >> 24) & 0x7F))
        data.append(UInt8((streamId >> 16) & 0xFF))
        data.append(UInt8((streamId >> 8) & 0xFF))
        data.append(UInt8(streamId & 0xFF))

        return data
    }

    public static let size = 9
}

/// Represents an HTTP/2 frame.
public struct HTTP2Frame: Sendable {
    public let header: HTTP2FrameHeader
    public let payload: Data

    public init(header: HTTP2FrameHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    /// Parses a complete frame from data with optional max frame size validation.
    /// - Parameters:
    ///   - data: Raw frame data including header.
    ///   - maxFrameSize: Maximum allowed frame size (default: 16384 per RFC 7540).
    ///   - validateSize: Whether to enforce max frame size (default: true).
    /// - Returns: A parsed frame or `nil` if invalid or incomplete.
    public static func parse(from data: Data, maxFrameSize: UInt32 = 16384, validateSize: Bool = true) -> HTTP2Frame? {
        guard let header = HTTP2FrameHeader.parse(from: data) else {
            return nil
        }

        // Rule: Validate frame size against SETTINGS_MAX_FRAME_SIZE (RFC 7540 §4.2).
        if validateSize && header.length > maxFrameSize {
            return nil
        }

        let payloadStartOffset = HTTP2FrameHeader.size
        let payloadEndOffset = payloadStartOffset + Int(header.length)

        guard data.count >= payloadEndOffset else {
            return nil
        }

        let start = data.startIndex
        let payloadStart = data.index(start, offsetBy: payloadStartOffset)
        let payloadEnd = data.index(start, offsetBy: payloadEndOffset)
        let payload = data[payloadStart ..< payloadEnd]

        return HTTP2Frame(header: header, payload: Data(payload))
    }

    /// Serializes the complete frame to data.
    public func serialize() -> Data {
        var data = header.serialize()
        data.append(payload)
        return data
    }

    /// Returns the total frame size (header + payload).
    public var totalSize: Int {
        HTTP2FrameHeader.size + Int(header.length)
    }
}

/// Represents HTTP/2 SETTINGS frame parameters.
public struct HTTP2Settings: Sendable {
    public var headerTableSize: UInt32 = 4096
    public var enablePush: Bool = true
    public var maxConcurrentStreams: UInt32?
    public var initialWindowSize: UInt32 = 65535
    public var maxFrameSize: UInt32 = 16384
    public var maxHeaderListSize: UInt32?

    /// RFC 7540 §6.5.2: Min and max values for SETTINGS_MAX_FRAME_SIZE.
    public static let minFrameSize: UInt32 = 16384 // 2^14
    public static let maxFrameSizeLimit: UInt32 = 16_777_215 // 2^24 - 1

    /// Parses settings from a SETTINGS frame payload.
    public static func parse(from data: Data) -> HTTP2Settings? {
        var settings = HTTP2Settings()

        var offset = data.startIndex
        while offset + 6 <= data.endIndex {
            let id = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let value =
                UInt32(data[offset + 2]) << 24
                    | UInt32(data[offset + 3]) << 16
                    | UInt32(data[offset + 4]) << 8
                    | UInt32(data[offset + 5])

            if let settingId = HTTP2SettingIdentifier(rawValue: id) {
                switch settingId {
                case .headerTableSize:
                    settings.headerTableSize = value
                case .enablePush:
                    settings.enablePush = (value != 0)
                case .maxConcurrentStreams:
                    settings.maxConcurrentStreams = value
                case .initialWindowSize:
                    // Rule: Max initial window size is 2^31-1 (RFC 7540 §6.5.2).
                    guard value <= 0x7FFF_FFFF else {
                        return nil
                    }
                    settings.initialWindowSize = value
                case .maxFrameSize:
                    // Rule: Validate frame size range (RFC 7540 §6.5.2).
                    guard value >= Self.minFrameSize && value <= Self.maxFrameSizeLimit else {
                        return nil
                    }
                    settings.maxFrameSize = value
                case .maxHeaderListSize:
                    settings.maxHeaderListSize = value
                }
            }

            offset += 6
        }

        return settings
    }

    /// Serializes settings to a SETTINGS frame payload.
    /// - Returns: Serialized settings data, or `nil` if invalid.
    public func serialize() -> Data? {
        guard maxFrameSize >= Self.minFrameSize && maxFrameSize <= Self.maxFrameSizeLimit else {
            return nil
        }
        guard initialWindowSize <= 0x7FFF_FFFF else {
            return nil
        }

        var data = Data()

        func addSetting(_ id: HTTP2SettingIdentifier, _ value: UInt32) {
            data.append(UInt8((id.rawValue >> 8) & 0xFF))
            data.append(UInt8(id.rawValue & 0xFF))

            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }

        addSetting(.headerTableSize, headerTableSize)
        addSetting(.enablePush, enablePush ? 1 : 0)
        if let max = maxConcurrentStreams {
            addSetting(.maxConcurrentStreams, max)
        }
        addSetting(.initialWindowSize, initialWindowSize)
        addSetting(.maxFrameSize, maxFrameSize)
        if let max = maxHeaderListSize {
            addSetting(.maxHeaderListSize, max)
        }

        return data
    }
}

/// Represents HTTP/2 stream priority information.
public struct HTTP2Priority: Sendable {
    public let exclusive: Bool
    public let streamDependency: UInt32
    public let weight: UInt8

    /// Parses a priority block from 5-byte data.
    public static func parse(from data: Data) -> HTTP2Priority? {
        guard data.count >= 5 else { return nil }

        // Rule: Use startIndex when parsing Data because indices are not stable after mutation.
        let start = data.startIndex

        let firstByte = UInt32(data[start])
        let exclusive = (firstByte & 0x80) != 0
        let streamDependency =
            ((firstByte & 0x7F) << 24)
                | UInt32(data[start + 1]) << 16
                | UInt32(data[start + 2]) << 8
                | UInt32(data[start + 3])

        let weight = data[start + 4]

        return HTTP2Priority(exclusive: exclusive, streamDependency: streamDependency, weight: weight)
    }

    /// Serializes the priority block to 5 bytes.
    public func serialize() -> Data {
        var data = Data(capacity: 5)

        let firstByte = (exclusive ? 0x80 : 0) | UInt8((streamDependency >> 24) & 0x7F)
        data.append(firstByte)
        data.append(UInt8((streamDependency >> 16) & 0xFF))
        data.append(UInt8((streamDependency >> 8) & 0xFF))
        data.append(UInt8(streamDependency & 0xFF))
        data.append(weight)

        return data
    }
}

/// Defines the HTTP/2 connection preface constants.
public enum HTTP2Preface {
    public static let clientPreface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".data(using: .ascii)!
    public static let length = 24

    /// Returns whether data starts with the HTTP/2 preface.
    public static func isHTTP2Preface(_ data: Data) -> Bool {
        guard data.count >= length else { return false }
        return data.prefix(length) == clientPreface
    }
}
